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
    enable | disable)
        # Like the real one: a missing unit fails the whole call, doing nothing.
        verb=$1
        shift
        [[ ${1-} == --now ]] && shift
        for unit; do
            if [[ ! -e ${FAKE_UNIT_DIR:-/nonexistent}/$unit ]]; then
                echo "Failed to $verb unit: Unit $unit does not exist" >&2
                exit 1
            fi
        done
        ;;
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
    echo 1 >"$work/sys/class/power_supply/usb/online"
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
    mkdir -p "$work/sys/power" "$work/proc" "$work/fake/armada"
    echo '[s2idle]' >"$work/sys/power/mem_sleep"
    : >"$work/sys/power/state"
    cat >"$work/proc/interrupts" <<'EOF'
           CPU0       CPU1
 42:          3          0  pmic_arb 8388611 Edge      pm8941_pwrkey
 77:        120          0  ipcc  65536 Edge      glink-adsp
EOF
    cp "$repo/nova-charge-limit.conf" "$work/etc/nova-charge-limit.conf"
    touch "$work/fake/installed"
}

run() {
    PATH="$work/bin:$PATH" \
        FAKE_DIR="$work/fake" FAKE_TOOL="${service_tool:-$tool}" \
        NOVA_CHARGE_LIMIT_SYS_ROOT="$work/sys" \
        NOVA_CHARGE_LIMIT_CONFIG="$work/etc/nova-charge-limit.conf" \
        NOVA_CHARGE_LIMIT_STATE="$work/fake/state" \
        NOVA_CHARGE_LIMIT_INTERVAL=${interval:-0} \
        NOVA_CHARGE_LIMIT_RETRY_DELAY=0 \
        NOVA_CHARGE_LIMIT_SERVICE_WAIT=2 \
        NOVA_CHARGE_LIMIT_MAX_TICKS=${max_ticks:-1} \
        NOVA_CHARGE_LIMIT_ALLOW_NONROOT=${allow_nonroot:-1} \
        NOVA_CHARGE_LIMIT_SUDO=${test_sudo:-sudo} \
        NOVA_CHARGE_LIMIT_ARMADA_SLEEP_CONFIG="$work/etc/armada-sleep.conf" \
        NOVA_CHARGE_LIMIT_SLEEP_CONFIG="$work/fake/sleep.conf" \
        NOVA_CHARGE_LIMIT_ARMADA_RUN="$work/fake/armada" \
        NOVA_CHARGE_LIMIT_PROC_ROOT="$work/proc" \
        NOVA_CHARGE_LIMIT_WAKE_SETTLE=0 \
        NOVA_CHARGE_LIMIT_SETTLE=1 \
        NOVA_CHARGE_LIMIT_SLEEP_SETTLE=1 \
        NOVA_CHARGE_LIMIT_POLL_DELAY=0.05 \
        NOVA_CHARGE_LIMIT_SHORT_SLEEP=${short_sleep:-30} \
        "${runner[@]}" "$tool" "$@" >"${out_file:-$work/out}" 2>&1
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
unplug() { echo 0 >"$work/sys/class/power_supply/usb/online"; }
output_count() { (($(grep -cF -- "$1" "$work/out") == $2)); }

# The Nova asleep on the charger with deep sleep on: "nova-charge-limit sleep"
# chose fake suspend at 69%, and Armada's fake suspend is running.
deep_setup() {
    setup nova
    sed -i 's/^DEEP_SLEEP_AT_LIMIT=.*/DEEP_SLEEP_AT_LIMIT=yes/' "$work/etc/nova-charge-limit.conf"
    service_state current
    capacity 69
    run sleep
    touch "$work/fake/armada/fake-suspend.active"
    capacity 80
}
wake_irq() { echo "$1" >"$work/sys/power/pm_wakeup_irq"; }
slept_real() { [[ $(<"$work/sys/power/state") == mem && $(<"$work/sys/power/mem_sleep") == s2idle ]]; }
not_slept_real() { [[ ! -s $work/sys/power/state ]]; }
service_state() { printf 'pid=%s\nmethod=%s\n' "$$" "$1" >"$work/fake/state"; }
# The suspend mode Armada's device-env would pick: the last suspend_mode line.
sleep_mode() {
    local mode=device-default line
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line =~ ^[[:space:]]*suspend_mode[[:space:]]*=[[:space:]]*(fake|s2idle)[[:space:]]*$ ]] &&
            mode=${BASH_REMATCH[1]}
    done <"$work/fake/sleep.conf"
    [[ $mode == "$1" ]]
}
state_has() { grep -qx -- "$1" "$work/fake/state" 2>/dev/null; }
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

