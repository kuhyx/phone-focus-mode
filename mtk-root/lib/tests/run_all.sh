#!/usr/bin/env bash
# Runs every lib test in this repo.
#
# The glob is test_*.sh, NOT one prefix per subject, so a suite added later is
# picked up without editing this file.
#
# Carried over from testsAndMisc, where this directory also held suites for
# non-mtk libraries. Here every suite is an mtk one, but the glob stays generic
# for the same reason it was generic there.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

rc=0
for t in "$HERE"/test_*.sh; do
	printf '\n=== %s ===\n' "$(basename "$t")"
	# Each suite exits non-zero on failure; keep going so one red suite does not
	# hide the state of the others, then fail the run as a whole.
	# Invoked directly, NOT as `bash "$t"`: a fresh process per suite matters
	# because mtk_common.sh declares readonly patterns, and sourcing it twice in
	# one shell aborts under set -e.
	"$t" || rc=1
done

exit "$rc"
