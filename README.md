# Phone Focus Mode

Location-based app restriction for a rooted Android phone using wireless ADB.

When within ~500m of home: only whitelisted productive apps remain usable.
When outside that radius: all apps work normally.

## Requirements

- Rooted phone with **Magisk** installed
- Wireless ADB enabled (`Settings → Developer options → Wireless debugging`)
- `adb` installed on your PC (`sudo apt install adb` on Debian/Ubuntu)
- GPS/Location enabled on the phone

## Setup (first time)

### 1. Find your home coordinates

Open Google Maps, right-click your apartment → copy the coordinates shown.

### 2. Edit `config_secrets.sh`

```sh
HOME_LAT="-48.876667"   # your latitude
HOME_LON="-123.393333"  # your longitude
```

### 3. (Optional) Adjust the whitelist in `config.sh`

To find the exact package name of any app:

```bash
./deploy.sh <phone_ip> --find-pkg stronglift
./deploy.sh <phone_ip> --find-pkg anki
./deploy.sh <phone_ip> --find-pkg pomodoro
```

Then add the correct package name to `WHITELIST` in `config.sh`.

### 4. Deploy

```bash
chmod +x deploy.sh
./deploy.sh 192.168.1.42        # replace with your phone's IP
```

This:

1. Pushes all scripts to `/data/local/tmp/focus_mode/` on the device
2. Installs a Magisk `service.d` script so the daemon auto-starts on boot
3. Starts the daemon immediately

## Usage

```bash
./deploy.sh <ip> --status    # Current mode, location, distance from home
./deploy.sh <ip> --log       # View recent daemon log
./deploy.sh <ip> --list      # List all apps + whitelist status
./deploy.sh <ip> --enable    # Force focus mode ON (for testing)
./deploy.sh <ip> --disable   # Force focus mode OFF
./deploy.sh <ip> --stop      # Stop daemon entirely (restores all apps)
./deploy.sh <ip> --start     # Start daemon
./deploy.sh <ip> --restart   # Restart daemon (picks up config changes)
./deploy.sh <ip> --pull-log  # Download log file to your PC
```

## How it works

```
Every 60 seconds:
  get_location()  ─── dumpsys location ──► lat,lon
        │
        ▼
  calc_distance()  ─── Haversine formula ──► meters
        │
        ├── within radius?  ──► enable_focus_mode()
        │                           pm disable-user all non-whitelisted apps
        │                           record which apps were disabled
        │
        └── outside radius? ──► disable_focus_mode()
                                    pm enable each app in the disabled list
```

**Hysteresis:** 50m buffer prevents rapid toggling at the boundary. You must travel
`radius - 50m` inward to trigger lock, and `radius + 50m` outward to unlock.

**Fail-safe:** If location is unavailable for 5 consecutive checks (~5 minutes),
focus mode is automatically disabled so you can't be locked out.

**State persistence:** The daemon records exactly which apps _it_ disabled
(in `/data/local/tmp/focus_mode/disabled_by_focus.txt`), so it never accidentally
re-enables apps that were already disabled by the user before focus mode ran.

## On-device control (without PC)

From a root terminal app (e.g. Termux + tsu):

```sh
su --mount-master -c 'sh /data/local/tmp/focus_mode/focus_ctl.sh status'
su --mount-master -c 'sh /data/local/tmp/focus_mode/focus_ctl.sh disable'
```

**Why `--mount-master`:** MagiskSU puts each `su -c` session in an isolated
mount namespace by default, so bind mounts made by the hosts enforcer would be
invisible (and `/data/adb/focus_mode/*` checks would fail due to SELinux
interactions). `--mount-master` joins the global namespace where the daemons
(started from Magisk `service.d` at boot) actually live. The boot autostart
script doesn't need this flag because `post-fs-data` already runs there.

## File layout

| File                | Purpose                                                |
| ------------------- | ------------------------------------------------------ |
| `config.sh`         | Coordinates, radius, whitelist, constants              |
| `focus_daemon.sh`   | Main daemon — runs on device, loops every 60s          |
| `focus_ctl.sh`      | Control utility — runs on device                       |
| `curfew_enforcer.sh`| Night-curfew enforcer — grayscale + DND + optional net |
| `hosts_enforcer.sh` | Bind-mounts `hosts.canonical` over `/system/etc/hosts` |
| `magisk_service.sh` | Magisk boot hook → auto-starts both daemons            |
| `deploy.sh`         | PC-side ADB deployment and control script              |

## Hosts hardening

A second daemon, `hosts_enforcer.sh`, locks the phone's `/system/etc/hosts`
to the same blocklist installed by `linux_configuration/hosts/install.sh`
on the PC. Three layers:

1. Canonical copy at `/data/adb/focus_mode/hosts.canonical` is `chattr +i`.
2. It is bind-mounted read-only over `/system/etc/hosts` at boot.
3. A watchdog verifies a sha256 every 15 seconds and restores on mismatch.

This blocks the common `echo > /etc/hosts` one-liner from a terminal app.
It is NOT a guarantee against a determined root user on the device itself —
a real "impossible without USB" gate would require removing `su` access,
which would break the rest of this system. The watchdog at least ensures
tampering is logged and reverted within ~15s.