# --- charger firmware lag (seen on the Nova) ---------------------------------
cc="$bat/constant_charge_current"
# Polls a check for up to 3 seconds, so the tests don't race the service.
wait_until() {
    local i
    for ((i = 0; i < 150; i++)); do
        "$@" && return 0
        sleep 0.02
    done
    return 1
}
# Keeps the firmware reporting $1 for $2 rounds of 20ms, like a firmware that
# hasn't applied (or keeps undoing) the requested current.
firmware_reports() {
    local i
    for ((i = 0; i < $2; i++)); do
        echo "$1" >"$cc"
        sleep 0.02
    done
}

setup nova
capacity 85
interval=0.3 max_ticks=0 run run &
pid=$!
check "lag: the service asks for a pause" wait_until current_is 0
echo 7200000 >"$cc"
check "lag: ...and asks again while the firmware still reports the old value" wait_until current_is 0
stop_service "$pid"
check "lag: a pause the firmware hasn't applied yet is not an error" fails output_has "could not"
check "lag: ...and causes no warning" fails output_has "still reports"
check "lag: the pause is logged once" output_count "charging paused" 1

setup nova
capacity 85
interval=0.2 max_ticks=0 run run &
pid=$!
wait_until current_is 0
firmware_reports 7200000 60
check "lag: keeps asking until the firmware applies it" wait_until output_has "the charger firmware now reports charging paused"
stop_service "$pid"
check "lag: warns once when the firmware keeps reporting the old value" output_count "the charger firmware still reports charging allowed after 3 checks" 1
check "lag: the warning shows the raw value" output_has "(constant_charge_current reads 7200000)"

setup nova
capacity 60
echo 7000000 >"$cc"
run run
check "lag: a current below the maximum counts as charging allowed" current_is 7000000
check "lag: ...so nothing is requested" fails output_has "battery at 60%"
check "lag: the state records it" state_has "firmware=allowed"

setup nova
capacity 74
echo 0 >"$cc"
interval=0.2 max_ticks=0 run run &
pid=$!
wait_until current_is "$max_current"
echo 7000000 >"$cc"
sleep 0.5
stop_service "$pid"
check "lag: resuming accepts a lower current from the firmware" current_is 7000000
check "lag: resume logged once" output_count "charging resumed" 1
check "lag: no resume warning" fails output_has "still reports"

setup nova
capacity 85
chmod 444 "$cc"
run run
check "lag: a rejected write logs the kernel's reason" output_has "writing 0 to constant_charge_current failed: Permission denied"
check "lag: ...and nothing is recorded as paused" state_has "charging=allowed"
chmod 644 "$cc"

setup nova
capacity 77
interval=0.2 max_ticks=0 run run &
pid=$!
wait_until state_has "charging=allowed"
out_file="$work/out-sleep" run sleep
check "sleep: pauses charging for sleep" grep -qF "charging paused for sleep" "$work/out-sleep"
check "sleep: the pause for sleep leaves a note for the service" test -e "$work/fake/state.sleep-pause"
check "sleep: the running service picks up the note" wait_until test ! -e "$work/fake/state.sleep-pause"
sleep 0.5
check "sleep: ...and keeps the pause instead of undoing it" current_is 0
stop_service "$pid"
check "sleep: the service didn't resume charging between the resume point and the limit" \
    output_count "charging resumed" 0

setup nova
capacity 85
interval=0.2 max_ticks=0 run run &
pid=$!
wait_until current_is 0
stop_service "$pid"
check "restore: stopping restores charging" current_is "$max_current"

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

