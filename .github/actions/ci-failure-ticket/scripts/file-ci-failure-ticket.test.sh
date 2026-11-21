#!/usr/bin/env bash
# file-ci-failure-ticket.test.sh — smoke tests for file-ci-failure-ticket.sh:
# the consolidated CI-failure Linear ticket filer.
#
# file-ci-failure-ticket.sh guards its `main()` behind a `BASH_SOURCE`
# check (same pattern notify-release-slack.sh uses), so sourcing it here
# pulls in its pure helpers without attempting a real Linear call. `curl`
# is stubbed via a mock bin directory prepended to PATH for the end-to-end
# main() scenarios, so these tests run with no network access and no real
# Linear credentials.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$script_dir/file-ci-failure-ticket.sh"

fail=0

assert_eq() {
  local actual="$1" expected="$2" msg="$3"
  if [[ "$actual" != "$expected" ]]; then
    echo "FAIL: $msg"
    echo "  expected: $expected"
    echo "  got: $actual"
    fail=1
  else
    echo "PASS: $msg"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" msg="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "FAIL: $msg"
    echo "  expected to contain: $needle"
    echo "  got: $haystack"
    fail=1
  else
    echo "PASS: $msg"
  fi
}

# shellcheck source=./file-ci-failure-ticket.sh
# shellcheck disable=SC1091 # dynamic $script path - shellcheck can't verify without -x
source "$script"

# --- ci_failure_marker / build_search_query: pure, no network --------------

marker="$(ci_failure_marker "mecha10" "Main")"
assert_eq "$marker" "<!-- ci-failure-key: ci-failure:mecha10:Main -->" \
  "ci_failure_marker: embeds repo and workflow name"

search_query="$(build_search_query "$marker")"
assert_contains "$(echo "$search_query" | jq -r '.variables.descriptionContains')" "ci-failure:mecha10:Main" \
  "build_search_query: variable carries the marker"
assert_eq "$(echo "$search_query" | jq -r '.variables.teamKey')" "LAB" \
  "build_search_query: defaults to the LAB team"

# --- build_description -------------------------------------------------------

description="$(build_description "mecha10" "Main" "https://example.com/run/1" "$marker")"
assert_contains "$description" "**Repository:** \`mecha10\`" \
  "build_description: includes repo name"
assert_contains "$description" "**Workflow:** \`Main\`" \
  "build_description: includes workflow name"
assert_contains "$description" "https://example.com/run/1" \
  "build_description: includes run url"
assert_contains "$description" "$marker" \
  "build_description: embeds the dedup marker"

# --- build_label_ids_json ----------------------------------------------------

assert_eq "$(build_label_ids_json '[]')" '["01f4906f-28d8-4ff9-b95c-a1d6de39d1ca"]' \
  "build_label_ids_json: default is CI label only"
assert_eq "$(build_label_ids_json)" '["01f4906f-28d8-4ff9-b95c-a1d6de39d1ca"]' \
  "build_label_ids_json: missing arg also defaults to CI label only"
assert_eq "$(build_label_ids_json '["37adccdc-90c5-4bdf-a2ff-43447949dca6"]')" \
  '["01f4906f-28d8-4ff9-b95c-a1d6de39d1ca","37adccdc-90c5-4bdf-a2ff-43447949dca6"]' \
  "build_label_ids_json: appends an extra label (e.g. mecha10's Rust label)"
assert_eq "$(build_label_ids_json 'not json')" '["01f4906f-28d8-4ff9-b95c-a1d6de39d1ca"]' \
  "build_label_ids_json: malformed extra input fails safe to CI label only"

# --- main(): end-to-end against mocked curl ----------------------------------

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

mock_bin="$work_dir/bin"
mkdir -p "$mock_bin"
PATH="$mock_bin:$PATH"

# Scenario 1: LINEAR_API_KEY unset - no curl call should happen at all. A
# curl mock that always fails proves this.
cat > "$mock_bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl should not have been called with LINEAR_API_KEY unset" >&2
exit 1
EOF
chmod +x "$mock_bin/curl"

