# mecha10-actions

Shared, reusable GitHub Actions composite actions and workflows for `mecha-industries` repos.

This is the **real source of truth**, org-owned — not a mirror of a personal-account repo.
(mecha-industries/mecha10 previously had a daily-synced mirror of `PeterChauYEG/labone-actions`,
decommissioned 2026-08 because referencing an external personal-account repo for CI isn't
allowed by org policy. This repo is different: it's owned by `mecha-industries` itself, so
`uses: mecha-industries/mecha10-actions/...@<ref>` references from other mecha-industries repos
are allowed.)

## Why this exists

Several near-identical CI steps are copy-pasted across mecha10/mecha10-api/mecha10-dashboard/
mecha10-deploy/mecha10-rl/mecha10-nodes/user-tools (confirmed duplication in ~15 jobs across 6
repos as of 2026-11). This repo consolidates those into reusable composite actions so a fix or
version bump lands once, not once per repo.

## What's here

| Path | Purpose |
|------|---------|
| `.github/actions/trivy-scan/` | Runs an Aqua Trivy scan (`vuln` or `secret` mode) against a bare `ubuntu:22.04` container job — replaces the `apt-get install curl ca-certificates` + `aquasecurity/trivy-action@...` steps duplicated verbatim across every consuming repo's `security.yml`/`pr.yml`. |
| `.github/actions/deps-changes/` | Runs `dorny/paths-filter` to detect dependency-manifest changes — replaces the `changes` job body duplicated across consuming repos' `security.yml` files. |

## Usage

From a consuming repo's workflow, inside a job running `container: image: ubuntu:22.04`:

```yaml
steps:
  - uses: actions/checkout@v7
  - uses: mecha-industries/mecha10-actions/.github/actions/trivy-scan@main
    with:
      scanners: vuln   # or: secret
      severity: HIGH,CRITICAL
```

Pin to a tag once this repo cuts a first release; `@main` is fine for the initial rollout while
this is still new.

Optional inputs for repos that need them:
- `resilient-install: "true"` - downloads the Trivy binary directly from GitHub's
  releases/download CDN with a retry loop instead of letting `trivy-action`'s own
  `setup-trivy` installer run (its version-lookup call is flaky under load). Pair with
  `trivy-version` (default `v0.76.2`) to pin the downloaded release.
- `db-repository` / `java-db-repository` - override `TRIVY_DB_REPOSITORY` /
  `TRIVY_JAVA_DB_REPOSITORY` (e.g. to point at a `ghcr.io` mirror), same as mecha10-deploy's
  job does today. Leave unset to use Trivy's own defaults.

Both are purely additive and off by default, so existing callers are unaffected.

### deps-changes

Replaces the `changes` job body duplicated across consuming repos' `security.yml` files
(dependency-manifest change detection via `dorny/paths-filter`). Job-level concerns — `if:`,
`runs-on:`, `permissions:`, and `outputs:` — can't live in a composite action, so the caller's
job still declares them itself and re-exports the action's `deps` output:

```yaml
jobs:
  changes:
    name: changes
    if: github.event_name != 'schedule'
    runs-on: arc-catfood-minimal
    timeout-minutes: 10
    permissions:
      contents: read
      pull-requests: read
    outputs:
      deps: ${{ steps.filter.outputs.deps }}
    steps:
      - uses: mecha-industries/mecha10-actions/.github/actions/deps-changes@main
        id: filter
```

The default `filters` input is the broad polyglot dependency-manifest list (`package.json`,
`yarn.lock`, `pnpm-lock.yaml`, `Cargo.toml`, `Cargo.lock`, `requirements*.txt`, `pyproject.toml`,
`Gemfile`, `Gemfile.lock`, `go.mod`, `go.sum`) — a superset of any single-ecosystem repo's
narrower list, so Rust-only repos (e.g. mecha10-nodes) get identical behavior from the default
without passing anything. Pass `filters` with a full `paths-filter` `filters:` block to override
it for repos that want something narrower or different.

## Adding more shared actions

Each new shared piece gets its own directory under `.github/actions/<name>/` with an
`action.yml` (composite action) and a short README section here. Candidates already identified
but not yet extracted (see mecha10-development's CI audit, 2026-11):
- The `libudev-dev`/`clang`/`mold` apt-install pattern repeated across several repos' Rust jobs
  (lower priority once baked into each repo's own dedicated runner image, as mecha10's was).
- The yamllint/shellcheck/uv Python-tooling bootstrap pattern used by several non-Python-image
  jobs.
