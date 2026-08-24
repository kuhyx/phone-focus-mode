# android-guardian

A Magisk module that keeps an Android device's hosts blocklist and blocked-app
list enforced across reboots. Extracted from the `testsAndMisc` monorepo with
its history.

```
module/    the Magisk module: post-fs-data.sh, service.sh, uninstall.sh,
           module.prop, blocked_apps.txt
tests/     two suites covering the boot hook and the service loop
```

## Install

Packaged and pushed by `update_android_hosts.sh` in
[`testsAndMisc`](https://github.com/kuhyx/testsAndMisc)
(`linux_configuration/scripts/single_use/utils/`), which zips `module/` and
extracts it into `/data/adb/modules/android_guardian` over adb. Point it at a
checkout of this repo with `ANDROID_GUARDIAN_DIR`.

## Tests

```bash
for t in tests/*.sh; do bash "$t"; done
```

Both run without a device: they exercise the scripts' logic against a
throwaway worktree, not real hardware.

## Note on the extraction

`heavy_job_lock.sh` was a sibling of this module in the monorepo but did not
come with it — it is a shared lock library whose only installer is the
digital-wellbeing pacman wrapper, so it travels with that instead.
