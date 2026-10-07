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

### Sleep

Real sleep (`s2idle`) freezes the service, so nothing could stop charging
at the limit. Unlike the Steam Deck, the Nova has nothing that keeps
enforcing it while asleep. So just before each sleep, `nova-charge-limit`
picks the sleep mode:

| When the Nova goes to sleep… | What happens |
| --- | --- |
| plugged in, battery below the resume point (75%) | It sleeps in Armada's **fake suspend**: screen, sound, lights, input and your apps are off or frozen, but the service keeps running. It charges to 80%, pauses, and stays there. |
| plugged in, battery at 75% or more | Charging is paused, then it sleeps normally. |
| unplugged | Charging is paused, then it sleeps normally. If you plug it in while it's asleep, it won't charge until you wake it. |

On waking, the service resumes charging if the battery is below 75%.

This uses a drop-in for Armada's `systemd-suspend.service`. Before each
sleep, the drop-in has `suspend-dispatch` read a copy of your
`/etc/armada/sleep.conf` (in `/run`), with `suspend_mode = fake` added only
for that one sleep. Your own sleep setting isn't changed.

See [Why it doesn't work like the Steam Deck](#why-it-doesnt-work-like-the-steam-deck)
for why fake suspend is needed and what the alternatives are.

### Deep sleep at the limit (experimental, off by default)

Fake suspend uses more power than real sleep, and it keeps doing so after
the battery reaches the limit. With deep sleep at the limit turned on, the
Nova switches to real sleep once charging pauses:

```bash
nova-charge-limit deep-sleep on    # turn it on
nova-charge-limit deep-sleep off   # back to plain fake suspend
```

1. You put the Nova to sleep on the charger below 75%. It sleeps in fake
   suspend and charges, as above.
2. At 80% the service pauses charging. That pause holds through real sleep.
3. The service then enters real sleep (`s2idle`) from inside the fake
   suspend. The screen, input and your apps stay off.
4. You press the power button. The Nova wakes from real sleep, and fake
   suspend wakes the screen and apps as usual.

After any other wake, the service decides what to do:

| What woke the Nova | What happens |
| --- | --- |
| Power button, or anything the service can't identify | It never goes back to real sleep for this sleep. If fake suspend hasn't woken up after 3 seconds, the service asks it to (`/run/armada/fake-suspend.wake`), so the screen doesn't stay off. |
| Anything else, e.g. the charger being plugged in or unplugged | It checks the battery. If charging is paused, or the charger was unplugged (charging is then paused), it goes back to real sleep. If the charger is plugged in and the battery is below 75%, charging resumes and it stays in fake suspend until 80%. |

The wake reason comes from `/sys/power/pm_wakeup_irq` and
`/proc/interrupts`. Anything named like `pwrkey`, `resin`, `power`, `key`,
`lid` or `hall` counts as you waking it.

Safety limits:

- It only applies to a fake suspend that `nova-charge-limit` chose. If you
  set `suspend_mode = fake` in `/etc/armada/sleep.conf` yourself, it leaves
  that alone.
- If the Nova wakes up 5 times in a row within 30 seconds of entering real
  sleep, or real sleep fails 3 times, it gives up and stays in fake suspend
  for the rest of that sleep.
- The inner real sleep skips Armada's sleep hooks (wake logging, controller
  lights, power-button handling). Fake suspend has already turned those off.

It's experimental because it hasn't been tried on a Nova yet. If waking up
ever takes more than one power-button press, or the screen stays off, turn
it off with `nova-charge-limit deep-sleep off` and open an issue with the
output of `journalctl -u nova-charge-limit -b`.

### Install locations

`/usr` (including `/usr/local`) is read-only on Armada OS, so the command
is installed to `/var/lib/nova-charge-limit/bin` and put on your `PATH` by
`/etc/profile.d/nova-charge-limit.sh`. The service, the suspend drop-in and
the settings go in `/etc`. Armada OS keeps both `/var` and `/etc` across OS
updates, so you don't need to rebuild the image.

## Why it doesn't work like the Steam Deck

On the Steam Deck, the charge limit holds whether the Deck is awake,
asleep or powered off. On the Nova it needs fake suspend to hold during
sleep, and it can't hold at all while the Nova is off. This section
explains why, and what it would take to match the Deck.

### How the Steam Deck does it

SteamOS doesn't enforce the limit itself. It hands the limit to the Deck's
**embedded controller** (EC), a small chip that runs the charger
independently of the main processor. SteamOS writes it through the
`jupiter` ACPI driver (`max_battery_charge_level`). Because the EC keeps
running on its own, it stops charging at the limit while the Deck is
awake, asleep or off. Most laptops' "battery conservation" modes work the
same way.

### What the Nova has instead

The Nova's equivalent of the EC is the **charger firmware**. It runs on a
separate Qualcomm processor (the ADSP) and is controlled by Linux's
`qcom_battmgr` driver. That firmware offers two relevant controls:

