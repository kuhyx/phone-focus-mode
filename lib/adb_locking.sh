#!/usr/bin/env bash
# lib/adb_locking.sh — single-instance run lock and per-marker cooldowns.
# Sourced by adb_common.sh; do not execute directly, and do not source it
# on its own: it reads LOCK_DIR, LAST_RUN_DIR and LOCK_FILE, and calls the
# _info/_warn/_fatal helpers, all of which adb_common.sh defines first.

_adb_release_lock() {
	if [[ -n "${LOCK_FILE}" && -d "${LOCK_FILE}" ]]; then
		rm -rf "${LOCK_FILE}"
	fi
}

adb_acquire_lock() {
	local lock_pid_file=""
	local old_pid=""

	mkdir -p "${LOCK_DIR}"
	LOCK_FILE="${LOCK_DIR}/run_phone.lock"
	lock_pid_file="${LOCK_FILE}/pid"

	if mkdir "${LOCK_FILE}" 2>/dev/null; then
		printf '%s\n' "$$" >"${lock_pid_file}"
		trap _adb_release_lock EXIT INT TERM
		_info "Acquired run lock (PID $$)"
		return 0
	fi

	old_pid="$(cat "${lock_pid_file}" 2>/dev/null || printf '')"
	if [[ -n "${old_pid}" ]] && kill -0 "${old_pid}" 2>/dev/null; then
		_fatal "Another run_phone.sh instance is already running (PID ${old_pid}). Aborting."
	fi

	_warn "Stale lock directory found (PID ${old_pid} no longer running). Removing."
	rm -rf "${LOCK_FILE}"

	if ! mkdir "${LOCK_FILE}" 2>/dev/null; then
		_fatal "Could not acquire run lock at ${LOCK_FILE}. Another process may have raced us."
	fi

	printf '%s\n' "$$" >"${lock_pid_file}"
	trap _adb_release_lock EXIT INT TERM
	_info "Acquired run lock (PID $$)"
}

adb_check_cooldown() {
	local cooldown_secs="${1:-300}"
	local elapsed=0
	local last_run=0
	local marker_name="${2:-default}"
	local marker="${LAST_RUN_DIR}/${marker_name}"
	local now=0

	mkdir -p "${LAST_RUN_DIR}"
	if [[ -f "${marker}" ]]; then
		last_run="$(cat "${marker}")"
		if [[ "${last_run}" =~ ^[0-9]+$ ]]; then
			now="$(date +%s)"
			elapsed=$((now - last_run))
			if ((elapsed < cooldown_secs)); then
				_info "Cooldown active: last run ${elapsed}s ago, cooldown is ${cooldown_secs}s. Skipping."
				return 1
			fi
		else
			_warn "Ignoring invalid cooldown marker: ${marker}"
		fi
	fi

	return 0
}

adb_mark_last_run() {
	local marker_name="${1:-default}"

	mkdir -p "${LAST_RUN_DIR}"
	date +%s >"${LAST_RUN_DIR}/${marker_name}"
}
