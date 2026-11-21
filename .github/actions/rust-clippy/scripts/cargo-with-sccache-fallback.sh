#!/usr/bin/env bash
#
# cargo-with-sccache-fallback.sh
#
# Runs a cargo command with sccache as RUSTC_WRAPPER, and transparently
# retries (without sccache, or after a `cargo clean`, or with a cleared
# registry index cache) when the failure looks like a cache problem rather
# than a real compile/lint/test failure.
#
# Reconciled from three divergent per-repo copies (mecha-industries/mecha10,
# mecha10-api, mecha10-nodes) - see the owning PR body for the full diff
# table. Every retry branch below is gated on either a specific error-output
# signature or a specific argv shape, so folding all three repos' retry
# logic into one script cannot change behavior for a repo whose build never
# hits that signature/shape - it's a pure superset.
#
# sccache defaults to local-disk caching (SCCACHE_DIR), set by
# scripts/ci/setup-sccache-cache-mode.sh (run once per job, before this
# script's first invocation) - this script just needs SCCACHE_DIR to
# already be set correctly in the environment.
#
# Usage:
#   ./cargo-with-sccache-fallback.sh cargo clippy --workspace -- -D warnings

set -uo pipefail

if [[ "$#" -eq 0 ]]; then
  echo "usage: $0 <cargo command...>" >&2
  exit 2
fi

# Pattern matched against the first attempt's combined output to decide
# whether a failure is an sccache/cache-storage problem worth retrying, vs.
# a real cargo failure that should be reported as-is.
SCCACHE_ERROR_PATTERN='sccache: error|Server startup failed|cache storage failed|could not execute process .sccache'

# Cross-machine stale-`target/`-cache glibc mismatch (LAB-2261) - e.g.:
#   /lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_2.39' not found
GLIBC_ERROR_PATTERN="GLIBC_[0-9]+\\.[0-9]+' not found"

# Cross-job stale-`target/`-cache fingerprint mismatch (LAB-3556) - e.g.:
#   error[E0463]: can't find crate for `tokio_macros`
MISSING_CRATE_ERROR_PATTERN="error\\[E0463\\]: can't find crate for"

# Corrupted/truncated sparse-registry index cache entry for a crate that's
# never actually compiled by this build (seen on jobs that build the same
# example unconditionally with no `needs:` gate between them, racing a cold
# dependency fetch). Cargo misreads the corrupted entry as "this package
# comes from a path source" instead of the registry. Fix is to clear the
# registry's *index* cache (not `cargo clean`, which only touches `target/`
# and wouldn't touch this) and retry.
PATH_SOURCE_ERROR_PATTERN="failed to find [^ ]+ v?[0-9][^ ]* in path source"

# `cargo test ... --doc` against a scope made up entirely of bin-only
# packages hard-fails with this exact message instead of reporting "0
# doctests ran" - there's nothing to doctest, so this is not a real test
# failure. Scoped to `--doc` invocations only (checked below).
NO_LIB_TARGETS_ERROR_PATTERN="error: no library targets found in package"

config_file=""
config_backup=""

# cargo-llvm-cov instruments binaries into target/llvm-cov-target, a
# separate, independently-fingerprinted tree from the plain `target/` build
# that clippy/plain-test/doctest steps share - letting it pile up stacks
# disk usage on top of theirs instead of sharing it (LAB-5249's "No space
# left on device" doctest failures). Only `cargo llvm-cov nextest ...`
# invocations are matched here deliberately: those callers already flush
# lcov.info to disk before returning and have nothing later in the same job
# depend on the instrumented binaries/profile data afterwards. Plain
# `cargo llvm-cov ... --lcov` without `nextest` is NOT matched - that caller
# (this repo's own rust-coverage action) runs `cargo llvm-cov report` right
# after, reusing the same profile data target/llvm-cov-target holds, so
# cleaning it up there would break that follow-up call. See LAB-5254.
needs_llvm_cov_target_cleanup=0
saw_llvm_cov=0
saw_nextest=0
for arg in "$@"; do
  [[ "$arg" == "llvm-cov" ]] && saw_llvm_cov=1
  [[ "$arg" == "nextest" ]] && saw_nextest=1
done
if [[ "$saw_llvm_cov" -eq 1 && "$saw_nextest" -eq 1 ]]; then
  needs_llvm_cov_target_cleanup=1
fi

