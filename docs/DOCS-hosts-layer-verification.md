# Hosts layer: what is verified, and what cannot be

Status as of 2026-08-24. This is a record of a verification boundary, not a
task list. It exists because "the hosts layer is tested" was true in a way that
was easy to over-read: the tests were all PC-side, and the half that actually
blocks anything had never run on hardware.

## Short version

| Stage | Verified? | How |
|---|---|---|
| Generator is present, or the deploy dies | yes, PC | `tests/test_hosts_staging.py::test_missing_generator_fails_closed` |
| `hosts_supplemental.txt` present, or the deploy dies | yes, PC | `::test_missing_supplemental_fails_closed` |
| Supplemental appended to the canonical byte-for-byte | yes, PC | `::test_supplemental_is_appended_verbatim` |
| `hosts.sha256` covers the appended bytes | yes, PC | `::test_hash_covers_the_supplemental` |
| Workout variant strips YouTube, keeps the phone layer | yes, PC | `::test_workout_variant_strips_youtube_but_keeps_supplemental` |
| Supplemental blocks no Play/GMS hostname | yes, PC | `tests/test_hosts_supplemental.py` |
| **Files actually pushed to the device** | **no** | root-gated, see below |
| **`hosts_enforcer.sh` running on device** | **no** | root-gated |
| **Bind mount over `/system/etc/hosts`** | **no** | root-gated |
| **Magisk module sync / `chattr +i` protection** | **no** | needs Magisk |
| **A hostname in the file failing to resolve on the phone** | **no** | root-gated |

Everything above the line runs in CI on every push (`pytest tests focus_policy`).
Nothing below the line has ever executed on a phone, and on the current device
it never will.

## Why it cannot be verified on the Pixel 6a

The Pixel 6a (`23181JEGR08034`) is unrooted **by design and permanently** — it
is not a pending task, and the device will not be rooted. Measured
2026-08-24: `adb shell which su` returns nothing, and no Magisk package is
installed.

`deploy.sh` gates the entire remote phase on root, at step 2 of 7:

```sh
echo "[2/7] Verifying root access..."
if ! adb_root "id" | grep -q "uid=0"; then
    echo "ERROR: Could not get root shell. Is Magisk installed?"
```

`adb_root` is `adb shell su -c "sh -s"`. On this phone that fails, so the
deploy exits **before** `_deploy_stage_assets` is ever called. The hosts files
are therefore not merely un-mounted on this device — they are never pushed.

The requirement is not incidental to the phone's ROM; it is inherent to the
mechanism. Every path in the layer needs uid 0:

- `hosts_mount.sh` — `mount -o remount,rw /system`, `umount`, and the bind
  mount itself. All root-only syscalls; there is no unrooted equivalent.
  Android offers no supported way to substitute `/system/etc/hosts`.
- `hosts_magisk.sh` — reads and writes `/data/adb/modules/hosts/`, and applies
  `chattr +i` to stop the Magisk app disabling the module. Needs both root and
  Magisk specifically.
- `hosts_enforcer.sh` — sources `hosts_magisk.sh` and calls
  `protect_magisk_module` in its main loop.

So there is no "root but no Magisk" middle path to exercise: the enforcer's
loop is wired to the Magisk module. An emulator would have to supply root *and*
Magisk to prove anything the PC tests do not already prove, and a Magisk-rooted
AVD is a different platform (x86 system image, different `/system` mount
topology, no vendor overlay) from the arm64 device this ships to — so a pass
there would not transfer to hardware anyway. That is why no emulator run was
attempted rather than one being attempted and reported as equivalent.

The other absorbed repo, `mtk-root/`, targets a Ulefone X12 Pro, and
`hosts_magisk.sh` was written for the earlier rooted Blackview BL-9000 (still
named in `deploy.sh`'s header). Neither device is attached: `adb devices -l`
lists exactly one device, the Pixel 6a. A rooted device is where this layer
*could* be verified; none is available.

## What the PC-side test actually proves

`tests/test_hosts_staging.py` executes the **real** `_deploy_stage_assets` from
`deploy_phases.sh` — sourced, not reimplemented — with two things replaced:

- `HOSTS_GENERATOR` points at a stub emitting known bytes (the seam already
  existed at `deploy_phases.sh:79`).
- `adb` is a stub earlier on `PATH` that records `adb push <src> <dest>` by
  copying the source aside.

The tests then assert on the exact bytes that *would* reach the device, and on
the sha256 the enforcer later re-computes to detect tampering. That last one is
the load-bearing assertion: the hash must be taken after the supplemental is
appended, or every deploy would look tampered with on device.

Driving the real shell function is deliberate. A Python reimplementation of the
append would keep passing while `deploy_phases.sh` drifted underneath it.
Confirmed with two mutations run against a throwaway worktree of `HEAD`:

| Mutation to `deploy_phases.sh` | Result |
|---|---|
| Delete `cat "$HOSTS_SUPPLEMENTAL" >>"$HOSTS_TMP"` | 2 tests fail |
| Move the `compute_file_hash` call to before the append | 1 test fails |

Both were reverted; the worktree was removed.

Note `tests/mutations/*.json` in this repo currently has **no runner** — the
files came across with the monorepo absorption and nothing executes them. The
two mutations above were therefore run by hand and recorded here rather than
added to a registry that does not fire.

## What "the hosts layer works" is still resting on

Honestly stated: on the PC-side pipeline being correct, plus the enforcer code
having worked on the previous rooted device. On the current phone the layer is
**inert** — not broken, not bypassed, simply never installed, because the deploy
stops at the root check.

Blocking on this phone is done by the **app layer** instead (the Device Owner
hiding packages) and by DNS. That is not a downgrade for the Play Store case in
particular: Play is geofenced (hidden at home, shown away), and a static hosts
file is one file identical in both places, so it could not express the geofence
even with root. See `hosts_supplemental.txt`'s header and
`DOCS-policy-lists.md#why-the-play-store-is-blocked-at-home-only`.

`hosts_supplemental.txt` deliberately blocks nothing today. It is kept as the
phone's hook for future phone-only blocks so the staging path and its guard
tests stay wired up; `tests/test_hosts_supplemental.py` enforces that no
Play/GMS hostname is ever added to it, since that would break infakt's PairIP
license check everywhere, including away from home.

## What would change this

Only a rooted, Magisk-equipped device that this policy is meant to run on. If
one appears, the unverified rows above become testable by running `deploy.sh`
against it and checking, on device: `mount | grep /system/etc/hosts`, the
enforcer's log via `focus_ctl.sh hosts-log`, and that a hostname listed in the
canonical fails to resolve. Until then those rows stay "no".