# The user's case: an updated git checkout, but the service still runs an older install.
setup nova
sed 's/^version=.*/version=1.2.0/' "$tool" >"$work/old-installed"
chmod +x "$work/old-installed"
service_tool="$work/old-installed"
check "set: works when the service is older" run set 80
check "set: warns that the service is older" output_has "warning: the service is running version 1.2.0"
check "set: says how to update it" output_has "To update it, run: sudo bash ./install.sh"
# Before 1.3.1 the service didn't report a version.
# shellcheck disable=SC2016 # a literal $version in the sed pattern
sed 's/^version=.*/version=1.2.0/; s/"version=\$version" //' "$tool" >"$work/old-installed"
run set 80
check "set: warns about a service from before versions were reported" output_has "the service is running an older version"
unset service_tool

setup nova
check "set: no version warning when the service matches" run set 80
check "set: ...really none" fails output_has "warning: the service is running"

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
# Your situation: plugged in at 69%, limit 80%.
setup nova
service_state current
capacity 69
check "sleep: succeeds" run sleep
check "sleep: plugged in below the resume point uses fake suspend" sleep_mode fake
check "sleep: keeps charging into fake suspend" current_is "$max_current"
check "sleep: logs the fake suspend" output_has "battery at 69% and charging: sleeping in fake suspend so charging stops at 80%"

setup nova
service_state current
capacity 77
run sleep
check "sleep: plugged in past the resume point pauses" current_is 0
check "sleep: ...and sleeps for real" sleep_mode device-default
check "sleep: logs the pause" output_has "battery at 77%: charging paused for sleep"

setup nova
service_state current
unplug
capacity 50
run sleep
check "sleep: unplugged pauses so a charger plugged in during sleep can't pass the limit" current_is 0
check "sleep: unplugged sleeps for real" sleep_mode device-default

setup nova
service_state current
echo 'suspend_mode = s2idle' >"$work/etc/armada-sleep.conf"
capacity 69
run sleep
check "sleep: fake suspend overrides the user's sleep.conf" sleep_mode fake
check "sleep: keeps the user's sleep.conf lines" grep -qx 'suspend_mode = s2idle' "$work/fake/sleep.conf"

setup nova
service_state current
printf 'suspend_mode = fake' >"$work/etc/armada-sleep.conf"
capacity 77
run sleep
check "sleep: otherwise passes the user's sleep.conf through" sleep_mode fake
check "sleep: copies it unchanged" cmp -s "$work/etc/armada-sleep.conf" "$work/fake/sleep.conf"

setup nova
service_state current
capacity 77
echo 0 >"$bat/constant_charge_current"
run sleep
check "sleep: already paused stays paused" current_is 0
check "sleep: already paused sleeps for real" sleep_mode device-default

setup nova
service_state firmware
capacity 69
run sleep
check "sleep: firmware limits need no fake suspend" sleep_mode device-default
check "sleep: leaves firmware-enforced limits alone" current_is "$max_current"

setup nova
printf 'pid=999999999\nmethod=current\n' >"$work/fake/state"
capacity 69
run sleep
check "sleep: does nothing when the service is not running" current_is "$max_current"
check "sleep: still writes the sleep config" sleep_mode device-default

setup nova
service_state current
echo 'CHARGE_LIMIT=100' >"$work/etc/nova-charge-limit.conf"
capacity 69
run sleep
check "sleep: no limit sleeps normally" sleep_mode device-default
check "sleep: no limit keeps charging" current_is "$max_current"

setup nova
service_state current
echo 'CHARGE_LIMIT=bad' >"$work/etc/nova-charge-limit.conf"
printf 'suspend_mode = fake\n' >"$work/fake/sleep.conf"
run sleep
check "sleep: a bad config still replaces a stale sleep config" sleep_mode device-default

setup firmware
run run
echo 0 >"$bat/constant_charge_current"
check "reset: succeeds" run reset
check "reset: thresholds 100/95" thresholds 100 95
check "reset: resumes charging" current_is "$max_current"
check "reset: keeps the saved limit" config_untouched

# --- deep sleep at the limit -------------------------------------------------
# Two checks: the first pauses charging at the limit, the second could sleep.
max_ticks=2

