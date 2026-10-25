#!/usr/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -uo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "${work:?}"' EXIT
failures=0
check() {
    local name=$1
    shift
    if "$@"; then echo "ok   $name"; else echo "FAIL $name"; failures=$((failures + 1)); fi
}
fails() { ! "$@"; }
mkdir -p "$work/bin"
cat >"$work/bin/systemctl" <<'EOF'
#!/bin/bash
echo "$*" >>"$CASE/commands"
case $1 in
    show)
        [[ $2 == -p && $3 == ActiveState && $4 == --value ]] || exit 1
        if [[ -e $CASE/show-fails ]]; then exit 1; fi
        if [[ -e $CASE/state-$5 ]]; then cat "$CASE/state-$5"; else cat "$CASE/unit-state"; fi
        ;;
    is-active)
        [[ $* == 'is-active --quiet armada-powerd.service' ]] || exit 1
        [[ ! -e $CASE/powerd-failed ]]
        ;;
    --no-block)
        [[ $2 == suspend ]] || exit 1
        echo request >>"$CASE/events"
        # Never request another sleep while the first lifecycle is unfinished.
        if [[ ! -e $CASE/fake-complete || $(<"$CASE/unit-state") != inactive ||
              $(<"$CASE/sys/class/power_supply/battery/constant_charge_current") != 0 ]]; then
            echo "unsafe handoff" >&2
            exit 1
        fi
        if [[ -e $CASE/request-fails ]]; then echo "suspend denied by inhibitor" >&2; exit 1; fi
        if [[ -e $CASE/no-pre ]]; then exit 0; fi
        echo active >"$CASE/unit-state"
        if [[ -e $CASE/disable-in-pre ]]; then
            sed -i 's/DEEP_SLEEP_AT_LIMIT=yes/DEEP_SLEEP_AT_LIMIT=no/' "$NOVA_CHARGE_LIMIT_CONFIG"
        fi
        "$TOOL" sleep >>"$CASE/hook.log" 2>&1 || exit 1
        echo pre >>"$CASE/events"
        if ! grep -qx 'suspend_mode = s2idle' "$NOVA_CHARGE_LIMIT_SLEEP_CONFIG"; then
            echo "pre-sleep hook did not select real sleep" >&2
            exit 1
        fi
        if [[ -e $CASE/no-post ]]; then exit 0; fi
        if [[ -e $CASE/unplug-on-wake ]]; then
            echo 0 >"$CASE/sys/class/power_supply/usb/online"
            echo 60 >"$CASE/sys/class/power_supply/battery/capacity"
        fi
        echo inactive >"$CASE/unit-state"
        SERVICE_RESULT=$(cat "$CASE/result") "$TOOL" sleep-finished >>"$CASE/hook.log" 2>&1
        echo post >>"$CASE/events"
        ;;
    *) echo "unexpected systemctl call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$work/bin/systemctl"
export PATH="$work/bin:$PATH"
export TOOL="$repo/nova-charge-limit"
export NOVA_CHARGE_LIMIT_ALLOW_NONROOT=1
export NOVA_CHARGE_LIMIT_RETRY_DELAY=0
export NOVA_CHARGE_LIMIT_INTERVAL=0
export NOVA_CHARGE_LIMIT_HANDOFF_WAIT=2
export NOVA_CHARGE_LIMIT_HANDOFF_POLL=0.02
export NOVA_CHARGE_LIMIT_MAX_TICKS=4
export NOVA_CHARGE_LIMIT_SETTLE=0