| Control | What it should do | Does it work on the Nova? |
| --- | --- | --- |
| `charge_control_end_threshold` / `charge_control_start_threshold` | Stop charging at X%, resume below Y% (EC-style) | **No.** The firmware accepts the values, but they read back as `0` and are ignored. With v1.1.0 the 80% limit was sent to the firmware, and the battery still charged from 69% to 96% while asleep. |
| `constant_charge_current` (added by Armada's kernel patch `0903`) | Battery charge current; `0` stops charging while USB keeps powering the device | **Yes**, and the setting holds through sleep. |

The working control is an **on/off switch**, not a "stop at 80%" setting.
Something has to watch the battery level and flip the switch at the right
moment. That's what the `nova-charge-limit` service does.

### Why fake suspend is needed

Real sleep (`s2idle`) freezes every program, including the service, so
nothing can flip the switch at 80% while the Nova sleeps. The firmware
keeps whichever state it was given before sleep:

- **Charging on:** it charges past the limit (the 96% case).
- **Charging off:** it doesn't charge at all until you wake it.

Fake suspend is Armada's own lighter sleep mode. It turns the screen,
sound, lights and input off and freezes your apps, but leaves system
services running. Using it only while charging toward the limit keeps the
limit exact. The cost is that the Nova uses more power during that sleep
than in real sleep. The charger supplies that power, but if you unplug
during the sleep, the battery drains faster.

### The options

| Approach | Exact limit in sleep? | Downsides |
| --- | --- | --- |
| **Fake suspend** (what this project does) | Yes | More power used while asleep on the charger. Unplugging during that sleep drains the battery faster. |
| **Fake suspend, then real sleep at the limit** (this project, [opt-in](#deep-sleep-at-the-limit-experimental-off-by-default)) | Yes | Only uses fake suspend while charging. Experimental: relies on the power button wake being recognised. |
| **Periodic wake-ups**: real sleep, with an RTC alarm waking the Nova every few minutes to check | Roughly; can overshoot by a few % between checks | Unverified that the Nova's RTC alarm can wake it from sleep. Each wake may briefly turn the screen and Steam back on. Not recommended. |
| **Kernel change in Armada** | Yes, in real sleep | Closest to the Deck. Has to be accepted into Armada and shipped in an OS update. |

### The kernel option in detail

The closest match to the Deck would put the "stop at X%" logic in the
kernel instead of in a program:

- **How it would work:** the charger firmware already sends battery
  updates (`NOTIF_BAT_STATUS` and similar) to `qcom_battmgr`, which reports
  them with `power_supply_changed()`. The driver could check the battery
  level on each update and set the charge current to `0` at the limit. The
  kernel can handle that during real sleep without waking your apps.
- **Precedent:** Armada already does something similar. Kernel patch
  `0532` keeps the fan running while charging in sleep. It registers a
  power-supply notifier (`power_supply_reg_notifier`) and reacts to charger
  events during suspend-to-idle (`PM_SUSPEND_TO_IDLE`). `armada-powerd`
  turns it on through `pwm1_sleep_charging`.
- **Who it would help:** every Armada device that uses `qcom_battmgr`,
  including the AYN Odin 2 and Thor and the Retroid Pocket 6 mentioned in
  [armada-os/armada#363](https://github.com/armada-os/armada/issues/363).
- **Caveats:** it can't be added from outside the OS image; it would need
  a pull request to Armada and a new Armada release. It's also unverified
  whether the Nova's charger firmware sends battery updates during sleep.
  Patch `0532` has the same caveat: it only works with power-supply
  drivers that keep reporting during suspend-to-idle.

### Powered off

None of these options can keep the limit while the Nova is fully powered
off. Linux isn't running, so the device's own boot-time charging firmware
takes over and will most likely charge toward 100%. The Deck manages it
only because its EC enforces the limit independently. On the Nova, that
would need the charger firmware to honour `charge_control_end_threshold`,
and it doesn't.

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
nova-charge-limit status          # battery level, the limit, and how it is enforced
nova-charge-limit set 80          # stop at 80%, resume below 75%
nova-charge-limit set 90 70       # stop at 90%, resume below 70%
nova-charge-limit off             # charge to 100% again
nova-charge-limit deep-sleep on   # experimental: real sleep once the limit is reached
nova-charge-limit deep-sleep off
```

Every command except `status` asks for your password through `sudo` itself.
Don't type `sudo` in front: `sudo` only searches the read-only system
folders, so it reports `command not found`.

`set`, `off` and `deep-sleep` save to `/etc/nova-charge-limit.conf`, so the
settings survive reboots and updates. You can also edit that file and run
`nova-charge-limit apply`.

Example `status` output on the Nova:

```text
Device:      Retroid Pocket Nova
Configured:  stop at 80%, resume below 75% (/etc/nova-charge-limit.conf)
Deep sleep:  off
Battery:     80% (Not charging) at /sys/class/power_supply/battery
Service:     running; pauses charging at the limit (firmware ignores charge thresholds)
Charging:    paused
Raw:         end_threshold=0 start_threshold=0 charge_current=0 charge_current_max=...
```

Logs: `journalctl -u nova-charge-limit`. The service logs each pause and
resume, and with deep sleep on, each switch to real sleep and what woke the
Nova.

## Notes

- **Reboots and updates:** the service starts at every boot, and the
  install survives Armada OS updates.
- **Sleep:** see [Sleep](#sleep). While in the charging fake suspend, the
  Nova uses more power than in real sleep, but it comes from the charger. If
  you unplug it during that sleep, wake it and put it back to sleep so it
  goes into real sleep and drains less.
- **Powered off:** most likely not enforced. With the device off, Linux isn't
  running and the device's own charging firmware takes over, so it will
  probably charge to 100%. To keep the limit, charge while the device is on
  or asleep. See [Powered off](#powered-off).
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
thresholds, and removes every installed file, including the suspend drop-in.

## Development

```bash
bash tests/nova-charge-limit-test.sh   # fake sysfs and systemd, no device needed
```

Keep line endings LF (`.gitattributes` enforces this); CRLF breaks the
scripts on the device.

## License

GPL-2.0-or-later, the same as Armada OS. See [LICENSE](LICENSE).
