# Assessment: shared `ci-core.yml` reusable workflow

Status: assessment only — no `ci-core.yml` workflow was written. Sources: this repo's own
`docs/rust-pr-engine-design.md` (live reads of `mecha10` 2121 lines/23 jobs, `mecha10-api` 1778
lines/20 jobs, `mecha10-nodes` 637 lines/10 jobs) and `docs/web-pr-engine-design.md` (live reads
of `mecha10-dashboard` `pr.yml`/`main.yml`, `mecha10-rl` `pr.yml`/`main.yml`, `mecha10-deploy`
`pr.yml`/`main.yml`, `mecha10-e2e` `pr.yml`, `user-tools` `ci.yml`), both already covering 8 of
the 9 named repos. `mecha10-assets` was not covered by either prior doc, so it was read live in
this pass (`gh api repos/mecha-industries/mecha10-assets/contents/.github/workflows/pr.yml` —
156 lines; it has no `main.yml`). Branch protection was not re-read here because this PR adopts
nothing in any consumer repo — see "Scope" below.

## 0. The task's own premise, checked

The dispatch instructions estimated "~33 duplicate job definitions" for `lint`/`typecheck`/
`test`/`build`/`scan` across the 9 repos' `pr.yml`+`main.yml`, and explicitly warned that estimate
"has been wrong before in this migration" — citing a "14 duplicate slack calls" claim that turned
out to be 14 call sites of an already-shared action, and a "3 duplicate setup-node sites" claim
that turned out to span two different package managers. Measuring directly against the two
existing per-repo matrices plus the `mecha10-assets` read shows the `ci-core` estimate falls into
the exact same trap.

## 1. What stack each repo actually runs

| Repo | Stack | lint/typecheck/build/test shape |
|---|---|---|
| `mecha10` | Rust (+ Node for `quality-check`/scans) | `cargo fmt`/`clippy`/`nextest`, sharded; Node lint via `yarn` inside one REPO-SPECIFIC job |
| `mecha10-api` | Rust (+ 3 Node microservices) | `cargo fmt`/`clippy`/`nextest`, sharded; `ci-auth`/`ci-relay`/`ci-payments` each run `pnpm`+`turbo` |
| `mecha10-nodes` | Rust | `cargo fmt`/`clippy`/`nextest`, unsharded |
| `mecha10-dashboard` | Next.js/React, Yarn | `yarn` lint/typecheck/build/test via the `cached-script` composite action |
| `mecha10-rl` | Python, `uv` | `ruff`/`pytest` — no Node/TS anywhere in either workflow |
| `mecha10-deploy` | Docker Compose / Caddyfile / Dockerfile / TOML | validation scripts only — no lint/typecheck/build/test job family at all |
| `mecha10-e2e` | Bash/bats | one `node --check` syntax check on a single file — no install/build/test pipeline |
| `user-tools` | POSIX/bash, `curl \| sh` distribution | no Node/TS content |
| `mecha10-assets` | Python (bespoke JSON/YAML + cross-file schema validation) | `validate` (JSON/YAML parse) + `test` (`pytest`), each with its own `apt-get install python3-pip` retry loop |

Only **two** repos (`mecha10`, `mecha10-api`) run a sharded Rust pipeline; one more
(`mecha10-nodes`) runs an unsharded Rust pipeline; one (`mecha10-dashboard`) runs the Node/Yarn
shape; the remaining five run five mutually-incompatible bespoke shapes (Python+uv, Docker/infra
validation, bats, bare POSIX, bespoke-Python-with-apt). There is no single `lint`/`typecheck`/
`test`/`build` tool invocation shared across more than one stack family — the job *names* repeat,
the job *bodies* don't.

## 2. Per job-family reality check

