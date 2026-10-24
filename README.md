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

   The firmware applies a new charge current a little later. Read back
   straight after a change, it still reports the old value (e.g. `7200000`
   just after writing `0`). So the service remembers what it asked for and
   asks again at each check until the firmware reports it. It only warns if
   the firmware still disagrees after 3 checks (about 90 seconds). Any
   non-zero current counts as "charging allowed", since the firmware may
   report less than the maximum (e.g. `7000000` of `7200000`).

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

**The managed handoff in v1.4.0-rc.1 replaces the unsafe nested kernel sleep
used by v1.3.2.** It is a prerelease for device testing, not a confirmed fix
for every audio or kernel resume problem. v1.3.2 remains available as the
previous stable release.

```bash
nova-charge-limit deep-sleep on
nova-charge-limit deep-sleep off
```

With deep sleep enabled:

1. Put the Nova to sleep on the charger below the resume point (75% by
   default). It enters fake suspend and the limiter keeps watching charging.
2. At the limit (80%), the limiter pauses charging and waits until the
   firmware reports the pause.
3. It asks Armada to **finish fake suspend normally**, including restoring
   its power policy, thawing apps and restoring display/audio.
4. It waits for `systemd-suspend.service`, `suspend.target` and
   `sleep.target` to become inactive and checks that `armada-powerd` is
   running and charging is still paused.
5. It requests **one new suspend through systemd**, with a one-shot `s2idle`
   override. Armada's normal suspend dispatcher, systemd sleep hooks and
   user-session freeze/thaw now handle real sleep.
6. When that cycle ends, it returns to ordinary awake charging rules.
   It does not use wake-IRQ guesses to repeatedly put the Nova back to sleep.

**Trade-off:** the screen may briefly light up, a sound may play, or a game
may briefly resume between the two sleep cycles. This is intentional: the
old fake cycle must finish completely before normal real sleep begins.

If you unplug during the charging fake sleep, charging is paused and the
same managed handoff can happen. When real sleep ends, charging resumes
below the resume point, as it does after any ordinary wake. A charger
connection may wake the device; it is not automatically re-suspended.

Safety limits:

- It only acts on a fake suspend the limiter chose. An explicit
  `suspend_mode = fake` in your Armada settings is left alone.
- It won't start a handoff if fake suspend already has a wake request.
- A stuck fake resume, unavailable unit state, inactive power daemon or
  unconfirmed charging pause prevents the real-sleep request.
- If systemd refuses the request or the pre/post hooks do not complete,
  the error is logged and the handoff is not retried automatically.
- The handoff request is tied to the running limiter process and consumed
  once. Restarting the limiter clears it.
- No watchdog is disabled and no audio service is automatically restarted.

The old path wrote directly to `/sys/power/state` from inside fake suspend.
A captured long-sleep failure showed an `armada-powerd` watchdog abort,
PipeWire killed with SIGKILL, and kernel RCU warnings on wake. This release
removes that bypass. The watchdog abort is confirmed; the sender of
PipeWire's SIGKILL and any underlying kernel timekeeping fault remain
unconfirmed. An ordinary managed suspend may still expose an Armada bug.

To test this candidate from an existing checkout:

```bash
git fetch origin --tags
git switch --detach v1.4.0-rc.1
sudo bash ./install.sh
nova-charge-limit deep-sleep on
```

Existing limit/resume/deep-sleep settings are kept. To return to stable,
switch to `main`, pull, and run the installer again. A detached release
checkout cannot use `git pull` until you switch back to a branch.

After testing, collect the following over SSH before rebooting if audio
still fails:

```bash
{
  date
  /var/lib/nova-charge-limit/bin/nova-charge-limit status
  timeout 8 wpctl status
  timeout 8 wpctl get-volume @DEFAULT_AUDIO_SINK@
  systemctl --no-pager status armada-powerd.service
  journalctl --user -b --no-pager -n 150 -u pipewire -u pipewire-pulse -u wireplumber
  sudo journalctl -b --no-pager -n 200 -u nova-charge-limit -u systemd-suspend -u armada-powerd
  sudo journalctl -k -b --no-pager -n 200
} > ~/nova-managed-sleep-diagnostic.txt 2>&1
```

For SSH, first set `XDG_RUNTIME_DIR=/run/user/$(id -u)` and
`DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus` using `export`.
Review the report before sharing. It may include usernames, device names
and network details. Keep audio services intact until the failure is captured.

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
| **Fake suspend, then managed real sleep at the limit** (this project, [opt-in](#deep-sleep-at-the-limit-experimental-off-by-default)) | Software-enforced while charging; pause held in real sleep | Briefly resumes before starting a normal real-sleep cycle. Hardware verification is still needed. |
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
Version:     1.4.0-rc.1
Raw:         end_threshold=0 start_threshold=0 charge_current=0 charge_current_max=...
```

Just after a change, `Charging:` can show for example
`paused (waiting for the charger firmware, which still reports allowed)`.
That clears within a check or two.

Logs: `journalctl -u nova-charge-limit`. The service logs its version when
it starts, each pause and resume, and with deep sleep on, each switch to
real sleep and what woke the Nova. The pause before sleep is logged by
`systemd-suspend.service`; to see both, run
`journalctl -u nova-charge-limit -u systemd-suspend -b`.

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

**`could not pause charging (constant_charge_current reads back 7200000)`** or **`could not resume charging`**

These came from versions 1.1.0 to 1.3.0, and they were usually false alarms:
charging *was* paused or resumed, but the charger firmware reports the change
a little later. Version 1.3.1 no longer treats that delay as a failure.
Update and reinstall as above.

**`ignoring unknown setting DEEP_SLEEP_AT_LIMIT`**, or `status` says
**`the service runs an older version`**

The settings file is newer than the installed service. That happens when
you `git pull` and run `./nova-charge-limit` from the folder without
reinstalling, or when the installer stopped early (see below). The service
always runs the installed copy in `/var/lib/nova-charge-limit/bin`. Run
`sudo bash ./install.sh` in the updated folder. From 1.3.1 on, `set`, `off`
and `deep-sleep` also warn about this.

**`Failed to enable unit: Unit nova-charge-limit-sleep.service does not exist`**

A bug in the installers of versions 1.2.0 to 1.3.1. They removed the old
sleep unit from 1.1.0 but then still tried to enable it. The installer
stopped at that point, before restarting the service, so the old version
kept running. Version 1.3.2 fixes this. Get the latest copy and run the
installer again; it also cleans up what the failed install left behind:

```bash
cd nova-charge-limiter && git pull && sudo bash ./install.sh
```

## Uninstall

```bash
sudo bash ./uninstall.sh
```

This stops the service, turns charging back on, lifts the firmware
thresholds, and removes every installed file, including the suspend drop-in.

## Development

```bash
bash tests/nova-charge-limit-test.sh   # fake sysfs and systemd, no device needed
bash tests/managed-sleep-test.sh      # complete fake-to-managed sleep handoff
```

Keep line endings LF (`.gitattributes` enforces this); CRLF breaks the
scripts on the device.

## License

GPL-2.0-or-later, the same as Armada OS. See [LICENSE](LICENSE).
