#!/usr/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Exercises nova-charge-limit against a fake sysfs tree and a fake systemd.
set -uo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tool="$repo/nova-charge-limit"
work=$(mktemp -d)
trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT

if ((EUID == 0)); then
    echo "run the tests as a normal user (they rely on file permissions)" >&2
    exit 1
fi

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

bat="$work/sys/class/power_supply/battery"
max_current=3000000

# Fake systemd: "restart" runs one service check in the foreground.
mkdir -p "$work/bin"
cat >"$work/bin/systemctl" <<'EOF'
#!/usr/bin/bash
echo "$*" >>"$FAKE_DIR/systemctl.log"
case $1 in
    cat) [[ -e $FAKE_DIR/installed ]] ;;
    restart)
        NOVA_CHARGE_LIMIT_MAX_TICKS=1 "$FAKE_TOOL" run 2>"$FAKE_DIR/service.log" &
        pid=$!
        wait "$pid"
        echo $? >"$FAKE_DIR/service.exit"
        echo "$pid" >"$FAKE_DIR/pid"
        ;;
    show) cat "$FAKE_DIR/pid" ;;
    is-active) [[ $(<"$FAKE_DIR/service.exit") == 0 ]] ;;
esac
EOF
# shellcheck disable=SC2016 # expanded by the fake journalctl
printf '#!/bin/sh\ncat "$FAKE_DIR/service.log"\n' >"$work/bin/journalctl"
chmod +x "$work/bin/systemctl" "$work/bin/journalctl"

# Fresh fake sysfs, config and service state for each case.
#   firmware: the charger firmware honours the charge thresholds
#   nova:     it ignores them (they read back 0); the charge current limit works
#   none:     it ignores them and there is no charge current limit
setup() {
    chmod -R u+w "$work/sys" "$work/etc" "$work/fake" 2>/dev/null
    rm -rf "${work:?}/sys" "${work:?}/etc" "${work:?}/fake"
    mkdir -p "$work/sys/class/power_supply/usb" "$work/sys/firmware/devicetree/base" \
        "$work/etc" "$work/fake" "$bat"
    printf 'Retroid Pocket Nova\0' >"$work/sys/firmware/devicetree/base/model"
    echo USB >"$work/sys/class/power_supply/usb/type"
    echo Battery >"$bat/type"
    echo 64 >"$bat/capacity"
    echo Charging >"$bat/status"
    case ${1:-firmware} in
        firmware)
            echo 100 >"$bat/charge_control_end_threshold"
            echo 95 >"$bat/charge_control_start_threshold"
            ;;
        nova | none)
            echo 0 >"$bat/charge_control_end_threshold"
            echo 0 >"$bat/charge_control_start_threshold"
            chmod 444 "$bat/charge_control_end_threshold" "$bat/charge_control_start_threshold"
            ;;
    esac
    if [[ ${1:-firmware} != none ]]; then
        echo "$max_current" >"$bat/constant_charge_current"
        echo "$max_current" >"$bat/constant_charge_current_max"
    fi
    cp "$repo/nova-charge-limit.conf" "$work/etc/nova-charge-limit.conf"
    touch "$work/fake/installed"
}

run() {
    PATH="$work/bin:$PATH" \
        FAKE_DIR="$work/fake" FAKE_TOOL="$tool" \
        NOVA_CHARGE_LIMIT_SYS_ROOT="$work/sys" \
        NOVA_CHARGE_LIMIT_CONFIG="$work/etc/nova-charge-limit.conf" \
        NOVA_CHARGE_LIMIT_STATE="$work/fake/state" \
        NOVA_CHARGE_LIMIT_INTERVAL=${interval:-0} \
        NOVA_CHARGE_LIMIT_RETRY_DELAY=0 \
        NOVA_CHARGE_LIMIT_SERVICE_WAIT=2 \
        NOVA_CHARGE_LIMIT_MAX_TICKS=${max_ticks:-1} \
        NOVA_CHARGE_LIMIT_ALLOW_NONROOT=${allow_nonroot:-1} \
        NOVA_CHARGE_LIMIT_SUDO=${test_sudo:-sudo} \
        "${runner[@]}" "$tool" "$@" >"$work/out" 2>&1
}
runner=()

