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
| `.github/actions/ci-failure-ticket/` | Checks out the repo and runs its own ticket-filing script to file a Linear ticket for a failed CI job — replaces the checkout + "File CI failure ticket" step pair duplicated near byte-for-byte across every consuming repo's `security.yml`/`ci.yml`/`main.yml` `ci-failure-ticket` jobs. The caller's job keeps its own `needs:`/`if: always() && contains(needs.*.result, 'failure')` gating. |

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

For the `ci-failure-ticket` job in a consuming repo's workflow, the caller keeps the job-level
`needs:`/`if:` gating and delegates the step body:

```yaml
ci-failure-ticket:
  name: ci-failure-ticket
  needs: [trivy-vuln, trivy-secret]
  if: always() && contains(needs.*.result, 'failure')
  runs-on: arc-catfood-minimal
  timeout-minutes: 10
  permissions:
    contents: read
  steps:
    - uses: mecha-industries/mecha10-actions/.github/actions/ci-failure-ticket@main
      with:
        workflow-name: "Security Scan"
        linear-api-key: ${{ secrets.LINEAR_API_KEY }}
```

Pass `script-path` only if the repo's ticket-filing script isn't at the default
`scripts/ci/file-ci-failure-ticket.sh` (e.g. `scripts/file-ci-failure-ticket.sh`).

## Adding more shared actions

Each new shared piece gets its own directory under `.github/actions/<name>/` with an
`action.yml` (composite action) and a short README section here. Candidates already identified
but not yet extracted (see mecha10-development's CI audit, 2026-11):
- The `libudev-dev`/`clang`/`mold` apt-install pattern repeated across several repos' Rust jobs
  (lower priority once baked into each repo's own dedicated runner image, as mecha10's was).
- The yamllint/shellcheck/uv Python-tooling bootstrap pattern used by several non-Python-image
  jobs.
