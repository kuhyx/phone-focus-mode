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

### 2. Edit `config.sh`

```sh
HOME_LAT="52.123456"   # your latitude
HOME_LON="21.098765"   # your longitude
RADIUS=500             # meters
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
su -c 'sh /data/local/tmp/focus_mode/focus_ctl.sh status'
su -c 'sh /data/local/tmp/focus_mode/focus_ctl.sh disable'
```

## File layout

| File                | Purpose                                       |
| ------------------- | --------------------------------------------- |
| `config.sh`         | Coordinates, radius, whitelist, constants     |
| `focus_daemon.sh`   | Main daemon — runs on device, loops every 60s |
| `focus_ctl.sh`      | Control utility — runs on device              |
| `magisk_service.sh` | Magisk boot hook → auto-starts daemon         |
| `deploy.sh`         | PC-side ADB deployment and control script     |

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
