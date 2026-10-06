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

Everything is installed to `/etc` and `/usr/local`. Armada OS (bootc) keeps
those across OS updates, so you don't need to rebuild the image.

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
It applies the limit right away and prints the status.

## Usage

```bash
nova-charge-limit status          # current battery level and the active limit
sudo nova-charge-limit set 80     # stop at 80%, resume below 75%
sudo nova-charge-limit set 90 70  # stop at 90%, resume below 70%
sudo nova-charge-limit off        # charge to 100% again
```

`set` and `off` save to `/etc/nova-charge-limit.conf`, so the setting
survives reboots. You can also edit that file and run
`sudo nova-charge-limit apply`.

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