setup() {
    CASE="$work/case"
    export CASE
    rm -rf "$CASE"
    mkdir -p "$CASE/sys/class/power_supply/"{battery,usb} "$CASE/sys/power" "$CASE/armada"
    export NOVA_CHARGE_LIMIT_SYS_ROOT="$CASE/sys"
    export NOVA_CHARGE_LIMIT_CONFIG="$CASE/limit.conf"
    export NOVA_CHARGE_LIMIT_STATE="$CASE/state"
    export NOVA_CHARGE_LIMIT_SLEEP_CONFIG="$CASE/sleep.conf"
    export NOVA_CHARGE_LIMIT_ARMADA_SLEEP_CONFIG="$CASE/user-sleep.conf"
    export NOVA_CHARGE_LIMIT_ARMADA_RUN="$CASE/armada"
    printf 'CHARGE_LIMIT=80\nCHARGE_RESUME=70\nDEEP_SLEEP_AT_LIMIT=yes\n' >"$CASE/limit.conf"
    printf '# nova-charge-limit: charging toward the limit\nsuspend_mode = fake\n' >"$CASE/sleep.conf"
    touch "$CASE/armada/fake-suspend.active"
    echo 80 >"$CASE/sys/class/power_supply/battery/capacity"
    echo 0 >"$CASE/sys/class/power_supply/battery/charge_control_end_threshold"
    chmod 444 "$CASE/sys/class/power_supply/battery/charge_control_end_threshold"
    echo 0 >"$CASE/sys/class/power_supply/battery/constant_charge_current"
    echo 7200000 >"$CASE/sys/class/power_supply/battery/constant_charge_current_max"
    echo Battery >"$CASE/sys/class/power_supply/battery/type"
    echo USB >"$CASE/sys/class/power_supply/usb/type"
    echo 1 >"$CASE/sys/class/power_supply/usb/online"
    echo '[s2idle] deep' >"$CASE/sys/power/mem_sleep"
    : >"$CASE/sys/power/state"
    echo active >"$CASE/unit-state"
    echo success >"$CASE/result"
}
run_service() { "$TOOL" run >"$CASE/out" 2>&1; }
output_has() { grep -qF -- "$1" "$CASE/out"; }
no_suspend() { ! grep -q '^--no-block suspend$' "$CASE/commands" 2>/dev/null; }
requested_once() { [[ $(grep -cx -- '--no-block suspend' "$CASE/commands") == 1 ]]; }
no_raw_sleep() {
    [[ ! -s $CASE/sys/power/state && $(<"$CASE/sys/power/mem_sleep") == '[s2idle] deep' ]]
}
finish_fake() {
    local i
    for ((i = 0; i < 200; i++)); do
        [[ ! -e $CASE/armada/fake-suspend.wake ]] || break
        sleep 0.01
    done
    [[ -e $CASE/armada/fake-suspend.wake ]] || return 1
    if [[ -e $CASE/new-fake ]]; then
        rm -f "$CASE/armada/fake-suspend.active"
        touch "$CASE/armada/fake-suspend.active"
        return 0
    fi
    # The flag disappears before the unit finishes its resume work.
    rm -f "$CASE/armada/fake-suspend.active" "$CASE/armada/fake-suspend.wake"
    echo deactivating >"$CASE/unit-state"
    sleep 0.1
    if [[ -e $CASE/charge-reset ]]; then
        echo 7200000 >"$CASE/sys/class/power_supply/battery/constant_charge_current"
    fi
    touch "$CASE/fake-complete"
    echo fake-complete >>"$CASE/events"
    echo inactive >"$CASE/unit-state"
}
run_with_fake() {
    finish_fake &
    local fake_pid=$!
    run_service
    local result=$?
    wait "$fake_pid" || return 1
    if [[ -e $CASE/async-request ]]; then
        local i
        for ((i = 0; i < 300; i++)); do
            [[ ! -e $CASE/async-done ]] || break
            sleep 0.01
        done
        [[ -e $CASE/async-done ]] || return 1
    fi
    return "$result"
}

cat >"$work/bin/async-systemctl" <<'EOF'
#!/bin/bash
if [[ $1 == --no-block ]]; then
    owner=$(sed -n 's/^pid=//p' "$NOVA_CHARGE_LIMIT_STATE")
    # Hold the intermediate hook phase long enough for the daemon to see it.
    printf '%s preparing\n' "$owner" >"$NOVA_CHARGE_LIMIT_STATE.handoff.async"
    mv "$NOVA_CHARGE_LIMIT_STATE.handoff.async" "$NOVA_CHARGE_LIMIT_STATE.handoff"
    touch "$CASE/async-request"
    (
        sleep 0.1
        printf '%s requested\n' "$owner" >"$NOVA_CHARGE_LIMIT_STATE.handoff.async"
        mv "$NOVA_CHARGE_LIMIT_STATE.handoff.async" "$NOVA_CHARGE_LIMIT_STATE.handoff"
        "$FAKE_SYSTEMCTL" "$@"
        touch "$CASE/async-done"
    ) >"$CASE/async.log" 2>&1 </dev/null &
    exit 0