# shellcheck disable=SC2329,SC2317 # invoked indirectly via the `trap` below
on_exit() {
  if [[ -n "$config_backup" ]]; then
    mv -f "$config_backup" "$config_file"
  fi

  if [[ "$needs_llvm_cov_target_cleanup" -eq 1 ]]; then
    # Scoped to this invocation's own checkout only (never a shared/global
    # path) so a concurrently-running job on another self-hosted runner -
    # with its own checkout and its own in-progress target/llvm-cov-target
    # - is never touched by this.
    cleanup_repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    rm -rf "$cleanup_repo_root/target/llvm-cov-target"
  fi
}
trap on_exit EXIT INT TERM

output=$(RUSTC_WRAPPER=sccache "$@" 2>&1)
status=$?
printf '%s\n' "$output"

if [[ "$status" -eq 0 ]]; then
  exit 0
fi

# cargo/rustc can emit ANSI color codes that land inside the literal error
# text the patterns above match against, splitting what looks like one
# contiguous string across several ANSI-code-interrupted fragments (LAB-3570/
# LAB-3569). Strip ANSI escapes into a separate variable for matching only;
# $output itself (already printed above) stays colorized for readability.
plain_output=$(printf '%s\n' "$output" | sed -E $'s/\x1b\\[[0-9;]*[a-zA-Z]//g')

if grep -qiE "$GLIBC_ERROR_PATTERN" <<<"$plain_output"; then
  echo "::warning::target/ cache appears to have been built on a machine with a different glibc - cleaning and retrying" >&2

  "$1" clean
  "$@"
  exit $?
fi

if grep -qE "$MISSING_CRATE_ERROR_PATTERN" <<<"$plain_output"; then
  echo "::warning::target/ cache appears to be from a differently-scoped job (stale fingerprint hiding a missing crate) - cleaning and retrying" >&2

  "$1" clean
  "$@"
  exit $?
fi

if grep -qE "$PATH_SOURCE_ERROR_PATTERN" <<<"$plain_output"; then
  echo "::warning::cargo's local registry index cache looks corrupted (a package it should fetch from the registry is being misread as a path source) - clearing the index cache and retrying" >&2

  cargo_home="${CARGO_HOME:-$HOME/.cargo}"
  rm -rf "${cargo_home}/registry/index"
  "$@"
  exit $?
fi

if grep -qiE "$SCCACHE_ERROR_PATTERN" <<<"$plain_output"; then
  echo "::warning::sccache appears unavailable (cache-storage issue) - retrying without sccache" >&2

  # Unsetting RUSTC_WRAPPER alone is not enough: the repo's .cargo/config.toml
  # may hardcode `build.rustc-wrapper = "sccache"`, and cargo falls back to
  # that config-file value whenever the env var isn't set. Temporarily move
  # config.toml out of the way for the retry only, and restore it
  # unconditionally via the on_exit trap - this runs on shared self-hosted
  # runners, so leaving the repo in a modified state is not acceptable even
  # if the retry itself fails or the script is interrupted.
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  config_file="$repo_root/.cargo/config.toml"

  if [[ -f "$config_file" ]]; then
    config_backup="$(mktemp "${config_file}.bak.XXXXXX")"
    mv -f "$config_file" "$config_backup"
  fi

  # Belt-and-suspenders on top of the config.toml move above: some other
  # config source (e.g. a runner-level $CARGO_HOME/config.toml) may also set
  # `build.rustc-wrapper`. `--config` is cargo's own documented override
  # mechanism - a CLI-supplied `--config` value takes precedence over every
  # config *file* cargo would otherwise merge in, regardless of which file
  # set it or where it lives. "$1" is always "cargo" per this script's usage
  # contract - the override must land immediately after it and before the
  # subcommand.
  env -u RUSTC_WRAPPER "$1" --config 'build.rustc-wrapper=""' "${@:2}"
  exit $?
fi

# `cargo test ... --doc` against a scope with zero library targets: not a
# real failure, just nothing to doctest. Only applies to `--doc` invocations,
# and only when every `error:`/`error[...]:` line in the output matches the
# no-lib-targets signature - if a *different* real error is mixed in, this
# still fails normally.
is_doc_invocation=0
for arg in "$@"; do
  if [[ "$arg" == "--doc" ]]; then
    is_doc_invocation=1
    break
  fi
done

if [[ "$is_doc_invocation" -eq 1 ]] && grep -qE "$NO_LIB_TARGETS_ERROR_PATTERN" <<<"$plain_output"; then
  other_errors=$(grep -E '^error(\[[^]]*\])?:' <<<"$plain_output" | grep -vE "$NO_LIB_TARGETS_ERROR_PATTERN" || true)
  if [[ -z "$other_errors" ]]; then
    echo "::notice::no library targets in scope for --doc - nothing to doctest, treating as pass" >&2
    exit 0
  fi
fi

# Real failure (not sccache-related) - report it as-is.
exit "$status"
