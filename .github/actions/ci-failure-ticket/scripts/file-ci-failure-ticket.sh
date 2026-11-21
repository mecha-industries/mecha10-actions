#!/usr/bin/env bash
# file-ci-failure-ticket.sh <workflow-name> <run-url>
#
# LAB: consolidated CI-failure Linear ticket filer. Files one Urgent (P0)
# Linear ticket when a main-branch CI/release workflow fails, or comments on
# the existing open ticket for this repo+workflow instead of creating a
# duplicate.
#
# This used to be copy-pasted into eight separate repos (mecha10,
# mecha10-api, mecha10-nodes, mecha10-rl, mecha10-dashboard, mecha10-deploy,
# mecha10-assets, user-tools) because mecha-industries repos cannot
# reference actions cross-org. Reconciling all eight found the dedup/filing
# logic itself byte-identical in behavior everywhere - every copy searches
# for an open LAB ticket whose description contains a
# `ci-failure-key:<repo>:<workflow>` marker, comments on it if found, and
# otherwise creates a new priority-1 ticket with that marker embedded (so
# the dispatch pipeline's later title rewrite doesn't break dedup on the
# next failure). No flag was needed for that part - there is nothing to
# reconcile.
#
# The only real differences were cosmetic/labeling:
#   - the default workflow-name used when invoked with no $1 ("Main" in six
#     of the eight copies, "CI" in mecha10-rl, "Release" in mecha10-assets)
#   - which Linear labels get attached beyond the universal CI label
#     (mecha10/mecha10-nodes also attach a Rust label; mecha10-dashboard
#     also attaches a Web label; the other five attach only the CI label)
# Both are now flags (see EXTRA_LABEL_IDS below and the action's
# extra-label-ids input), defaulting to the most common current behavior
# (CI label only, "Main" default) so adopting the bundled script changes no
# repo's filed-ticket content unless it opts in.
#
# Usage directly (bypassing the action, e.g. for local testing):
#   LINEAR_API_KEY=... GITHUB_REPOSITORY=mecha-industries/mecha10 \
#     ./file-ci-failure-ticket.sh "Main" "https://github.com/.../actions/runs/123"
#
# Normal usage is through the ci-failure-ticket composite action (see
# ../action.yml), which wires workflow-name/linear-api-key/extra-label-ids
# to this script's args/env and runs actions/checkout first.
#
# Required env vars:
#   LINEAR_API_KEY       - Linear GraphQL API key (repo secret). Empty is
#                           treated as "Linear filing not configured for
#                           this run" and skips with a log line, not a
#                           failure - matching every one of the eight source
#                           scripts' existing behavior for this exact case.
#   GITHUB_REPOSITORY    - e.g. "mecha-industries/mecha10"
#
# Optional env vars:
#   EXTRA_LABEL_IDS       - JSON array of additional Linear label IDs to
#                            attach beyond the universal CI label. Default
#                            "[]" (CI label only).
#   LINEAR_TEAM_KEY        - Linear team key to file under. Default "LAB".
#   LINEAR_API_URL         - override for the GraphQL endpoint, for testing.
#
# Requires: jq, curl.
set -uo pipefail

LOG_PREFIX="[file-ci-failure-ticket]"
CI_LABEL_ID="01f4906f-28d8-4ff9-b95c-a1d6de39d1ca"
LINEAR_API_URL="${LINEAR_API_URL:-https://api.linear.app/graphql}"
LINEAR_TEAM_KEY="${LINEAR_TEAM_KEY:-LAB}"

# Pure-ish helpers (no network) kept separate so file-ci-failure-ticket.test.sh
# can exercise them directly against canned JSON, same split as
# notify-release-slack.sh's is_empty_units/resolve_channel/build_message_text.

# ci_failure_marker <repo_name> <workflow_name>
# The dedup marker embedded in every filed ticket's description. Deliberately
# keyed on the description body, not the title: downstream ticket-enrichment
# in the Linear dispatch pipeline rewrites the title after creation, so an
# exact-title search would miss the renamed ticket on the next failure and
# file a duplicate. The marker survives that rename.
ci_failure_marker() {
  local repo_name="$1" workflow_name="$2"
  echo "<!-- ci-failure-key: ci-failure:${repo_name}:${workflow_name} -->"
}

# build_search_query <marker>
build_search_query() {
  local marker="$1"
  jq -n --arg teamKey "$LINEAR_TEAM_KEY" --arg descriptionContains "$marker" '{
    query: "query($teamKey: String!, $descriptionContains: String!) { issues(filter: { team: { key: { eq: $teamKey } }, state: { type: { nin: [\"completed\", \"cancelled\", \"duplicate\"] } }, description: { contains: $descriptionContains } }, first: 1) { nodes { id identifier url } } }",
    variables: { teamKey: $teamKey, descriptionContains: $descriptionContains }
  }'
}

# build_description <repo_name> <workflow_name> <run_url> <marker>
build_description() {
  local repo_name="$1" workflow_name="$2" run_url="$3" marker="$4"
  printf '**Repository:** `%s`\n**Workflow:** `%s`\n**Run:** %s\n\n%s\n' \
    "$repo_name" "$workflow_name" "$run_url" "$marker"
}

# build_label_ids_json <extra_label_ids_json>
# Always includes CI_LABEL_ID; appends whatever extra label IDs the caller
# asked for (mecha10/mecha10-nodes's Rust label, mecha10-dashboard's Web
# label, etc). Malformed/empty input degrades to "[]" so a bad env var
# never fails the whole run over a labeling nicety.
build_label_ids_json() {
  local extra_label_ids_json="${1:-[]}"
  local extra_normalized
  extra_normalized="$(echo "$extra_label_ids_json" | jq -c 'if type == "array" then . else [] end' 2>/dev/null)" || extra_normalized="[]"
  jq -nc --arg ciLabelId "$CI_LABEL_ID" --argjson extra "$extra_normalized" \
    '[$ciLabelId] + $extra'
}