fi
exec "$FAKE_SYSTEMCTL" "$@"
EOF
chmod +x "$work/bin/async-systemctl"

setup
check "handoff: completes" run_with_fake
check "handoff: requests one managed suspend" requested_once
check "handoff: waits for fake resume before managed pre/post hooks" \
    test "$(cat "$CASE/events")" = "$(printf 'fake-complete\nrequest\npre\npost')"
check "handoff: logs completion" output_has "managed real sleep cycle finished"
check "handoff: never writes kernel sleep or changes mem_sleep directly" no_raw_sleep
check "handoff: consumes its one-shot request" test ! -e "$CASE/state.handoff"
check "handoff: charge remains paused" test "$(<"$CASE/sys/class/power_supply/battery/constant_charge_current")" = 0
check "handoff: no audio service or watchdog changes" fails grep -Eq 'pipewire|wireplumber|Watchdog|restart|stop ' "$CASE/commands"

setup
export NOVA_CHARGE_LIMIT_SYSTEMCTL="$work/bin/async-systemctl"
export FAKE_SYSTEMCTL="$work/bin/systemctl"
check "async handoff: completes when preparation is observed between phases" run_with_fake
check "async handoff: reports completion" output_has "managed real sleep cycle finished"
check "async handoff: does not falsely report cancellation" fails output_has "managed real sleep was cancelled"
check "async handoff: still requests exactly one sleep" requested_once
unset NOVA_CHARGE_LIMIT_SYSTEMCTL FAKE_SYSTEMCTL

setup
touch "$CASE/request-fails"
run_with_fake
check "failure: reports systemd refusal" output_has "systemd refused managed real sleep: suspend denied by inhibitor"
check "failure: does not retry suspend" requested_once
check "failure: removes the handoff request" test ! -e "$CASE/state.handoff"
check "failure: never falls back to raw sleep" no_raw_sleep

setup
echo failed >"$CASE/result"
run_with_fake
check "failure: a failed real-sleep service is not counted as successful" output_has "managed real sleep was cancelled"
check "failure: reports underlying service result" grep -qF "managed sleep service failed: failed" "$CASE/hook.log"
check "failure: no repeat sleep after failed service" requested_once

setup
run_service
check "failure: stuck fake resume aborts the handoff" output_has "fake suspend did not finish cleanly"
check "failure: no real sleep while fake is still running" no_suspend
check "failure: no raw fallback when fake is stuck" no_raw_sleep

setup
touch "$CASE/show-fails"
run_with_fake
check "failure: a missing unit state is not treated as inactive" no_suspend
check "failure: missing unit state is reported" output_has "fake suspend did not finish cleanly"

for unit in systemd-suspend.service suspend.target sleep.target; do
    setup
    echo active >"$CASE/state-$unit"
    run_with_fake
    check "lifecycle: waits until $unit is inactive" no_suspend
done

setup
touch "$CASE/new-fake"
run_with_fake
check "lifecycle: a different fake-sleep cycle cancels the handoff" no_suspend
check "lifecycle: reports the changed fake cycle" output_has "a new fake suspend started"

setup
touch "$CASE/powerd-failed"
run_with_fake
check "failure: power daemon failure prevents managed suspend" no_suspend
check "failure: reports power daemon failure" output_has "armada-powerd is not running"

setup
touch "$CASE/charge-reset"
run_with_fake
check "failure: revalidates the charging pause after fake resume" no_suspend
check "failure: logs a lost charging pause" output_has "firmware no longer confirms charging is paused"

setup
touch "$CASE/no-pre"
run_with_fake
check "failure: missing managed pre-sleep hook times out" output_has "managed sleep did not complete its lifecycle"
check "failure: no repeated request when pre hook is absent" requested_once
check "failure: expired request cannot affect the next sleep" test ! -e "$CASE/state.handoff"

setup
touch "$CASE/no-post"
run_with_fake
check "failure: missing post hook doesn't trigger another suspend" requested_once
check "failure: missing post hook is reported" output_has "managed sleep did not complete its lifecycle"

