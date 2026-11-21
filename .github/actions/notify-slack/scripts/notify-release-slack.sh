#!/usr/bin/env bash
# notify-release-slack.sh <units_json_file|->
#
# LAB-5479: consolidated Slack release-notification script. Posts ONE
# grouped message to #release listing every unit released in a run, each
# linking to its GitHub Release notes.
#
# This used to be copy-pasted verbatim into each repo's own scripts/release/
# (mecha10-api, mecha10-nodes, mecha10-rl, mecha10-dashboard, mecha10-deploy,
# mecha10-assets) because mecha-industries repos cannot reference actions
# cross-org. Reconciling all six copies found them behaviorally identical -
# mecha10-api and mecha10-nodes were byte-identical, and the other four
# differed only in header comments and test-fixture example data, never in
# logic. This file is that single reconciled copy, now shipped inside the
# notify-slack composite action itself (see action.yml, which invokes it via
# $GITHUB_ACTION_PATH) instead of being duplicated per repo. No behavior
# flag was needed to cover the six repos' differences, because there weren't
# any to cover.
#
# This script only builds and posts the message. It does NOT decide which
# units were released or create tags/GitHub Releases or assemble per-unit
# changelog fragments - the caller is responsible for producing the input
# JSON and calling this script (via the notify-slack action) from its own
# release job.
#
# Input: a JSON array of {"unit": "...", "version": "...", "release_url":
# "..."} objects, one per unit released in the run - read from the file
# path given as $1, or from stdin if $1 is "-" or omitted. An empty array
# (`[]`) is a valid, expected input for "nothing released this run": the
# script exits 0 and sends nothing, rather than posting a confusing empty
# message.
#
# Requires SLACK_BOT_TOKEN in the environment (skips with a log line and
# exit 0, not an error, if unset - e.g. a fork PR run with no repo secrets)
# and posts to channel SLACK_RELEASE_CHANNEL_ID if set, else the literal
# `#release`. A non-2xx/non-ok Slack response is a hard failure (exit 1,
# error on stderr) - same as every one of the six original copies.
#
# Usage directly (bypassing the action, e.g. for local testing):
#   echo '[{"unit":"mecha10-cli","version":"0.8.2","release_url":"https://github.com/mecha-industries/mecha10/releases/tag/cli-v0.8.2"}]' \
#     | SLACK_BOT_TOKEN=xoxb-... ./notify-release-slack.sh -
#
# Normal usage is through the notify-slack composite action (see
# .github/actions/notify-slack/action.yml), which wires units-json/
# slack-bot-token/slack-channel/slack-api-url inputs to this script's
# stdin/env vars.
#
# Requires: jq, curl.
set -uo pipefail

SLACK_API_URL="${SLACK_API_URL:-https://slack.com/api/chat.postMessage}"

# Pure-ish helpers (no network) kept separate so
# notify-release-slack.test.sh can exercise them directly against canned
# JSON, same split as wait-for-release-pr.sh's pr_field/
# summarize_blocking_checks.

# is_empty_units <units_json>
# True (exit 0) when the input is not a JSON array with at least one
# element - covers `[]`, missing/malformed input, and a bare `null`.
is_empty_units() {
  local units_json="$1"
  local count
  count="$(echo "$units_json" | jq 'if type == "array" then length else -1 end' 2>/dev/null)" || return 0
  [ "$count" -le 0 ]
}

# resolve_channel
# vars.SLACK_RELEASE_CHANNEL_ID (passed through as the SLACK_RELEASE_CHANNEL_ID
# env var by the calling workflow) if set and non-empty, else the literal
# `#release` - same fallback the inline step used
# (`vars.SLACK_RELEASE_CHANNEL_ID || '#release'`).
resolve_channel() {
  if [ -n "${SLACK_RELEASE_CHANNEL_ID:-}" ]; then
    echo "$SLACK_RELEASE_CHANNEL_ID"
  else
    echo "#release"
  fi
}

# build_message_text <units_json>
# One grouped Slack message (Slack mrkdwn): a header line with the release
# count, then one "<url|unit vversion>" bullet per unit, in input order.
build_message_text() {
  local units_json="$1"
  local count
  count="$(echo "$units_json" | jq 'length')"

  local header
  if [ "$count" -eq 1 ]; then
    header=":rocket: *1 unit released:*"
  else
    header=":rocket: *${count} units released:*"
  fi

  local bullets
  bullets="$(echo "$units_json" | jq -r '.[] | "• <\(.release_url)|\(.unit) v\(.version)>"')"

  printf '%s\n%s' "$header" "$bullets"
}

# main() is guarded by the sourcing check at the bottom so
# notify-release-slack.test.sh can `source` this file to reach the helpers
# above without attempting a real Slack post.
main() {
  local input="${1:--}"
  local units_json

  if [ "$input" = "-" ]; then
    units_json="$(cat)"
  else
    units_json="$(cat "$input")" || {
      echo "ERROR: could not read units JSON from '$input'" >&2
      return 1
    }
  fi

  if ! echo "$units_json" | jq -e . >/dev/null 2>&1; then
    echo "ERROR: input is not valid JSON" >&2
    return 1
  fi

  if is_empty_units "$units_json"; then
    echo "No units released this run - skipping #release Slack notification"
    return 0
  fi

  if [ -z "${SLACK_BOT_TOKEN:-}" ]; then
    echo "SLACK_BOT_TOKEN not set - skipping #release Slack notification"
    return 0
  fi

  local channel text payload response ok
  channel="$(resolve_channel)"
  text="$(build_message_text "$units_json")"
  payload="$(jq -n --arg channel "$channel" --arg text "$text" \
    '{channel: $channel, text: $text}')"

  response="$(curl -sS -X POST "$SLACK_API_URL" \
    -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
    -H "Content-Type: application/json; charset=utf-8" \
    -d "$payload")"

  ok="$(echo "$response" | jq -r '.ok // false' 2>/dev/null)"
  if [ "$ok" != "true" ]; then
    echo "ERROR: Slack chat.postMessage failed: $response" >&2
    return 1
  fi

  echo "Posted #release Slack notification for $(echo "$units_json" | jq 'length') unit(s) to $channel"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
  exit $?
fi
