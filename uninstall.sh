#!/usr/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Removes nova-charge-limit and lets the battery charge to 100% again.
set -euo pipefail

destdir=${DESTDIR:-}
# Tests only: with DESTDIR set, still run the systemctl steps (against a fake).
live=0
[[ -z $destdir || ${NOVA_CHARGE_LIMIT_TEST_LIVE:-0} == 1 ]] && live=1
bin_dir="$destdir/var/lib/nova-charge-limit"
bin="$bin_dir/bin/nova-charge-limit"
files=(
    "$destdir/etc/nova-charge-limit.conf"
    "$destdir/etc/systemd/system/nova-charge-limit.service"
    "$destdir/etc/systemd/system/systemd-suspend.service.d/50-nova-charge-limit.conf"
    "$destdir/etc/systemd/system/nova-charge-limit-sleep.service"
    "$destdir/etc/systemd/system/sleep.target.wants/nova-charge-limit-sleep.service"
    "$destdir/etc/udev/rules.d/90-nova-charge-limit.rules"
    "$destdir/etc/profile.d/nova-charge-limit.sh"
    "$destdir/run/nova-charge-limit-sleep.conf"
)

if ((live)); then
    [[ -n $destdir ]] || ((EUID == 0)) || { echo "uninstall.sh: run with sudo" >&2; exit 1; }
    # Stopping the service resumes charging if it had paused it. One unit per
    # call: systemctl skips the whole call if any unit is missing.
    systemctl disable --now nova-charge-limit.service 2>/dev/null || true
    if [[ -e $destdir/etc/systemd/system/nova-charge-limit-sleep.service ]]; then
        systemctl disable nova-charge-limit-sleep.service 2>/dev/null || true
    fi
    # The firmware thresholds stay set until lifted.
    if [[ -x $bin ]]; then
        "$bin" reset || echo "uninstall.sh: could not lift the limit; run: echo 100 | sudo tee /sys/class/power_supply/battery/charge_control_end_threshold" >&2
    fi
fi

rm -f "${files[@]}"
rm -rf "${bin_dir:?}"
# Only if empty: other drop-ins may share it.
rmdir "$destdir/etc/systemd/system/systemd-suspend.service.d" 2>/dev/null || true

if ((live)); then
    systemctl daemon-reload
    udevadm control --reload-rules 2>/dev/null || true
fi
echo "nova-charge-limit removed"
