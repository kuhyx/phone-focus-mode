#!/usr/bin/env bash
# shellcheck disable=SC2329  # test_* run via the declare -F loop
# Tests for scripts/deploy_owner.sh with stub adb, a stub phone_deploy.sh and
# a scratch "live checkout" cloned from a scratch origin. Nothing touches the
# real phone or ~/src/phone-focus-mode.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly DEPLOY="${REPO_ROOT}/scripts/deploy_owner.sh"
TMP="$(mktemp -d)"
readonly TMP
trap 'rm -rf -- "${TMP}"' EXIT

# Stub adb: state, versionCode and device owner come from files in $STUB.
write_stubs() {
	mkdir -p "${STUB}/bin"
	cat >"${STUB}/bin/adb" <<'EOF'
#!/usr/bin/env bash
echo "adb $*" >>"${STUB}/calls"
case "$*" in
	*get-state*) [[ "$(cat "${STUB}/state")" == device ]] && echo device || exit 1 ;;
	*"dumpsys package"*) echo "    versionCode=$(cat "${STUB}/vc") minSdk=24 targetSdk=36" ;;
	*"dpm list-owners"*) cat "${STUB}/owners" ;;
	*) exit 0 ;;
esac
EOF
	cat >"${STUB}/phone_deploy.sh" <<'EOF'
#!/usr/bin/env bash
echo "phone_deploy $*" >>"${STUB}/calls"
rc="$(cat "${STUB}/deploy_rc")"
[[ "${rc}" == 0 ]] && echo $(( $(cat "${STUB}/vc") + 1 )) >"${STUB}/vc"
exit "${rc}"
EOF
	chmod +x "${STUB}/bin/adb" "${STUB}/phone_deploy.sh"
}

# A bare origin one commit ahead of a clean live clone that has key.properties.
setup() {
	STUB="${TMP}/$1"
	export STUB
	write_stubs
	echo device >"${STUB}/state"
	echo 100 >"${STUB}/vc"
	printf 'Device owner (User 0):\n  admin=com.kuhy.focus_owner/.AdminReceiver,DeviceOwner\n' >"${STUB}/owners"
	echo 0 >"${STUB}/deploy_rc"
	: >"${STUB}/calls"
	git init -q --bare "${STUB}/origin.git"
	git clone -q "${STUB}/origin.git" "${STUB}/seed" 2>/dev/null
	git -C "${STUB}/seed" -c user.name=t -c user.email=t@t commit -q --allow-empty -m one
	git -C "${STUB}/seed" push -q origin HEAD:main
	git clone -q -b main "${STUB}/origin.git" "${STUB}/live"
	git -C "${STUB}/seed" -c user.name=t -c user.email=t@t commit -q --allow-empty -m two
	git -C "${STUB}/seed" push -q origin HEAD:main
	mkdir -p "${STUB}/live/focus-owner/android"
	echo "keyAlias=x" >"${STUB}/live/focus-owner/android/key.properties"
	printf 'key.properties\n' >"${STUB}/live/.git/info/exclude"
}

run_deploy() {
	PATH="${STUB}/bin:${PATH}" FOCUS_OWNER_LIVE_DIR="${STUB}/live" \
		PHONE_DEPLOY="${STUB}/phone_deploy.sh" ADB_SERIAL=SERIAL1 \
		bash "${DEPLOY}" >"${STUB}/out" 2>&1
}

live_head() { git -C "${STUB}/live" rev-parse HEAD; }
origin_head() { git -C "${STUB}/origin.git" rev-parse main; }

test_success_pulls_deploys_and_passes_health() {
	setup ok
	run_deploy
	[[ "$(live_head)" == "$(origin_head)" ]]
	grep -q "phone_deploy ${STUB}/live/focus-owner --release" "${STUB}/calls"
	[[ "$(cat "${STUB}/vc")" == 101 ]]
}

test_rerun_is_idempotent() {
	setup rerun
	run_deploy
	run_deploy
	[[ "$(cat "${STUB}/vc")" == 102 ]]
}

test_unreachable_phone_fails_before_touching_anything() {
	setup offline
	echo offline >"${STUB}/state"
	local before rc=0
	before="$(live_head)"
	run_deploy || rc=$?
	[[ "${rc}" == 30 ]]
	[[ "$(live_head)" == "${before}" ]]
	! grep -q phone_deploy "${STUB}/calls"
}

test_phone_deploy_failure_propagates() {
	setup refused
	echo 46 >"${STUB}/deploy_rc"
	local rc=0
	run_deploy || rc=$?
	[[ "${rc}" == 46 ]]
}

test_lost_device_owner_fails_health() {
	setup noowner
	run_deploy_then_drop_owner() {
		# shellcheck disable=SC2016  # literal ${STUB} for the stub to expand
		sed -i 's/^rc=.*/rc=0; : >"${STUB}\/owners"/' "${STUB}/phone_deploy.sh"
		run_deploy
	}
	local rc=0
	run_deploy_then_drop_owner || rc=$?
	[[ "${rc}" != 0 ]]
}

test_unchanged_version_fails_health() {
	setup samevc
	sed -i 's/^\[\[ .*vc"$/:/' "${STUB}/phone_deploy.sh"
	local rc=0
	run_deploy || rc=$?
	[[ "${rc}" != 0 ]]
}

test_missing_key_properties_fails_before_build() {
	setup nokey
	rm "${STUB}/live/focus-owner/android/key.properties"
	local rc=0
	run_deploy || rc=$?
	[[ "${rc}" != 0 ]]
	! grep -q phone_deploy "${STUB}/calls"
}

test_dirty_live_checkout_fails() {
	setup dirty
	echo junk >"${STUB}/live/untracked-edit"
	git -C "${STUB}/live" add untracked-edit
	local rc=0
	run_deploy || rc=$?
	[[ "${rc}" != 0 ]]
	! grep -q phone_deploy "${STUB}/calls"
}

failed=0
for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
	if ("${t}"); then echo "ok   ${t}"; else echo "FAIL ${t}"; failed=1; fi
done
exit "${failed}"
