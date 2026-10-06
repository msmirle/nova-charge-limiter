#!/usr/bin/bash
# Installs nova-charge-limit. Everything lands in /etc and /usr/local, which
# Armada OS (bootc) keeps across OS updates.
set -euo pipefail

src=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# DESTDIR stages the files without touching the running system.
destdir=${DESTDIR:-}
limit='' resume='' force=0

usage() {
    echo "Usage: sudo ./install.sh [--limit PERCENT] [--resume PERCENT] [--force]"
    echo
    echo "  --limit   Stop charging at PERCENT (55-100, default 80 or the saved value)"
    echo "  --resume  Resume charging below PERCENT (50-95, default limit-5)"
    echo "  --force   Install even if no battery charge control is found"
}

while (($#)); do
    case $1 in
        --limit) limit=${2-}; shift ;;
        --resume) resume=${2-}; shift ;;
        --force) force=1 ;;
        -h | --help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
    shift
done
[[ -z $resume || -n $limit ]] || { echo "install.sh: --resume needs --limit" >&2; exit 2; }

if [[ -z $destdir ]]; then
    ((EUID == 0)) || { echo "install.sh: run with sudo" >&2; exit 1; }
    shopt -s nullglob
    knobs=(/sys/class/power_supply/*/charge_control_end_threshold)
    shopt -u nullglob
    if ((${#knobs[@]} == 0 && !force)); then
        echo "install.sh: this device exposes no battery charge control" >&2
        echo "(no /sys/class/power_supply/*/charge_control_end_threshold); use --force to install anyway" >&2
        exit 1
    fi
fi

bin="$destdir/usr/local/bin/nova-charge-limit"
conf="$destdir/etc/nova-charge-limit.conf"
unit="$destdir/etc/systemd/system/nova-charge-limit.service"
rules="$destdir/etc/udev/rules.d/90-nova-charge-limit.rules"

install -Dm755 "$src/nova-charge-limit" "$bin"
install -Dm644 "$src/nova-charge-limit.service" "$unit"
install -Dm644 "$src/90-nova-charge-limit.rules" "$rules"
if [[ -e $conf ]]; then
    echo "Keeping existing $conf"
else
    install -Dm644 "$src/nova-charge-limit.conf" "$conf"
fi

if [[ -n $destdir ]]; then
    echo "Staged into $destdir"
    exit 0
fi

# Files copied in from a user's home can carry the wrong SELinux label.
if command -v restorecon >/dev/null; then
    restorecon -F "$bin" "$conf" "$unit" "$rules" || true
fi
systemctl daemon-reload
systemctl enable nova-charge-limit.service
udevadm control --reload-rules || true

if [[ -n $limit ]]; then
    "$bin" set "$limit" ${resume:+"$resume"}
else
    "$bin" apply
fi
echo
"$bin" status