| Job family | Genuinely duplicate across ≥3 repos? | Why / why not |
|---|---|---|
| `scan` | **No further work needed** | Already extracted as `security-scan.yml`, a real reusable workflow in this repo, already called by `mecha10`, `mecha10-api`, `mecha10-nodes`, `mecha10-dashboard`, `mecha10-assets` today. Nothing left to abstract — this job family is the one part of the ~33 count that was already fixed before this task started. |
| `lint`/`fmt` | **No** | Rust side: identical shape across `mecha10`/`mecha10-api`/`mecha10-nodes`, but already assessed in `docs/rust-pr-engine-design.md` §2-3 as `SHARED-PARAMETERISED` and built into `rust-pr.yml` — see §3 below, this is not new scope. Node side: only `mecha10-dashboard` has this job at all (one repo, not three). Everyone else's "lint" is a different tool entirely (`ruff`, bespoke JSON/YAML parse, none). |
| `typecheck` | **No** | Exists only in `mecha10-dashboard` (`tsc`) and inside `mecha10-api`'s/`mecha10`'s per-service Node jobs (`ci-auth`/`ci-relay`/`ci-payments`, already classified `REPO-SPECIFIC` in `rust-pr-engine-design.md` §2 for their multi-service Node/pnpm/turbo architecture). Not a cross-repo duplicate; one real site plus three bespoke, already-assessed sites. |
| `test` | **No** | Rust `test`/`test-shard` is `CALLER-ONLY` per `rust-pr-engine-design.md` §2 (explicit job-graph-bound sharding + aggregator — a reusable workflow cannot express the caller's own `needs:` graph). Node `test` (`mecha10-dashboard`) is one repo. `pytest`/`bats`/none elsewhere are four more mutually distinct shapes. |
| `build` | **No** | Only `mecha10-api` has a standalone `build` (`cargo check`) job — one data point, already flagged in `rust-pr-engine-design.md` §2 as "not a parameterization case yet." `mecha10-dashboard`'s Next.js build is the Node shape (one repo). Nothing to extract for the other six. |

## 3. What this means for `ci-core.yml`

Every job family in the task's duplication claim is one of:

1. **Already extracted**, one layer below the workflow, as a composite action (`rust-fmt`,
   `rust-clippy`, `rust-coverage`, `cached-script`, `actionlint`) or a reusable workflow
   (`security-scan.yml`) — adopted already by most of the 9 repos.
2. **Already assessed and built** for the one case that cleared the bar (Rust `fmt`/`clippy`/
   `doctest`/`coverage`/mutants → `rust-pr.yml`, consumed today by `mecha10-nodes`; declined for
   `mecha10`/`mecha10-api` because their sharded job graphs are `CALLER-ONLY` by construction —
   `rust-pr-engine-design.md` §2-6).
3. **Already assessed and declined** for the Node shape (`web-pr-engine-design.md`: only one of
   five candidate repos is actually Node/TS, and that one repo is already a thin wrapper over
   existing composite actions with nothing left to extract).
4. **A single data point with no second consumer** (`mecha10-api`'s `build`, `mecha10-assets`'
   `validate`/`test`, `mecha10-rl`'s `ruff`/`pytest`, `mecha10-deploy`'s validation scripts,
   `mecha10-e2e`'s syntax check, `user-tools`' shell checks) — none of these five repos shares a
   tool invocation with any other repo in the list for this job family. Building shared inputs
   for a one-consumer job is the same anti-pattern `web-pr-engine-design.md` §2 already rejected.

There is no residual set of jobs that is simultaneously (a) not already covered by an existing
composite action or reusable workflow, (b) shared in actual tool invocation (not just job name)
across three or more repos, and (c) parameterizable in ≤2-3 inputs. A `ci-core.yml` built to
cover the task's named job families would have to either stay narrowly Rust-scoped — in which
case it is `rust-pr.yml`, which already exists and already has its one real consumer — or branch
internally on stack (`if: inputs.stack == 'rust' ... elif 'node' ...`), which is not
parameterization, it's reimplementing per-stack CI inside one file with a worse input surface
than the composite-action layer it would sit on top of.

## 4. Recommendation

**Do not build `ci-core.yml`.** The genuinely shared surface across these 9 repos is already
extracted at the composite-action layer (7 of this repo's 17 actions are used across ≥3 repos
today) and at the one reusable-workflow layer that cleared the bar (`security-scan.yml`, already
near-universally adopted). The one additional reusable workflow that was ever justified by a real
job-graph match (`rust-pr.yml`) is already built and already has its one real consumer. Building
a second, broader reusable workflow on top of that — with zero consumers on day one, same as the
now-deleted `rust-main.yml` and the declined `web-pr.yml`/`web-main.yml` — would repeat the exact
failure mode this task's own brief warns about: untested shared CI code sitting unconsumed until
an adoption pass finally exercises it and discovers a bug (the `fail-if-required-failed`
incident) or discovers it was never worth shipping (`rust-main.yml`).

**If a future pass wants real traction here**, the actionable gap is adoption of the *existing*
composite actions, not a new workflow: confirm every repo that already matches `rust-pr.yml`'s
shape (none beyond `mecha10-nodes` today, per §6 of `rust-pr-engine-design.md`) or
`security-scan.yml`'s shape (already near-universal) stays that way as new repos are added, and
leave the five structurally-bespoke repos (`mecha10-rl`, `mecha10-deploy`, `mecha10-e2e`,
`user-tools`, `mecha10-assets`) alone — none of them has a second repo sharing its tool
invocation to parameterize against.
