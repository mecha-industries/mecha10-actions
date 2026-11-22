#!/usr/bin/env bash
# Smoke tests for setup-sccache-cache-mode.sh.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$script_dir/setup-sccache-cache-mode.sh"

fail=0

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

work_dir="$(mktemp -d)"
trap 'chmod -R u+rwx "$work_dir" 2>/dev/null || true; rm -rf "$work_dir"' EXIT

run_script() {
  local home="$1" ref="$2" event="$3" runner_temp="$4" env_file="$5"
  set +e
  out=$(env HOME="$home" GITHUB_REF="$ref" GITHUB_EVENT_NAME="$event" \
          RUNNER_TEMP="$runner_temp" GITHUB_ENV="$env_file" \
          SCCACHE_PERSISTENT_MOUNT="$work_dir/no-such-persistent-mount" \
          bash "$script" 2>&1)
  status=$?
  set -e
  echo "$out"
  return "$status"
}

# Case 1: $HOME is writable, push to main - must use the HOME-based main
# cache dir directly.
home1="$work_dir/home1"
mkdir -p "$home1"
env1="$work_dir/env1"
out=$(run_script "$home1" "refs/heads/main" "push" "$work_dir/rt1" "$env1")
status=$?
if [[ $status -eq 0 ]]; then
  echo "PASS: exits 0 for a writable-HOME main push"
else
  echo "FAIL: expected exit 0, got $status"
  fail=1
fi
assert_contains "$out" "HOME (${home1}) is writable" "reports HOME as writable"
assert_contains "$(cat "$env1")" "SCCACHE_DIR=${home1}/.cache/sccache-main" "main push uses HOME-based main cache dir when HOME is writable"

# Case 2: $HOME is writable, PR-triggered (not a main push) - should use the
# HOME-based scratch dir.
home2="$work_dir/home2"
mkdir -p "$home2"
env2="$work_dir/env2"
out=$(run_script "$home2" "refs/heads/feature" "pull_request" "$work_dir/rt2" "$env2")
status=$?
if [[ $status -eq 0 ]]; then
  echo "PASS: exits 0 for a writable-HOME PR run"
else
  echo "FAIL: expected exit 0, got $status"
  fail=1
fi
assert_contains "$(cat "$env2")" "SCCACHE_DIR=${home2}/.cache/sccache-scratch" "PR run uses HOME-based scratch cache dir when HOME is writable"

# Case 3: $HOME is NOT writable (the arc-catfood-rust UID/HOME mismatch),
# workflow_dispatch. Must fall back to $RUNNER_TEMP instead of failing - this
# is the behavior mecha10-api's old local copy was missing.
home3="$work_dir/home3"
mkdir -p "$home3"
chmod 000 "$home3"
runner_temp3="$work_dir/rt3"
env3="$work_dir/env3"
out=$(run_script "$home3" "refs/heads/feature" "workflow_dispatch" "$runner_temp3" "$env3")
status=$?
chmod 755 "$home3"
if [[ $status -eq 0 ]]; then
  echo "PASS: exits 0 for a non-writable-HOME workflow_dispatch run"
else
  echo "FAIL: expected exit 0, got $status"
  fail=1
fi
assert_contains "$out" "HOME (${home3}) is not writable" "reports HOME as not writable"
assert_contains "$(cat "$env3")" "SCCACHE_DIR=${runner_temp3}/sccache-home-fallback/sccache-scratch" "falls back to RUNNER_TEMP-based scratch cache dir when HOME is not writable"

# Case 4: $HOME is NOT writable, but on a main push - the fallback must
# still kick in rather than assuming the push-to-main path is always safe.
home4="$work_dir/home4"
mkdir -p "$home4"
chmod 000 "$home4"
runner_temp4="$work_dir/rt4"
env4="$work_dir/env4"
out=$(run_script "$home4" "refs/heads/main" "push" "$runner_temp4" "$env4")
status=$?
chmod 755 "$home4"
if [[ $status -eq 0 ]]; then
  echo "PASS: exits 0 for a non-writable-HOME main push"
else
  echo "FAIL: expected exit 0, got $status"
  fail=1
