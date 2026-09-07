# Nothing in discovery.sh may disable or cap AWS CLI pagination.
#
# That multi-page result sets arrive whole is checked for all three
# implementations by test/cases/11_pagination.sh, against an endpoint that
# really does paginate. What that cannot check is the bash-specific way to
# break it: `--no-paginate`, `--max-items` and `--page-size` each make the CLI
# return a prefix of the data and exit 0. The result looks exactly like a small
# account rather than a truncated scan — the failure mode this whole ticket is
# about — and it would still pass an end-to-end test whenever the fixture
# happened to fit in one page.
#
# Python and Go have no equivalent: their paginators are types, not flags.

for flag in --no-paginate --max-items --page-size --starting-token; do
  if grep -q -- "$flag" "$DISCOVERY_SH"; then
    _fail "discovery.sh does not use $flag" \
          "$(grep -n -- "$flag" "$DISCOVERY_SH" | head -1)"
  else
    _pass "discovery.sh does not use $flag"
  fi
done

# Every inventory call must go through fetch_json, which is what records a
# failure. A bare `aws ec2 describe-...` would reintroduce the silent fallback
# that hid the missing regions in the first place.
stray=$(grep -nE '^[[:space:]]*aws (ec2|dlm|backup) ' "$DISCOVERY_SH" | grep -v 'describe-regions' || true)
if [[ -z "$stray" ]]; then
  _pass "every inventory call goes through fetch_json"
else
  _fail "every inventory call goes through fetch_json" "$stray"
fi