# Stops a background "run" through the PID the tool itself records.
stop_service() {
    kill -TERM "$(sed -n 's/^pid=//p' "$work/fake/state")"
    wait "$1"
}

thresholds() {
    [[ $(<"$bat/charge_control_end_threshold") == "$1" && $(<"$bat/charge_control_start_threshold") == "$2" ]]
}

current_is() { [[ $(<"$bat/constant_charge_current") == "$1" ]]; }
capacity() { echo "$1" >"$bat/capacity"; }
state_has() { grep -qx -- "$1" "$work/fake/state"; }
config_has() { grep -qx -- "$1" "$work/etc/nova-charge-limit.conf"; }
config_untouched() { cmp -s "$repo/nova-charge-limit.conf" "$work/etc/nova-charge-limit.conf"; }
output_has() { grep -qF -- "$1" "$work/out"; }
service_log_has() { grep -qF -- "$1" "$work/fake/service.log"; }
not_restarted() { ! grep -q restart "$work/fake/systemctl.log" 2>/dev/null; }

# --- run: firmware thresholds --------------------------------------------
setup firmware
check "run: firmware thresholds 80/75" run run
check "run: firmware thresholds written" thresholds 80 75
check "run: firmware method recorded" state_has "method=firmware"
check "run: firmware leaves the charge current alone" current_is "$max_current"
check "run: firmware logs how the limit is enforced" output_has "the charger firmware enforces the limit"

setup firmware
printf 'CHARGE_LIMIT="85"\r\nCHARGE_RESUME = 70 \r\n' >"$work/etc/nova-charge-limit.conf"
check "run: tolerates quotes, spaces and CRLF" run run
check "run: CRLF config thresholds" thresholds 85 70

setup firmware
rm -f "$bat/charge_control_start_threshold"
check "run: works without a start threshold" run run
check "run: end-only battery" test "$(<"$bat/charge_control_end_threshold")" = 80

setup firmware
mv "$bat" "$work/sys/class/power_supply/qcom-battmgr-bat"
bat="$work/sys/class/power_supply/qcom-battmgr-bat"
check "run: finds a battery by type when not named 'battery'" run run
check "run: fallback battery thresholds" thresholds 80 75
bat="$work/sys/class/power_supply/battery"

setup firmware
interval=0.2 max_ticks=0 run run &
pid=$!
sleep 0.5
echo 0 >"$bat/charge_control_end_threshold"
echo 0 >"$bat/charge_control_start_threshold"
sleep 0.6
stop_service "$pid"
check "run: re-applies thresholds the firmware dropped" thresholds 80 75
check "run: logs the re-apply" output_has "the charge thresholds were reset"

# --- run: charge current fallback (the Nova) ------------------------------
setup nova
check "run: nova falls back to the charge current" run run
check "run: nova method recorded" state_has "method=current"
check "run: nova explains the fallback" output_has "ignored the charge thresholds (reads back end=0)"
check "run: below the limit keeps charging" current_is "$max_current"
check "run: below the limit state" state_has "charging=allowed"

setup nova
capacity 80
check "run: at the limit pauses charging" run run
check "run: paused charge current" current_is 0
check "run: paused state" state_has "charging=paused"
check "run: logs the pause" output_has "battery at 80%: charging paused"

setup nova
capacity 91
run run
check "run: above the limit pauses charging" current_is 0

setup nova
capacity 77
echo 0 >"$bat/constant_charge_current"
run run
check "run: stays paused between resume point and limit" current_is 0

setup nova
capacity 77
run run
check "run: keeps charging between resume point and limit" current_is "$max_current"

setup nova
capacity 74
echo 0 >"$bat/constant_charge_current"
run run
check "run: below the resume point resumes charging" current_is "$max_current"
check "run: logs the resume" output_has "battery at 74%: charging resumed"

