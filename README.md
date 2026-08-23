# mtk-root

MediaTek (MT6765) rooting toolkit — preflight, recon, stock dump, and root
verification for a Ulefone X12 Pro, extracted from the `testsAndMisc`
monorepo with its history.

```
mtk_root/     the numbered stages, install.sh and udev rules
              -> start at mtk_root/README.md, and READY.md for the
                 arrival-day sequence
lib/          mtk_common / mtk_classify / mtk_device / mtk_partitions,
              sourced by the stages as ../lib/<name>.sh
lib/tests/    84 tests; run ./lib/tests/run_all.sh
```

These libraries lived in `linux_configuration/scripts/lib/` in the monorepo,
one directory up from the stages that source them. That relative layout is
preserved here, so every `source "$SCRIPT_DIR/../lib/..."` resolves unchanged.

CI runs shellcheck over every script with no severity filter (see
`.shellcheckrc`) plus the full test suite.
