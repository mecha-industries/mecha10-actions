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
| `.github/actions/actionlint/` | Runs `rhysd/actionlint` against the checked-out repo's workflow YAML and exposes `outcome`/`report` outputs — never fails the job itself. |
| `.github/actions/ci-failure-ticket/` | Checks out the repo and runs its own ticket-filing script to file a Linear ticket for a failed CI job — replaces the checkout + "File CI failure ticket" step pair duplicated near byte-for-byte across every consuming repo's `security.yml`/`ci.yml`/`main.yml` `ci-failure-ticket` jobs. The caller's job keeps its own `needs:`/`if: always() && contains(needs.*.result, 'failure')` gating. |
| `.github/actions/commit-and-push-writeback/` | Stages, commits, and pushes generated files directly to the default branch, with fetch/rebase/push retry over concurrent pushes — replaces the writeback mechanics duplicated across mecha10-api/mecha10-dashboard/mecha10-rl's `update-status-table` jobs. |
| `.github/actions/deps-changes/` | Runs `dorny/paths-filter` to detect dependency-manifest changes — replaces the `changes` job body duplicated across consuming repos' `security.yml` files. |
| `.github/actions/file-linear-tickets/` | Files a deduped Linear ticket for every failed entry in a JSON report file, from a single job instead of one ticket-filing step per scan job — hoisted from mecha10/mecha10-api/mecha10-dashboard. |
| `.github/actions/trivy-scan/` | Runs an Aqua Trivy scan (`vuln` or `secret` mode) against a bare `ubuntu:22.04` container job — replaces the `apt-get install curl ca-certificates` + `aquasecurity/trivy-action@...` steps duplicated verbatim across every consuming repo's `security.yml`/`pr.yml`. |
| `.github/actions/cached-script/` | Restores Node/Yarn deps via the sibling `setup-node-yarn` action and runs a cached `yarn <script>` (lint/typecheck/build/test), with an optional script-specific incremental cache layered on top. |
| `.github/actions/rust-coverage/` | Runs `cargo-llvm-cov` over the workspace (or an affected-crate subset), uploads the lcov + text report, and appends it to the job summary — expects the caller to have already checked out the repo and installed a Rust toolchain. |
| `.github/actions/rust-fmt/` | Runs `cargo fmt --all --check` (or a crate subset), always with `continue-on-error`, and exposes `outcome`/`report` outputs — expects the caller to have already checked out the repo. |
| `.github/actions/rust-clippy/` | Runs `cargo clippy --workspace -- -D warnings` (or a crate subset, optionally via the caller's own sccache-fallback script), always with `continue-on-error`, and exposes `outcome`/`report` outputs — expects the caller to have already checked out the repo. |
| `.github/actions/scan-with-report/` | Runs a yarn report-producing scan script (design-system, dead-code, etc.), posts/updates a sticky PR comment via `danger-js`, and exposes `outcome`/`report`/`groups` outputs. |
| `.github/actions/setup-node-yarn/` | Checks out the repo, enables Corepack, sets up Node from `package.json`, and restores the Yarn + `node_modules` caches keyed on `yarn.lock`. |
| `.github/actions/setup-python-uv/` | Installs Python and `uv` (with `astral-sh/setup-uv` caching) — expects the caller to have already checked out the repo. |
| `.github/actions/setup-rust/` | Installs a stable Rust toolchain via `dtolnay/rust-toolchain`, optionally installs `libudev-dev`, and optionally runs `Swatinem/rust-cache` — expects the caller to have already checked out the repo. |
| `.github/actions/web-changes/` | Checks out the repo and runs `dorny/paths-filter` to expose a fixed set of web/Next.js path-change outputs (`react_ui`, `web_source`, `web_deps`, `image`, `any`, etc.). |

## Usage

Pin to a tag once this repo cuts a first release; `@main` is fine for the initial rollout while
this is still new.

### trivy-scan

From a consuming repo's workflow, inside a job running `container: image: ubuntu:22.04`:

```yaml
steps:
  - uses: actions/checkout@v7
  - uses: mecha-industries/mecha10-actions/.github/actions/trivy-scan@main
    with:
      scanners: vuln   # or: secret
      severity: HIGH,CRITICAL
```

Inputs:
- `scanners` (required) - Trivy scanner(s) to run: `vuln` or `secret`.
- `severity` (default `HIGH,CRITICAL`) - comma-separated severity levels to fail on.
- `scan-ref` (default `.`) - path to scan.
- `trivy-action-version` (default `v0.36.0`) - pinned `aquasecurity/trivy-action` version.
- `resilient-install: "true"` - downloads the Trivy binary directly from GitHub's
  releases/download CDN with a retry loop instead of letting `trivy-action`'s own
  `setup-trivy` installer run (its version-lookup call is flaky under load). Pair with
  `trivy-version` (default `v0.76.2`) to pin the downloaded release.
- `db-repository` / `java-db-repository` - override `TRIVY_DB_REPOSITORY` /
  `TRIVY_JAVA_DB_REPOSITORY` (e.g. to point at a `ghcr.io` mirror), same as mecha10-deploy's
  job does today. Leave unset to use Trivy's own defaults.
- `cache-db: "true"` - caches the Trivy vulnerability DB in `.cache/trivy` with a date-keyed
  `actions/cache` key (`trivy-db-YYYY-MM-DD`, falling back to any `trivy-db-` prefix match) and
  passes `cache: false` / `cache-dir: .cache/trivy` to `trivy-action`, instead of letting
  `trivy-action` manage its own cache.
- `cache-write` (default `"false"`) - only used when `cache-db` is `"true"`. Set to `"true"` on
  exactly one trigger (conventionally push-to-main) so that trigger writes a day's DB entry via
  `actions/cache`; every other trigger (PRs, scheduled runs, other branches) must leave
  `cache-write` unset/`"false"` so it only reads via `actions/cache/restore` — otherwise multiple
  runs race to write the same multi-hundred-MB cache entry.

All of the cache-related inputs are purely additive and off by default, so existing callers
passing neither `cache-db` nor `cache-write` are unaffected.

### ci-failure-ticket

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

Inputs:
- `workflow-name` (required) - human-readable label for the failed workflow, passed as the
  script's first argument (e.g. `"Security Scan"`, `"CI"`).
- `linear-api-key` (required) - Linear API key, e.g. `${{ secrets.LINEAR_API_KEY }}`.
- `script-path` (default `scripts/ci/file-ci-failure-ticket.sh`) - path to the repo's own
  ticket-filing script. Pass this only if the repo's script isn't at the default path (e.g.
  `scripts/file-ci-failure-ticket.sh`).

The caller's job still owns the `needs: [...]` and `if: always() && contains(needs.*.result,
'failure')` gating and the `ci-failure-ticket` job name itself — those are job-level edges that
cannot move into a composite action.

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

Inputs:
- `filters` (optional) - `paths-filter` `filters:` YAML block. Defaults to the broad polyglot
  dependency-manifest list (`package.json`, `yarn.lock`, `pnpm-lock.yaml`, `Cargo.toml`,
  `Cargo.lock`, `requirements*.txt`, `pyproject.toml`, `Gemfile`, `Gemfile.lock`, `go.mod`,
  `go.sum`) — a superset of any single-ecosystem repo's narrower list, so Rust-only repos (e.g.
  mecha10-nodes) get identical behavior from the default without passing anything. Pass `filters`
  to narrow or otherwise customize the list for repos that want something different.

A composite action can't contribute edges to another job's `needs:` graph or declare job-level
`if:`/`permissions:`/`outputs:`, so the caller's `changes` job must still declare its own `if:`,
`runs-on:`, `permissions: { contents: read, pull-requests: read }` (`pull-requests: read` is
required by `paths-filter` on `pull_request` events), and an `outputs:` mapping that re-exports
this action's `deps` output.

### actionlint

```yaml
steps:
  - id: lint
    uses: mecha-industries/mecha10-actions/.github/actions/actionlint@main
    with:
      actionlint-version: "1.7.12"

  - name: Fail on actionlint findings
    if: steps.lint.outputs.outcome == 'failure'
    run: exit 1
