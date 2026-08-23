# phone-focus-mode

GPS-based Android focus enforcer: a Magisk-backed set of shell daemons that
block distracting apps, enforce a hosts blocklist, hold a night curfew and
gate tethering — driven by whether the phone is at home. Extracted from the
`testsAndMisc` monorepo with its history.

```
*.sh              the enforcers, daemons and ctl_* subcommands
lib/              the libraries they source, split under a 250-line cap
lib/tests/        35 shell suites
focus_policy/     the Python half: parses config.sh into a typed policy and
                  exports the JSON asset that focus-owner consumes
tests/            Python tests, plus mutation fixtures for the shell suites
focus_status_app/ the on-phone status app
docs/             design notes and policy lists
```

## Secrets

`config_secrets.sh` holds `HOME_LAT` / `HOME_LON` and is **never committed**.
`config.sh` tolerates its absence so a clean clone and CI can still source it;
the enforcers simply behave as "not home" until it exists.

## Tests

```bash
python -m pytest tests focus_policy -q     # 161 tests
for t in lib/tests/test_*.sh; do bash "$t"; done
```

Both run without a device or a secrets file. The suites pin their own
coordinates — see the note in `lib/tests/ctl_libs_harness.sh` about why.

**Known gap:** `lib/tests/test_magisk_service.sh` hangs instead of finishing.
It behaved the same way in the monorepo and was never wired into CI there, so
CI here skips it explicitly rather than pretending it passes.

## Related repos

- [`focus-owner`](https://github.com/kuhyx/focus-owner) — the Device-Owner
  enforcer, which consumes `focus_policy`'s exported `policy.json`.
- [`android-guardian`](https://github.com/kuhyx/android-guardian) — an
  independent Magisk module for hosts/app blocking.
