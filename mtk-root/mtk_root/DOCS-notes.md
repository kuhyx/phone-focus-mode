# mtk_root — build notes, surprises, and mistakes

Written 2026-08-04, while preparing for a Ulefone Armor X12 Pro that had not
yet arrived.

## Installed versions (this host, 2026-08-04)

| Tool              | Version                          |
| ----------------- | -------------------------------- |
| adb               | 1.0.41 (android-tools)           |
| fastboot          | 37.0.0-android-tools             |
| python3           | 3.14.6                           |
| shellcheck        | present                          |
| shfmt             | 3.13.1                           |
| systemd / udevadm | 261 (`udevadm verify` available) |
| mtkclient         | rev `0542a87`, 2026-08-02        |
| Magisk            | v30.7                            |

## Magisk provenance

Kept here as well as in `~/.cache/mtk-root/stock/README.md`, because the cache
is not version-controlled and vanishes with a cleanup.

| field   | value                                                              |
| ------- | ------------------------------------------------------------------ |
| version | v30.7 (released 2026-02-23)                                        |
| asset   | `Magisk-v30.7.apk`                                                 |
| sha256  | `e0d32d2123532860f97123d927b1bb86c4e08e6fd8a48bfc6b5bee0afae9ebd5` |
| size    | 11613864 bytes                                                     |

**Trap:** the same GitHub release also publishes **`app-debug.apk`** (~25 MB),
and a naive "first .apk asset" match picks it. That is the debug build, not the
one to install. I hit this during the fetch. Match the filename exactly.

Re-check before use:

```bash
curl -fsSL https://api.github.com/repos/topjohnwu/Magisk/releases/latest \
  | grep -E '"(tag_name|browser_download_url)"'
```

## Surprises

**1. The Ulefone is probably the `init_boot` branch, not `boot`.**
The Armor X12 Pro launched on Android 13 (Aug 2023). Per AOSP, devices
_launching_ on 13+ carry the ramdisk in `init_boot`, so the Ulefone is likely
the opposite branch from the Pixel used to validate this toolkit. The Pixel run
therefore does **not** exercise the code path the Ulefone will need. Fixtures
cover it; hardware has not.

**2. The mtkclient venv on this host was broken, not missing.**
`~/.cache/bl9000-root/mtkclient/venv` existed and looked complete, but every
`import usb` failed under Python 3.14 — a Python upgrade had orphaned it. This
is why `00-preflight.sh` tests _importability_ rather than directory existence:
the failure mode that costs an evening is the one that looks fine on disk.

**3. `/etc/udev/rules.d/51-android.rules` had a world-writable catch-all.**
`ATTR{idVendor}=="*", ATTR{idProduct}=="*", MODE="0666"` grants every local
process read/write access to _every_ USB device — storage, security keys, not
just phones. Commented out on 2026-08-04 via `install.sh --fix-udev`; backup at
`51-android.rules.bak-20260804T183038Z`. adb connectivity was re-verified
afterwards. Note `51-pinephone.rules` still sets `MODE="0666"`, but scoped to
specific devices rather than a wildcard.

**4. SIGPIPE killed the preflight script.**
`adb version | head -1` under `set -o pipefail` exits 141 when `head` closes the
pipe. The script aborted mid-run on its very first execution. Version strings
are now captured whole and sliced with parameter expansion.

**5. A test fix silently punched a hole in the read-only guard.**
To stop the static scan tripping on the word "fastboot" inside `printf` text, I
first stripped _all_ quoted strings — which also hid
`mtk_adb shell "reboot bootloader"` from every check. The guard protecting a
daily-driver phone was weaker after the "fix" than before it. Now only the
arguments of `printf`/`echo`/`cat` are stripped, and
`test_read_only_scan_catches_injection` asserts the scan actually fails on
injected commands.

**6. `20-dump-stock.sh` exited silently when no recon had run.**
`find` on a nonexistent cache dir fails under `set -e`, so the script printed
its title and stopped with no explanation. Guarded; it now says which command
to run first.

## Assumptions that need checking against the real device

- **Ulefone property values are guessed.** `ro.product.manufacturer=Ulefone`,
  `ro.product.model=Armor X12 Pro`, `ro.board.platform=mt6765`. If the unit
  reports otherwise, `classify_device` returns `UNKNOWN` and everything
  refuses — safe, but it will look like a bug. Run
  `./10-recon.sh --explain-classification`, then widen the patterns at the top
  of `../lib/mtk_common.sh`.
- **Path semantics A/B/C/D are inferred.** The companion document defining them
  was never provided, so `10-recon.sh` prints an assumption banner every run.
- **The Ulefone USB vendor ID is unknown.** `udev/60-mtk-root.rules` covers
  MediaTek `0e8d`; if the device enumerates under a Ulefone-specific VID, add
  it (`lsusb` with the phone attached).
- **mtkclient's install steps may drift.** `install.sh` falls back to
  `pip install <clone>` when `requirements.txt` is absent, but read the current
  README if the venv build ever fails.

## Verified good news

mtkclient rev `0542a87` has an explicit **MT6765** entry in
`mtkclient/config/brom_config.py` (`name="MT6765/MT8768t"`, loader
`mt6765_payload.bin`) — the Ulefone's exact chipset is supported. This does
**not** establish that this particular unit's BROM is accessible: SLA/DAA
authentication state is per-device and undocumented.