```

Inputs:
- `actionlint-version` (default `"1.7.12"`) - pinned `actionlint` version passed to
  `download-actionlint.bash`. Never `"latest"`.

Outputs:
- `outcome` - `success` or `failure`, the scan step's own outcome.
- `report` - contents of `actionlint-report.txt` (or a placeholder if it wasn't written).

This action **never fails the job itself** — it always runs the scan with `continue-on-error` and
exposes `outcome`/`report` as outputs instead. A caller that wants a hard gate must add its own
`if: steps.<id>.outputs.outcome == 'failure'` -> `exit 1` step right after using this action, as
shown above; a caller that wants to capture the report for downstream ticket-filing or PR comments
can consume the outputs directly instead.

### file-linear-tickets

```yaml
steps:
  - name: Write report entries
    run: |
      cat > "${{ runner.temp }}/file-linear-tickets-entries.json" <<EOF
      [
        {"name": "trivy-vuln", "outcome": "${{ needs.trivy-vuln.outputs.outcome }}", "report": ${{ toJSON(needs.trivy-vuln.outputs.report) }}, "groups": "[]"}
      ]
      EOF

  - uses: mecha-industries/mecha10-actions/.github/actions/file-linear-tickets@main
    with:
      entries-file: ${{ runner.temp }}/file-linear-tickets-entries.json
      linear-api-key: ${{ secrets.LINEAR_API_KEY }}
      pr-number: ${{ github.event.pull_request.number }}
      pr-url: ${{ github.event.pull_request.html_url }}
      run-url: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}
      script-path: scripts/ci/file-linear-ticket.sh
