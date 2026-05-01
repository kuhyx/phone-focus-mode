## Phone focus mode

Rooted-Android hardening + recovery workflow for daily backup/monitoring and
post-format recovery.

The visible entrypoint is:

```bash
./scripts/run_all/run_phone.sh
```

That wrapper forwards to `phone_focus_mode/run_phone.sh`, which orchestrates
backup, monitoring, drift repair, and full recovery.

## Quick usage

### Normal day

```bash
./scripts/run_all/run_phone.sh
```

This runs `auto` mode:

- verifies and selects one device (USB or paired wireless ADB)
- checks format indicators first
- if phone appears wiped: prints warning + suggests `fresh-phone`, then exits
- otherwise collects monitoring snapshot, runs incremental backup, applies only
  low-risk minor repairs, prints summary

`auto` never restores APK/media and never re-deploys.

### After a factory reset

```bash
./scripts/run_all/run_phone.sh fresh-phone
```

This mode:

- verifies prerequisites (ADB auth, root, Magisk runtime)
- takes pre-change snapshot
- restores security stack by delegating to `deploy.sh`
- restores safe APK/media backup items
- takes post-restore snapshot and prints required manual follow-up steps

### If something looks wrong

```bash
./scripts/run_all/run_phone.sh doctor
```

This mode:

- runs monitoring checks
- repairs common drift (daemon restarts, hosts file re-push)
- re-runs deployment only when boot persistence is missing
- avoids broad data restore actions

### Other modes

```bash
./scripts/run_all/run_phone.sh backup
./scripts/run_all/run_phone.sh monitor
./scripts/run_all/run_phone.sh --help
```

## Device targeting

Both the wrapper and `deploy.sh` support explicit device selection:

```bash
ADB_SERIAL=<device-serial> ./scripts/run_all/run_phone.sh auto
ADB_SERIAL=<device-serial> bash phone_focus_mode/deploy.sh --status
```

`deploy.sh` still supports the existing phone-IP flow:

```bash
bash phone_focus_mode/deploy.sh 192.168.1.42 --status
```

## Requirements

- rooted phone with Magisk installed
- USB debugging enabled and authorized (or paired wireless ADB)
- `adb` available on PC (`sudo pacman -S android-tools` on Arch Linux)
- location services enabled on phone

## Setup essentials

1. Set home coordinates in `phone_focus_mode/config_secrets.sh`.
2. Optionally tune whitelist and behavior in `phone_focus_mode/config.sh`.
3. Perform initial deploy:

   ```bash
   bash phone_focus_mode/deploy.sh <phone_ip>
   ```

## Systemd automation (PC user service)

Install timer-based periodic runs:

```bash
bash phone_focus_mode/systemd/install_pc_phone_automation.sh
```

This installs user units under `~/.config/systemd/user/`:

- `phone-auto-sync.service`
- `phone-auto-sync.timer` (every 30 minutes, persistent)

## Relevant files

| File                                  | Purpose                                    |
| ------------------------------------- | ------------------------------------------ |
| `scripts/run_all/run_phone.sh`        | Thin, visible wrapper for daily use        |
| `phone_focus_mode/run_phone.sh`       | Main orchestration logic                   |
| `phone_focus_mode/lib/adb_common.sh`  | ADB selection, locking, identity helpers   |
| `phone_focus_mode/lib/backup.sh`      | Incremental backup logic                   |
| `phone_focus_mode/lib/monitor.sh`     | Security/health checks and reports         |
| `phone_focus_mode/lib/restore.sh`     | Safe restore helpers used by `fresh-phone` |
| `phone_focus_mode/deploy.sh`          | Security-stack deployment primitive        |
| `phone_focus_mode/backup_manifest.sh` | Declarative backup/restore scope           |

## Notes

- Backup scope and restore policies live in `phone_focus_mode/backup_manifest.sh`.
- Sensitive coordinates should stay in `config_secrets.sh` and out of version
  control.
- On-device direct control remains available via `focus_ctl.sh`.
