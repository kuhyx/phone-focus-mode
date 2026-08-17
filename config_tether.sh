#!/system/bin/sh
# shellcheck shell=ash
# config_tether.sh — the tethering enforcer's settings: the feature switch,
# poll interval, log and state paths, the offload setting it snapshots, its
# iptables chain, and the override/force hooks.
#
# Sourced by config.sh where these definitions used to sit. None of these is
# read by focus_policy's loader; see the note in config_paths.sh.

# ============================================================
# HOTSPOT / TETHERING BLOCK (closes the "second phone" bypass)
# ============================================================
# The hosts file, dns_enforcer and the curfew net layer all only touch this
# phone's OWN traffic (system resolver + OUTPUT chain). A tethered second
# device's packets are FORWARDed + NAT'd through us on an unfiltered path, so
# it browses freely on our mobile data. tether_enforcer.sh closes that hole.
# Always-on like dns_enforcer, but only ACTS while focus mode is ON (i.e. you
# are at home: $MODE_FILE == "focus") OR the force-test file is present. Covers
# WiFi, USB and Bluetooth tethering, since all of it traverses FORWARD.
export TETHER_ENFORCER_ENABLED=1
export TETHER_CHECK_INTERVAL=5
export TETHER_LOG="$STATE_DIR/tether_enforcer.log"
export TETHER_ENFORCER_STATE="$STATE_DIR/tether_applied"
# Lever 1: disable Android's hardware/BPF tether offload so forwarded traffic
# is actually seen by netfilter (otherwise the FORWARD rule can be silently
# skipped). AOSP global key Settings.Global.TETHER_OFFLOAD_DISABLED; 1=disabled.
# Snapshotted on entry and restored on exit so we never clobber a user value.
export TETHER_OFFLOAD_KEY="tether_offload_disabled"
export TETHER_OFFLOAD_SNAP="$STATE_DIR/tether_offload.snap"
# Lever 2: blanket REJECT of the FORWARD chain (both iptables + ip6tables).
# Re-pinned only when tampered (chain_intact gate, like dns_enforcer) so we do
# not fork an `iptables -L` every second — that pegged netd + overheated the
# phone during curfew-net tuning (see CURFEW_NET_REASSERT_INTERVAL note above).
export TETHER_IPT_CHAIN="FOCUS_TETHER_BLOCK"
# Lever 3 (best-effort, WiFi only): actively stop a running softAP each tick so
# the hotspot toggle visibly flips off. Version-gated (cmd wifi stop-softap is
# Android 11+). The FORWARD block remains the version-independent catch-all.
export TETHER_STOP_SOFTAP_ENABLED=1
# Escape hatches (mirrors the curfew override/force pair):
#   tether_override -> suspend the block without stopping the daemon.
#   tether_force_on -> force the block ACTIVE regardless of location (daytime
#                      on-device validation via `focus_ctl.sh tether-test-on`).
export TETHER_OVERRIDE_FILE="$STATE_DIR/tether_override"
export TETHER_FORCE_FILE="$STATE_DIR/tether_force_on"