```

Inputs:
- `entries-file` (required) - path to a file holding a JSON array of `{name, outcome, report,
  groups}` objects, one per upstream job. `outcome` is that job's `outputs.outcome` (only
  `"failure"` entries file a ticket). `groups` is optional (omit, or pass `"[]"`, for jobs that
  don't produce a groups file).
- `linear-api-key` (required) - Linear GraphQL API key, forwarded to the filing script as
  `LINEAR_API_KEY`.
- `pr-number` (required) - pull request number, forwarded as `PR_NUMBER`.
- `pr-url` (required) - pull request HTML URL, forwarded as `PR_URL`.
- `run-url` (required) - workflow run URL, forwarded as `RUN_URL`.
- `script-path` (required, no default) - path, relative to the caller's checked-out repo, to that
  repo's own ticket-filing script (e.g. `scripts/ci/file-linear-ticket.sh`,
  `services/api/scripts/file-linear-ticket.sh`). The existing callers' scripts diverge in
  team/label IDs and dedup details, so each caller keeps its own script and passes its path here.

**`entries-file` is a file path, never inline JSON, on purpose.** A composite action's inputs
become plain environment variables under the hood — packing every upstream job's full report text
into one env var can exceed Linux's per-process exec limit (`MAX_ARG_STRLEN`, 128KB) and fail the
whole step with an opaque "Argument list too long" (this has happened in production). Write the
JSON to disk with a `run:` step (no such limit there) and pass its path instead, e.g.
`${{ runner.temp }}/file-linear-tickets-entries.json`.

### commit-and-push-writeback

```yaml
update-status-table:
  name: update-status-table
  if: "!contains(github.event.head_commit.message, 'chore: update status table')"
  concurrency:
    group: update-status-table-${{ github.ref }}
  permissions:
    contents: write
  runs-on: arc-catfood-minimal
  timeout-minutes: 10
  steps:
    - run: ./scripts/generate-status-table.sh
    - uses: mecha-industries/mecha10-actions/.github/actions/commit-and-push-writeback@main
      with:
        gh-pat: ${{ secrets.GH_PAT }}
        paths: STATUS.md
        commit-message: "chore: update status table"
```

Inputs:
- `gh-pat` (required) - a PAT (not `GITHUB_TOKEN`) with Contents: read/write on this repo, passed
  as `${{ secrets.GH_PAT }}`. `GITHUB_TOKEN` cannot push straight past branch protection, so this
  action fails loudly if `gh-pat` is empty instead of silently falling back or failing with an
  opaque auth error.
- `paths` (required) - newline- or space-separated file path(s) to stage and commit.
- `commit-message` (required) - commit message for the writeback commit.
- `target-branch` (default `"main"`) - branch to push the writeback commit to.
- `max-retries` (default `"3"`) - number of fetch/rebase/push attempts before failing the step.

This action pushes directly to a protected default branch using a PAT, rebasing over any
concurrent commit that lands on the target branch between checkout and push. It never
force-pushes and never hard-resets over the remote branch — a rebase conflict fails the step
loudly instead of silently discarding either side. What stays out of scope, and must stay in the
caller: the content generation itself (what changed and which script built it), and the job-level
`needs:`, `concurrency:`, `permissions: contents: write`, and `if:` skip guard — a composite
action cannot contribute to another job's `needs:` graph or declare job-level
`if:`/`concurrency:`/`permissions:`, so the calling job must keep declaring all of those,
including an `if:` that skips runs whose own commit message matches `commit-message` above (so
this job's writeback commit doesn't retrigger itself).

### setup-node-yarn

```yaml
steps:
  - uses: mecha-industries/mecha10-actions/.github/actions/setup-node-yarn@main
    with:
      cache-key-prefix: lint
      cache-write: ${{ github.event_name == 'push' }}