setup nova
capacity 75
echo 0 >"$bat/constant_charge_current"
run run
check "run: at the resume point stays paused" current_is 0

setup nova
echo 'CHARGE_LIMIT=100' >"$work/etc/nova-charge-limit.conf"
capacity 100
echo 0 >"$bat/constant_charge_current"
run run
check "run: limit 100 always charges" current_is "$max_current"

setup nova
capacity 80
interval=0.2 max_ticks=0 run run &
pid=$!
sleep 0.5
capacity 83
sleep 0.6
stop_service "$pid"
check "run: warns when the battery rises while paused" output_has "the battery rose from 80% to 83% while charging was paused"
check "run: restores charging when stopped" current_is "$max_current"
check "run: logs the restore" output_has "charging allowed again"

setup nova
echo 0 >"$bat/constant_charge_current_max"
check "run: unusable charge current max exits 3" exits 3 run run
check "run: explains the missing charge control" output_has "no working charge control"

setup none
check "run: no charge control exits 3" exits 3 run run

setup nova
rm -rf "$bat"
runner=(timeout 3)
check "run: waits for the battery" exits 124 run run
runner=()
check "run: says it is waiting" output_has "waiting for the battery"

setup firmware
echo 'CHARGE_LIMIT=eighty' >"$work/etc/nova-charge-limit.conf"
check "run: rejects a non-numeric limit" fails run run
check "run: explains a non-numeric limit" output_has "the limit must be 55-100, got 'eighty'"
check "run: leaves thresholds alone on bad config" thresholds 100 95

setup firmware
echo 'CHARGE_LIMIT=80 extra' >"$work/etc/nova-charge-limit.conf"
check "run: rejects an unparsable line" fails run run
check "run: explains the unparsable line" output_has "cannot parse line"

setup firmware
echo '# nothing set' >"$work/etc/nova-charge-limit.conf"
check "run: requires CHARGE_LIMIT" fails run run
check "run: explains missing CHARGE_LIMIT" output_has "CHARGE_LIMIT is not set"

setup firmware
rm -f "$work/etc/nova-charge-limit.conf"
check "run: fails without a config" fails run run

# --- set / off / apply (through the fake service) -------------------------
setup firmware
check "set: 85 on firmware" run set 85
check "set: 85 thresholds" thresholds 85 80
check "set: saves the limit" config_has "CHARGE_LIMIT=85"
check "set: keeps the default resume" config_has "CHARGE_RESUME="
check "set: restarts the service" grep -qx "restart nova-charge-limit.service" "$work/fake/systemctl.log"
check "set: reports firmware enforcement" output_has "Charging stops at 85% and resumes below 80%; the charger firmware enforces it."

setup firmware
check "set: 90 70" run set 90 70
check "set: 90 70 thresholds" thresholds 90 70
check "set: saves the resume point" config_has "CHARGE_RESUME=70"

setup firmware
check "set: 55 clamps the default resume to 50" run set 55
check "set: 55 thresholds" thresholds 55 50

setup firmware
check "set: normalises leading zeros" run set 080
check "set: 080 saved as 80" config_has "CHARGE_LIMIT=80"

setup nova
check "set: 80 on the nova" run set 80
check "set: reports pausing" output_has "Charging pauses at 80% and resumes below 75%; the service watches the battery."
check "set: reports the charging state" output_has "Battery is at 64%: charging allowed."

setup nova
capacity 88
run set 80
check "set: pauses straight away above the limit" current_is 0
check "set: reports the pause" output_has "Battery is at 88%: charging paused."

setup none
check "set: fails without working charge control" fails run set 80
check "set: shows the service log" output_has "no working charge control"

setup firmware
rm -f "$work/fake/installed"
check "set: fails when the service is not installed" fails run set 80
check "set: says to run install.sh" output_has "service is not installed; run install.sh"

