#!/usr/bin/env bash
# Test runner for bash/discovery.sh.
#
#   ./test/run_tests.sh              # run every case
#   ./test/run_tests.sh 01 03        # run cases whose filename matches any argument
#
# Each case lives in test/cases/*.sh and runs in its own subshell with
# test/lib/harness.sh already sourced.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

for dep in jq bash; do
  command -v "$dep" >/dev/null 2>&1 || { echo "Error: '$dep' is required to run the tests." >&2; exit 1; }
done

# Collect cases, optionally filtered by the arguments given.
cases=()
for f in "$HERE"/cases/*.sh; do
  [[ -f "$f" ]] || continue
  if [[ $# -eq 0 ]]; then
    cases+=("$f")
  else
    for pattern in "$@"; do
      case "$(basename "$f")" in *"$pattern"*) cases+=("$f"); break ;; esac
    done
  fi
done

if [[ ${#cases[@]} -eq 0 ]]; then
  echo "No test cases matched." >&2
  exit 1
fi

total_failed=0
total_cases=0

for case_file in "${cases[@]}"; do
  total_cases=$(( total_cases + 1 ))
  name="$(basename "$case_file" .sh)"
  printf '\n▸ %s\n' "$name"

  # Run in a subshell so a case can't leak state (env, cwd, traps) into the next.
  (
    # shellcheck source=lib/harness.sh
    . "$HERE/lib/harness.sh"
    trap teardown_sandbox EXIT
    # shellcheck source=/dev/null
    . "$case_file"
    exit "$FAILURES"
  )
  case_failures=$?

  if [[ "$case_failures" -eq 0 ]]; then
    printf '  PASS\n'
  else
    printf '  FAIL (%d assertion(s))\n' "$case_failures"
    total_failed=$(( total_failed + 1 ))
  fi
done

printf '\n─────────────────────────────────────\n'
if [[ "$total_failed" -eq 0 ]]; then
  printf 'All %d case(s) passed.\n' "$total_cases"
  exit 0
fi
printf '%d of %d case(s) failed.\n' "$total_failed" "$total_cases"
exit 1
