# Night curfew and the hotspot/tethering block

## Night curfew (after 23:00 at home)

On top of the location-based focus mode, a **time-gated curfew** makes the phone
boring and largely unusable late at night so you go to sleep instead of doom-
scrolling. It activates only when focus mode is already ON (i.e. you are at
home) **and** the local clock is inside the curfew window (default 23:00–05:00).
Out of that window, or away from home, nothing changes.

While the curfew is active it applies three allow-list layers — _block
everything except a short essential list_:

1. **Apps.** The daemon swaps the permissive `WHITELIST` for the strict
   `NIGHT_WHITELIST` (banking, maps, calendar, clock, authenticators, gov ID,
   workout/diet). Everything else — browsers, social, messaging, email, media,
   manga, stores — is `pm disable-user`'d and re-enabled automatically at
   05:00. Same proven mechanism as location focus; no new disable path.
2. **Display + notifications.** `curfew_enforcer.sh` forces the screen to
   **grayscale** and DND to **alarms-only**, re-applying every 5s so toggling
   them off in Settings snaps back. (Snap-back is the realistic lock; truly
   blocking Settings risks system instability, so it is deliberately avoided.)
3. **Internet (optional, default OFF).** A per-UID `iptables` allow-list that
   gives network only to the `NIGHT_WHITELIST` apps (plus root/system/shell +
   DNS) and cuts off every other app. Enable `CURFEW_NET_ENABLED=1` in
   `config.sh` only after validating it on-device (see test hook below).

### Configuration (`config.sh`)

```sh
NIGHT_CURFEW_ENABLED=1       # master switch
NIGHT_CURFEW_START="2300"    # local HHMM; window wraps past midnight
NIGHT_CURFEW_END="0500"
CURFEW_GRAYSCALE_ENABLED=1   # force monochrome
CURFEW_DND_ENABLED=1         # force DND alarms-only
CURFEW_NET_ENABLED=0         # per-UID internet allow-list (prove first!)
```

Edit `NIGHT_WHITELIST` (right below `WHITELIST`) to choose what stays usable at
night. Allow-list by design: when in doubt, leave it out. The active keyboard
and the core dialer/SMS/home apps are always protected automatically (a 1am
reboot can never strand you without a keyboard), and the default browser is
intentionally _not_ protected at night so it can be disabled.

### Control

```bash
# On-device (root shell):
focus_ctl.sh curfew-status     # window, enforcer state, what's applied
focus_ctl.sh curfew-test-on    # FORCE curfew now (daytime validation)
focus_ctl.sh curfew-test-off   # clear the force
focus_ctl.sh curfew-off        # escape hatch: suspend curfew now
focus_ctl.sh curfew-on         # re-arm (clear the override)
focus_ctl.sh curfew-log        # enforcer log
```

### Opting out at 2am (no PC)

The companion status notification grows a **"Suspend curfew till morning"**
action while the curfew is active. Tapping it drops the override file (curfew
off until you re-arm); the label flips to **"Re-arm curfew"**. The action is
hidden during the day so it is not a casual temptation. Without the PC this is
the only on-device opt-out — by design. From the PC you can always
`./deploy.sh <ip> --restart` or run `focus_ctl.sh curfew-off` over ADB.

### Validating before you trust it overnight

Because a misconfigured curfew can lock apps at 2am, validate it during the day
with the force hook, **not** by waiting for 23:00:

```bash
focus_ctl.sh curfew-test-on    # mBank + keyboard work, Firefox gone, gray, DND
focus_ctl.sh curfew-test-off   # blocked apps come BACK (the reconcile path)
```

The clock parser fails **open** (treated as daytime) on a malformed time, so a
broken `date` can never trap you behind the strict list.

## Hotspot / tethering block (closes the "second phone" bypass)

Every other network layer only filters **this** phone's own traffic:
`/system/etc/hosts` is consulted by the phone's system resolver, and both
`dns_enforcer` and the curfew net layer only touch the **OUTPUT** chain. When
the phone shares its mobile data as a WiFi hotspot, a tethered second phone's
packets are **FORWARDed + NAT'd** through this phone on a path none of that
covers — so the second phone browses freely and defeats focus mode.

`tether_enforcer.sh` closes that hole. It is always-on but **only acts while
focus mode is ON** (i.e. you are at home, `current_mode.txt == focus`), and
converges three levers every `TETHER_CHECK_INTERVAL` seconds:

1. **Disable tether offload** — sets `settings global tether_offload_disabled 1`
   so forwarded traffic is actually seen by netfilter instead of being shunted
   around it by the hardware/BPF fast path. Snapshotted on entry, restored on
   exit.
2. **FORWARD blanket REJECT** — an `iptables`/`ip6tables` chain
   (`FOCUS_TETHER_BLOCK`) pinned at position 1 of `FORWARD`, rejecting all
   forwarded packets. This is the version-independent catch-all and covers
   **WiFi, USB and Bluetooth** tethering. The phone's own traffic uses
   OUTPUT/INPUT, never FORWARD, so normal connectivity is untouched. Rebuilt
   only when tampered (chain-intact gate), so it does not fork an `iptables -L`
   every second (that pegged netd and overheated the phone during curfew-net
   tuning).
3. **Stop the softAP** (best-effort, WiFi only, Android 11+) — `cmd wifi
stop-softap` each tick so the hotspot toggle visibly flips back off.

On the transition away from home it restores the offload snapshot and tears the
FORWARD chain down, leaving tethering usable.

### Configuration (`config.sh`)

```sh
TETHER_ENFORCER_ENABLED=1     # master switch
TETHER_CHECK_INTERVAL=5       # re-assert cadence (seconds)
TETHER_STOP_SOFTAP_ENABLED=1  # also actively kill a running softAP
```

### Control

```bash
focus_ctl.sh tether-status     # enforcer state, offload flag, FORWARD chain
focus_ctl.sh tether-test-on    # FORCE the block now (daytime validation)
focus_ctl.sh tether-test-off   # clear the force
focus_ctl.sh tether-stop       # escape hatch: stop it, restore tethering
focus_ctl.sh tether-start      # (re)start the enforcer
focus_ctl.sh tether-log        # enforcer log
```

The escape hatch is `tether-stop` over ADB (or a fresh `deploy.sh`), consistent
with `dns_enforcer`/`launcher_enforcer` — there is no companion-app button.
`tether_override` (created manually) suspends the block without stopping the
daemon.

### Validating before you trust it

Because Android's tether offload can silently skip the FORWARD rule on some
ROMs, validate on-device with a **real second phone** — do not trust rule
counts:

```bash
focus_ctl.sh tether-test-on    # hotspot on + second phone browsing → it loses
                               # internet within one interval; this phone stays
                               # online. Watch: focus_ctl.sh tether-log
focus_ctl.sh tether-test-off   # forwarding restored, second phone browses again
```

If the second phone keeps browsing with the block applied, offload is being
bypassed: confirm the exact global key with
`adb shell su -c 'settings list global | grep -i offload'` and update
`TETHER_OFFLOAD_KEY` in `config.sh`.