deep_setup
check "sleep: mentions the switch to real sleep when deep sleep is on" output_has "then switching to real sleep"

deep_setup
wake_irq 42
check "deep: runs" run run
check "deep: pauses at the limit" current_is 0
check "deep: enters real sleep (s2idle)" slept_real
check "deep: announces the switch" output_has "battery at 80% with charging paused: switching from fake suspend to real sleep"
check "deep: power button wake is a user wake" output_has "(wake: 42 pm8941_pwrkey); leaving it to fake suspend to wake up"
check "deep: asks a stuck fake suspend to wake" test -e "$work/fake/armada/fake-suspend.wake"
check "deep: logs the wake request" output_has "asked it to wake up"

deep_setup
wake_irq 42
max_ticks=4 run run
check "deep: never sleeps again after a power button wake" output_count "woke from real sleep" 1

deep_setup
rm -f "$work/sys/power/pm_wakeup_irq"
max_ticks=4 run run
check "deep: an unknown wake counts as a user wake" output_has "(wake: unknown); leaving it to fake suspend"
check "deep: ...and never sleeps again" output_count "woke from real sleep" 1

deep_setup
wake_irq 99
max_ticks=4 run run
check "deep: an IRQ missing from /proc/interrupts counts as a user wake" output_has "(wake: 99 unknown); leaving it"

deep_setup
wake_irq 77
short_sleep=0 max_ticks=4 run run
check "deep: a background wake goes back to sleep" output_count "(wake: 77 glink-adsp); going back to sleep" 3
check "deep: background wakes don't wake fake suspend" test ! -e "$work/fake/armada/fake-suspend.wake"

deep_setup
wake_irq 77
max_ticks=10 run run
check "deep: gives up after 5 short sleeps in a row" output_has "woke from real sleep 5 times in a row within 30s (last wake: 77 glink-adsp); staying in fake suspend"
check "deep: ...after exactly 4 retries" output_count "going back to sleep" 4
check "deep: charging stays paused after giving up" current_is 0

deep_setup
wake_irq 77
chmod 444 "$work/sys/power/state"
max_ticks=6 run run
check "deep: gives up if real sleep can't be entered" output_has "could not enter real sleep 3 times; staying in fake suspend"
check "deep: retries before giving up" output_count "could not enter real sleep; trying again" 2

deep_setup
echo 'deep' >"$work/sys/power/mem_sleep"
run run
check "deep: needs s2idle" not_slept_real

deep_setup
sed -i 's/^DEEP_SLEEP_AT_LIMIT=.*/DEEP_SLEEP_AT_LIMIT=no/' "$work/etc/nova-charge-limit.conf"
run run
check "deep: off by default keeps fake suspend" not_slept_real
check "deep: off still pauses at the limit" current_is 0

deep_setup
capacity 77
run run
check "deep: waits until charging pauses" not_slept_real
check "deep: keeps charging toward the limit" current_is "$max_current"

deep_setup
rm -f "$work/fake/armada/fake-suspend.active"
run run
check "deep: only inside fake suspend" not_slept_real

deep_setup
# The user's own fake suspend: no marker from "nova-charge-limit sleep".
printf 'suspend_mode = fake\n' >"$work/fake/sleep.conf"
touch "$work/fake/armada/fake-suspend.active"
run run
check "deep: leaves a fake suspend it didn't choose alone" not_slept_real

deep_setup
touch -d '-5 minutes' "$work/fake/sleep.conf"
run run
check "deep: ignores a stale sleep config" not_slept_real

deep_setup
wake_irq 77
unplug
capacity 60
short_sleep=0 max_ticks=3 run run
check "deep: unplugged during fake suspend pauses charging" current_is 0
check "deep: logs the unplug" output_has "charger unplugged during sleep: charging paused"
check "deep: ...and sleeps for real" slept_real
check "deep: stays paused across background wakes" output_count "going back to sleep" 2

deep_setup
wake_irq 42
unplug
capacity 60
run run
check "deep: after a power button wake, the awake rules apply again" current_is "$max_current"

