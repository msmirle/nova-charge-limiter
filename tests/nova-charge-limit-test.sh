#!/usr/bin/bash
# Exercises nova-charge-limit against a fake sysfs tree.
set -uo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tool="$repo/nova-charge-limit"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failures=0
check() {
    local name=$1
    shift
    if "$@"; then
        echo "ok   $name"
    else
        echo "FAIL $name"
        failures=$((failures + 1))
    fi
}
fails() { ! "$@"; }
exits() {
    local code=$1
    shift
    "$@"
    (($? == code))
}

# Fresh fake sysfs + config for each case.
setup() {
    rm -rf "${work:?}/sys" "${work:?}/etc"
    mkdir -p "$work/sys/class/power_supply/usb" "$work/sys/firmware/devicetree/base" "$work/etc"
    printf 'Retroid Pocket Nova\0' >"$work/sys/firmware/devicetree/base/model"
    echo USB >"$work/sys/class/power_supply/usb/type"
    make_battery "${1:-battery}"
    cp "$repo/nova-charge-limit.conf" "$work/etc/nova-charge-limit.conf"
}

make_battery() {
    local dir="$work/sys/class/power_supply/$1"
    mkdir -p "$dir"
    echo Battery >"$dir/type"
    echo 64 >"$dir/capacity"
    echo Charging >"$dir/status"
    echo 100 >"$dir/charge_control_end_threshold"
    echo 95 >"$dir/charge_control_start_threshold"
}

run() {
    NOVA_CHARGE_LIMIT_SYS_ROOT="$work/sys" \
        NOVA_CHARGE_LIMIT_CONFIG="$work/etc/nova-charge-limit.conf" \
        NOVA_CHARGE_LIMIT_WAIT=0 \
        NOVA_CHARGE_LIMIT_RETRY_DELAY=0 \
        NOVA_CHARGE_LIMIT_ALLOW_NONROOT=${allow_nonroot:-1} \
        "$tool" "$@" >"$work/out" 2>&1
}

thresholds() {
    local dir="$work/sys/class/power_supply/${3:-battery}"
    [[ $(<"$dir/charge_control_end_threshold") == "$1" && $(<"$dir/charge_control_start_threshold") == "$2" ]]
}

config_has() { grep -qx -- "$1" "$work/etc/nova-charge-limit.conf"; }
config_untouched() { cmp -s "$repo/nova-charge-limit.conf" "$work/etc/nova-charge-limit.conf"; }
output_has() { grep -qF -- "$1" "$work/out"; }

# --- apply ---------------------------------------------------------------
setup
check "apply: default config gives 80/75" run apply
check "apply: thresholds written" thresholds 80 75
check "apply: reports the result" output_has "charging stops at 80% and resumes below 75%"

setup
printf 'CHARGE_LIMIT="85"\r\nCHARGE_RESUME = 70 \r\n' >"$work/etc/nova-charge-limit.conf"
check "apply: tolerates quotes, spaces and CRLF" run apply
check "apply: CRLF config thresholds" thresholds 85 70

setup
echo 'CHARGE_LIMIT=eighty' >"$work/etc/nova-charge-limit.conf"
check "apply: rejects a non-numeric limit" fails run apply
check "apply: explains a non-numeric limit" output_has "the limit must be 55-100, got 'eighty'"
check "apply: leaves thresholds alone on bad config" thresholds 100 95

setup
echo 'CHARGE_LIMIT=80 extra' >"$work/etc/nova-charge-limit.conf"
check "apply: rejects an unparsable line" fails run apply
check "apply: explains the unparsable line" output_has "cannot parse line"

setup
echo '# nothing set' >"$work/etc/nova-charge-limit.conf"
check "apply: requires CHARGE_LIMIT" fails run apply
check "apply: explains missing CHARGE_LIMIT" output_has "CHARGE_LIMIT is not set"

setup
rm -f "$work/etc/nova-charge-limit.conf"
check "apply: fails without a config" fails run apply

setup
rm -rf "$work/sys/class/power_supply/battery"
check "apply: fails when no battery appears" fails run apply
check "apply: explains the missing battery" output_has "no battery with charge control appeared"

setup qcom-battmgr-bat
check "apply: finds a battery by type when not named 'battery'" run apply
check "apply: fallback battery thresholds" thresholds 80 75 qcom-battmgr-bat

setup
rm -f "$work/sys/class/power_supply/battery/charge_control_start_threshold"
check "apply: works without a start threshold" run apply
check "apply: end-only battery" test "$(<"$work/sys/class/power_supply/battery/charge_control_end_threshold")" = 80