```

Inputs:
- `cache-key-prefix` (required) - job/purpose identifier (e.g. `lint`, `test`) folded into the
  Yarn download-cache key.
- `working-directory` (default `.`) - directory the app lives in.
- `extra-paths` (default `''`) - extra paths folded into the `node_modules` cache entry.
- `extra-cache-key-glob-1` / `extra-cache-key-glob-2` (default `''`) - extra glob(s) folded into
  the `node_modules` cache key's `hashFiles` alongside `yarn.lock`.
- `ssh-deploy-key` (default `''`) - SSH private key for cloning private git-dependency packages.
- `gh-token` (default `''`) - GitHub token exposed as `GH_TOKEN` to the install step only.
- `cache-write` (default `'false'`) - `'true'` to read+write the `node_modules` cache
  (push-to-main), `'false'` to only read it (PR runs).

This action **checks out the repository itself** (`actions/checkout@v7`) - callers don't add
their own checkout step before it.

### cached-script

```yaml
steps:
  - uses: mecha-industries/mecha10-actions/.github/actions/cached-script@main
    with:
      deps-cache-key-prefix: lint
      script: lint
      cache-path: .eslintcache
      cache-key-prefix: eslintcache
      cache-key-extra-glob-1: .eslintrc*
      cache-write: ${{ github.event_name == 'push' }}
```

Inputs:
- `deps-cache-key-prefix` (required) - passed through to `setup-node-yarn`'s `cache-key-prefix`.
- `working-directory` (default `.`).
- `extra-paths`, `extra-deps-cache-key-glob-1`, `extra-deps-cache-key-glob-2`, `ssh-deploy-key`,
  `gh-token` (all default `''`) - passed straight through to the matching `setup-node-yarn` input.
- `script` (required) - `package.json` script name to run (e.g. `lint`, `typecheck`, `build`).
- `script-args` (default `''`) - extra CLI args forwarded to the script.
- `cache-path` (default `''`) - script-specific incremental-cache path (e.g. `.eslintcache`,
  `tsconfig.tsbuildinfo`, `.jestcache`); empty skips this cache entirely.
- `cache-key-prefix` (default `''`) - required whenever `cache-path` is set.
- `cache-key-extra-glob-1` / `cache-key-extra-glob-2` (default `''`) - extra glob(s) folded into
  this action's own script-specific cache key.
- `cache-write` (default `'false'`) - `'true'` to read+write the script-specific cache
  (push-to-main), `'false'` to only read it (PR runs).

This action calls the sibling `setup-node-yarn` action **internally, via its full cross-repo
path** (`mecha-industries/mecha10-actions/.github/actions/setup-node-yarn@main`) - a consumer
gets the shared `setup-node-yarn`, not a local copy, and inherits its checkout + Yarn/
`node_modules` caching. Don't add a separate checkout step before this action.

### setup-rust

```yaml
steps:
  - uses: actions/checkout@v7
  - uses: mecha-industries/mecha10-actions/.github/actions/setup-rust@main
    with:
      components: clippy,rustfmt
      install-libudev: 'true'
```

Inputs:
- `components` (default `''`) - comma-separated Rust components to install (e.g. `rustfmt,clippy`).
- `install-libudev` (default `'false'`) - install the `libudev-dev` system package before the
  toolchain step.
- `enable-rust-cache` (default `'true'`) - run `Swatinem/rust-cache` after installing the toolchain.

This action does **not** check out the repository itself - the caller must run
`actions/checkout` first; a second checkout here would clobber whatever the caller's earlier
steps already produced in the workspace. `enable-rust-cache` defaults to `true`; a caller that
already manages its own build cache (e.g. via `mozilla-actions/sccache-action`) should pass
`enable-rust-cache: 'false'`, or drop its own cache step, to avoid two caches competing.

### rust-coverage

```yaml
steps:
  - uses: actions/checkout@v7
  - uses: mecha-industries/mecha10-actions/.github/actions/setup-rust@main
  - uses: mecha-industries/mecha10-actions/.github/actions/rust-coverage@main
    with:
      crate-scope: workspace
```

Inputs:
- `crate-scope` (required) - `workspace` (run across the whole workspace) or `subset` (narrow to
  `affected-crates`).
- `affected-crates` (default `''`) - space-separated crate names to scope to when `crate-scope` is
  `subset`; ignored otherwise.
- `sccache-cache-mode-script` (default `scripts/ci/setup-sccache-cache-mode.sh`) - repo-local
  script that decides sccache's cache dir/mode.
- `cargo-fallback-script` (default `scripts/ci/cargo-with-sccache-fallback.sh`) - repo-local
  script that runs a cargo command with sccache, retrying on cache-related failures.

No coverage threshold is enforced here - the calling job decides whether to fail on a broken
instrumented build/test run. Like `setup-rust`, this action does **not** check out the
repository itself and expects the calling job to have already checked out and installed a Rust
toolchain. It installs its own `dtolnay/rust-toolchain` + sccache steps rather than delegating to
`setup-rust`, to avoid a cross-PR ordering dependency between the two hoists. Callers outside
mecha10 must either carry the two `scripts/ci/...` helper scripts at their default paths, or
override `sccache-cache-mode-script`/`cargo-fallback-script` to point at their own equivalents.

### rust-fmt

```yaml
steps:
  - uses: actions/checkout@v7
  - uses: mecha-industries/mecha10-actions/.github/actions/setup-rust@main
    with:
      components: rustfmt
  - id: fmt
    uses: mecha-industries/mecha10-actions/.github/actions/rust-fmt@main

  - name: Fail on fmt findings
    if: steps.fmt.outputs.outcome == 'failure'
    run: exit 1