for bad in "54" "101" "abc" "-5" "1000" "80 80" "80 96" "80 49" "80 x"; do
    setup firmware
    # shellcheck disable=SC2086
    check "set: rejects '$bad'" fails run set $bad
    check "set: '$bad' leaves the config alone" config_untouched
    check "set: '$bad' does not touch the service" not_restarted
done

setup firmware
rm -rf "$bat"
check "set: fails without charge control" fails run set 80
check "set: no battery leaves the config alone" config_untouched

setup nova
capacity 90
run set 80
check "off: lifts the limit" run off
check "off: charging resumes" current_is "$max_current"
check "off: saves 100" config_has "CHARGE_LIMIT=100"
check "off: clears the resume point" config_has "CHARGE_RESUME="
check "off: reports no limit" output_has "No charge limit: the battery charges to 100%."

setup firmware
run set 85
run set 80
check "set: rewrites the shipped default byte for byte" config_untouched

setup firmware
echo 'CHARGE_LIMIT=90' >"$work/etc/nova-charge-limit.conf"
check "apply: applies the saved limit" run apply
check "apply: saved thresholds" thresholds 90 85

# --- sleep / reset ---------------------------------------------------------
setup nova
printf 'pid=1\nmethod=current\n' >"$work/fake/state"
capacity 77
check "sleep: succeeds" run sleep
check "sleep: pauses past the resume point" current_is 0
check "sleep: logs the pause" output_has "charging paused for sleep"

setup nova
printf 'pid=1\nmethod=current\n' >"$work/fake/state"
capacity 70
run sleep
check "sleep: keeps charging below the resume point" current_is "$max_current"

setup nova
printf 'pid=1\nmethod=firmware\n' >"$work/fake/state"
capacity 77
run sleep
check "sleep: leaves firmware-enforced limits alone" current_is "$max_current"

setup nova
capacity 77
run sleep
check "sleep: does nothing when the service is not running" current_is "$max_current"

setup firmware
run run
echo 0 >"$bat/constant_charge_current"
check "reset: succeeds" run reset
check "reset: thresholds 100/95" thresholds 100 95
check "reset: resumes charging" current_is "$max_current"
check "reset: keeps the saved limit" config_untouched

# --- status / usage ---------------------------------------------------------
setup nova
capacity 82
printf 'pid=%s\nmethod=current\nlimit=80\nresume=75\ncapacity=82\ncharging=paused\n' "$$" >"$work/fake/state"
check "status: succeeds" run status
check "status: shows the device" output_has "Device:      Retroid Pocket Nova"
check "status: shows the config" output_has "Configured:  stop at 80%, resume below 75%"
check "status: shows the battery" output_has "Battery:     82% (Charging)"
check "status: shows the method" output_has "Service:     running; pauses charging at the limit"
check "status: shows the charging state" output_has "Charging:    paused"
check "status: shows raw values" output_has "Raw:         end_threshold=0 start_threshold=0 charge_current=$max_current"

setup firmware
check "status: reports a stopped service" run status
check "status: suggests apply" output_has "Service:     not running (start it with: nova-charge-limit apply)"

setup firmware
echo 'CHARGE_LIMIT=20' >"$work/etc/nova-charge-limit.conf"
check "status: still reports with a bad config" run status
check "status: flags the bad config" output_has "Configured:  invalid"

setup firmware
rm -rf "$bat"
check "status: fails without charge control" fails run status

check "usage: no command exits 2" exits 2 run
check "usage: unknown command exits 2" exits 2 run frobnicate
check "usage: set without a value exits 2" exits 2 run set
check "usage: run takes no arguments" exits 2 run run now
check "usage: --help succeeds" run --help

# --- root -------------------------------------------------------------------
setup firmware
allow_nonroot=0
printf '#!/bin/sh\necho "SUDO $*"\n' >"$work/fake-sudo"
chmod +x "$work/fake-sudo"
test_sudo="$work/fake-sudo"
for cmd in run apply off reset sleep; do
    check "$cmd: hands off to sudo when not root" run "$cmd"
    check "$cmd: sudo gets the absolute path" output_has "SUDO -- $(readlink -f "$tool") $cmd"