deep_setup
wake_irq 42
interval=0.2 max_ticks=0 run run &
pid=$!
sleep 0.6
rm -f "$work/fake/armada/fake-suspend.active" "$work/fake/armada/fake-suspend.wake"
sleep 0.6
capacity 69
# The next sleep: the running service is what "sleep" looks for.
run_sleep_out=$(PATH="$work/bin:$PATH" NOVA_CHARGE_LIMIT_SYS_ROOT="$work/sys" \
    NOVA_CHARGE_LIMIT_CONFIG="$work/etc/nova-charge-limit.conf" NOVA_CHARGE_LIMIT_STATE="$work/fake/state" \
    NOVA_CHARGE_LIMIT_ARMADA_SLEEP_CONFIG="$work/etc/armada-sleep.conf" \
    NOVA_CHARGE_LIMIT_SLEEP_CONFIG="$work/fake/sleep.conf" NOVA_CHARGE_LIMIT_ALLOW_NONROOT=1 \
    "$tool" sleep 2>&1)
touch "$work/fake/armada/fake-suspend.active"
capacity 80
sleep 0.8
stop_service "$pid"
check "deep: a new fake suspend starts fresh" output_count "switching from fake suspend to real sleep" 2
check "the next sleep chose fake suspend again" grep -qF "sleeping in fake suspend until" <<<"$run_sleep_out"
unset run_sleep_out

setup nova
echo 'DEEP_SLEEP_AT_LIMIT=maybe' >>"$work/etc/nova-charge-limit.conf"
check "deep: rejects a bad DEEP_SLEEP_AT_LIMIT" fails run run
check "deep: explains the bad value" output_has "DEEP_SLEEP_AT_LIMIT must be yes or no, got 'maybe'"

setup firmware
check "deep-sleep on: succeeds" run deep-sleep on
check "deep-sleep on: saves yes" config_has "DEEP_SLEEP_AT_LIMIT=yes"
check "deep-sleep on: keeps the limit" config_has "CHARGE_LIMIT=80"
check "deep-sleep on: restarts the service" grep -qx "restart nova-charge-limit.service" "$work/fake/systemctl.log"
check "deep-sleep on: explains it" output_has "Deep sleep at the limit: on (experimental)"
check "set: keeps deep sleep on" run set 85
check "set: deep sleep still on" config_has "DEEP_SLEEP_AT_LIMIT=yes"
check "off: keeps deep sleep on" run off
check "off: deep sleep still on" config_has "DEEP_SLEEP_AT_LIMIT=yes"
run set 80
check "deep-sleep off: succeeds" run deep-sleep off
check "deep-sleep off: explains it" output_has "Deep sleep at the limit: off"
check "deep-sleep off: restores the shipped config byte for byte" config_untouched

setup firmware
echo 'CHARGE_LIMIT=90' >"$work/etc/nova-charge-limit.conf"
echo 'CHARGE_RESUME=70' >>"$work/etc/nova-charge-limit.conf"
run deep-sleep on
check "deep-sleep on: keeps a custom resume point" config_has "CHARGE_RESUME=70"
check "deep-sleep on: keeps a custom limit" config_has "CHARGE_LIMIT=90"

setup firmware
check "deep-sleep: rejects other values" exits 2 run deep-sleep maybe
check "deep-sleep: needs a value" exits 2 run deep-sleep
check "deep-sleep: bad value leaves the config alone" config_untouched
unset max_ticks

# --- status / usage ---------------------------------------------------------
setup nova
capacity 82
printf 'pid=%s\nmethod=current\nlimit=80\nresume=75\ncapacity=82\ncharging=paused\n' "$$" >"$work/fake/state"
check "status: succeeds" run status
check "status: shows the device" output_has "Device:      Retroid Pocket Nova"
check "status: shows deep sleep off by default" output_has "Deep sleep:  off"
check "status: shows the config" output_has "Configured:  stop at 80%, resume below 75%"
check "status: shows the battery" output_has "Battery:     82% (Charging)"
check "status: shows the method" output_has "Service:     running; pauses charging at the limit"
check "status: shows the charging state" output_has "Charging:    paused"
check "status: flags a service older than this copy" output_has "Version:     the service runs an older version, this copy is"

