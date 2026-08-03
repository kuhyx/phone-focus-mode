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
		wait "$PID" 2>/dev/null || true # let its TERM handler finish before rm
	fi
	rm -rf "$RUN"
}
trap cleanup EXIT
mkdir -p "$RUN/bin" "$RUN/state" "$RUN/ipt" "$RUN/settings" "$RUN/calls" "$RUN/app"
STATE="$RUN/state"

# --- fake config.sh in the daemon's own dir (it sources "$SCRIPT_DIR/config.sh") ---
cp "$SRC" "$RUN/app/tether_enforcer.sh"
cat >"$RUN/app/config.sh" <<EOF
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
cat >"$RUN/bin/settings" <<EOF
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
cat >"$RUN/bin/iptables" <<EOF
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
printf '#!/usr/bin/env bash\necho "cmd $*" >> "%s/calls/cmd.log"\nexit 0\n' "$RUN" >"$RUN/bin/cmd"
printf '#!/usr/bin/env bash\necho 13\n' >"$RUN/bin/getprop"
chmod +x "$RUN/bin/"*
export PATH="$RUN/bin:$PATH"

PASS=0
FAIL=0
ok() {
	PASS=$((PASS + 1))
	printf '  OK: %s\n' "$1"
}
no() {
	FAIL=$((FAIL + 1))
	printf '  FAIL: %s\n' "$1"
}
applied() { [ -f "$STATE/tether_applied" ]; }
offload() { cat "$RUN/settings/tether_offload_disabled" 2>/dev/null || echo "<unset>"; }
v4jump() { [ -f "$RUN/ipt/iptables/jump" ]; }
v6jump() { [ -f "$RUN/ipt/ip6tables/jump" ]; }
v4rules() { grep -c '^-A' "$RUN/ipt/iptables/rules" 2>/dev/null || echo 0; }
softap() { grep -c 'stop-softap' "$RUN/calls/cmd.log" 2>/dev/null || echo 0; }

sh "$RUN/app/tether_enforcer.sh" &
PID=$!
sleep 2

# [A] Away from home -> block OFF
if applied; then no "A: applied while away"; else ok "A: not applied while away"; fi
if [ "$(offload)" = "<unset>" ]; then ok "A: offload untouched away"; else no "A: offload changed away"; fi
if v4jump; then no "A: v4 jump while away"; else ok "A: no v4 jump while away"; fi

# [B] force-on -> block ENGAGES (all three levers)
touch "$STATE/tether_force_on"
sleep 3
if applied; then ok "B: applied on force"; else no "B: not applied on force"; fi
if [ "$(offload)" = "1" ]; then ok "B: offload disabled"; else no "B: offload=$(offload)"; fi
if v4jump; then ok "B: v4 FORWARD jump pinned"; else no "B: no v4 jump"; fi
if v6jump; then ok "B: v6 FORWARD jump pinned"; else no "B: no v6 jump"; fi
if [ "$(v4rules)" = "1" ]; then ok "B: single REJECT rule (no rebuild loop)"; else no "B: v4 rules=$(v4rules)"; fi
if [ "$(softap)" -ge 1 ]; then ok "B: stop-softap invoked"; else no "B: softap not stopped"; fi
if [ "$(cat "$STATE/tether_offload.snap" 2>/dev/null)" = "null" ]; then ok "B: offload snapshot captured"; else no "B: bad snapshot"; fi

# [C] clear force -> block REVERTS
rm -f "$STATE/tether_force_on"
sleep 3
if applied; then no "C: still applied"; else ok "C: reverted on force-clear"; fi
if [ "$(offload)" = "<unset>" ]; then ok "C: offload restored"; else no "C: offload=$(offload)"; fi
if v4jump; then no "C: v4 jump remains"; else ok "C: v4 chain torn down"; fi

# [D] current_mode=focus -> ENGAGES via home gate
echo focus >"$STATE/current_mode.txt"
sleep 3
if applied; then ok "D: applied at home (focus)"; else no "D: not applied at home"; fi
if v4jump; then ok "D: v4 jump pinned at home"; else no "D: no v4 jump at home"; fi

# [E] override -> SUSPENDS even at home
touch "$STATE/tether_override"
sleep 3
if applied; then no "E: applied despite override"; else ok "E: suspended by override"; fi
if v4jump; then no "E: v4 jump despite override"; else ok "E: torn down by override"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
