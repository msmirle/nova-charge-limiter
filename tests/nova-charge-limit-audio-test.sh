#!/usr/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -uo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "${work:?}"' EXIT
mkdir -p "$work/bin" "$work/runtime/1000"
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

cat >"$work/bin/runuser" <<'EOF'
#!/bin/bash
echo "$*" >>"$FAKE_AUDIO/runuser.log"
[[ $1 == -u && $2 == test-session && $3 == -- ]] || exit 1
shift 3
exec "$@"
EOF
cat >"$work/bin/id" <<'EOF'
#!/bin/bash
if [[ $* == '-u test-session' ]]; then echo 1000; else /usr/bin/id "$@"; fi
EOF
cat >"$work/bin/wpctl" <<'EOF'
#!/bin/bash
echo "$*" >>"$FAKE_AUDIO/commands"
printf '%s\n%s\n' "$XDG_RUNTIME_DIR" "$DBUS_SESSION_BUS_ADDRESS" >"$FAKE_AUDIO/env"
counter="$FAKE_AUDIO/$1-failures"
if [[ -e $counter && $(<"$counter") -gt 0 ]]; then
    echo "$(( $(<"$counter") - 1 ))" >"$counter"
    echo "audio server not ready" >&2
    exit 1
fi
case $1 in
    inspect)
        printf 'id %s, type PipeWire:Interface:Node\n' "$(<"$FAKE_AUDIO/id")"
        if [[ ! -e $FAKE_AUDIO/no-name ]]; then
            printf '  * node.name = "%s"\n' "$(<"$FAKE_AUDIO/name")"
        fi
        ;;
    get-volume)
        [[ $2 == "$(<"$FAKE_AUDIO/id")" ]] || exit 1
        printf 'Volume: 0.65'
        [[ $(<"$FAKE_AUDIO/muted") == 0 ]] || printf ' [MUTED]'
        echo
        ;;
    set-mute)
        [[ $2 == "$(<"$FAKE_AUDIO/id")" ]] || exit 1
        [[ -e $FAKE_AUDIO/ignore-set ]] || echo "$3" >"$FAKE_AUDIO/muted"
        ;;
    *) echo "unexpected audio command" >&2; exit 1 ;;
esac
EOF
cat >"$work/bin/systemctl" <<'EOF'
#!/bin/bash
echo "$*" >>"$FAKE_AUDIO/systemctl.log"
if [[ -e $FAKE_AUDIO/restart-fails ]]; then
    echo "audio service restart failed" >&2
    exit 1
fi
EOF
cat >"$work/bin/journalctl" <<'EOF'
#!/bin/bash
echo "test journal: $*"
EOF
chmod +x "$work/bin/"*

setup() {
    rm -rf "$work/fake"
    mkdir -p "$work/fake"
    echo alsa_output.nova >"$work/fake/name"
    echo 71 >"$work/fake/id"
    echo 0 >"$work/fake/muted"
}
run() {
    PATH="$work/bin:$PATH" FAKE_AUDIO="$work/fake" ARMADA_SESSION_USER=test-session \
        XDG_RUNTIME_DIR="$work/runtime/1000" DBUS_SESSION_BUS_ADDRESS="unix:path=$work/runtime/1000/bus" \
        NOVA_CHARGE_LIMIT_AUDIO_STATE="$work/fake/state" \
        NOVA_CHARGE_LIMIT_AUDIO_RUNTIME="$work/runtime" \
        NOVA_CHARGE_LIMIT_AUDIO_RETRY_DELAY=0 \
        NOVA_CHARGE_LIMIT_ALLOW_NONROOT=1 \
        bash "${target:-$repo/nova-charge-limit-audio}" "$@" >"$work/out" 2>&1
}
output_has() { grep -qF -- "$1" "$work/out"; }
called() { grep -qxF -- "$1" "$work/fake/commands"; }
not_called() { ! called "$1"; }
muted_is() { [[ $(<"$work/fake/muted") == "$1" ]]; }
calls() { (($(grep -cxF -- "$1" "$work/fake/commands") == $2)); }

# Reproduce Armada's one-shot unmute failing while the server is not ready.
setup
check "save: succeeds" run save
check "save: private snapshot" test "$(stat -c %a "$work/fake/state")" = 600
check "save: targets the session user, not root" grep -q '^-u test-session -- env ' "$work/fake/runuser.log"
check "save: supplies the runtime directory" grep -qxF "$work/runtime/1000" "$work/fake/env"
check "save: supplies the user bus" grep -qxF "unix:path=$work/runtime/1000/bus" "$work/fake/env"
echo 1 >"$work/fake/muted"
echo 2 >"$work/fake/set-mute-failures"
check "resume: survives two rejected unmute attempts" run restore
check "resume: restores sound after a transient failure" muted_is 0
check "resume: retries the failed command" calls "set-mute 71 0" 3
check "resume: logs the recovery" output_has "restored output alsa_output.nova (muted=0)"
check "resume: consumes the snapshot" test ! -e "$work/fake/state"
check "resume: a duplicate restore does nothing" run restore
check "resume: no duplicate audio command" calls "set-mute 71 0" 3

