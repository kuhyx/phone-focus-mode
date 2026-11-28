# CLAUDE.md

Phone focus-mode tooling: bash enforcers/daemons, `focus_policy` and
`rethink_rules` (Python), `android-guardian`, `mtk-root`, and the `focus-owner`
Flutter/Kotlin app (own suite: `flutter test` + `flutter analyze --fatal-infos`
inside `focus-owner/`; not part of the commands below).

## Commands

- run: `./run_phone.sh auto` | n/a: needs a connected phone; `--help` lists modes
- test: `scripts/test_changed.sh --all`
- test-changed: `scripts/test_changed.sh`
- lint: n/a: dropped (kuhy, 2026-11-27)
- coverage: n/a: dropped (kuhy, 2026-11-27)
- coverage-gaps: n/a: dropped (kuhy, 2026-11-27)
- deploy: `scripts/deploy_owner.sh` | release build + `adb install -r` of focus-owner on the Pixel, health = versionCode rose and still device owner