out="$(LINEAR_API_KEY= GITHUB_REPOSITORY=mecha-industries/mecha10 main "Main" "https://example.com/run/1" 2>&1)"; rc=$?
assert_eq "$rc" "0" "main(): missing LINEAR_API_KEY exits 0"
assert_contains "$out" "LINEAR_API_KEY not set" "main(): missing key logs a skip, not an error"

# Scenario 2: existing open ticket found - comments instead of creating.
cat > "$mock_bin/curl" <<'EOF'
#!/usr/bin/env bash
query="${@: -1}"
if echo "$query" | grep -q '"query"'; then
  if echo "$query" | grep -q 'issues('; then
    echo '{"data":{"issues":{"nodes":[{"id":"issue-1","identifier":"LAB-1","url":"https://linear.app/x/issue/LAB-1"}]}}}'
  elif echo "$query" | grep -q 'commentCreate'; then
    echo '{"data":{"commentCreate":{"success":true}}}'
  else
    echo '{"data":{}}'
  fi
fi
EOF
chmod +x "$mock_bin/curl"

out="$(LINEAR_API_KEY=lin_test GITHUB_REPOSITORY=mecha-industries/mecha10 main "Main" "https://example.com/run/1" 2>&1)"; rc=$?
assert_eq "$rc" "0" "main(): existing ticket found exits 0"
assert_contains "$out" "existing open ticket LAB-1" "main(): comments on existing ticket instead of filing a duplicate"

# Scenario 3: no existing ticket - creates a new one with the default
# (CI-label-only) label set.
captured_create_payload="$work_dir/captured_create.json"
cat > "$mock_bin/curl" <<EOF
#!/usr/bin/env bash
query="\${@: -1}"
if echo "\$query" | grep -q 'issues('; then
  echo '{"data":{"issues":{"nodes":[]}}}'
elif echo "\$query" | grep -q 'teams('; then
  echo '{"data":{"teams":{"nodes":[{"id":"team-1"}]}}}'
elif echo "\$query" | grep -q 'workflowStates('; then
  echo '{"data":{"workflowStates":{"nodes":[{"id":"state-1"}]}}}'
elif echo "\$query" | grep -q 'issueCreate'; then
  echo "\$query" > "$captured_create_payload"
  echo '{"data":{"issueCreate":{"success":true,"issue":{"identifier":"LAB-2","url":"https://linear.app/x/issue/LAB-2"}}}}'
fi
EOF
chmod +x "$mock_bin/curl"

out="$(LINEAR_API_KEY=lin_test GITHUB_REPOSITORY=mecha-industries/mecha10-api main "Main" "https://example.com/run/2" 2>&1)"; rc=$?
assert_eq "$rc" "0" "main(): no existing ticket creates a new one"
assert_contains "$out" "created LAB-2" "main(): logs the created ticket identifier"
assert_eq "$(jq -r '.variables.labelIds | length' "$captured_create_payload")" "1" \
  "main(): default label set is CI label only"

# Scenario 4: EXTRA_LABEL_IDS set (e.g. mecha10's Rust label) - appended.
out="$(LINEAR_API_KEY=lin_test GITHUB_REPOSITORY=mecha-industries/mecha10 EXTRA_LABEL_IDS='["37adccdc-90c5-4bdf-a2ff-43447949dca6"]' \
  main "Main" "https://example.com/run/3" 2>&1)"; rc=$?
assert_eq "$rc" "0" "main(): with EXTRA_LABEL_IDS creates a new ticket"
assert_eq "$(jq -r '.variables.labelIds | length' "$captured_create_payload")" "2" \
  "main(): EXTRA_LABEL_IDS appends to the default CI label"

# Scenario 5: GITHUB_REPOSITORY unset - hard failure, not a silent skip.
out="$(LINEAR_API_KEY=lin_test GITHUB_REPOSITORY= main "Main" "https://example.com/run/4" 2>&1)"; rc=$?
assert_eq "$rc" "1" "main(): missing GITHUB_REPOSITORY is a hard failure"
assert_contains "$out" "GITHUB_REPOSITORY not set" "main(): missing repo logs an error, not a silent skip"

if [ "$fail" -ne 0 ]; then
  echo "Some file-ci-failure-ticket.sh tests failed."
  exit 1
fi
echo "All file-ci-failure-ticket.sh tests passed."
