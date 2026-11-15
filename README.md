# phone-focus-mode

GPS-based Android focus enforcer: a Magisk-backed set of shell daemons that
block distracting apps, enforce a hosts blocklist, hold a night curfew and
gate tethering — driven by whether the phone is at home. Extracted from the
`testsAndMisc` monorepo with its history.

Every change that lands on the phone lives here. `android-guardian`,
`mtk-root` and `focus-owner` were absorbed as subtrees (with their history)
and their standalone repos deleted, so a change spanning the policy and its
on-device consumer is one commit rather than a cross-repo ordering problem.

```
*.sh              the enforcers, daemons and ctl_* subcommands
lib/              the libraries they source, split under a 250-line cap
lib/tests/        35 shell suites
focus_policy/     the Python half: parses config.sh into a typed policy and
                  exports the JSON asset that focus-owner consumes
rethink_rules/    pushes config_rethink.sh's domains into RethinkDNS over
                  adb/uiautomator (the app has no import path for rules)
tests/            Python tests, plus mutation fixtures for the shell suites
focus_status_app/ the on-phone status app
docs/             design notes and policy lists

focus-owner/      the Device-Owner enforcer (Flutter + Kotlin), which consumes
                  focus_policy's exported policy.json
android-guardian/ an independent Magisk module for hosts/app blocking
mtk-root/         the MT6765 rooting toolkit that puts Magisk on the device
```

## Unrooted phone

The Pixel 6a (`23181JEGR08034`) is stock, bootloader-locked, Device Owner =
`com.kuhy.focus_owner`, and stays unrooted. `run_phone.sh` detects that (`su`
absent) and switches to a read-only mode: `adb shell` reads and `adb pull`
only, never a write to the phone.

```bash
./run_phone.sh enroll     # once, and again after each OTA (it changes the build fingerprint)
./run_phone.sh monitor    # battery, storage, Device Owner, focus_owner, RethinkDNS, private DNS
./run_phone.sh backup     # ~/phone_backups/<serial>/history/<ts>/, `latest` -> newest
./run_phone.sh auto       # what phone-auto-sync.timer runs every 30 min
```

- `monitor` marks the root-only checks (daemons, hosts, iptables, launcher,
  boot script) `skipped`, not `error`, so a healthy phone exits 0.
- `backup` uses the same capture as `phone_backup.sh`: package lists, every
  third-party APK, shared storage, settings, the Device Owner record and
  `RESTORE-BY-HAND.md`. `verify_backup` must pass before `latest` moves.
  Identical files across `history/` are hardlinked, so daily snapshots cost
  only what changed. App private data is out of reach without root.
- `auto` backs up at most once per `BACKUP_AUTO_INTERVAL_SECS` (24 h) and
  monitors every run. Losing two of `FORMAT_INDICATORS_UNROOTED` (Device
  Owner, focus_owner, RethinkDNS) means a wipe: it warns and exits 2.
- `fresh-phone` and `doctor` write to the phone and still need root.

## Secrets

`config_secrets.sh` holds `HOME_LAT` / `HOME_LON` and is **never committed**.
`config.sh` tolerates its absence so a clean clone and CI can still source it;
the enforcers simply behave as "not home" until it exists.

## Tests

```bash
python -m pytest tests focus_policy rethink_rules -q
for t in lib/tests/test_*.sh; do bash "$t"; done
```

Both run without a device or a secrets file. The suites pin their own
coordinates — see the note in `lib/tests/ctl_libs_harness.sh` about why.

**Known gap:** `lib/tests/test_magisk_service.sh` hangs instead of finishing.
It behaved the same way in the monorepo and was never wired into CI there, so
CI here skips it explicitly rather than pretending it passes.

The absorbed subtrees carry their own suites, wired into CI explicitly rather
than by glob (the root globs match neither of their layouts):

```bash
for t in android-guardian/tests/*.sh; do bash "$t"; done
./mtk-root/lib/tests/run_all.sh
cd focus-owner && flutter analyze --fatal-infos && flutter test
```
