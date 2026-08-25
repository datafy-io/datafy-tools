# The file named by --output is the tool's only product. Progress, warnings and
# the closing tallies go to stderr, so stdout stays clean for the caller and an
# operator who redirects it still sees which subscriptions were skipped —
# problems scrolling into /dev/null is part of how DT-11095 stayed invisible.

setup_sandbox

scenario <<'JSON'
{ "subscriptions": [
    "aaaaaaaa-0000-0000-0000-000000000001",
    "bbbbbbbb-0000-0000-0000-000000000002"
  ],
  "disks": 2,
  "deny_by_subscription": { "bbbbbbbb-0000-0000-0000-000000000002": ["*"] } }
JSON

run_discovery

assert_equals 0 "$DISCOVERY_STATUS" "exits 0"
assert_empty "$(cat "$STDOUT_FILE")" "stdout carries nothing at all"

assert_not_empty "$(cat "$STDERR_FILE")" "the diagnostics went to stderr"
grep -q "Datafy Discovery Tool" "$STDERR_FILE" \
  && _pass "the banner is on stderr" \
  || _fail "the banner is on stderr" "not found in stderr"
grep -q "bbbbbbbb-0000-0000-0000-000000000002" "$STDERR_FILE" \
  && _pass "the failed subscription is named on stderr" \
  || _fail "the failed subscription is named on stderr" "not found in stderr"

# --version is the exception: there the version *is* the output, so it goes to
# stdout where a caller can capture it.
: > "$STDOUT_FILE"; : > "$STDERR_FILE"
"$PYTHON_BIN" "$DISCOVERY" --version >"$STDOUT_FILE" 2>"$STDERR_FILE"
version_status=$?

assert_equals 0 "$version_status" "--version exits 0"
assert_not_empty "$(cat "$STDOUT_FILE")" "--version writes to stdout"
assert_contains "$(cat "$STDOUT_FILE")" "Azure" "--version names the Azure edition"
