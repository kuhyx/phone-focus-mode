# Updating and troubleshooting

## Updating

> **This section is the rooted daemon path only.** On the Device Owner phone
> (`focus-owner`) the policy is a Flutter asset compiled into the APK, so
> pushing `config.sh` achieves nothing there — regenerate the asset, rebuild
> and reinstall. See `focus-owner/README.md`, sections "Policy" and
> "Build and verify".

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