```

Inputs:
- `crate-scope` (default `workspace`) - `workspace` (`cargo fmt --all`) or `subset` (scope to
  `affected-crates` via repeated `-p <crate>` flags). `cargo fmt` has no `--workspace` flag;
  `--all` is its equivalent.
- `affected-crates` (default `''`) - space-separated crate names, consulted only when
  `crate-scope` is `subset`.
- `working-directory` (default `.`) - directory to run `cargo fmt` in.
- `cargo-profile-dev-debug` (default `'0'`) - exported as `CARGO_PROFILE_DEV_DEBUG` for the fmt
  step; empty leaves the workspace's own `[profile.dev] debug` setting untouched. `cargo fmt
  --check` never executes a binary, so the workspace's `debug = 1` is pure waste here — a caller
  that wants that workspace default (mecha10-nodes does) must pass an empty string.
- `omit-report-on-success` (default `'true'`) - replace a passing run's report output with a
  placeholder instead of the full (empty) output, to stay under GitHub's 1MB job-outputs cap.

Outputs:
- `outcome` - `success` or `failure`, the `cargo fmt` step's own outcome.
- `report` - contents of the `cargo fmt --check` report (or a placeholder).

This action does **not** run `actions/checkout` - same contract as `trivy-scan`, it runs mid-job
after the caller has already checked out the repo. It never fails the job itself: the `cargo fmt`
step always runs with `continue-on-error`, so a caller wanting a hard gate must add its own
`if: steps.<id>.outputs.outcome == 'failure'` -> `exit 1` step, as shown above.

### rust-clippy

```yaml
steps:
  - uses: actions/checkout@v7
  - uses: mecha-industries/mecha10-actions/.github/actions/setup-rust@main
    with:
      components: clippy
  - id: clippy
    uses: mecha-industries/mecha10-actions/.github/actions/rust-clippy@main

  - name: Fail on clippy findings
    if: steps.clippy.outputs.outcome == 'failure'
    run: exit 1
```

Inputs:
- `crate-scope` (default `workspace`) - `workspace` (`cargo clippy --workspace`) or `subset`
  (scope to `affected-crates` via repeated `-p <crate>` flags). Unlike `cargo fmt`, `cargo clippy`
  does support `--workspace`.
- `affected-crates` (default `''`) - space-separated crate names, consulted only when
  `crate-scope` is `subset`.
- `working-directory` (default `.`) - directory to run `cargo clippy` in.
- `cargo-profile-dev-debug` (default `'0'`) - exported as `CARGO_PROFILE_DEV_DEBUG` for the
  clippy step; empty leaves the workspace's own `[profile.dev] debug` setting untouched. `cargo
  clippy` only compiles+lints and never executes a binary, so the workspace's `debug = 1` is pure
  waste here — a caller that wants that workspace default (mecha10-nodes does) must pass an empty
  string.
- `omit-report-on-success` (default `'true'`) - replace a passing run's report output with a
  placeholder instead of the full (empty) output, to stay under GitHub's 1MB job-outputs cap.
- `sccache-fallback-script` (default `scripts/ci/cargo-with-sccache-fallback.sh`) - path, relative
  to `working-directory`, to the calling repo's own sccache-wrapping script for the `cargo
  clippy` invocation. Leave empty to run `cargo clippy` directly with no wrapper.

Outputs:
- `outcome` - `success` or `failure`, the `cargo clippy` step's own outcome.
- `report` - contents of the `cargo clippy` report (or a placeholder).

This action does **not** run `actions/checkout` - same contract as `trivy-scan`, it runs mid-job
after the caller has already checked out the repo. It never fails the job itself: the `cargo
clippy` step always runs with `continue-on-error`, so a caller wanting a hard gate must add its
own `if: steps.<id>.outputs.outcome == 'failure'` -> `exit 1` step, as shown above. Internally it
calls `setup-rust` with `enable-rust-cache: false` and defaults `sccache-fallback-script` to
`scripts/ci/cargo-with-sccache-fallback.sh` — a caller relying on `Swatinem/rust-cache` for
clippy needs to know that caching is deliberately off here, unlike this action's own call to
`setup-rust` for other steps.

Job-level concerns stay with the caller for both actions above: `needs:`/`if:` gating, `runs-on:`,
`timeout-minutes:`, `permissions:`, and the job's own `outputs:` re-export — a composite action
cannot contribute to another job's `needs:` graph. mecha10 adopts `rust-clippy` inside a
`clippy-shard` matrix leg; this action covers the single `cargo clippy` step body shared by every
shard, not the sharding/matrix machinery itself.

### scan-with-report

```yaml
steps:
  - uses: mecha-industries/mecha10-actions/.github/actions/setup-node-yarn@main
    with:
      cache-key-prefix: design-system
  - uses: mecha-industries/mecha10-actions/.github/actions/scan-with-report@main
    id: scan
    with:
      script: design-system
      report-file: design-system-report.md
      sticky-header: design-system-scan