done
check "set: sudo gets all arguments" run set 85 70
check "set: sudo argument list" output_has "SUDO -- $(readlink -f "$tool") set 85 70"
check "set: nothing written before elevating" thresholds 100 95
check "status: needs no root" run status
test_sudo=no-such-sudo
check "apply: fails without sudo" fails run apply
check "apply: explains it needs root" output_has "this command needs root"
unset allow_nonroot test_sudo

# --- install / uninstall ----------------------------------------------------
stage="$work/stage"
staged() { DESTDIR="$stage" bash "$repo/$1" "${@:2}" >/dev/null 2>&1; }
mkdir -p "$stage/etc/udev/rules.d"
touch "$stage/etc/udev/rules.d/90-nova-charge-limit.rules"
check "install: stages into DESTDIR" staged install.sh
check "install: nothing under read-only /usr" test ! -e "$stage/usr"
check "install: binary is executable" test -x "$stage/var/lib/nova-charge-limit/bin/nova-charge-limit"
check "install: unit installed" cmp -s "$repo/nova-charge-limit.service" "$stage/etc/systemd/system/nova-charge-limit.service"
check "install: sleep unit installed" cmp -s "$repo/nova-charge-limit-sleep.service" "$stage/etc/systemd/system/nova-charge-limit-sleep.service"
check "install: unit runs the installed binary" grep -q '^ExecStart=/usr/bin/bash /var/lib/nova-charge-limit/bin/nova-charge-limit run$' "$stage/etc/systemd/system/nova-charge-limit.service"
check "install: removes the 1.0.x udev rule" test ! -e "$stage/etc/udev/rules.d/90-nova-charge-limit.rules"
check "install: PATH snippet installed" cmp -s "$repo/nova-charge-limit-path.sh" "$stage/etc/profile.d/nova-charge-limit.sh"
# shellcheck disable=SC1091
check "install: PATH snippet adds the bin dir once" test "$(PATH=/usr/bin; . "$stage/etc/profile.d/nova-charge-limit.sh"; . "$stage/etc/profile.d/nova-charge-limit.sh"; echo "$PATH")" = /usr/bin:/var/lib/nova-charge-limit/bin
check "install: config installed" cmp -s "$repo/nova-charge-limit.conf" "$stage/etc/nova-charge-limit.conf"
echo 'CHARGE_LIMIT=90' >"$stage/etc/nova-charge-limit.conf"
staged install.sh
check "install: keeps an existing config" grep -qx 'CHARGE_LIMIT=90' "$stage/etc/nova-charge-limit.conf"
check "install: --resume needs --limit" fails staged install.sh --resume 70
check "install: rejects unknown options" exits 2 staged install.sh --bogus
check "uninstall: removes staged files" staged uninstall.sh
check "uninstall: nothing left" test -z "$(find "$stage" -type f)"
check "uninstall: removes the bin dir" test ! -e "$stage/var/lib/nova-charge-limit"

# shellcheck disable=SC2016 # expanded by the inner bash
check "install: names the destinations" bash -c 'DESTDIR="$1" bash "$2/install.sh" | grep -qx "Installing nova-charge-limit to /var/lib/nova-charge-limit/bin and /etc"' _ "$stage" "$repo"
staged uninstall.sh
stage="$work/stage-ro"
mkdir -p "$stage/etc"
chmod 555 "$stage/etc"
check "install: fails on an unwritable destination" fails staged install.sh
# shellcheck disable=SC2016 # expanded by the inner bash
check "install: names the unwritable path" bash -c 'DESTDIR="$1" bash "$2/install.sh" 2>&1 | grep -qF "cannot write $1/etc/systemd/system/nova-charge-limit.service"' _ "$stage" "$repo"
chmod 755 "$stage/etc"

echo
if ((failures)); then
    echo "$failures check(s) failed"
    exit 1
fi
echo "all checks passed"
