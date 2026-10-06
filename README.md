# nova-charge-limiter

Stops the battery of a **Retroid Pocket Nova** running **Armada OS** from
charging past 80% (or any limit from 55% to 100%), to slow battery wear.
This is the feature asked for in
[armada-os/armada#363](https://github.com/armada-os/armada/issues/363).

## How it works

The Nova is a Snapdragon 8 Gen 2 (SM8550/QCS8550) device. Armada's kernel
driver for its charger firmware (`qcom_battmgr`) offers two ways to limit
charging. A small background service (`nova-charge-limit.service`) uses
whichever one works on your device:

1. **Charger firmware thresholds** (`charge_control_end_threshold` /
   `charge_control_start_threshold`). Where the firmware honours them, it
   stops charging at 80% and starts again below 75% by itself. The service
   only checks every 30 seconds that the limit is still set, for example
   after sleep.
2. **Pausing charging** (`constant_charge_current`). **This is what the Nova
   uses.** Its charger firmware (shared with the AYN Odin 2) accepts the
   thresholds but ignores them: they read back as 0. Instead, the service
   checks the battery every 30 seconds. At 80% it sets the battery charge
   current to 0, which pauses charging while USB keeps powering the device.
   Below 75% it restores the full charge current. Armada added this control
   in its kernel patch `0903` for bypass charging.

If the service stops (shutdown, uninstall, `off`), it always turns charging
back on, so the battery is never left unable to charge.

`/usr` (including `/usr/local`) is read-only on Armada OS, so the command
is installed to `/var/lib/nova-charge-limit/bin` and put on your `PATH` by
`/etc/profile.d/nova-charge-limit.sh`. The services and settings go in
`/etc`. Armada OS keeps both `/var` and `/etc` across OS updates, so you
don't need to rebuild the image.

## Install

1. Get this folder onto the Nova, e.g. in **Desktop Mode** open **Konsole**
   and run `git clone https://github.com/msmirle/nova-charge-limiter.git`.
2. In Konsole, run:

   ```bash
   cd nova-charge-limiter
   sudo bash ./install.sh              # limit to 80%
   # or pick your own limit and resume points:
   sudo bash ./install.sh --limit 85 --resume 75
   ```

The installer starts by printing
`Installing nova-charge-limit to /var/lib/nova-charge-limit/bin and /etc`.
It refuses to run if the device has no charge-control setting. It starts
the service, waits for its first battery check, and prints which method is
in use. Open a new terminal afterwards so the `nova-charge-limit` command
is found.

To update, `git pull` in the folder and run `sudo bash ./install.sh` again.
Your saved limit is kept.

## Usage

```bash
nova-charge-limit status      # battery level, the limit, and how it is enforced
nova-charge-limit set 80      # stop at 80%, resume below 75%
nova-charge-limit set 90 70   # stop at 90%, resume below 70%
nova-charge-limit off         # charge to 100% again
```

Every command except `status` asks for your password through `sudo` itself.
Don't type `sudo` in front: `sudo` only searches the read-only system
folders, so it reports `command not found`.

`set` and `off` save to `/etc/nova-charge-limit.conf`, so the setting
survives reboots. You can also edit that file and run
`nova-charge-limit apply`.

Example `status` output on the Nova:

```text
Device:      Retroid Pocket Nova
Configured:  stop at 80%, resume below 75% (/etc/nova-charge-limit.conf)
Battery:     80% (Not charging) at /sys/class/power_supply/battery
Service:     running; pauses charging at the limit (firmware ignores charge thresholds)
Charging:    paused
Raw:         end_threshold=0 start_threshold=0 charge_current=0 charge_current_max=...
```

Logs: `journalctl -u nova-charge-limit`. The service logs each pause and
resume.

## Notes

- **Reboots and updates:** the service starts at every boot, and the
  install survives Armada OS updates.
- **Sleep:** the service can't watch the battery while the Nova sleeps.
  Before sleep, if the battery is already at or above the resume point
  (75%), charging is paused so it can't pass the limit. If it is below that,
  charging continues during sleep and **may go past the limit**. The service
  catches up within 30 seconds of waking.
- **Powered off:** most likely not enforced. With the device off, Linux isn't
  running and the device's own charging firmware takes over, so it will
  probably charge to 100%. To keep the limit, charge while the device is on.
- The battery can go up to 1% past the limit before the next check, because
  the service checks every 30 seconds.
- Steam may show the battery as *Not charging* at the limit while plugged
  in. That's expected.
- If the charger firmware also ignores the charge current, the battery keeps
  rising while "paused". The service then logs a warning saying so; please
  open an issue with the output of `nova-charge-limit status` and
  `journalctl -u nova-charge-limit`.
- Other Snapdragon handhelds in Armada use the same driver (e.g. AYN
  Odin 2/Odin 3/Thor, Retroid Pocket 6), so this may work there too. It has
  only been designed against the Nova.

## Troubleshooting

**`install: cannot create regular file '/usr/local/bin/nova-charge-limit': Read-only file system`**

You are running an old copy of the installer. `/usr/local` is read-only on
Armada OS, and current versions don't use it. Get the latest copy and run it
again:

```bash
cd nova-charge-limiter && git pull     # if you cloned it
# or start fresh:
rm -rf nova-charge-limiter
git clone https://github.com/msmirle/nova-charge-limiter.git
cd nova-charge-limiter && sudo bash ./install.sh
```

The current installer's first line of output names `/var/lib/nova-charge-limit/bin`.

**`the charger did not accept limit 80%/resume 75% (reads back end=0 start=0)`**

This came from version 1.0.x, which only knew the firmware thresholds. The
Nova's firmware ignores those. Update and reinstall as above; the current
version pauses charging instead.

## Uninstall

```bash
sudo bash ./uninstall.sh
```

This stops the service, turns charging back on, lifts the firmware
thresholds, and removes every installed file.

## Development

```bash
bash tests/nova-charge-limit-test.sh   # fake sysfs and systemd, no device needed
```

Keep line endings LF (`.gitattributes` enforces this); CRLF breaks the
scripts on the device.

## License

GPL-2.0-or-later, the same as Armada OS. See [LICENSE](LICENSE).