fi
assert_contains "$(cat "$env4")" "SCCACHE_DIR=${runner_temp4}/sccache-home-fallback/sccache-main" "falls back to RUNNER_TEMP-based main cache dir on a main push when HOME is not writable"

# Case 5: no $RUNNER_TEMP set at all (bare /tmp fallback) and non-writable
# HOME - make sure the ${RUNNER_TEMP:-/tmp} default actually works.
home5="$work_dir/home5"
mkdir -p "$home5"
chmod 000 "$home5"
env5="$work_dir/env5"
set +e
# shellcheck disable=SC2016 # $0 is bash -c's own arg, must stay unexpanded here
out=$(env HOME="$home5" GITHUB_REF="refs/heads/feature" GITHUB_EVENT_NAME="pull_request" \
        GITHUB_ENV="$env5" SCCACHE_PERSISTENT_MOUNT="$work_dir/no-such-persistent-mount" \
        bash -c 'unset RUNNER_TEMP; exec "$0"' "$script" 2>&1)
status=$?
set -e
chmod 755 "$home5"
if [[ $status -eq 0 ]]; then
  echo "PASS: exits 0 for a non-writable-HOME run with no \$RUNNER_TEMP set"
else
  echo "FAIL: expected exit 0, got $status"
  fail=1
fi
assert_contains "$(cat "$env5")" "SCCACHE_DIR=/tmp/sccache-home-fallback/sccache-scratch" "falls back to bare /tmp when neither HOME nor \$RUNNER_TEMP is usable"

# Case 6: the persistent NFS mount (/data/sccache on real runner pods,
# stubbed here via SCCACHE_PERSISTENT_MOUNT) is present and writable - it
# must win over $HOME even when $HOME is also writable, since only the
# mount actually persists across jobs.
home6="$work_dir/home6"
mkdir -p "$home6"
data_mount6="$work_dir/data-sccache6"
mkdir -p "$data_mount6"
env6="$work_dir/env6"
set +e
out=$(env HOME="$home6" GITHUB_REF="refs/heads/main" GITHUB_EVENT_NAME="push" \
        RUNNER_TEMP="$work_dir/rt6" GITHUB_ENV="$env6" \
        SCCACHE_PERSISTENT_MOUNT="$data_mount6" \
        bash "$script" 2>&1)
status=$?
set -e
if [[ $status -eq 0 ]]; then
  echo "PASS: exits 0 when the persistent data mount is present"
else
  echo "FAIL: expected exit 0, got $status"
  fail=1
fi
assert_contains "$out" "${data_mount6} is present and writable" "reports the persistent data mount as in use"
assert_contains "$(cat "$env6")" "SCCACHE_DIR=${data_mount6}/sccache-main" "uses the persistent data mount for the main cache dir, even though HOME is also writable"

# Case 7: the persistent data mount path exists but isn't writable (e.g. a
# misconfigured/read-only mount) - must fall back to HOME, not error out.
home7="$work_dir/home7"
mkdir -p "$home7"
data_mount7="$work_dir/data-sccache7"
mkdir -p "$data_mount7"
chmod 555 "$data_mount7"
env7="$work_dir/env7"
set +e
out=$(env HOME="$home7" GITHUB_REF="refs/heads/feature" GITHUB_EVENT_NAME="pull_request" \
        RUNNER_TEMP="$work_dir/rt7" GITHUB_ENV="$env7" \
        SCCACHE_PERSISTENT_MOUNT="$data_mount7" \
        bash "$script" 2>&1)
status=$?
set -e
chmod 755 "$data_mount7"
if [[ $status -eq 0 ]]; then
  echo "PASS: exits 0 when the persistent data mount exists but isn't writable"
else
  echo "FAIL: expected exit 0, got $status"
  fail=1
fi
assert_contains "$out" "HOME (${home7}) is writable" "falls back to HOME when the data mount exists but isn't writable"
assert_contains "$(cat "$env7")" "SCCACHE_DIR=${home7}/.cache/sccache-scratch" "uses HOME-based scratch dir when the data mount isn't writable"

if [[ $fail -ne 0 ]]; then
  echo "One or more tests FAILED"
  exit 1
fi
echo "All setup-sccache-cache-mode.sh tests passed"