Status and logs:

```bash
./deploy.sh <ip> --hosts-status
./deploy.sh <ip> --hosts-log
```

## Periodic rescan / Play Store

The focus daemon now **re-scans every tick** (not just on first entry). If
you re-enable an app via Play Store or `pm enable`, it gets re-disabled
within `CHECK_INTERVAL_FOCUS` seconds. `com.android.vending` (Play Store),
`com.*.packageinstaller`, and popular terminal apps are also uninstalled
`--user 0` in focus mode to close the usual bypass paths. Google Play
Services (`com.google.android.gms`) is left alone so banking apps work.

## Night curfew (after 23:00 at home)

On top of the location-based focus mode, a **time-gated curfew** makes the phone
boring and largely unusable late at night so you go to sleep instead of doom-
scrolling. It activates only when focus mode is already ON (i.e. you are at
home) **and** the local clock is inside the curfew window (default 23:00–05:00).
Out of that window, or away from home, nothing changes.

While the curfew is active it applies three allow-list layers — *block
everything except a short essential list*:

1. **Apps.** The daemon swaps the permissive `WHITELIST` for the strict
   `NIGHT_WHITELIST` (banking, maps, calendar, clock, authenticators, gov ID,
   workout/diet). Everything else — browsers, social, messaging, email, media,
   manga, stores — is `pm disable-user`'d and re-enabled automatically at
   05:00. Same proven mechanism as location focus; no new disable path.
2. **Display + notifications.** `curfew_enforcer.sh` forces the screen to
   **grayscale** and DND to **alarms-only**, re-applying every 5s so toggling
   them off in Settings snaps back. (Snap-back is the realistic lock; truly
   blocking Settings risks system instability, so it is deliberately avoided.)
3. **Internet (optional, default OFF).** A per-UID `iptables` allow-list that
   gives network only to the `NIGHT_WHITELIST` apps (plus root/system/shell +
   DNS) and cuts off every other app. Enable `CURFEW_NET_ENABLED=1` in
   `config.sh` only after validating it on-device (see test hook below).

### Configuration (`config.sh`)

```sh
NIGHT_CURFEW_ENABLED=1       # master switch
NIGHT_CURFEW_START="2300"    # local HHMM; window wraps past midnight
NIGHT_CURFEW_END="0500"
CURFEW_GRAYSCALE_ENABLED=1   # force monochrome
CURFEW_DND_ENABLED=1         # force DND alarms-only
CURFEW_NET_ENABLED=0         # per-UID internet allow-list (prove first!)
```

Edit `NIGHT_WHITELIST` (right below `WHITELIST`) to choose what stays usable at
night. Allow-list by design: when in doubt, leave it out. The active keyboard
and the core dialer/SMS/home apps are always protected automatically (a 1am
reboot can never strand you without a keyboard), and the default browser is
intentionally *not* protected at night so it can be disabled.

### Control

```bash
# On-device (root shell):
focus_ctl.sh curfew-status     # window, enforcer state, what's applied
focus_ctl.sh curfew-test-on    # FORCE curfew now (daytime validation)
focus_ctl.sh curfew-test-off   # clear the force
focus_ctl.sh curfew-off        # escape hatch: suspend curfew now
focus_ctl.sh curfew-on         # re-arm (clear the override)
focus_ctl.sh curfew-log        # enforcer log
```

### Opting out at 2am (no PC)

The companion status notification grows a **"Suspend curfew till morning"**
action while the curfew is active. Tapping it drops the override file (curfew
off until you re-arm); the label flips to **"Re-arm curfew"**. The action is
hidden during the day so it is not a casual temptation. Without the PC this is
the only on-device opt-out — by design. From the PC you can always
`./deploy.sh <ip> --restart` or run `focus_ctl.sh curfew-off` over ADB.

### Validating before you trust it overnight

Because a misconfigured curfew can lock apps at 2am, validate it during the day
with the force hook, **not** by waiting for 23:00:

```bash
focus_ctl.sh curfew-test-on    # mBank + keyboard work, Firefox gone, gray, DND
focus_ctl.sh curfew-test-off   # blocked apps come BACK (the reconcile path)
```

The clock parser fails **open** (treated as daytime) on a malformed time, so a
broken `date` can never trap you behind the strict list.

## Updating

After editing `config.sh` (e.g. changing whitelist):

```bash
./deploy.sh <ip>             # re-pushes all files
# or just the config:
adb push config.sh /data/local/tmp/focus_mode/config.sh
./deploy.sh <ip> --restart
```

## Troubleshooting

**Location always unavailable:**

- Enable GPS and network location on the phone
- Open Google Maps once to warm up the GPS provider
- The daemon logs every attempt; check with `--log`

**App won't disable:**

- Some system apps can't be disabled even as root; they're silently skipped
- Check log for "Failed to disable" warnings

**Daemon not starting on boot:**

- Verify Magisk is installed and `service.d` is supported
- Check `/data/adb/service.d/99-focus-mode.sh` exists and is executable
- Some Magisk versions use `/data/adb/post-fs-data.d/` instead; try both

**Wrong package name in whitelist:**

- Use `./deploy.sh <ip> --find-pkg <keyword>` to find the exact package name
- Package names are case-sensitive
