#!/usr/bin/env bash
# notify-release-slack.test.sh — smoke tests for notify-release-slack.sh
# (LAB-5479): the consolidated grouped-Slack-release-notification script.
#
# notify-release-slack.sh guards its `main()` behind a `BASH_SOURCE` check
# (same pattern wait-for-release-pr.sh uses), so sourcing it here pulls in
# its pure helpers without attempting a real Slack post. `curl` is stubbed
# via a mock bin directory prepended to PATH for the end-to-end main()
# scenarios, so these tests run with no network access and no real Slack
# credentials.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$script_dir/notify-release-slack.sh"

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

# shellcheck source=./notify-release-slack.sh
# shellcheck disable=SC1091 # dynamic $script path - shellcheck can't verify without -x
source "$script"

# --- is_empty_units: pure jq logic, no network needed ----------------------

assert_eq "$(is_empty_units '[]'; echo $?)" "0" \
  "is_empty_units: empty array is empty"
assert_eq "$(is_empty_units 'null'; echo $?)" "0" \
  "is_empty_units: bare null is empty"
assert_eq "$(is_empty_units 'not json'; echo $?)" "0" \
  "is_empty_units: malformed input treated as empty (fails safe, no post)"
assert_eq "$(is_empty_units '[{"unit":"a","version":"1.0.0","release_url":"https://x"}]'; echo $?)" "1" \
  "is_empty_units: one-element array is not empty"

# --- resolve_channel ---------------------------------------------------------

( unset SLACK_RELEASE_CHANNEL_ID; assert_eq "$(resolve_channel)" "#release" \
  "resolve_channel: falls back to literal #release when unset" )
( export SLACK_RELEASE_CHANNEL_ID="C0123456"; assert_eq "$(resolve_channel)" "C0123456" \
  "resolve_channel: uses SLACK_RELEASE_CHANNEL_ID when set" )

# --- build_message_text -----------------------------------------------------

one_unit='[{"unit":"mecha10-cli","version":"0.8.2","release_url":"https://example.com/cli-v0.8.2"}]'
text="$(build_message_text "$one_unit")"
assert_contains "$text" "1 unit released" "build_message_text: singular header for one unit"
assert_contains "$text" "<https://example.com/cli-v0.8.2|mecha10-cli v0.8.2>" \
  "build_message_text: links the single unit to its release URL"

two_units='[
  {"unit":"mecha10-cli","version":"0.8.2","release_url":"https://example.com/cli-v0.8.2"},
  {"unit":"mecha10-launcher","version":"1.1.0","release_url":"https://example.com/launcher-v1.1.0"}
]'
text="$(build_message_text "$two_units")"
assert_contains "$text" "2 units released" "build_message_text: plural header for multiple units"
assert_contains "$text" "<https://example.com/cli-v0.8.2|mecha10-cli v0.8.2>" \
  "build_message_text: includes first unit"
assert_contains "$text" "<https://example.com/launcher-v1.1.0|mecha10-launcher v1.1.0>" \
  "build_message_text: includes second unit"

# --- main(): end-to-end against mocked curl ---------------------------------

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

mock_bin="$work_dir/bin"
mkdir -p "$mock_bin"
PATH="$mock_bin:$PATH"

# Scenario 1: empty units list - no curl call should happen at all. A curl
# mock that always fails proves this: if main() posted anyway, the run
# would fail/non-zero instead of the clean no-op we assert.
cat > "$mock_bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl should not have been called for an empty units list" >&2
exit 1
EOF
chmod +x "$mock_bin/curl"

out="$(echo '[]' | SLACK_BOT_TOKEN=xoxb-test main - 2>&1)"; rc=$?
assert_eq "$rc" "0" "main(): empty units list exits 0"
assert_contains "$out" "No units released" "main(): empty units list logs a no-op, not an empty post"

# Scenario 2: SLACK_BOT_TOKEN unset - also no curl call, still exit 0.
out="$(echo "$one_unit" | SLACK_BOT_TOKEN= main - 2>&1)"; rc=$?
assert_eq "$rc" "0" "main(): missing SLACK_BOT_TOKEN exits 0"
assert_contains "$out" "SLACK_BOT_TOKEN not set" "main(): missing token logs a skip, not an error"

# Scenario 3: successful post - curl mock returns Slack's {"ok": true} and
# records the payload it was given so we can assert on channel/text.
captured_payload="$work_dir/captured_payload.json"
cat > "$mock_bin/curl" <<EOF
#!/usr/bin/env bash
# notify-release-slack.sh invokes: curl -sS -X POST <url> -H ... -H ... -d <payload>
echo "\${@: -1}" > "$captured_payload"
echo '{"ok": true}'
EOF
chmod +x "$mock_bin/curl"

out="$(echo "$two_units" | SLACK_BOT_TOKEN=xoxb-test SLACK_RELEASE_CHANNEL_ID=C0123456 main - 2>&1)"; rc=$?
assert_eq "$rc" "0" "main(): successful post exits 0"
assert_contains "$out" "Posted #release Slack notification for 2 unit(s)" \
  "main(): successful post logs the unit count"
assert_eq "$(jq -r '.channel' "$captured_payload")" "C0123456" \
  "main(): posts to the resolved channel"
assert_contains "$(cat "$captured_payload")" "mecha10-launcher v1.1.0" \
  "main(): payload text includes both units"

# Scenario 4: Slack API reports failure (ok: false) - main() should
# propagate the error rather than silently succeeding.
cat > "$mock_bin/curl" <<'EOF'
#!/usr/bin/env bash
echo '{"ok": false, "error": "channel_not_found"}'
EOF
chmod +x "$mock_bin/curl"

set +e
out="$(echo "$one_unit" | SLACK_BOT_TOKEN=xoxb-test main - 2>&1)"; rc=$?
set -e
assert_eq "$rc" "1" "main(): Slack API failure response returns non-zero"
assert_contains "$out" "channel_not_found" "main(): Slack API failure surfaces Slack's error detail"

# Scenario 5: reading units from a file path instead of stdin.
units_file="$work_dir/units.json"
echo "$one_unit" > "$units_file"
cat > "$mock_bin/curl" <<'EOF'
#!/usr/bin/env bash
echo '{"ok": true}'
EOF
chmod +x "$mock_bin/curl"

out="$(SLACK_BOT_TOKEN=xoxb-test main "$units_file" 2>&1)"; rc=$?
assert_eq "$rc" "0" "main(): reads units JSON from a file path argument"
assert_contains "$out" "Posted #release Slack notification for 1 unit(s)" \
  "main(): file-path input posts correctly"

if [ "$fail" -ne 0 ]; then
  echo "Some notify-release-slack.sh tests failed."
  exit 1
fi
echo "All notify-release-slack.sh tests passed."
