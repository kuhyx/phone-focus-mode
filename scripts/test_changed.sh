#!/bin/bash

# ============================================================================
# Run only the tests related to files changed vs HEAD (staged, unstaged and
# untracked). Quiet: failures plus a one-line summary. Python changes map to
# pytest files (full pytest when unmapped); shell changes map to
# lib/tests/test_<name>.sh, or the whole shell suite when unmapped.
# test_magisk_service.sh is skipped: it hangs (same carve-out as CI).
# `--all` runs every python and shell suite (the contract `test` command).
# Flutter (focus-owner) has its own suite: run `flutter test` there.
# ============================================================================

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
CHANGED=()
while IFS= read -r f; do
    [[ -n "$f" && -e "$f" ]] && CHANGED+=("$f")
done < <({ git diff --name-only HEAD 2>/dev/null || true; git ls-files --others --exclude-standard; } | sort -u)

py_full=0 sh_full=0
if [[ "${1:-}" == "--all" ]]; then py_full=1 sh_full=1; CHANGED=(all); fi
py_tests=() sh_tests=()
for f in "${CHANGED[@]}"; do
    case "$f" in
        tests/conftest.py | pyproject.toml) py_full=1 ;;
        *.py)
            base="$(basename "$f" .py)"
            if [[ "$base" == test_* ]]; then py_tests+=("$f")
            else
                mapfile -t m < <(git ls-files "*test_${base}.py")
                if [[ ${#m[@]} -gt 0 ]]; then py_tests+=("${m[@]}"); else py_full=1; fi
            fi
            ;;
        lib/tests/test_*.sh) sh_tests+=("$f") ;;
        lib/tests/*.sh) sh_full=1 ;;
        *.sh)
            base="$(basename "$f" .sh)"
            if [[ -f "lib/tests/test_${base}.sh" ]]; then sh_tests+=("lib/tests/test_${base}.sh")
            else sh_full=1; fi
            ;;
    esac
done

rc=0 n=0
if [[ $py_full -eq 1 ]]; then
    python3 -m pytest -q --tb=short || rc=1; n=$((n + 1))
elif [[ ${#py_tests[@]} -gt 0 ]]; then
    python3 -m pytest -q --tb=short "${py_tests[@]}" || rc=1; n=$((n + ${#py_tests[@]}))
fi
if [[ $sh_full -eq 1 ]]; then
    mapfile -t sh_tests < <(git ls-files 'lib/tests/test_*.sh' | grep -v test_magisk_service)
fi
for t in "${sh_tests[@]}"; do
    out="$(timeout 300 bash "$t" 2>&1)" || { rc=1; echo "FAIL $t"; tail -20 <<<"$out"; }
    n=$((n + 1))
done
if [[ $n -eq 0 ]]; then echo "no python/shell changes vs HEAD: nothing to test"; exit 0; fi
echo "ran $n test target(s): $([[ $rc -eq 0 ]] && echo pass || echo FAIL)"
exit "$rc"
