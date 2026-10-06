#!/usr/bin/bash
# Removes nova-charge-limit and lets the battery charge to 100% again.
set -euo pipefail

destdir=${DESTDIR:-}
bin="$destdir/usr/local/bin/nova-charge-limit"
files=(
    "$bin"
    "$destdir/etc/nova-charge-limit.conf"
    "$destdir/etc/systemd/system/nova-charge-limit.service"
    "$destdir/etc/udev/rules.d/90-nova-charge-limit.rules"
)

if [[ -z $destdir ]]; then
    ((EUID == 0)) || { echo "uninstall.sh: run with sudo" >&2; exit 1; }
    systemctl disable --now nova-charge-limit.service 2>/dev/null || true
    # Lift the limit now; the charger firmware does not drop it on its own.
    if [[ -x $bin ]]; then
        "$bin" off || echo "uninstall.sh: could not lift the limit; run: echo 100 | sudo tee /sys/class/power_supply/battery/charge_control_end_threshold" >&2
    fi
fi

rm -f "${files[@]}"

if [[ -z $destdir ]]; then
    systemctl daemon-reload
    udevadm control --reload-rules || true
fi
echo "nova-charge-limit removed"
