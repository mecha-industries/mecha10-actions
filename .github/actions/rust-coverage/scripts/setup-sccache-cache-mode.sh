#!/usr/bin/env bash
#
# setup-sccache-cache-mode.sh
#
# Decides where sccache reads/writes its local-disk cache for this job, and
# exports SCCACHE_DIR (via $GITHUB_ENV) accordingly.
#
# Reconciled from three divergent per-repo copies (mecha-industries/mecha10,
# mecha10-api, mecha10-nodes) - see the owning PR body for the full diff
# table. The three were materially identical: same persistent-mount-first,
# HOME-second, RUNNER_TEMP-last cache-base selection, and the same
# main-writes / branch-reads-only split below. The only real functional gap
# was that mecha10-api's copy never had the HOME-not-writable fallback to
# RUNNER_TEMP that mecha10 (#1744/#1745) and mecha10-nodes already carried -
# this reconciled copy keeps that fallback, which only ever activates when
# $HOME truly isn't writable and therefore cannot regress mecha10-api's
# current passing runs.
#
# gha-runner-docker's old Docker-based dispatch system bind-mounted one
# persistent, shared, host-wide cache directory per repo at
# /root/.cache/sccache-main into every container - the same directory for
# every container, main or PR/branch alike. If every build both read AND
# wrote that directory directly, a broken or in-progress branch's compiler
# output could silently pollute the cache every other build (including
# main) reads from next, with no isolation or eviction.
#
# So only a push to main writes there directly. Every other build copies
# the shared cache into a scratch directory and points SCCACHE_DIR there
# instead: warm cache hits seeded from main's latest state, but any new
# writes during this build never touch the shared directory.
#
# Usage: run as a normal step early in a job, after "Set up sccache" -
# writes to $GITHUB_ENV directly, so it doesn't need to be sourced.

set -euo pipefail

# CI has since moved to the k3s/ARC runner pool (arc-catfood-rust / arc-
# mecha10), where pods are fully ephemeral and $HOME is NOT bind-mounted to
# anything persistent - a build "succeeds" at writing under $HOME, but that
# directory vanishes with the pod, giving the main/branch cache-safety split
# below near-zero real cross-job cache hit rate in production. That pool now
# has a real persistent, shared mount instead: /data/sccache, an NFS share
# on a dedicated NAS pool, mounted identically on every node (wired into the
# arc-rust image/values in gha-runner-docker). Prefer that when it's present
# and writable.
#
# SCCACHE_PERSISTENT_MOUNT is overridable purely so the companion test
# script can point it at a fake, writable directory instead of the real
# absolute path - the real runner pool never sets this env var, so
# production behavior is unaffected by this name (each of the three source
# repos used a different override name here; none of them set it in
# production, so picking one canonical name is a no-op behavior change).
PERSISTENT_CACHE_MOUNT="${SCCACHE_PERSISTENT_MOUNT:-/data/sccache}"

# On most runners $HOME is writable and that's where we want the cache to
# live if there's no better persistent mount available. But some
# arc-catfood-rust runner pods have a UID/HOME mismatch where $HOME reports
# /root yet the job's actual user has no write access there - any mkdir
# under $HOME then fails with "Permission denied" (mecha-industries/mecha10
# #1744/#1745; the pod spec itself needs a separate fix in the
# gha-runner-docker repo). Detect that case up front and fall back to
# $RUNNER_TEMP (guaranteed-writable on every GitHub Actions job) so the job
# doesn't just die here. This only changes behavior when $HOME truly isn't
# writable - the already-working push-to-main path keeps using $HOME as
# before whenever it can.
HOME_CACHE_BASE="${HOME:-/root}/.cache"
FALLBACK_CACHE_BASE="${RUNNER_TEMP:-/tmp}/sccache-home-fallback"

if [[ -d "$PERSISTENT_CACHE_MOUNT" && -w "$PERSISTENT_CACHE_MOUNT" ]]; then
  CACHE_BASE="$PERSISTENT_CACHE_MOUNT"
  echo "[setup-sccache-cache-mode] ${PERSISTENT_CACHE_MOUNT} is present and writable - using it for sccache dirs"
elif mkdir -p "$HOME_CACHE_BASE" 2>/dev/null && [[ -w "$HOME_CACHE_BASE" ]]; then
  CACHE_BASE="$HOME_CACHE_BASE"
  echo "[setup-sccache-cache-mode] HOME (${HOME:-/root}) is writable - using it for sccache dirs"
else
  CACHE_BASE="$FALLBACK_CACHE_BASE"
  echo "[setup-sccache-cache-mode] HOME (${HOME:-/root}) is not writable on this runner - falling back to ${CACHE_BASE} for sccache dirs"
fi

MAIN_CACHE_DIR="${CACHE_BASE}/sccache-main"
SCRATCH_CACHE_DIR="${CACHE_BASE}/sccache-scratch"

# Explicit, not relying on sccache's own default: the persistent mount has
# no other size cap of its own, and sccache only enforces its LRU eviction
# while actually running against MAIN_CACHE_DIR - i.e. only on a main push,
# same gate as this branch below.
export SCCACHE_CACHE_SIZE="8G"
echo "SCCACHE_CACHE_SIZE=${SCCACHE_CACHE_SIZE}" >>"$GITHUB_ENV"

if [[ "${GITHUB_REF:-}" == "refs/heads/main" && "${GITHUB_EVENT_NAME:-}" == "push" ]]; then
  echo "SCCACHE_DIR=${MAIN_CACHE_DIR}" >>"$GITHUB_ENV"
  echo "[setup-sccache-cache-mode] main push - writing directly to the shared cache"
  exit 0
fi

mkdir -p "$SCRATCH_CACHE_DIR"
if [[ -d "$MAIN_CACHE_DIR" ]]; then
  # sccache's local-disk cache only ever creates new content-addressed
  # files or removes old ones via LRU eviction - it never mutates an
  # existing cache file's content in place - so hardlinking existing
  # entries instead of copying them is safe. Hardlinks only work within a
  # single filesystem though, so detect that at runtime and fall back to a
  # full `cp -a` copy otherwise. Either way, -a/-al preserve mtimes (a
  # hardlink shares the same inode as the original) which sccache relies on
  # for eviction bookkeeping.
  main_dev=$(stat -c %d "$MAIN_CACHE_DIR" 2>/dev/null || echo "")
  scratch_dev=$(stat -c %d "$SCRATCH_CACHE_DIR" 2>/dev/null || echo "")
  if [[ -n "$main_dev" && "$main_dev" == "$scratch_dev" ]]; then
    cp -al "${MAIN_CACHE_DIR}/." "$SCRATCH_CACHE_DIR/" 2>/dev/null || true
    echo "[setup-sccache-cache-mode] not a main push - seeded scratch via hardlinks (same filesystem as sccache-main), writes stay local to this job"
  else
    cp -a "${MAIN_CACHE_DIR}/." "$SCRATCH_CACHE_DIR/" 2>/dev/null || true
    echo "[setup-sccache-cache-mode] not a main push - seeded a scratch copy of the shared cache (different filesystem, full copy), writes stay local to this job"
  fi
fi
echo "SCCACHE_DIR=${SCRATCH_CACHE_DIR}" >>"$GITHUB_ENV"
