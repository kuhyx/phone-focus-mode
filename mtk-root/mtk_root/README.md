# mtk_root

Host tooling for rooting a MediaTek Android device: preflight, read-only
recon, stock partition dump, and post-flash verification.

Built ahead of a Ulefone Armor X12 Pro (MediaTek Helio G36 / MT6765) arriving,
and validated read-only against a Pixel 6a.

**There is no flashing script, deliberately.** Automating irreversible
partition writes would defeat the confirmation steps that catch a wrong
partition name or a missing slot suffix. Flashing stays manual.

## Scripts

| Script              | Device needed | What it does                                                                    |
| ------------------- | ------------- | ------------------------------------------------------------------------------- |
| `install.sh`        | no            | Installs deps, clones mtkclient + builds its venv, installs narrowed udev rules |
| `00-preflight.sh`   | no            | Verifies the host is intact. Run this first when the phone arrives              |
| `10-recon.sh`       | yes           | **Read-only.** Reads every fact needed to pick a path, writes a facts file      |
| `20-dump-stock.sh`  | yes           | MediaTek only. Dumps the stock ramdisk + vbmeta via mtkclient                   |
| `90-verify-root.sh` | yes           | Post-flash checks, reported one by one                                          |

## Usage

```bash
./install.sh                 # once, or after a Python upgrade
./00-preflight.sh            # confirm the host is ready
./10-recon.sh                # read the device, decide the path
./20-dump-stock.sh           # Ulefone only, after recon
# ... patch with Magisk and flash MANUALLY ...
./90-verify-root.sh          # check what actually worked
```

Add `--serial <serial>` to any device-facing script when more than one phone
is attached; they refuse to guess rather than picking one.

## Design notes

**Partition discovery never hardcodes `boot` vs `init_boot`.** It reads
`/dev/block/by-name/`, derives the slot scheme from observed `_a` suffixes, and
picks the ramdisk carrier by preference order `init_boot` → `boot` over what is
actually present. Per AOSP, devices launching on Android 13+ carry the ramdisk
in `init_boot`; earlier devices keep it in `boot` even after upgrading. That
rule explains why the preference order is right, but the code consults the
filesystem, not the API level — so one code path serves both a Pixel (no
`init_boot`, falls through to `boot_a`) and a 13-launch MediaTek device
(`init_boot_a` taken). Patching the wrong one produces a phone that will not
boot.

**Classification refuses rather than guesses.** `ULEFONE` requires a positive
MediaTek platform signal _and_ a vendor/model match. There is no "not a Pixel,
so presumably the Ulefone" fallback: a third phone attached by accident lands
in `UNKNOWN` and every caller stops.

**Carrier lock is reported as `UNDETERMINED`, always.** No readable property
distinguishes carrier-locked from "the OEM unlocking toggle is simply off":
`sys.oem_unlock_allowed` mirrors the toggle, `ro.oem_unlock_supported` is not
populated on Pixels, and `settings get global oem_unlock_allowed` is null until
the toggle is used. Asserting a negative here would wrongly rule out a path, so
the script reports the raw signals and refuses to conclude. Settle it out of
band via an IMEI check.

**`10-recon.sh` is read-only and the tests enforce it.** `tests/run_tests.sh`
statically scans it for `fastboot`, `magiskboot`, `adb reboot/push/install`,
`settings put`, `dd`, `mkfs` and `erase`, and separately asserts the scan
_fails_ when such a command is injected into a copy — a guard never observed
failing is not known to work.

## Artifacts

Images, APKs and facts files go to `~/.cache/mtk-root/`, never into the repo:
the pre-commit hook rejects all binaries, and a factory image runs to several
GB. Only text manifests belong in git.

Ulefone firmware is deliberately **not** pre-fetched — the stock ramdisk is
dumped off the device itself, so it matches that exact unit and build.

## Tests

```bash
./tests/run_tests.sh
```

58 assertions, fully offline. Fixtures are `props.txt` + `by-name.txt`
directories fed in via `MTK_ROOT_FIXTURE`; `MTK_DUMP_CMD` stubs the mtkclient
invocation so the dump/manifest logic is exercised without hardware.

`tests/fixtures/pixel-boot-ab/` is harvested from a real Pixel 6a. The
`ulefone-*` fixtures are synthetic and encode _assumed_ property values — see
`NOTES.md`.

## Related

`../single_use/utils/root_bl9000.sh` is an older, single-device rooting script
for a Blackview MT6893. It is untouched by this toolkit and still works; the
two share no code by design, so changes here cannot break it.