```

Inputs:
- `script` (required) - yarn script to run, e.g. `design-system`, `dead-code`.
- `working-directory` (default `.`).
- `report-file` (required) - path to the markdown report the script writes.
- `sticky-header` (required) - unique id for the `danger-js` sticky PR comment (`danger ci --id`).
- `gh-token` (default `''`) - forwarded as `GH_TOKEN`/`GITHUB_TOKEN` to the scan script step only.
- `blocking` (default `'true'`) - whether a scan failure fails the containing job.

Outputs:
- `outcome` - `success` or `failure`, the scan step's own outcome.
- `report` - contents of `report-file` (or a placeholder if it wasn't written).
- `groups` - contents of the scan's `<script>-groups.json` (derived from `report-file`), or `[]`
  if the script never wrote one.

This action does **not** check out the repository and does **not** restore deps itself - the
caller must run its own checkout + Node/Yarn setup (e.g. `setup-node-yarn`) first, since some
callers also need job-level settings like `permissions: pull-requests: write` that a composite
action can't set for its caller. Unlike `actionlint`, this action fails the containing job
**itself** by default (`blocking: 'true'`) when the scan script fails; pass `blocking: 'false'`
for an advisory-only scan that still posts its sticky comment and exposes outputs, but never
blocks merge.

### setup-python-uv

```yaml
steps:
  - uses: actions/checkout@v7
  - uses: mecha-industries/mecha10-actions/.github/actions/setup-python-uv@main
    with:
      python-version: '3.12'
```

Inputs:
- `python-version` (default `'3.12'`) - Python version to install.
- `cache-prefix` (default `''`) - cache key prefix for `astral-sh/setup-uv` (use `"main"` for the
  main branch).

This action does **not** check out the repository itself - it expects to run mid-job after the
calling job has already checked out the repo.

### web-changes

```yaml
jobs:
  web-changes:
    name: web-changes
    runs-on: arc-catfood-minimal
    timeout-minutes: 10
    permissions:
      contents: read
      pull-requests: read
    outputs:
      web: ${{ steps.filter.outputs.web }}
      any: ${{ steps.filter.outputs.any }}
      image: ${{ steps.filter.outputs.image }}
    steps:
      - uses: mecha-industries/mecha10-actions/.github/actions/web-changes@main
        id: filter
```

No inputs. Outputs (all from `dorny/paths-filter`, passed straight through): `workflows`,
`react_ui`, `web_source`, `web_deps`, `tsconfig`, `eslint_config`, `jest_config`, `web`,
`ls_lint`, `any`, `image`.

This action **checks out the repository itself**. Like `deps-changes`, it uses
`dorny/paths-filter`, so on `pull_request` events the caller's job must declare
`permissions: { contents: read, pull-requests: read }`, and a composite action can't contribute
to another job's `needs:` graph or declare job-level `outputs:` - so the caller's job must
re-export whichever of this action's outputs it needs via its own `outputs:` mapping, as shown
above.

## Reusable workflows

Unlike the composite actions above (one `with:` call per step), a reusable workflow is invoked
once via `uses:` at the *job* level and owns its own job graph. This repo has one so far:

### security-scan.yml

The shared engine behind every mecha-industries repo's `security.yml`: a `changes` gate (skip the
vulnerability scan on PRs/pushes that touch no dependency manifest), `trivy-vuln` and
`trivy-secret` scan jobs built on this repo's own `trivy-scan` action, an optional
`required-checks` aggregate gate, and an optional `ci-failure-ticket` job. Every point where the
seven current `security.yml` callers diverge (gating formula, Trivy DB mirror, caching, script
path, whether `required-checks`/`changes` even exist) is a `workflow_call` input - see the input
descriptions in `security-scan.yml` itself for the full list and defaults.

Every job, including `trivy-vuln`/`trivy-secret`, runs on the single `minimal-runner-label` runner
(default `arc-catfood-minimal`) with no `container:` block: `trivy-scan` is called with
`direct-binary: true`, which downloads the Trivy binary and runs it from a plain shell step instead
of delegating to the Docker-container `aquasecurity/trivy-action`, so no Docker CLI on the runner
host is needed. The workflow also exposes a top-level `workflow_call` `changes` output (alongside
the existing `deps` output), passed through from the `changes` job's `deps-changes` call - for a
monorepo caller whose `deps-filters` defines one key per package, the CALLING workflow can gate its
own downstream jobs per package off this output, e.g.
`contains(fromJSON(needs.security-scan.outputs.changes), 'crate-a')`.

Add this to a consuming repo's `.github/workflows/security.yml` (adjust the `on:` triggers and
`with:` inputs for that repo's current behavior):

```yaml
name: Security Scan
run-name: Dependency & secret scan

