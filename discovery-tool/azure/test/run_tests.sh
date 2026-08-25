#!/usr/bin/env bash
# Test runner for the Azure discovery tool.
#
#   ./azure/test/run_tests.sh              # every case
#   ./azure/test/run_tests.sh 04 07        # cases matching these patterns
#
# Each case in test/cases/ runs in its own subshell with test/lib/harness.sh
# already sourced. A case describes the tenant it needs as a scenario; the
# harness starts a fake ARM endpoint over HTTPS and points the tool at it via
# AZURE_ARM_ENDPOINT, so the real azure-core pipeline — credential policy,
# retry policy, nextLink pagination — is exercised against it.
#
# Set DISCOVERY_PYTHON to test against a specific interpreter, e.g. a virtualenv
# that has azure-identity installed.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

PYTHON_BIN="${DISCOVERY_PYTHON:-python3}"

for dep in jq curl; do
  command -v "$dep" >/dev/null 2>&1 || { echo "Error: '$dep' is required to run the tests." >&2; exit 1; }
done

command -v "$PYTHON_BIN" >/dev/null 2>&1 || {
  echo "Error: '$PYTHON_BIN' not found. Set DISCOVERY_PYTHON to an interpreter that has azure-identity." >&2
  exit 1
}

if ! "$PYTHON_BIN" -c "import azure.identity, azure.core" >/dev/null 2>&1; then
  echo "Error: azure-identity is not installed for '$PYTHON_BIN'." >&2
  echo "       pip install azure-identity" >&2
  echo "       or point DISCOVERY_PYTHON at a virtualenv that has it." >&2
  exit 1
fi

if ! "$PYTHON_BIN" -c "import cryptography" >/dev/null 2>&1; then
  echo "Error: the 'cryptography' package is required — the fake ARM endpoint" >&2
  echo "       generates a TLS certificate with it. It normally arrives with" >&2
  echo "       azure-identity; install it with: pip install cryptography" >&2
  exit 1
fi

export DISCOVERY_PYTHON="$PYTHON_BIN"

# ── Which cases to run ─────────────────────────────────────────────────────────

patterns=("$@")
cases=()
for f in "$HERE"/cases/*.sh; do
  [[ -f "$f" ]] || continue
  if [[ ${#patterns[@]} -eq 0 ]]; then
    cases+=("$f")
  else
    for pattern in "${patterns[@]}"; do
      case "$(basename "$f")" in *"$pattern"*) cases+=("$f"); break ;; esac
    done
  fi
done

if [[ ${#cases[@]} -eq 0 ]]; then
  echo "No test cases matched." >&2
  exit 1
fi

# ── Run ────────────────────────────────────────────────────────────────────────

printf 'Interpreter under test: %s (%s)\n' "$PYTHON_BIN" "$("$PYTHON_BIN" -V 2>&1)"

total_failed=0
total_runs=0
failed_names=()

for case_file in "${cases[@]}"; do
  name="$(basename "$case_file" .sh)"
  printf '\n▸ %s\n' "$name"
  total_runs=$(( total_runs + 1 ))

  # A subshell per case so none can leak state — env, cwd, traps — into the next.
  (
    # shellcheck source=lib/harness.sh
    . "$HERE/lib/harness.sh"
    trap teardown_sandbox EXIT
    # shellcheck source=/dev/null
    . "$case_file"
    exit "$FAILURES"
  )
  case_failures=$?

  if [[ "$case_failures" -ne 0 ]]; then
    printf '  FAIL (%d assertion(s))\n' "$case_failures"
    total_failed=$(( total_failed + 1 ))
    failed_names+=("$name")
  fi
done

printf '\n─────────────────────────────────────\n'
if [[ "$total_failed" -eq 0 ]]; then
  printf 'All %d case(s) passed.\n' "$total_runs"
  exit 0
fi
printf '%d of %d case(s) failed:\n' "$total_failed" "$total_runs"
printf '  %s\n' "${failed_names[@]}"
exit 1