if ((EUID != 0)); then
    setup
    chmod 444 "$work/sys/class/power_supply/battery/charge_control_end_threshold"
    check "apply: fails when the firmware rejects the write" fails run apply
    check "apply: explains the rejected write" output_has "the charger did not accept limit 80%/resume 75%"

    setup
    allow_nonroot=0
    check "apply: requires root" fails run apply
    check "apply: asks for sudo" output_has "run this command with sudo"
    unset allow_nonroot
fi

# --- set / off -----------------------------------------------------------
setup
check "set: 85" run set 85
check "set: 85 thresholds" thresholds 85 80
check "set: saves the limit" config_has "CHARGE_LIMIT=85"
check "set: keeps the default resume" config_has "CHARGE_RESUME="

setup
check "set: 90 70" run set 90 70
check "set: 90 70 thresholds" thresholds 90 70
check "set: saves the resume point" config_has "CHARGE_RESUME=70"

setup
check "set: 55 clamps the default resume to 50" run set 55
check "set: 55 thresholds" thresholds 55 50

setup
check "set: normalises leading zeros" run set 080
check "set: 080 thresholds" thresholds 80 75
check "set: 080 saved as 80" config_has "CHARGE_LIMIT=80"

for bad in "54" "101" "abc" "-5" "1000" "80 80" "80 96" "80 49" "80 x"; do
    setup
    # shellcheck disable=SC2086
    check "set: rejects '$bad'" fails run set $bad
    check "set: '$bad' leaves the config alone" config_untouched
    check "set: '$bad' leaves thresholds alone" thresholds 100 95
done

setup
rm -rf "$work/sys/class/power_supply/battery"
check "set: fails without charge control" fails run set 80
check "set: no battery leaves the config alone" config_untouched

setup
run set 90 70
check "off: lifts the limit" run off
check "off: thresholds 100/95" thresholds 100 95
check "off: saves 100" config_has "CHARGE_LIMIT=100"
check "off: clears the resume point" config_has "CHARGE_RESUME="

setup
run set 85
run set 80
check "set: rewrites the shipped default byte for byte" config_untouched

# --- status / usage ------------------------------------------------------
setup
run apply
check "status: succeeds" run status
check "status: shows the device" output_has "Device:      Retroid Pocket Nova"
check "status: shows the config" output_has "Configured:  stop at 80%, resume below 75%"
check "status: shows the battery" output_has "Battery:     64% (Charging)"
check "status: shows the active limit" output_has "Active:      stop at 80%, resume below 75%"

setup
echo 'CHARGE_LIMIT=20' >"$work/etc/nova-charge-limit.conf"
check "status: still reports with a bad config" run status
check "status: flags the bad config" output_has "Configured:  invalid"

setup
rm -rf "$work/sys/class/power_supply/battery"
check "status: fails without charge control" fails run status

check "usage: no command exits 2" exits 2 run
check "usage: unknown command exits 2" exits 2 run frobnicate
check "usage: set without a value exits 2" exits 2 run set
check "usage: --help succeeds" run --help

# --- install / uninstall -------------------------------------------------
stage="$work/stage"
staged() { DESTDIR="$stage" bash "$repo/$1" "${@:2}" >/dev/null 2>&1; }
check "install: stages into DESTDIR" staged install.sh
check "install: binary is executable" test -x "$stage/usr/local/bin/nova-charge-limit"
check "install: unit installed" cmp -s "$repo/nova-charge-limit.service" "$stage/etc/systemd/system/nova-charge-limit.service"
check "install: udev rule installed" cmp -s "$repo/90-nova-charge-limit.rules" "$stage/etc/udev/rules.d/90-nova-charge-limit.rules"
check "install: config installed" cmp -s "$repo/nova-charge-limit.conf" "$stage/etc/nova-charge-limit.conf"
echo 'CHARGE_LIMIT=90' >"$stage/etc/nova-charge-limit.conf"
staged install.sh
check "install: keeps an existing config" grep -qx 'CHARGE_LIMIT=90' "$stage/etc/nova-charge-limit.conf"
check "install: --resume needs --limit" fails staged install.sh --resume 70
check "install: rejects unknown options" exits 2 staged install.sh --bogus
check "uninstall: removes staged files" staged uninstall.sh
check "uninstall: nothing left" test -z "$(find "$stage" -type f)"

echo
if ((failures)); then
    echo "$failures check(s) failed"
    exit 1
fi
echo "all checks passed"