linear_graphql() {
  local query_json="$1"
  curl -s -X POST "$LINEAR_API_URL" \
    -H "Authorization: $LINEAR_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$query_json"
}

linear_comment_on_issue() {
  local issue_id="$1" body="$2" comment_json
  comment_json=$(jq -n --arg issueId "$issue_id" --arg body "$body" \
    '{query:"mutation($issueId:String!,$body:String!){commentCreate(input:{issueId:$issueId,body:$body}){success}}", variables:{issueId:$issueId, body:$body}}')
  linear_graphql "$comment_json" > /dev/null
}

linear_find_team_id() {
  local team_response team_id
  team_response=$(linear_graphql "$(jq -n --arg teamKey "$LINEAR_TEAM_KEY" '{query:"query($teamKey: String!){ teams(filter: { key: { eq: $teamKey } }) { nodes { id } } }", variables:{teamKey:$teamKey}}')")
  team_id=$(echo "$team_response" | jq -r '.data.teams.nodes[0].id // empty')

  if [[ -z "$team_id" ]]; then
    echo "${LOG_PREFIX} ERROR: could not find ${LINEAR_TEAM_KEY} team" >&2
    return 1
  fi

  echo "$team_id"
}

linear_find_backlog_state_id() {
  local states_response state_id
  states_response=$(linear_graphql "$(jq -n --arg teamKey "$LINEAR_TEAM_KEY" '{query:"query($teamKey: String!){ workflowStates(filter: { team: { key: { eq: $teamKey } }, name: { eq: \"Backlog\" } }) { nodes { id } } }", variables:{teamKey:$teamKey}}')")
  state_id=$(echo "$states_response" | jq -r '.data.workflowStates.nodes[0].id // empty')

  if [[ -z "$state_id" ]]; then
    echo "${LOG_PREFIX} ERROR: could not find Backlog state" >&2
    return 1
  fi

  echo "$state_id"
}

linear_create_issue() {
  local team_id="$1" title="$2" description="$3" state_id="$4" priority="$5" label_ids_json="$6"
  local mutation query_json create_response success identifier url

  mutation='mutation($teamId: String!, $title: String!, $description: String!, $stateId: String!, $priority: Int, $labelIds: [String!]) {
    issueCreate(input: {
      teamId: $teamId,
      title: $title,
      description: $description,
      stateId: $stateId,
      priority: $priority,
      labelIds: $labelIds
    }) {
      success
      issue { identifier url }
    }
  }'

  query_json=$(jq -n \
    --arg mutation "$mutation" \
    --arg teamId "$team_id" \
    --arg title "$title" \
    --arg description "$description" \
    --arg stateId "$state_id" \
    --argjson priority "$priority" \
    --argjson labelIds "$label_ids_json" \
    '{
      query: $mutation,
      variables: {
        teamId: $teamId,
        title: $title,
        description: $description,
        stateId: $stateId,
        priority: $priority,
        labelIds: $labelIds
      }
    }')

  create_response=$(linear_graphql "$query_json")
  success=$(echo "$create_response" | jq -r '.data.issueCreate.success // false')

  if [[ "$success" != "true" ]]; then
    echo "${LOG_PREFIX} ERROR: issueCreate failed for \"$title\": $(echo "$create_response" | jq -r '.errors[0].message // "unknown"')" >&2
    return 1
  fi

  identifier=$(echo "$create_response" | jq -r '.data.issueCreate.issue.identifier')
  url=$(echo "$create_response" | jq -r '.data.issueCreate.issue.url')
  echo "${LOG_PREFIX} created $identifier: $url"
}

# main() is guarded by the sourcing check at the bottom so
# file-ci-failure-ticket.test.sh can `source` this file to reach the pure
# helpers above without attempting a real Linear call.
main() {
  local workflow_name="${1:-Main}"
  local run_url="${2:-}"

  if [[ -z "${LINEAR_API_KEY:-}" ]]; then
    echo "${LOG_PREFIX} WARN: LINEAR_API_KEY not set — skipping" >&2
    return 0
  fi

  if [[ -z "${GITHUB_REPOSITORY:-}" ]]; then
    echo "${LOG_PREFIX} ERROR: GITHUB_REPOSITORY not set" >&2
    return 1
  fi

  local repo_name title marker
  repo_name="${GITHUB_REPOSITORY#*/}"
  title="🔴 CI failing on main: ${repo_name}"
  marker="$(ci_failure_marker "$repo_name" "$workflow_name")"

  local search_response existing_id existing_identifier
  search_response=$(linear_graphql "$(build_search_query "$marker")")
  existing_id=$(echo "$search_response" | jq -r '.data.issues.nodes[0].id // empty')
  existing_identifier=$(echo "$search_response" | jq -r '.data.issues.nodes[0].identifier // empty')

  if [[ -n "$existing_id" ]]; then
    echo "${LOG_PREFIX} existing open ticket $existing_identifier — commenting instead of creating a duplicate"
    linear_comment_on_issue "$existing_id" "Still failing: \`${workflow_name}\` on main as of ${run_url}."
    return 0
  fi

  local team_id state_id description label_ids_json
  team_id=$(linear_find_team_id) || return 1
  state_id=$(linear_find_backlog_state_id) || return 1
  description="$(build_description "$repo_name" "$workflow_name" "$run_url" "$marker")"
  label_ids_json="$(build_label_ids_json "${EXTRA_LABEL_IDS:-[]}")"

  linear_create_issue "$team_id" "$title" "$description" "$state_id" 1 "$label_ids_json"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
  exit $?
fi