setup nova
capacity 80
printf 'pid=%s\nversion=%s\nmethod=current\ncharging=paused\nfirmware=allowed\n' "$$" \
    "$(sed -n 's/^version=//p' "$tool")" >"$work/fake/state"
run status
check "status: shows the version when the service matches" output_has "Version:     $(sed -n 's/^version=//p' "$tool")"
check "status: shows a pause the firmware hasn't applied" output_has "Charging:    paused (waiting for the charger firmware, which still reports allowed)"
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
check "deep-sleep: hands off to sudo" run deep-sleep on
check "deep-sleep: sudo argument list" output_has "SUDO -- $(readlink -f "$tool") deep-sleep on"
check "set: nothing written before elevating" thresholds 100 95
check "status: needs no root" run status
test_sudo=no-such-sudo
check "apply: fails without sudo" fails run apply
check "apply: explains it needs root" output_has "this command needs root"
unset allow_nonroot test_sudo

# --- install / uninstall ----------------------------------------------------
stage="$work/stage"
staged() { DESTDIR="$stage" bash "$repo/$1" "${@:2}" >/dev/null 2>&1; }
mkdir -p "$stage/etc/udev/rules.d" "$stage/etc/systemd/system"
touch "$stage/etc/udev/rules.d/90-nova-charge-limit.rules" "$stage/etc/systemd/system/nova-charge-limit-sleep.service"
check "install: stages into DESTDIR" staged install.sh
check "install: nothing under read-only /usr" test ! -e "$stage/usr"
check "install: binary is executable" test -x "$stage/var/lib/nova-charge-limit/bin/nova-charge-limit"
check "install: unit installed" cmp -s "$repo/nova-charge-limit.service" "$stage/etc/systemd/system/nova-charge-limit.service"
check "install: suspend drop-in installed" cmp -s "$repo/nova-charge-limit-suspend.conf" "$stage/etc/systemd/system/systemd-suspend.service.d/50-nova-charge-limit.conf"
check "install: unit runs the installed binary" grep -q '^ExecStart=/usr/bin/bash /var/lib/nova-charge-limit/bin/nova-charge-limit run$' "$stage/etc/systemd/system/nova-charge-limit.service"
check "install: drop-in runs the installed binary" grep -q '^ExecStartPre=-/usr/bin/bash /var/lib/nova-charge-limit/bin/nova-charge-limit sleep$' "$stage/etc/systemd/system/systemd-suspend.service.d/50-nova-charge-limit.conf"
check "install: drop-in and tool agree on the sleep config path" grep -q "^Environment=ARMADA_SLEEP_CONFIG=$(sed -n 's/^sleep_config=.*:-\(.*\)}$/\1/p' "$tool")$" "$stage/etc/systemd/system/systemd-suspend.service.d/50-nova-charge-limit.conf"
check "install: removes the 1.0.x udev rule" test ! -e "$stage/etc/udev/rules.d/90-nova-charge-limit.rules"
check "install: removes the 1.1.0 sleep unit" test ! -e "$stage/etc/systemd/system/nova-charge-limit-sleep.service"
check "install: PATH snippet installed" cmp -s "$repo/nova-charge-limit-path.sh" "$stage/etc/profile.d/nova-charge-limit.sh"
# shellcheck disable=SC1091,SC2030 # PATH is meant to change only in the subshell
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
check "uninstall: removes the empty drop-in dir" test ! -e "$stage/etc/systemd/system/systemd-suspend.service.d"

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