setup
run save
echo 1 >"$work/fake/muted"
echo 2 >"$work/fake/inspect-failures"
check "resume: retries while the sink is unavailable" run restore
check "resume: recovers after the sink returns" muted_is 0

setup
run save
echo 1 >"$work/fake/muted"
echo 2 >"$work/fake/get-volume-failures"
check "resume: retries a transient volume query failure" run restore
check "resume: volume query recovery" muted_is 0

setup
echo 1 >"$work/fake/muted"
run save
echo 0 >"$work/fake/muted"
check "resume: a deliberately muted device stays muted" run restore
check "resume: re-mutes after Armada unconditionally unmuted it" muted_is 1
check "resume: restores mute without changing volume" called "set-mute 71 1"

setup
run save
check "resume: already correct state succeeds" run restore
check "resume: no unnecessary unmute" not_called "set-mute 71 0"

setup
run save
echo 1 >"$work/fake/muted"
echo 92 >"$work/fake/id"
check "resume: accepts a recreated sink with the same name" run restore
check "resume: uses the new node id, not a stale id" called "set-mute 92 0"
check "resume: never uses the old node id" not_called "set-mute 71 0"

setup
run save
echo bluez_output.headphones >"$work/fake/name"
echo 1 >"$work/fake/muted"
check "resume: changed default output is not modified" run restore
check "resume: leaves new headphones muted" muted_is 1
check "resume: logs the changed output" output_has "default output changed"

setup
run save
echo 1 >"$work/fake/muted"
echo 99 >"$work/fake/inspect-failures"
check "resume: persistent failure is not success-shaped" fails run restore
check "resume: retries are bounded" test "$(<"$work/fake/inspect-failures")" = 94
check "resume: includes the underlying failure" output_has "audio mute recovery failed after 5 attempts: cannot inspect the default output: audio server not ready"
check "resume: logs where to diagnose deeper problems" output_has "journalctl --user"

setup
run save
echo 1 >"$work/fake/muted"
touch "$work/fake/ignore-set"
check "resume: verifies the unmute took effect" fails run restore
check "resume: logs an ignored write" output_has "did not keep its pre-sleep mute state"

setup
run save
touch "$work/fake/no-name"
check "save: invalid sink information fails" fails run save
check "save: failed save clears a previous snapshot" test ! -e "$work/fake/state"
check "save: logs the invalid output" output_has "wpctl inspect did not identify an output node"
check "restore: no saved snapshot means no action" run restore

setup
printf 'not\na\nvalid\nsnapshot\n' >"$work/fake/state"
check "restore: invalid snapshot is rejected" fails run restore
check "restore: explains the invalid snapshot" output_has "invalid audio snapshot"
check "restore: does not source a snapshot as code" test ! -e "$work/fake/commands"
check "usage: missing action fails" fails run
check "usage: extra arguments fail" fails run save extra

if ((EUID != 0)); then
    setup
    echo 1 >"$work/fake/muted"
    check "recover: explicitly restarts the logged-in user's audio services" run recover
    check "recover: correct services and user scope" grep -qxF -- \
        '--user restart pipewire.service pipewire-pulse.service wireplumber.service' "$work/fake/systemctl.log"
    check "recover: warns about stream interruption" output_has "active audio streams will be interrupted"
    check "recover: preserves deliberate mute" muted_is 1
    check "recover: doesn't elevate or use the root audio session" test ! -e "$work/fake/runuser.log"
    check "recover: doesn't pretend to verify audible playback" output_has "cannot verify the speakers or DSP"

    setup
    touch "$work/fake/restart-fails"
    check "recover: a failed restart is reported as failure" fails run recover
    check "recover: includes service manager error" output_has "audio service restart failed"
    check "recover: suggests diagnostics" output_has "nova-charge-limit audio-diagnose"

    setup
    echo 99 >"$work/fake/inspect-failures"
    check "recover: restart alone doesn't count as a recovered output" fails run recover
    check "recover: confirms missing output" output_has "no usable output returned"

    setup
    check "diagnose: completes" run diagnose
    check "diagnose: reports audio services" output_has \
        "## systemctl --user --no-pager status pipewire.service pipewire-pulse.service wireplumber.service"
    check "diagnose: includes sleep and limiter logs" output_has "-u nova-charge-limit -u systemd-suspend"
    check "diagnose: includes kernel logs" output_has "## journalctl -k -b"
    check "diagnose: records individual command exit statuses" output_has "exit_status="
    check "diagnose: no restart command" fails grep -q restart "$work/fake/systemctl.log"

    setup
    target="$repo/nova-charge-limit"
    check "CLI: routes audio-recover to the installed sibling helper" run audio-recover
    check "CLI: recovery checks the output" output_has "audio services restarted; output alsa_output.nova responds"
    check "CLI: routes audio-diagnose to the helper" run audio-diagnose
    check "CLI: includes the audio diagnostic" output_has "Nova charge limiter audio diagnostic"
    check "CLI: audio-recover rejects extra arguments" fails run audio-recover extra
    unset target
fi

echo
if ((failures)); then
    echo "$failures check(s) failed"
    exit 1
fi
echo "all audio checks passed"
