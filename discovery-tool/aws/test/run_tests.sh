#!/usr/bin/env bash
# Cross-implementation test runner.
#
#   ./test/run_tests.sh                       # every case, on every implementation
#   ./test/run_tests.sh --impl python         # one implementation
#   ./test/run_tests.sh --impl bash,go 01 04  # filtered by implementation and case
#
# Each case in test/cases/ runs once per implementation, in its own subshell,
# with test/lib/harness.sh already sourced. The case describes the org it needs
# as a scenario; the harness starts a fake AWS endpoint and points the tool at
# it via AWS_ENDPOINT_URL, so the real AWS CLI, real boto3 and the real Go SDK
# are each exercised against identical responses.
#
# An implementation whose toolchain is missing is reported as skipped rather
# than silently passing.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"

for dep in jq python3 curl; do
  command -v "$dep" >/dev/null 2>&1 || { echo "Error: '$dep' is required to run the tests." >&2; exit 1; }
done

# ── Arguments ──────────────────────────────────────────────────────────────────

WANTED_IMPLS="bash,python,go"
patterns=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --impl)    WANTED_IMPLS="$2"; shift 2 ;;
    --impl=*)  WANTED_IMPLS="${1#--impl=}"; shift ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         patterns+=("$1"); shift ;;
  esac
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/datafy-suite.XXXXXX")"
cleanup_work() { [[ -d "$WORK" ]] && rm -rf "$WORK"; return 0; }
trap cleanup_work EXIT

# ── Which implementations can actually run ─────────────────────────────────────

IMPLS=()
SKIPPED=()

impl_wanted() {
  local want
  local IFS=','
  for want in $WANTED_IMPLS; do
    [[ "$want" == "$1" ]] && return 0
  done
  return 1
}

if impl_wanted bash; then
  if command -v aws >/dev/null 2>&1; then
    IMPLS+=(bash)
  else
    SKIPPED+=("bash: aws-cli v2 not installed")
  fi
fi

if impl_wanted python; then
  if python3 -c "import boto3" >/dev/null 2>&1; then
    IMPLS+=(python)
  else
    SKIPPED+=("python: boto3 not installed")
  fi
fi

if impl_wanted go; then
  if command -v go >/dev/null 2>&1; then
    # Built once, up front: a compile failure is a suite-level problem, not
    # something every case should rediscover.
    if ( cd "$ROOT/golang" && go build -o "$WORK/discovery-go" . ) 2>"$WORK/go-build.log"; then
      export DISCOVERY_GO_BIN="$WORK/discovery-go"
      IMPLS+=(go)
    else
      echo "Error: the Go implementation does not build:" >&2
      head -5 "$WORK/go-build.log" >&2
      exit 1
    fi
  else
    SKIPPED+=("go: go toolchain not installed")
  fi
fi

if [[ ${#IMPLS[@]} -eq 0 ]]; then
  echo "Error: no implementation available to test." >&2
  printf '  %s\n' "${SKIPPED[@]+"${SKIPPED[@]}"}" >&2
  exit 1
fi

# ── Which cases to run ─────────────────────────────────────────────────────────

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

for note in "${SKIPPED[@]+"${SKIPPED[@]}"}"; do
  printf -- '- skipped %s\n' "$note"
done
printf 'Implementations under test: %s\n' "${IMPLS[*]}"

total_failed=0
total_runs=0
failed_names=()

for case_file in "${cases[@]}"; do
  name="$(basename "$case_file" .sh)"
  printf '\n▸ %s\n' "$name"

  for impl in "${IMPLS[@]}"; do
    total_runs=$(( total_runs + 1 ))
    printf '  %s\n' "$impl"

    # A subshell per (case, implementation) so neither can leak state — env,
    # cwd, traps — into the next.
    (
      export IMPL="$impl"
      # shellcheck source=lib/harness.sh
      . "$HERE/lib/harness.sh"
      trap teardown_sandbox EXIT
      # shellcheck source=/dev/null
      . "$case_file"
      exit "$FAILURES"
    )
    case_failures=$?

    if [[ "$case_failures" -ne 0 ]]; then
      printf '    FAIL (%d assertion(s))\n' "$case_failures"
      total_failed=$(( total_failed + 1 ))
      failed_names+=("$name [$impl]")
    fi
  done
done

printf '\n─────────────────────────────────────\n'
if [[ "$total_failed" -eq 0 ]]; then
  printf 'All %d case/implementation run(s) passed.\n' "$total_runs"
  exit 0
fi
printf '%d of %d case/implementation run(s) failed:\n' "$total_failed" "$total_runs"
printf '  %s\n' "${failed_names[@]}"
exit 1
