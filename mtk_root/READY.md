# READY — the day the Ulefone arrives

Prepared 2026-08-04. Everything below was built and tested before the device
existed on this desk. Read the status matrix before trusting any of it.

## Command sequence

Run from `~/testsAndMisc/linux_configuration/scripts/mtk_root/`.

```bash
# 1. Confirm nothing rotted in transit. Expect "HOST READY".
./00-preflight.sh

# 2. Enable Developer options -> USB debugging on the phone, plug it in,
#    accept the RSA prompt on its screen, then:
./10-recon.sh

#    Read the decision summary. If it says UNKNOWN, the property patterns need
#    widening -- see below. If it names a path, continue.

# 3. Check the phone screen yourself:
#    Settings > System > Developer options > "OEM unlocking"
#    toggleable => unlocking permitted;  greyed out => blocked.
#    A property cannot tell you this. Only the UI can.

# 4. Dump the stock images BEFORE touching anything.
./20-dump-stock.sh
#    Then copy ~/.cache/mtk-root/stock/ somewhere off this machine.

# 5. Patch and flash MANUALLY -- there is no script for this on purpose.
#    Use the partition name 10-recon.sh reported, not one from memory.

# 6. Check what actually worked:
./90-verify-root.sh
```

## If recon says UNKNOWN

Expected on first contact: the Ulefone's property values were guessed.

```bash
./10-recon.sh --explain-classification
```

It prints each property and the pattern it failed. Edit the marked block at
the top of `../lib/mtk_common.sh`, then re-run. The refusal is deliberate —
the alternative is a toolkit that treats any unrecognised phone as the target.

## Status: what is validated and what is not

| Capability                                                | Status                                                               |
| --------------------------------------------------------- | -------------------------------------------------------------------- |
| Host tool checks, groups, udev syntax, venv importability | **host-validated** — 12/12 on this machine                           |
| Device enumeration, `unauthorized` vs `device` triage     | **device-validated** (Pixel 6a)                                      |
| PIXEL classification                                      | **device-validated**                                                 |
| Partition discovery, **`boot`** carrier, A/B, slot suffix | **device-validated** — real Pixel, 53 partitions                     |
| Facts-file format and contents                            | **device-validated**                                                 |
| Partition discovery, **`init_boot`** carrier              | **fixture-tested only — never run against hardware**                 |
| A-only slot scheme                                        | **fixture-tested only**                                              |
| UNKNOWN-device refusal; non-MediaTek dump refusal         | **fixture-tested only**                                              |
| Dump manifest, sha256, size sanity, idempotence           | **fixture-tested only** — mtkclient stubbed via `MTK_DUMP_CMD`       |
| `10-recon.sh` is read-only                                | **statically enforced**, with a negative self-test                   |
| Carrier-lock determination                                | **not possible from the device — reported `UNDETERMINED` by design** |
| mtkclient reading a real partition over BROM              | **UNTESTED** — needs the Ulefone                                     |
| Magisk patch → flash → `90-verify-root.sh`                | **UNTESTED** — no unlocked device exists                             |
| Ulefone property values; A/B/C/D path semantics           | **GUESSED / ASSUMED**                                                |

The single most important line: **the Pixel validated the `boot` branch, and
the Ulefone almost certainly needs the `init_boot` branch.** The selection
logic is proven by fixtures; it has never run against a device that has an
`init_boot` partition.

## Pixel 6a — resolved status

|                   |                                                                      |
| ----------------- | -------------------------------------------------------------------- |
| serial            | `23181JEGR08034`                                                     |
| build             | `bluejay:16/CP1A.260405.005` (Android 16, security patch 2026-04-05) |
| bootloader        | `bluejay-16.4-14548185`                                              |
| launch API level  | 32 (Android 12) → ramdisk in **`boot`**, no `init_boot`              |
| partitions        | `boot_a`/`boot_b`, `vbmeta_a`/`vbmeta_b`, 53 total                   |
| bootloader state  | locked (`flash.locked=1`, `verifiedbootstate=green`)                 |
| OEM unlock toggle | never enabled (`settings global oem_unlock_allowed` = null)          |
| **carrier lock**  | **UNDETERMINED — needs an out-of-band check**                        |
| path              | **C or D, indeterminate**                                            |

**The carrier-lock question is not answered, and cannot be from software.**
`sys.oem_unlock_allowed` and `ro.oem_unlock_supported` are both unset, and
`settings get global oem_unlock_allowed` returns null — but those read
identically whether the phone is carrier-locked or the toggle has simply never
been switched on. `ro.carrier=unknown` suggests a non-carrier build and
`gsm.sim.operator.alpha=Orange` is only the current SIM; neither settles it.

**To settle it:** look at Developer options → OEM unlocking on the phone. If it
is toggleable, it is not carrier-locked and Path C is open. If greyed out,
check the IMEI with the carrier or against the Google Store order before
concluding — a toggle can grey out for no network, an unverified account, or a
pending update on a phone that is not carrier-locked at all.

## Re-check before use — these go stale

- **Magisk v30.7** (2026-02-23), sha256 `e0d32d2…afae9ebd5`. Verify it is still
  current; beware `app-debug.apk` in the same release, which is _not_ the one
  to install. See `NOTES.md`.
- **mtkclient rev `0542a87`** (2026-08-02). `./install.sh` pulls and rebuilds.
  Good sign: this rev has an explicit MT6765 entry with an `mt6765_payload.bin`
  loader — the Ulefone's exact chipset.
- **Pixel factory images** at `developers.google.com/android/images#bluejay`.
  Not downloaded; the toolkit does not act on the Pixel. Google moved the
  Pixel 6 series off monthly cadence, so the newest listed build may be ahead
  of what the phone runs.

## Open questions that need the physical device

- The BROM-mode key combination for the X12 Pro
- Whether mtkclient enumerates this unit, and whether its BROM is open or
  SLA/DAA-locked (chipset support ≠ this unit being accessible)
- Whether `fastboot flashing unlock` is enabled in its firmware build
- Whether the OEM unlocking toggle is available at all
- Its exact build ID
- Whether the udev rules genuinely grant access to the MediaTek VID in practice
  — rules syntax is verified, real BROM access is not
- Its USB vendor ID, if it differs from MediaTek's `0e8d`
