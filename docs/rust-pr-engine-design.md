# Design spec: shared `rust-pr.yml` reusable workflow

Status: design only, no workflow YAML proposed or changed by this document. Sources: the three
repos' current `pr.yml`/`develop.yml` as of this writing (`mecha10` 2121 lines/23 jobs,
`mecha10-api` 1778 lines/20 jobs, `mecha10-nodes` 637 lines/10 jobs), `security-scan.yml` (203
lines, the one existing reusable workflow in this repo), and the 17 composite actions under
`.github/actions/`. Branch-protection required contexts were read live via `gh api
repos/mecha-industries/<repo>/branches/main/protection`.

## 1. Job inventory matrix

Job **concepts** as rows (some map 1:1 to a job id, some are multi-job clusters that differ in
how they're grouped per repo). ✅ = present, ❌ = absent.

| Job concept | mecha10 | mecha10-api | mecha10-nodes |
|---|---|---|---|
| changes/detect (paths-filter + crate-scope) | ✅ `changes` — rust/quality/config/workflows filters + crate-scope/affected-crates/workspace-crates, `arc-catfood-rust` | ✅ `detect` — api/auth/relay/payments/workflows filters (two separate `paths-filter` steps, `some` vs `every` quantifier) + crate-scope/affected-crates, `arc-mecha10-api` | ✅ `changes` — single `all: ['**']` filter + crate-scope/affected-crates only, `arc-catfood-rust` |
| actionlint | ✅ gated on `workflows=='true' && action!='closed'`, `arc-mecha10` | ✅ gated on `workflows=='true'`, `arc-catfood-minimal` | ❌ no job at all |
| fragment/changeset check | ✅ `changeset-check` — `.changeset/*.md`, reuses crate-scope, skips `release/*` branches | ✅ `fragment-check` — `.changes/*.md`, derives "tracked" from 4 detect flags, also validates fragment schema | ✅ `fragment-check` — `.changes/*.md`, derives "tracked" via `build_nodes.py --print-nodes` (own node-detection script) |
| fmt | ✅ `rust-fmt` action, `arc-mecha10`, 20min | ✅ `rust-fmt` action, `working-directory: services/api`, `arc-catfood-rust`, 10min, `omit-report-on-success: false` | ✅ `rust-fmt` action, `arc-catfood-rust` (via `arc-mecha10`... see note), 15min |
| hakari (workspace-hack drift) | ✅ `hakari` | ❌ | ❌ |
| clippy sharding/plan | ✅ `clippy-plan` (4-way round-robin shard matrix) + `clippy-shard` (matrix) + `clippy` (aggregator, republishes outputs) | ❌ — `clippy` is one plain job | ❌ — `clippy` is one plain job |
| clippy (unsharded shape) | n/a (see above) | ✅ `rust-clippy` action, `arc-catfood-rust`, 30min | ✅ `rust-clippy` action, `arc-mecha10-rust`, 30min, custom linker env |
| test sharding/aggregation | ✅ `test-shard` (4-way nextest `--partition`, matrix) + `test` (aggregator over `test-shard`+`doctest`) | ✅ `test-shard` (4-way, matrix) + `test` (aggregator) | ❌ — single `test` job, unsharded nextest + inline doctest step |
| doctest | ✅ separate `doctest` job | ✅ separate `doctest` job | ❌ folded as a step inside the single `test` job |
| coverage | ✅ `coverage` — downloads 4 shards' raw `llvm-cov-target` artifacts, merges, reports, Codecov upload | ✅ `coverage` — same 4-shard download/merge pattern, `flags: rust-api` | ✅ `coverage` — direct `rust-coverage` action call (no sharding, no artifact merge) |
| dead-code scan | ✅ part of `dead_code_duplicate_code` (cargo-machete) | ✅ part of `rust_scans` (cargo-machete) | ✅ `cargo-machete` (own job, same tool, no duplicate-code paired with it) |
| duplicate-code scan | ✅ part of `dead_code_duplicate_code` (cargo-dupes) | ✅ part of `rust_scans` (cargo-dupes) | ❌ |
| file-size scan | ✅ part of `file_size_tech_debt` | ✅ part of `rust_scans` | ❌ |
| tech-debt scan | ✅ part of `file_size_tech_debt` | ✅ separate `tech-debt` job | ❌ |
| dependency-audit (cargo audit) | ✅ own job | ❌ ("never enabled... no inlined equivalent" per header) | ❌ |
| ignored-tests scan | ✅ own job, hard-blocking | ❌ | ❌ |
| useless-test-scan / cargo-mutants (in-diff, advisory) | ✅ `useless-test-scan`, groups output too | ✅ `useless-test-scan` | ✅ `cargo-mutants` (same tool/flags, no grouping output, posts comment directly) |
| unused-pub scan (rust-analyzer SCIP) | ✅ own job | ❌ | ❌ |
| post-scan-comments (danger-js aggregator) | ✅ collects 7 report artifacts, `arc-catfood-node` | ✅ collects 4 report artifacts, `arc-catfood-node` | ❌ — `cargo-machete`/`cargo-mutants` post their own sticky comment directly via `marocchino/sticky-pull-request-comment` |
| config-lint (mecha10.json/schema validation + self-healing push) | ✅ own job, `contents: write`, pushes a fix commit | ❌ | ❌ |
| quality-check (yarn lint + ~15 script unit-test suites) | ✅ own job, `arc-catfood-node` | ❌ (its script-test subset lives in `release-scripts-tests` instead, see below) | ❌ |
| build (`cargo check`) | ❌ | ✅ own job, `services/api`, `cargo check` only (never linked/deployed) | ❌ |
| per-service Node CI (`ci-auth`/`ci-relay`/`ci-payments`) | ❌ | ✅ 3 separate jobs — pnpm+turbo lint/build(+typecheck for payments)+advisory coverage, each gated on its own `detect` output | ❌ |
| release-scripts-tests / shell_lib_tests (bash+python smoke tests over `scripts/release/**`, fragment-template) | ⚠️ present but folded as extra steps inside `quality-check`, not a standalone job | ✅ standalone `release-scripts-tests` job | ✅ standalone `shell_lib_tests` job (broader — also covers `scripts/ci/lib/*.test.sh`) |
| file-linear-tickets | ✅ uses the shared composite action, 7-entry JSON | ✅ uses the shared composite action, 7-entry JSON | ❌ — no Linear ticket filing at all |
| required-checks (aggregate gate) | ✅ `needs:` 9 jobs, named "CI required checks" | ✅ `needs:` 11 jobs, named "CI required checks" | ✅ `needs:` 6 jobs, named "CI required checks" |

Note on mecha10-nodes' runner labels: its `fmt`/`clippy`/`test` jobs run on `arc-catfood-rust`
per the file's trigger comment; verified directly against the read file (not inferred).

## 2. Classification per job

| Job | Classification | Notes |
|---|---|---|
| changes/detect | **CALLER-ONLY** | Filter definitions are wildly repo-specific (single rust/quality/config/workflows set vs. 4-service set vs. single `all:['**']`); the underlying crate-scope algorithm is already shared as a *copied script* (`scripts/ci/affected_crates.py`), not as a workflow job — that reuse already happened one layer below the workflow. |
| actionlint | **SHARED-PARAMETERISED** | Both present callers already wrap the same `actionlint` composite action identically. Inputs: `enable-actionlint` (bool), `workflows-changed` (bool, passed from caller's own changes job), `runner-label`. |
| changeset-check/fragment-check | **CALLER-ONLY** | Each repo's "which units need a fragment" detection is structurally different (crate-scope reuse vs. 4 boolean flags vs. a bespoke node-detection script); only the leaf `check-fragment-present.sh` script is shared (already copied), not the job. |
| fmt | **SHARED-PARAMETERISED** | Identical shape in all three (checkout → `rust-fmt` action → fail on outcome). Inputs: `working-directory`, `crate-scope`, `affected-crates`, `omit-report-on-success`, `runner-label`, `timeout-minutes`. |
| hakari | **REPO-SPECIFIC** | `cargo-hakari`/workspace-hack is a mecha10-only workspace-management tool; no other repo has this crate structure. |
| clippy-plan / clippy-shard / clippy (aggregator) | **CALLER-ONLY** | Explicit job-graph-bound case: shard matrix + aggregator reading `needs.clippy-shard.result`. Shard count (4) and round-robin grouping logic are mecha10-specific; neither other repo shards clippy at all. |
| clippy (plain, unsharded) | **SHARED-PARAMETERISED** | mecha10-api's and mecha10-nodes' plain `clippy` jobs are near-identical wrappers around `rust-clippy`. Inputs: `working-directory`, `crate-scope`, `affected-crates`, `omit-report-on-success`, `runner-label`, `timeout-minutes`, custom linker env (`CARGO_TARGET_..._LINKER`, `RUSTFLAGS`) as an optional pass-through. |
| test-shard / test (aggregator) | **CALLER-ONLY** | Same explicit job-graph-bound case as clippy-shard: matrix + aggregator reading `needs.test-shard.result`/`needs.doctest.outputs.*`. Present in mecha10 and mecha10-api only. |
| doctest (standalone job) | **SHARED-PARAMETERISED** | mecha10's and mecha10-api's standalone `doctest` jobs are near-identical. Inputs: `working-directory`, `crate-scope`, `affected-crates`, `runner-label`, `timeout-minutes`. Not applicable to mecha10-nodes, which folds this into its single `test` job instead — see recommendation. |
| coverage (sharded-merge variant) | **CALLER-ONLY** | mecha10/mecha10-api's variant downloads and merges 4 shards' raw `llvm-cov-target` artifacts — only possible because the sharded `test-shard` job (itself CALLER-ONLY) exists upstream in the exact same job graph. |
| coverage (direct variant) | **SHARED-PARAMETERISED** | mecha10-nodes' variant is a direct, undecorated call to the `rust-coverage` composite action exactly as that action's own header documents — the action's intended usage shape. Inputs: `crate-scope`, `codecov-flag`, `runner-label`. |
| dead-code / duplicate-code scans | **CALLER-ONLY** | Grouped differently per repo (one combined job in mecha10, folded into a 3-way `rust_scans` job in mecha10-api, dead-code-only with no duplicate-code in mecha10-nodes) and mecha10-nodes lacks duplicate-code entirely — no single job shape fits all three. The underlying `scripts/ci/*-scan.sh` scripts are already copied verbatim between mecha10 and mecha10-api (not shared via workflow). |
| file-size scan | **CALLER-ONLY / effectively REPO-SPECIFIC to 2 of 3** | Present (differently grouped) in mecha10 and mecha10-api only; absent from mecha10-nodes entirely. |
| tech-debt scan | **CALLER-ONLY / effectively REPO-SPECIFIC to 2 of 3** | Same situation as file-size. |
| dependency-audit | **REPO-SPECIFIC** | Only mecha10 has it; mecha10-api's header explicitly documents it was never enabled there. One data point is not a parameterization case. |
| ignored-tests | **REPO-SPECIFIC** | mecha10-only; no equivalent script exists in the other two repos. |
| useless-test-scan / cargo-mutants | **SHARED-PARAMETERISED** | Genuinely present, same tool/approach, in all three (`cargo mutants --in-diff`, advisory, continue-on-error). Differs in: comment-posting mode (artifact-handoff to `post-scan-comments` in mecha10/mecha10-api vs. direct `marocchino` post in mecha10-nodes) and a grouping/`groups.json` output (mecha10 only). Inputs: `working-directory`, `crate-scope`, `comment-mode` (`artifact` \| `direct`), `enable-grouping`, `runner-label`, `timeout-minutes`. |
| unused-pub | **REPO-SPECIFIC** | mecha10-only; rust-analyzer SCIP indexing is a bespoke, whole-workspace-only scan with no equivalent elsewhere. |
| post-scan-comments | **CALLER-ONLY** | Explicit cross-runner artifact-based comment-posting case (`.github/actions` header pattern repeats this reasoning per-repo): the exact report-artifact-name-to-`danger --id`-mapping is hardcoded per repo and only knows about that repo's own upstream advisory jobs. Not applicable to mecha10-nodes at all (posts directly, no aggregator). |
| config-lint | **REPO-SPECIFIC** | mecha10.json schema validation + self-healing commit/push is bespoke business logic unique to mecha10's own config schema. |
| quality-check | **REPO-SPECIFIC** | Yarn/Node lint plus ~15 mecha10-specific script unit-test suites; nothing to parameterize against since no other repo has this job shape at all (its script-test subset structurally echoes `release-scripts-tests`/`shell_lib_tests` below, but is not cleanly separable without a mecha10-side refactor first). |
| build (`cargo check`) | **REPO-SPECIFIC** (today) | Only mecha10-api has it as a standalone job. Conceptually generic (a `cargo check` gate is portable), but with only one data point and no existing composite action for it (no "rust-check" action in this repo's 17), it's not a parameterization case yet — flag as a plausible *future* addition, not part of this design. |
| ci-auth / ci-relay / ci-payments | **REPO-SPECIFIC** | mecha10-api's unique multi-service (pnpm/turbo/Node) architecture; mecha10 and mecha10-nodes are pure-Rust and have nothing resembling this. |
| release-scripts-tests / shell_lib_tests | **CALLER-ONLY** (today) | Conceptually the same underlying tests (`scripts/release/*.test.sh`, `fragment-template/test_parse_fragments.py`) run in a standalone job in mecha10-api and mecha10-nodes, but are folded as extra steps inside mecha10's much larger `quality-check` job — not extractable into a shared job without first refactoring mecha10's own workflow, which is out of scope here. |
| file-linear-tickets | **CALLER-ONLY** | The composite action itself is already shared (this is the house pattern `security-scan.yml` also follows); the *job* that assembles the `entries-file` JSON is not — it directly references each repo's own differently-shaped upstream job outputs (`dead_code_duplicate_code.outputs.*` vs. `rust_scans.outputs.*`, 7 entries vs. 7 entries with different names), which the engine has no way to know about generically. |
| required-checks | **CALLER-ONLY** | By definition — `needs:` list and count differ per repo (9 vs. 11 vs. 6 jobs). Also see §5: this job must *never* move into the engine, for a reason beyond scope — see the risk register. |

## 3. Proposed input surface

Scoping the engine to exactly the SHARED-PARAMETERISED jobs identified above (`actionlint`, `fmt`,
`clippy`-plain, `doctest`-plain, `coverage`-direct, `useless-test-scan`/cargo-mutants) gives this
input surface:

| Input | Type | Default | mecha10 | mecha10-api | mecha10-nodes |
|---|---|---|---|---|---|
| `enable-actionlint` | boolean | `true` | `true` (own job stays caller-side today — see §4) | `true` | n/a (no job) |
| `workflows-changed` | boolean | `false` | from own `changes` job | from own `detect` job | n/a |
| `enable-fmt` | boolean | `true` | `true` | `true` | `true` |
| `enable-clippy` | boolean | `true` | `false` (stays caller-side, sharded) | `true` | `true` |
| `enable-doctest` | boolean | `true` | `false` (stays caller-side, paired with sharded test) | `false` (same) | `true` (would need to split out of its combined `test` job — see §4) |
| `enable-coverage` | boolean | `true` | `false` (sharded-merge variant stays caller-side) | `false` (same) | `true` |
| `enable-mutants` | boolean | `true` | `true` | `true` | `true` |
| `working-directory` | string | `'.'` | `'.'` | `'services/api'` | `'.'` |
| `crate-scope` | string | — (required) | from `changes` job | from `detect` job | from `changes` job |
| `affected-crates` | string | `''` | from `changes` job | from `detect` job | from `changes` job |
| `rust-runner-label` | string | `'arc-catfood-rust'` | `'arc-mecha10'` | `'arc-catfood-rust'` | `'arc-mecha10'`/`'arc-catfood-rust'` (verify exact) |
| `minimal-runner-label` | string | `'arc-catfood-minimal'` | same | same | same |
| `fmt-timeout-minutes` | number | `20` | `20` | `10` | `15` |
| `clippy-timeout-minutes` | number | `30` | n/a | `30` | `30` |
| `doctest-timeout-minutes` | number | `30` | n/a | `30` | n/a (folded) |
| `mutants-timeout-minutes` | number | `60` | `60` | `45` | n/a (verify; not explicitly re-read) |
| `omit-report-on-success` | boolean | `true` | default | `false` (explicit) | default |
| `custom-linker-env` | boolean | `false` | n/a | n/a | `true` (clang+mold/CARGO_TARGET_...) |
| `mutants-comment-mode` | string enum | `'artifact'` | `'artifact'` | `'artifact'` | `'direct'` |
| `mutants-enable-grouping` | boolean | `false` | `true` | `false` | `false` |
| `actionlint-version` | string | pinned | default | default | n/a |
| `codecov-flag` | string | `'rust'` | `'rust'` | `'rust-api'` | `'rust'` (verify) |

That's ~20 inputs for a 6-job engine. **This does not cross the ~30-input smell threshold, but
only because the shared surface was deliberately kept small.** Extending the engine to also cover
sharding parameters (shard count, partition strategy), the multi-service Node jobs, or
`config-lint`/`quality-check` would push this well past 30 very quickly, reproducing exactly the
`develop-rust-ci.yml`-style "dozens of `enable_*` flags" shape this spec was asked to flag as a
smell rather than present uncritically — so that expansion is explicitly **not** recommended.

## 4. Sketch of each repo's thin `pr.yml` after migration

### mecha10-nodes (637 lines today)

```
changes            — CALLER-ONLY, unchanged (~55 lines)
rust-ci:            uses: mecha-industries/mecha10-actions/.github/workflows/rust-pr.yml@main
                     (fmt + clippy + test/doctest + coverage + mutants in one call, ~20 lines)
shell_lib_tests     — CALLER-ONLY/REPO-SPECIFIC, unchanged (~85 lines)
fragment-check      — CALLER-ONLY, unchanged (~50 lines)
required-checks      — CALLER-ONLY, unchanged, needs:[rust-ci, changes, shell_lib_tests, fragment-check] (~15 lines)
```
Estimated resulting size: **~230-260 lines** (down from 637, a genuine ~60% reduction). Caveat:
mecha10-nodes currently folds doctest *inside* its single `test` job rather than as a separate
step/job — adopting the engine's `enable-doctest`/`enable-test` split cleanly requires that job to
be split first (a small, low-risk caller-side refactor, not a blocker).

### mecha10-api (1778 lines today)

```
detect              — CALLER-ONLY, unchanged (~205 lines)
rust-ci:             uses: .../rust-pr.yml@main (fmt + clippy + doctest only — NOT test/coverage,
                     which stay sharded caller-side; ~15 lines)
build               — REPO-SPECIFIC, unchanged (~60 lines)
test-shard / test   — CALLER-ONLY (sharded + aggregator), unchanged (~265 lines)
coverage            — CALLER-ONLY (shard-merge variant), unchanged (~90 lines)
rust_scans          — CALLER-ONLY, unchanged (~150 lines)
tech-debt           — CALLER-ONLY, unchanged (~40 lines)
useless-test-scan   — could move to engine (~90 lines saved) OR stay, if comment-mode wiring isn't worth it
post-scan-comments  — CALLER-ONLY, unchanged (~45 lines)
ci-auth/ci-relay/ci-payments — REPO-SPECIFIC, unchanged (~215 lines)
file-linear-tickets — CALLER-ONLY, unchanged (~40 lines)
release-scripts-tests — CALLER-ONLY, unchanged (~40 lines)
fragment-check      — CALLER-ONLY, unchanged (~55 lines)
required-checks     — CALLER-ONLY, unchanged (~20 lines)
```
Estimated resulting size: **~1500-1550 lines** — only `fmt`+`clippy`+`doctest`(+optionally
`useless-test-scan`) move, saving roughly 180-270 lines out of 1778. **This repo would still need
well over 1300 lines of CALLER-ONLY/REPO-SPECIFIC jobs after migration — about 75-80% of the
original file.** That is a plain admission the engine does not meaningfully simplify this repo.

### mecha10 (2121 lines today)

```
actionlint          — could move to engine, or stay (small either way, ~20 lines)
changes             — CALLER-ONLY, unchanged (~150 lines)
changeset-check     — CALLER-ONLY, unchanged (~60 lines)
hakari              — REPO-SPECIFIC, unchanged (~65 lines)
rust-ci:             uses: .../rust-pr.yml@main (fmt + doctest only — clippy AND test both stay
                     sharded caller-side; ~15 lines)
clippy-plan/clippy-shard/clippy — CALLER-ONLY, unchanged (~230 lines)
test-shard/test     — CALLER-ONLY, unchanged (~250 lines)
coverage            — CALLER-ONLY, unchanged (~100 lines)
dead_code_duplicate_code — CALLER-ONLY, unchanged (~180 lines)
file_size_tech_debt — CALLER-ONLY, unchanged (~70 lines)
dependency-audit    — REPO-SPECIFIC, unchanged (~35 lines)
ignored-tests       — REPO-SPECIFIC, unchanged (~85 lines)
useless-test-scan   — could move to engine (~150 lines saved) OR stay for the grouping output
unused-pub          — REPO-SPECIFIC, unchanged (~100 lines)
post-scan-comments  — CALLER-ONLY, unchanged (~60 lines)
config-lint         — REPO-SPECIFIC, unchanged (~140 lines)
quality-check       — REPO-SPECIFIC, unchanged (~135 lines)
file-linear-tickets — CALLER-ONLY, unchanged (~55 lines)
required-checks     — CALLER-ONLY, unchanged (~25 lines)
```
Estimated resulting size: **~1830-1900 lines** — only `fmt`+`doctest`(+optionally `actionlint` and
`useless-test-scan`) move, saving at most ~280 lines out of 2121 (~13%). **This repo would still
need roughly 1800+ lines of CALLER-ONLY/REPO-SPECIFIC jobs after migration — about 85-87% of the
original file.** Materially worse ROI than mecha10-api, because clippy is *also* sharded here on
top of test, removing one more job from the shareable set.

## 5. Risk register

### Required status-check contexts (read live via `gh api .../branches/main/protection`)

| Repo | Required contexts |
|---|---|
| mecha10 | `CI required checks`, `Security Scan required checks` |
| mecha10-api | `CI required checks`, `Security Scan required checks` |
| mecha10-nodes | `CI required checks` |

### The naming mechanism, verified empirically (not assumed)

A job inside a reusable workflow called via `jobs.<id>.uses: .../workflow.yml@main` **does** get
its check-run name prefixed `<caller-job-id> / <inner-job-name>` — confirmed directly against a
real commit on `mecha10`'s `main` branch:

```
security-scan / Security Scan required checks
security-scan / Trivy vulnerability scan
security-scan / changes
```

These prefixed check runs exist *in addition to* an **unprefixed** `Security Scan required
checks` context, which is what branch protection actually requires. Reading `mecha10`'s and
`mecha10-api`'s `security.yml` resolves the apparent contradiction: both already use the exact
pattern this design must copy —

```yaml
security-scan:
  uses: mecha-industries/mecha10-actions/.github/workflows/security-scan.yml@main
  with:
    enable-required-checks: false   # disables the reusable workflow's OWN internal gate job
required-checks:
  name: Security Scan required checks   # a separate, caller-side job
  needs: [security-scan]
  if: always()
  steps:
    - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
      run: exit 1
```

The registered required context is satisfied by this **caller-side** `required-checks` job
(whose name never changes, because it never moves), which depends on the single reusable-workflow
*call* job's aggregate result (`needs.security-scan.result`) — not on any individual job inside
the called workflow. This is already a proven, live pattern in this exact org, not a hypothetical.

### Per-context walkthrough

| Repo | Context | Accounted for by this design? |
|---|---|---|
| mecha10 | `CI required checks` | **Yes** — `required-checks` is classified CALLER-ONLY (§2) and stays in `pr.yml` unchanged, needing the single `rust-ci` call job's result the same way `security.yml` already needs `security-scan`'s result. |
| mecha10 | `Security Scan required checks` | **Yes, unaffected** — out of scope for this rust-pr.yml design; already uses the proven caller-side pattern above, untouched by anything proposed here. |
| mecha10-api | `CI required checks` | **Yes** — same reasoning as mecha10. |
| mecha10-api | `Security Scan required checks` | **Yes, unaffected** — same as mecha10. |
| mecha10-nodes | `CI required checks` | **Yes** — same reasoning; mecha10-nodes registers no Security Scan required context, so there is nothing else to track there. |

**The one way this goes wrong:** if a future implementer, "for consistency," folds a
`required-checks`-equivalent job *into* `rust-pr.yml` itself and removes the caller-side one. That
job's check-run name would then carry the `<caller-job-id> / ` prefix, silently stop matching the
registered `CI required checks` context, and leave every PR unable to satisfy branch protection
(or stuck relying on an admin bypass) until someone notices and re-registers the new prefixed
context — exactly the failure mode this document was asked to check for. §2 and §4 both already
keep `required-checks` CALLER-ONLY for all three repos; this section is the explicit reason why
that classification must never change.

### Other risks

- **Comment-mode fork** (artifact-handoff vs. direct `marocchino` post) is a real behavioral
  difference for `useless-test-scan`/`cargo-mutants`, not just a naming one — moving it into the
  engine without the `mutants-comment-mode` input would silently drop mecha10-nodes' direct
  sticky-comment behavior or break mecha10/mecha10-api's artifact-based `post-scan-comments`
  aggregation.
- **mecha10-nodes' `test`+doctest fold** means adopting even the small engine requires one
  caller-side refactor (split doctest out) before the call can be made — not a blocker, but not
  zero-cost either.
- **No empirical check was done** on whether `rust-runner-label` values differ enough (e.g.
  `arc-mecha10` vs `arc-catfood-rust` vs a hypothetical `arc-mecha10-nodes`) to need a per-job
  (not just per-call) override — flagged as uncertain in §3's table; confirm against each repo's
  live runner-label wiring before implementing.

## 6. Recommendation

**Adopt for mecha10-nodes only. Do not adopt for mecha10 or mecha10-api.**

- mecha10-nodes' job graph is already unsharded and already calls the shared composite actions
  (`rust-fmt`, `rust-clippy`, `rust-coverage`) directly with no wrapping — it is structurally the
  *closest match* to the engine's shared-job shape of any of the three repos. Migration plausibly
  shrinks its `pr.yml` by ~60% (637 → ~230-260 lines) with the lowest risk, since the only
  required context (`CI required checks`) stays on an unchanged, caller-side `required-checks`
  job throughout.
- mecha10-api's heaviest, most-duplicated-looking jobs (`test-shard`/`test` aggregator, the
  3-way-merged `rust_scans`, the 3 per-service Node jobs, `build`) are precisely the ones that
  cannot move into a reusable workflow per the CALLER-ONLY/REPO-SPECIFIC criteria in §2. The
  genuinely shareable surface (`fmt`, `clippy`, `doctest`, optionally `useless-test-scan`) is only
  ~15% of the file. Migrating leaves ~1500 of 1778 lines (~85%) untouched, for the cost of a new
  cross-repo dependency, a non-trivial input surface, and the required-checks naming trap in §5
  that this change would newly expose the team to (today nobody at mecha10-api needs to know
  about reusable-workflow check-name prefixing at all; adopting the engine makes that knowledge a
  permanent maintenance requirement).
- mecha10 is the *worst* candidate of the three, not a middle ground: clippy is sharded here on
  top of test (mecha10-api only shards test), and mecha10 additionally owns six REPO-SPECIFIC
  jobs with zero cross-repo reuse value (`hakari`, `config-lint`, `quality-check`, `unused-pub`,
  `ignored-tests`, `dependency-audit`) that dominate the file's size and complexity far more than
  anything genuinely duplicated with mecha10-api/mecha10-nodes. Migrating saves at most ~13% of
  the file (2121 → ~1830-1900 lines) while adding the same cross-repo-dependency and
  naming-trap risk as mecha10-api, for a smaller percentage return.
- Net: this is not a "build once, roll out to three repos" situation. The three repos' Rust CI
  job graphs have diverged far enough (sharding presence/absence, which advisory scans exist at
  all, multi-service vs. single-crate vs. single-workspace change detection) that a shared engine
  mostly captures the *small*, *already-thin* jobs (`fmt`, `clippy`-when-unsharded, `doctest`,
  `cargo-mutants`) and leaves the *large*, *expensive-to-maintain* jobs caller-side everywhere —
  which is the opposite of where a reusable-workflow investment pays off. mecha10-nodes is the one
  repo where "most of the file is the shared shape" is actually true today.