setup
touch "$CASE/armada/fake-suspend.wake"
run_service
check "user wake: already requested wake is not followed by another sleep" no_suspend
check "user wake: never uses raw suspend" no_raw_sleep

setup
sed -i 's/DEEP_SLEEP_AT_LIMIT=yes/DEEP_SLEEP_AT_LIMIT=no/' "$CASE/limit.conf"
run_service
check "opt-in: disabled leaves fake suspend alone" test ! -e "$CASE/armada/fake-suspend.wake"

setup
printf 'suspend_mode = fake\n' >"$CASE/sleep.conf"
run_service
check "ownership: user's fake suspend is left alone" test ! -e "$CASE/armada/fake-suspend.wake"

setup
printf 'suspend_mode = s2idle\nsuspend_mode = fake' >"$CASE/user-sleep.conf"
run_service
check "ownership: explicit user fake mode is not overridden even with our marker" \
    test ! -e "$CASE/armada/fake-suspend.wake"

setup
echo deep >"$CASE/sys/power/mem_sleep"
run_service
check "capability: no s2idle means no handoff" test ! -e "$CASE/armada/fake-suspend.wake"

setup
echo 7200000 >"$CASE/sys/class/power_supply/battery/constant_charge_current"
chmod 444 "$CASE/sys/class/power_supply/battery/constant_charge_current"
run_service
check "charging: no handoff until the firmware confirms pause" test ! -e "$CASE/armada/fake-suspend.wake"
chmod 644 "$CASE/sys/class/power_supply/battery/constant_charge_current"

setup
touch "$CASE/unplug-on-wake"
run_with_fake
check "wake: the managed cycle ends without automatically sleeping again" requested_once
check "wake: normal awake charging policy resumes after actual wake" \
    test "$(<"$CASE/sys/class/power_supply/battery/constant_charge_current")" = 7200000

setup
printf '999999999 requested\n' >"$CASE/state.handoff"
run_with_fake
check "ownership: stale handoff file is cleared on service start" requested_once
check "ownership: no stale handoff remains" test ! -e "$CASE/state.handoff"

setup
touch "$CASE/disable-in-pre"
run_with_fake
check "pre-sleep: opt-out made during the handoff cancels the override" \
    output_has "systemd refused managed real sleep: pre-sleep hook did not select real sleep"
check "pre-sleep: opt-out removes the one-shot handoff" test ! -e "$CASE/state.handoff"

setup
printf '999999999 requested\n' >"$CASE/state.handoff"
printf 'pid=%s\nmethod=current\n' "$$" >"$CASE/state"
"$TOOL" sleep >"$CASE/out" 2>&1
check "pre-sleep: ignores another process's stale request" \
    fails grep -qx 'suspend_mode = s2idle' "$CASE/sleep.conf"
"$TOOL" sleep-finished >>"$CASE/out" 2>&1
check "post-sleep: ignores another process's request" \
    test "$(<"$CASE/state.handoff")" = '999999999 requested'

setup
printf 'pid=%s\nmethod=current\n' "$$" >"$CASE/state"
printf '%s requested\n' "$$" >"$CASE/state.handoff"
sed -i 's/DEEP_SLEEP_AT_LIMIT=yes/DEEP_SLEEP_AT_LIMIT=no/' "$CASE/limit.conf"
"$TOOL" sleep >"$CASE/out" 2>&1
check "preparation: opt-out is cancelled only when the hook exits" \
    test "$(<"$CASE/state.handoff")" = "$$ cancelled"

setup
printf 'pid=%s\nmethod=current\n' "$$" >"$CASE/state"
printf '%s requested\n' "$$" >"$CASE/state.handoff"
echo 'CHARGE_LIMIT=not-a-percentage' >"$CASE/limit.conf"
check "preparation: invalid configuration is reported as failure" \
    fails "$TOOL" sleep
check "preparation: configuration failure does not leave a preparing request" \
    test "$(<"$CASE/state.handoff")" = "$$ cancelled"

echo
if ((failures)); then echo "$failures check(s) failed"; exit 1; fi
echo "all managed sleep checks passed"
