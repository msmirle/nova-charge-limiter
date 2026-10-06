# nova-charge-limiter

Stops the battery of a **Retroid Pocket Nova** running **Armada OS** from
charging past 80% (or any limit from 55% to 100%), to slow battery wear.
This is the feature asked for in
[armada-os/armada#363](https://github.com/armada-os/armada/issues/363).

## How it works

The Nova is a Snapdragon 8 Gen 2 (SM8550/QCS8550) device. Armada's kernel
driver for its charger firmware (`qcom_battmgr`) already exposes two
settings:

| File | Meaning | Range |
| --- | --- | --- |
| `/sys/class/power_supply/battery/charge_control_end_threshold` | stop charging at | 55–100 |
| `/sys/class/power_supply/battery/charge_control_start_threshold` | resume charging below | 50–95 |

When you write to them, the **charger firmware itself** enforces the limit:
it stops charging at 80% and starts again below 75%. While the limit holds,
the device still runs from USB power. Nothing needs to keep running in the
background.

The kernel does not remember these values across reboots. This project
re-applies your limit:

- at every boot (a systemd service, also triggered by a udev rule once the
  battery firmware has started), and
- after waking from suspend, in case the firmware lost it.

`/usr` (including `/usr/local`) is read-only on Armada OS, so the command
is installed to `/var/lib/nova-charge-limit/bin` and put on your `PATH` by
`/etc/profile.d/nova-charge-limit.sh`. The service, udev rule and settings
go in `/etc`. Armada OS keeps both `/var` and `/etc` across OS updates, so
you don't need to rebuild the image.

## Install

1. Copy this folder to the Nova (USB stick, SD card, `git clone`, …).
2. Switch to **Desktop Mode** and open **Konsole** in the folder.
3. Run:

   ```bash
   sudo bash ./install.sh              # limit to 80%
   # or pick your own limit and resume points:
   sudo bash ./install.sh --limit 85 --resume 75
   ```

The installer refuses to run if the device has no charge-control setting.
It applies the limit right away and prints the status. Open a new terminal
afterwards so the `nova-charge-limit` command is found.

## Usage

```bash
nova-charge-limit status      # current battery level and the active limit
nova-charge-limit set 80      # stop at 80%, resume below 75%
nova-charge-limit set 90 70   # stop at 90%, resume below 70%
nova-charge-limit off         # charge to 100% again
```

`set`, `off` and `apply` ask for your password through `sudo` themselves.
Don't type `sudo` in front: `sudo` only searches the read-only system
folders, so it reports `command not found`.

`set` and `off` save to `/etc/nova-charge-limit.conf`, so the setting
survives reboots. You can also edit that file and run
`nova-charge-limit apply`.

Example `status` output:

```text
Device:      Retroid Pocket Nova
Configured:  stop at 80%, resume below 75% (/etc/nova-charge-limit.conf)
Battery:     80% (Not charging) at /sys/class/power_supply/battery
Active:      stop at 80%, resume below 75%
```

Logs: `journalctl -u nova-charge-limit`.

## Uninstall

```bash
sudo bash ./uninstall.sh
```

This sets the limit back to 100% and removes every installed file.

## Notes

- **Reboots and updates:** the limit is re-applied at every boot, and the
  install survives Armada OS updates.
- **Sleep:** the charger firmware enforces the limit while asleep, and it is
  re-applied on wake.
- **Powered off:** most likely not enforced. With the device off, Linux isn't
  running and the device's own charging firmware takes over, so it will
  probably charge to 100%. To keep the limit, charge while the device is on
  or asleep.
- Steam may show the battery as *Not charging* at 80% while plugged in.
  That's expected.
- The firmware has no true "off" switch. `off` sets the limit to 100% (resume
  at 95%), which works the same as no limit.
- The same driver handles other Snapdragon handhelds in Armada (e.g. AYN
  Odin 2/Thor, Retroid Pocket 6). This tool finds any battery that exposes
  `charge_control_end_threshold`, so it may work there too. It has only been
  designed against the Nova.

## Development

```bash
bash tests/nova-charge-limit-test.sh   # runs against a fake sysfs, no device needed
```

Keep line endings LF (`.gitattributes` enforces this); CRLF breaks the
scripts on the device.