on:
  pull_request:
    types: [opened, synchronize]
  push:
    branches:
      - main
  schedule:
    - cron: '0 6 * * 1'

# The nested `changes` job in security-scan.yml requests `pull-requests: read` (required by
# dorny/paths-filter on pull_request events) - a reusable workflow's job can never be granted
# more permission than the CALLER itself grants, so this caller must declare
# `pull-requests: read` here too, not just `contents: read`. Skipping this causes a
# `startup_failure` whose cause only shows up in the GitHub web UI's validation error - it
# never surfaces via the REST/GraphQL APIs, so it's easy to misdiagnose as something else.
permissions:
  contents: read
  pull-requests: read

concurrency:
  group: security-${{ github.ref }}
  cancel-in-progress: true

jobs:
  security-scan:
    uses: mecha-industries/mecha10-actions/.github/workflows/security-scan.yml@main
    # Required so the called workflow's ci-failure-ticket job can read secrets.LINEAR_API_KEY.
    secrets: inherit
    with:
      # Only the push-to-main run writes a fresh Trivy DB cache entry - PR and scheduled runs
      # only read it, so they don't race to create their own multi-hundred-MB copy.
      cache-write: ${{ github.event_name == 'push' }}
```

Leave every other `with:` input unset to get `security-scan.yml`'s defaults (vuln + secret scans
both enabled, `HIGH,CRITICAL` severity, deps-gated vuln scan bypassed only on `schedule`,
`required-checks` and `ci-failure-ticket` both enabled, default script path, no DB caching). Pass
only the inputs a given repo actually needs to diverge from that baseline - see `security-scan.yml`
for the complete input list.

### Removed: cache-cleanup.yml

A `cache-cleanup.yml` reusable engine lived here for about a day. It was extracted (#43) from
four byte-identical weekly-cron caller copies in `mecha10`, `mecha10-api`, `mecha10-dashboard`,
and `mecha10-rl`. Before any repo adopted the extracted engine, the operator retired all
scheduled workflow crons org-wide, so all four callers deleted their thin `schedule`/
`workflow_dispatch` wrapper files instead (mecha10 #1891, mecha10-api #450, mecha10-dashboard
#974, mecha10-rl #496). With zero consumers and no remaining trigger to call it, the engine
itself was deleted rather than kept around as untested code — don't re-extract it unless a
caller with a real cron actually reappears.

### ⚠️ Required-check naming: branch protection on a reusable-workflow job

A job inside a called reusable workflow is reported to GitHub as
`<caller-job-id> / <job-name>` — e.g. the engine's `Security Scan required checks` job surfaces as
`security-scan / Security Scan required checks`. A repo whose branch protection requires the bare
name `Security Scan required checks` will therefore never see that context satisfied, and its PRs
stay `BLOCKED` forever.

Confirmed: mecha-industries/mecha10, mecha10-api and mecha10-rl all require the bare
`Security Scan required checks` context today.

The fix requires no branch-protection change. A top-level job in the calling workflow gets no
prefix, and a reusable-workflow caller job already succeeds or fails as the aggregate of every job
inside it. So the consumer declares its own aggregator with the exact name branch protection
expects:

```yaml
jobs:
  security-scan:
    uses: mecha-industries/mecha10-actions/.github/workflows/security-scan.yml@main
    secrets: inherit
    with:
      enable-required-checks: false   # the consumer aggregator below is the gate
  required-checks:
    name: Security Scan required checks     # exactly the branch-protection context name
    needs: [security-scan]
    if: always()
    runs-on: arc-catfood-minimal
    timeout-minutes: 10
    steps:
      - name: Fail if the security scan failed or was cancelled
        if: ${{ contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled') }}
        shell: bash
        run: exit 1
```

A repo whose branch protection does not gate on Security Scan (mecha10-dashboard, mecha10-deploy,
mecha10-nodes, user-tools) needs no aggregator job and can simply leave
`enable-required-checks: false`.

> `rust-main.yml`, a speculative shared push-to-main engine for mecha10/mecha10-api
> `main.yml`, was removed — it never had a consumer. See "Removed: rust-main.yml" in
> `docs/rust-pr-engine-design.md` for the rationale.

### rust-pr.yml

The shared engine behind the three Rust repos' PR-time `pr.yml`: `changes` (paths-filter +
affected-crate scoping), `actionlint`, `fmt`, `clippy`, `test`/`doctest`, `coverage`,
`dependency-audit`, `cargo-machete`, `cargo-mutants`, and `fragment-check` — every one gated behind
its own `enable_*` input, off by default, so a caller only pays for the jobs it asks for.

**Deliberately NOT in the engine** (see the comment block at the top of `rust-pr.yml` for the full
list): clippy/test shard matrices + their aggregators, the advisory scan jobs that post sticky
comments from a separate node-capable runner (`dead_code_duplicate_code`,
`file_size_tech_debt`, `ignored-tests`, `useless-test-scan`, `unused-pub`, `post-scan-comments`,
`config-lint`, `quality-check`, `rust_scans`, `tech-debt`), `changeset-check`/`hakari`/`build`/the
`ci-auth`/`ci-relay`/`ci-payments` per-service splits, `release-scripts-tests`, `shell_lib_tests`,
and `file-linear-tickets`. All of these are either job-graph-bound (their `needs:` references a
repo-specific job the engine can't see) or run bespoke per-repo scripts with no shared logic to
hoist — they stay in each repo's own caller `pr.yml`.

`required-checks` **always stays in the caller**, named exactly as branch protection expects today
— see the "Required-check naming" warning above; the same risk applies here; verified per repo
below.

Minimal thin-caller example (mecha10-nodes shape — single workspace, no sharding):

```yaml
name: CI

on:
  pull_request:
    branches: [main]
  push:
    branches: [main]

concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

# pull-requests: read is required by dorny/paths-filter (enable_changes); pull-requests: write
# is required by cargo-machete/cargo-mutants' sticky-comment posting. A reusable workflow's job
# can never hold more permission than its caller grants here.
permissions:
  contents: read
  pull-requests: write

jobs:
  rust-pr:
    uses: mecha-industries/mecha10-actions/.github/workflows/rust-pr.yml@main
    secrets: inherit
    with:
      enable_changes: true
      enable_fmt: true
      enable_clippy: true
      enable_test: true
      enable_doctest: true
      enable_coverage: true
      enable_cargo_machete: true
      enable_cargo_mutants: true
      enable_fragment_check: true

  # Repo-specific, stays in the caller: shell_lib_tests (bash/python smoke tests over
  # scripts/ci/lib and scripts/release), and everything required-checks below needs.
  shell_lib_tests:
    # ... unchanged from today's pr.yml ...
    runs-on: arc-catfood-minimal

  required-checks:
    name: CI required checks     # exactly the branch-protection context name
    needs: [rust-pr, shell_lib_tests]
    if: always()
    runs-on: arc-catfood-minimal
    timeout-minutes: 10
    steps:
      - if: ${{ contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled') }}
        run: exit 1
```

mecha10 and mecha10-api additionally pass `enable_actionlint: true` and `enable_dependency_audit:
true`, keep their clippy/test shard matrices, hakari/changeset-check/build/scan jobs, and
`file-linear-tickets` entirely in the caller, and their `required-checks` jobs list both the
engine's call job and every one of those caller-only jobs in `needs:` — see the PR description for
the full per-repo table.

## Adding more shared actions

Each new shared piece gets its own directory under `.github/actions/<name>/` with an
`action.yml` (composite action) and a short README section here.

Two authoring traps have already bitten this repo - avoid repeating them:
- `needs` is **not** a valid context inside a composite action. A required-checks aggregator
  cannot be a composite action; it must stay an inline job-level step (see the `required-checks`
  job above). An action referencing `needs` fails to load entirely.
- Never put a `${{ ... }}` expression inside a composite action's `description:` string, not even
  as a usage example. GitHub evaluates `description:` at manifest-load time, and the action fails
  to load with "Unrecognized named-value". Write env-var form or plain prose there instead.

Candidates already identified
but not yet extracted (see mecha10-development's CI audit, 2026-11):
- The `libudev-dev`/`clang`/`mold` apt-install pattern repeated across several repos' Rust jobs
  (lower priority once baked into each repo's own dedicated runner image, as mecha10's was).
- The yamllint/shellcheck/uv Python-tooling bootstrap pattern used by several non-Python-image
  jobs.
