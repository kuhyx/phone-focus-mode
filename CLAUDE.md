# CLAUDE.md

Phone focus-mode tooling: bash enforcers/daemons, `focus_policy` and
`rethink_rules` (Python), `android-guardian`, `mtk-root`, and the `focus-owner`
Flutter/Kotlin app (own suite: `flutter test` + `flutter analyze --fatal-infos`
inside `focus-owner/`; not part of the commands below).

## Commands

- run: `./run_phone.sh auto` | n/a: needs a connected phone; `--help` lists modes
- test: `scripts/test_changed.sh --all`
- test-changed: `scripts/test_changed.sh`
- lint: `git ls-files '*.sh' | xargs shellcheck`
- coverage: `python3 -m pytest -q --cov --cov-branch --cov-report=xml`
- coverage-gaps: `coverage-gaps coverage.xml`