# --- install / uninstall with systemctl (fake) -------------------------------
# The full install, including the systemctl steps a staged install skips.
# The fake systemctl fails on missing units like the real one.
stage="$work/live"
units="$stage/etc/systemd/system"
live() {
    # shellcheck disable=SC2031 # PATH is unchanged here; only a test subshell changed it
    PATH="$work/bin:$PATH" FAKE_DIR="$work/fake" FAKE_TOOL="$tool" FAKE_UNIT_DIR="$units" \
        DESTDIR="$stage" NOVA_CHARGE_LIMIT_TEST_LIVE=1 \
        NOVA_CHARGE_LIMIT_SYS_ROOT="$work/sys" \
        NOVA_CHARGE_LIMIT_CONFIG="$stage/etc/nova-charge-limit.conf" \
        NOVA_CHARGE_LIMIT_STATE="$work/fake/state" \
        NOVA_CHARGE_LIMIT_INTERVAL=0 NOVA_CHARGE_LIMIT_RETRY_DELAY=0 \
        NOVA_CHARGE_LIMIT_SERVICE_WAIT=2 NOVA_CHARGE_LIMIT_SETTLE=1 \
        NOVA_CHARGE_LIMIT_POLL_DELAY=0.05 NOVA_CHARGE_LIMIT_ALLOW_NONROOT=1 \
        bash "$repo/$1" "${@:2}" >"$work/out" 2>&1
}
systemctl_called() { grep -qx -- "$1" "$work/fake/systemctl.log"; }
never_called() { ! grep -qF -- "$1" "$work/fake/systemctl.log"; }

setup nova
rm -rf "$stage"
check "live install: a fresh install succeeds" live install.sh
check "live install: enables only the units it ships" systemctl_called "enable nova-charge-limit.service"
check "live install: never touches the old sleep unit" never_called "nova-charge-limit-sleep"
check "live install: starts the service" systemctl_called "restart nova-charge-limit.service"
check "live install: ends with the status" output_has "Version:     $(sed -n 's/^version=//p' "$tool")"
check "live install: no systemctl errors" fails output_has "Failed to"

# Upgrading from 1.1.0, which had a separate sleep unit.
setup nova
rm -rf "$stage"
mkdir -p "$units/sleep.target.wants" "$stage/etc/udev/rules.d"
touch "$units/nova-charge-limit.service" "$units/nova-charge-limit-sleep.service" \
    "$stage/etc/udev/rules.d/90-nova-charge-limit.rules"
ln -s ../nova-charge-limit-sleep.service "$units/sleep.target.wants/nova-charge-limit-sleep.service"
cp "$repo/nova-charge-limit.conf" "$stage/etc/nova-charge-limit.conf"
check "live upgrade from 1.1.0: succeeds" live install.sh
check "live upgrade from 1.1.0: stops the old service first" systemctl_called "disable --now nova-charge-limit.service"
check "live upgrade from 1.1.0: disables the old sleep unit on its own" systemctl_called "disable nova-charge-limit-sleep.service"
check "live upgrade from 1.1.0: removes the old sleep unit" test ! -e "$units/nova-charge-limit-sleep.service"
check "live upgrade from 1.1.0: removes its link" test ! -L "$units/sleep.target.wants/nova-charge-limit-sleep.service"
check "live upgrade from 1.1.0: enables only the new unit" systemctl_called "enable nova-charge-limit.service"
check "live upgrade from 1.1.0: no systemctl errors" fails output_has "Failed to"

# The state a failed 1.2.0-1.3.1 install left behind: the old sleep unit is
# gone but its link remains.
setup nova
rm -rf "$stage"
mkdir -p "$units/sleep.target.wants"
touch "$units/nova-charge-limit.service"
ln -s ../nova-charge-limit-sleep.service "$units/sleep.target.wants/nova-charge-limit-sleep.service"
cp "$repo/nova-charge-limit.conf" "$stage/etc/nova-charge-limit.conf"
check "live reinstall after a failed install: succeeds" live install.sh
check "live reinstall after a failed install: removes the dangling link" \
    test ! -L "$units/sleep.target.wants/nova-charge-limit-sleep.service"
check "live reinstall after a failed install: no systemctl errors" fails output_has "Failed to"
check "live reinstall after a failed install: the service runs" systemctl_called "restart nova-charge-limit.service"

check "live uninstall: succeeds" live uninstall.sh
check "live uninstall: stops and disables the service" systemctl_called "disable --now nova-charge-limit.service"
check "live uninstall: lifts the limit" output_has "limit lifted"
check "live uninstall: no systemctl errors" fails output_has "Failed to"
check "live uninstall: nothing left" test -z "$(find "$stage" -type f -o -type l)"

echo
if ((failures)); then
    echo "$failures check(s) failed"
    exit 1
fi
echo "all checks passed"
