#!/usr/bin/env bash
# Regression test for tether_enforcer.sh.
#
# The enforcer ends in `main "$@"` (an infinite loop), so — like a real deploy —
# we run it as a subprocess with the Android tools it calls (settings, iptables,
# ip6tables, cmd, getprop) replaced by stubs on PATH, and drive it through the
# full gate + apply/revert state machine, asserting observable state each step.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/../../tether_enforcer.sh"

RUN="$(mktemp -d)"
cleanup() {
    if [ -n "${PID:-}" ]; then
        kill "$PID" 2>/dev/null || true
        wait "$PID" 2>/dev/null || true  # let its TERM handler finish before rm
    fi
    rm -rf "$RUN"
}
trap cleanup EXIT
mkdir -p "$RUN/bin" "$RUN/state" "$RUN/ipt" "$RUN/settings" "$RUN/calls" "$RUN/app"
STATE="$RUN/state"

# --- fake config.sh in the daemon's own dir (it sources "$SCRIPT_DIR/config.sh") ---
cp "$SRC" "$RUN/app/tether_enforcer.sh"
cat > "$RUN/app/config.sh" <<EOF
export STATE_DIR="$STATE"
export MODE_FILE="$STATE/current_mode.txt"
export TETHER_ENFORCER_ENABLED=1
export TETHER_CHECK_INTERVAL=1
export TETHER_LOG="$STATE/tether_enforcer.log"
export TETHER_ENFORCER_STATE="$STATE/tether_applied"
export TETHER_OFFLOAD_KEY="tether_offload_disabled"
export TETHER_OFFLOAD_SNAP="$STATE/tether_offload.snap"
export TETHER_IPT_CHAIN="FOCUS_TETHER_BLOCK"
export TETHER_STOP_SOFTAP_ENABLED=1
export TETHER_OVERRIDE_FILE="$STATE/tether_override"
export TETHER_FORCE_FILE="$STATE/tether_force_on"
EOF

# --- stubs ---
cat > "$RUN/bin/settings" <<EOF
#!/usr/bin/env bash
db="$RUN/settings/tether_offload_disabled"
echo "settings \$*" >> "$RUN/calls/settings.log"
case "\$1 \$2" in
  "get global") [ -f "\$db" ] && cat "\$db" || echo "null" ;;
  "put global") printf '%s' "\$4" > "\$db" ;;
  "delete global") rm -f "\$db" ;;
esac
exit 0
EOF
# iptables/ip6tables: minimal chain-state model so chain_intact converges.
cat > "$RUN/bin/iptables" <<EOF
#!/usr/bin/env bash
bin="\$(basename "\$0")"; s="$RUN/ipt/\$bin"; mkdir -p "\$s"
[ "\$1" = "-w" ] && shift 2
case "\$1" in
  -L) [ -f "\$s/exists" ] ;;
  -N) touch "\$s/exists"; : > "\$s/rules" ;;
  -C) [ -f "\$s/jump" ] ;;
  -D) if [ -f "\$s/jump" ]; then rm -f "\$s/jump"; exit 0; else exit 1; fi ;;
  -I) touch "\$s/jump" ;;
  -A) echo "-A rule" >> "\$s/rules" ;;
  -F) : > "\$s/rules" ;;
  -S) cat "\$s/rules" 2>/dev/null ;;
  -X) rm -f "\$s/exists" "\$s/rules" "\$s/jump" ;;
esac
exit \$?
EOF
cp "$RUN/bin/iptables" "$RUN/bin/ip6tables"
printf '#!/usr/bin/env bash\necho "cmd $*" >> "%s/calls/cmd.log"\nexit 0\n' "$RUN" > "$RUN/bin/cmd"
printf '#!/usr/bin/env bash\necho 13\n' > "$RUN/bin/getprop"
chmod +x "$RUN/bin/"*
export PATH="$RUN/bin:$PATH"

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  OK: %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  FAIL: %s\n' "$1"; }
applied() { [ -f "$STATE/tether_applied" ]; }
offload() { cat "$RUN/settings/tether_offload_disabled" 2>/dev/null || echo "<unset>"; }
v4jump()  { [ -f "$RUN/ipt/iptables/jump" ]; }
v6jump()  { [ -f "$RUN/ipt/ip6tables/jump" ]; }
v4rules() { grep -c '^-A' "$RUN/ipt/iptables/rules" 2>/dev/null || echo 0; }
softap()  { grep -c 'stop-softap' "$RUN/calls/cmd.log" 2>/dev/null || echo 0; }

sh "$RUN/app/tether_enforcer.sh" & PID=$!
sleep 2

# [A] Away from home -> block OFF
applied && no "A: applied while away" || ok "A: not applied while away"
[ "$(offload)" = "<unset>" ] && ok "A: offload untouched away" || no "A: offload changed away"
v4jump && no "A: v4 jump while away" || ok "A: no v4 jump while away"

# [B] force-on -> block ENGAGES (all three levers)
touch "$STATE/tether_force_on"; sleep 3
applied && ok "B: applied on force" || no "B: not applied on force"
[ "$(offload)" = "1" ] && ok "B: offload disabled" || no "B: offload=$(offload)"
v4jump && ok "B: v4 FORWARD jump pinned" || no "B: no v4 jump"
v6jump && ok "B: v6 FORWARD jump pinned" || no "B: no v6 jump"
[ "$(v4rules)" = "1" ] && ok "B: single REJECT rule (no rebuild loop)" || no "B: v4 rules=$(v4rules)"
[ "$(softap)" -ge 1 ] && ok "B: stop-softap invoked" || no "B: softap not stopped"
[ "$(cat "$STATE/tether_offload.snap" 2>/dev/null)" = "null" ] && ok "B: offload snapshot captured" || no "B: bad snapshot"

# [C] clear force -> block REVERTS
rm -f "$STATE/tether_force_on"; sleep 3
applied && no "C: still applied" || ok "C: reverted on force-clear"
[ "$(offload)" = "<unset>" ] && ok "C: offload restored" || no "C: offload=$(offload)"
v4jump && no "C: v4 jump remains" || ok "C: v4 chain torn down"

# [D] current_mode=focus -> ENGAGES via home gate
echo focus > "$STATE/current_mode.txt"; sleep 3
applied && ok "D: applied at home (focus)" || no "D: not applied at home"
v4jump && ok "D: v4 jump pinned at home" || no "D: no v4 jump at home"

# [E] override -> SUSPENDS even at home
touch "$STATE/tether_override"; sleep 3
applied && no "E: applied despite override" || ok "E: suspended by override"
v4jump && no "E: v4 jump despite override" || ok "E: torn down by override"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
