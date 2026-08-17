#!/system/bin/sh
# shellcheck shell=ash
# config_curfew.sh — the night-curfew enforcer's settings: poll interval, log
# and state paths, the grayscale/DND/network feature switches, and the
# per-UID network chain.
#
# Sourced by config.sh where these definitions used to sit.
#
# The curfew WINDOW ($NIGHT_CURFEW_START/END/ENABLED) is deliberately NOT
# here: focus_policy's loader reads those out of config.sh's text. Only names
# the loader never reads may live in a sibling.

# --- Curfew enforcer (grayscale + DND + per-UID network allow-list) ---
# See curfew_enforcer.sh. Always-on like dns_enforcer, but only ACTS while the
# curfew window is open AND focus mode is ON. Re-applies every interval so a
# manual toggle in Settings snaps back ("hard to turn off"). NOTE: snap-back is
# the realistic lock; true impossibility would mean blocking the Settings app,
# which risks system instability, so we deliberately do not.
export CURFEW_ENFORCER_INTERVAL=5
export CURFEW_ENFORCER_LOG="$STATE_DIR/curfew_enforcer.log"
export CURFEW_ENFORCER_STATE="$STATE_DIR/curfew_applied"
# Grayscale: force the display to monochrome via the accessibility daltonizer.
export CURFEW_GRAYSCALE_ENABLED=1
# DND: force Do-Not-Disturb to alarms-only so notifications stop pulling you in
# while the morning alarm still rings.
export CURFEW_DND_ENABLED=1
# Per-UID internet allow-list. DEFAULT OFF: highest-risk layer, must be proven
# on-device (`focus_ctl.sh curfew-test-on`) before it is trusted to fire
# unattended at 23:00. When on, only $NIGHT_WHITELIST app UIDs (plus
# root/system/shell + DNS) get network; every other app is cut off. It is also
# largely redundant with the app-disable layer, so leaving it off is safe.
export CURFEW_NET_ENABLED=1
export CURFEW_NET_IPT_CHAIN="FOCUS_CURFEW_NET"
# Android's netd periodically reasserts the whole `filter` table via
# iptables-restore, which atomically erases our custom chain (proven on-device:
# the chain vanishes ~every 5s). The main enforcer tick (5s) rebuilds it but
# leaves up-to-5s leak windows. This watchdog re-pins the chain every
# CURFEW_NET_REASSERT_INTERVAL seconds *from a cached UID list* (no pm fork).
# A 1s interval was measured on-device to peg netd at ~30% CPU continuously
# (an `iptables -L` fork every second, all night), overheating the phone -
# throttled to 15s (matches HOSTS_CHECK_INTERVAL/LAUNCHER_CHECK_INTERVAL
# pacing) as a deliberate tradeoff: leak window grows from <=1s to <=15s.
# The proper fix is netd's own per-UID firewall (ndc/eBPF), tracked as a
# follow-up; this remains an interim stopgap either way.
export CURFEW_NET_REASSERT_INTERVAL=15
export CURFEW_NET_UID_CACHE="$STATE_DIR/curfew_net_uids.txt"
# Manual test toggle: `focus_ctl.sh curfew-test-on` writes this file to force
# curfew ACTIVE regardless of clock, so the whole stack can be validated during
# the day. `curfew-test-off` removes it.
export CURFEW_FORCE_FILE="$STATE_DIR/curfew_force_on"
