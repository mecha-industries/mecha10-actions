# Assessment: shared `release.yml` reusable workflow

Status: assessment only — no workflow YAML proposed or changed. Sources: each repo's release
surface read live at `ref=main` (`mecha10-nodes/.github/workflows/release.yml`, 990 lines;
`mecha10-assets/.github/workflows/release.yml`, 560 lines; `mecha10/.github/workflows/
tag-release-pr.yml`, 232 lines, plus the release-related jobs inside `mecha10/.github/workflows/
main.yml`, 2082 lines total; `mecha10-dashboard/.github/workflows/main.yml`, 688 lines total), this
repo's four existing shared actions (`calver-version-bump`, `commit-and-push-writeback`,
`notify-slack`, `ci-failure-ticket`), `security-scan.yml` (the one existing reusable workflow),
and live branch-protection reads via `gh api repos/mecha-industries/<repo>/branches/main/
protection`. Same method as `docs/rust-pr-engine-design.md`, applied to the release surface.

## 1. Job inventory matrix

| Job concept | mecha10-nodes | mecha10-assets | mecha10 | mecha10-dashboard |
|---|---|---|---|---|
| change/pending-unit detection | ✅ `detect` — fragment-based pending-node scan, bespoke `.changes/*.md` + per-node Cargo.toml versions | ✅ `validate` — bespoke asset-bundle validation | ✅ `detect` (main.yml) — crate-scope/affected-crates, shared with CI | ✅ `changes` — web-changes action, shared with CI |
| publish artefact | ✅ `build-nodes`/`combine-build-results`/`publish-node-catalog-data` — per-arch matrix, node-catalog deploy | ✅ `publish` — asset bundle upload | ✅ `build-cli`/`publish-crates`/`build-launcher`/`build-node-runner`/`upload-templates`/`publish-install-scripts`/`regenerate-schemas`/`publish-shape-catalog` — 7 distinct business-logic jobs | ✅ `publish-image`/`deploy` — Docker build+push+SSH restart |
| version bump | ✅ `release` job — per-node Cargo.toml bump via Python script, drains `.changes/*.md` fragments, **not CalVer** | ✅ `version-bump` — hand-rolled CalVer compute + push-retry loop, **not using `calver-version-bump` or `commit-and-push-writeback`** | ✅ `bump-framework` — framework-wide version bump tied to crate release, own mechanics | ✅ `version-bump` — hand-rolled CalVer compute + push-retry loop, **not using `calver-version-bump` or `commit-and-push-writeback`** |
| tag/release creation | ✅ per-node `git tag` at exact pushed SHA, no `gh release create` (deliberate — see job header) | ✅ `git tag` + `gh release create`, idempotent re-check | ✅ `tag-release` job in `tag-release-pr.yml` — opens a release PR, not a direct tag | ❌ none (image tag is the artefact) |
| status table writeback | ✅ `update-status-table` — hand-rolled push loop (not using `commit-and-push-writeback`) | ✅ `update-status-table` — hand-rolled push loop (not using `commit-and-push-writeback`) | ❌ (`update-release-status` is a different, crate-table concept, not read in full) | ✅ `update-status-table` — **already uses `commit-and-push-writeback`** |
| Slack notification | ✅ `slack-notification` — **already uses `notify-slack`** | ✅ `slack-notification` — **already uses `notify-slack`** | ✅ `tag-release-pr.yml`'s `tag-release` job — **already uses `notify-slack`** | ✅ `slack-notification` — **already uses `notify-slack`** |
| CI-failure ticket filing | ❌ no job at all | ✅ `ci-failure-ticket` — **already uses `ci-failure-ticket`** | ✅ `main.yml`'s `ci-failure-ticket` — **already uses `ci-failure-ticket`** | ✅ `ci-failure-ticket` — **already uses `ci-failure-ticket`** |

## 2. Classification per job concept

| Job concept | Classification | Notes |
|---|---|---|
| change/pending-unit detection | **REPO-SPECIFIC** | Four different detection substrates: fragment+Cargo.toml scan, bespoke asset validation, crate-scope CI reuse, web-changes CI reuse. No common shape. |
| publish artefact (node catalog, asset bundle, crates/cli/launcher/templates/install-scripts/shape-catalog, Docker image) | **DEFINITELY NOT SHAREABLE** (per the task's own scope) | This is the bulk of every release surface by line count and is pure business logic unique to what each repo ships. Confirmed by direct read, not assumed. |
| version bump | **ALREADY COVERED BY `calver-version-bump`, not by a missing workflow** | mecha10-assets and mecha10-dashboard's `version-bump` jobs are near-identical hand-rolled CalVer-compute-plus-push-retry-loop code — but that is *exactly* what `calver-version-bump` (compute half) + `commit-and-push-writeback` (push half) already do, and both repos simply haven't adopted either action yet. mecha10-nodes' and mecha10's version-bump concepts are structurally different (per-crate fragment-driven bump, framework-wide bump) and don't fit CalVer at all — correctly excluded from those two actions' scope already. |
| tag/release creation | **CALLER-ONLY** | `gh release create` vs. bare `git tag` vs. opening a release PR are three different release philosophies (see mecha10-nodes' own job-header rationale for deliberately having *no* GitHub Release object) — not a parameterization case, a genuine design divergence. |
| status table writeback | **ALREADY COVERED BY `commit-and-push-writeback`, not by a missing workflow** | mecha10-dashboard already calls it directly. mecha10-nodes and mecha10-assets still hand-roll the identical push-retry loop that action already replaces — an adoption gap in those two repos, not evidence a new reusable *workflow* is needed. The content-generation step itself (what changes, which script builds the diff) is REPO-SPECIFIC and correctly stays caller-side either way. |
| Slack notification | **ALREADY FULLY SHARED** | Every repo with a release Slack message already calls `notify-slack` directly. Nothing left to extract. |
| CI-failure ticket filing | **ALREADY FULLY SHARED** (where present) | Every repo that files one already calls `ci-failure-ticket` directly. mecha10-nodes has no such job at all — an adoption gap (could add one), not something a release engine would create. |

## 3. What a `release.yml` reusable workflow would actually contain

Given the classification above, the only two job concepts that are both (a) genuinely shared in
shape and (b) not already covered by an existing composite action are: none. Walking the
candidate list:

- **Version bump + status-table writeback**: already solved at the composite-action layer
  (`calver-version-bump`, `commit-and-push-writeback`). Wrapping them in a reusable *workflow*
  would only save the handful of lines each caller spends gluing the two actions together — and
  two of four repos (`mecha10-nodes`, `mecha10`) can't use the CalVer half at all, since their
  version concepts aren't CalVer. A workflow aggregating "CalVer bump + writeback" would only
  ever serve mecha10-assets and mecha10-dashboard (2 of 5 surfaces), and even for those two the
  job bodies differ in non-trivial ways: different version-source commands (`cat VERSION` vs.
  `node -p "require('./package.json').version"` — already exactly `calver-version-bump`'s
  `current-version-command` input), different changelog-drain scripts, different self-heal
  guard text, different `needs:`/`if:` sequencing against each repo's own publish job
  (`needs: validate` vs. `needs: [required-checks, deploy]` with an explicit race-prevention
  comment). None of that sequencing can move into a reusable workflow's own jobs without
  duplicating each caller's distinct upstream job names as new reusable-workflow inputs — which
  reproduces the exact "dozens of `enable_*`/`needs-name` flags" smell `rust-pr-engine-design.md`
  was asked to flag, for a two-repo audience.
- **Slack + ci-failure-ticket**: already fully shared at the correct layer (composite action, not
  workflow) and need no further wrapping — grouping them with version-bump into one call would
  only reintroduce the `needs:`-naming coupling problem above for no benefit, since both already
  work standalone with zero per-caller glue beyond a `with:` block.
- **Publish/tag/release creation**: out of scope per the task brief, and confirmed genuinely
  divergent by direct read (per-node tag-no-release vs. tagged-release vs. release-PR vs.
  image-tag-only).

There is no job concept left over that is (a) shared in shape across more than two of the five
release surfaces, (b) not already a thin direct call to an existing composite action, and (c) not
publish/business logic. A `release.yml` reusable workflow built from what's left would be a
wrapper around `calver-version-bump` + `commit-and-push-writeback` serving exactly two of five
surfaces, saving at most the ~10-15 lines of job boilerplate (`runs-on`, `permissions`, checkout,
PAT-presence check) each of those two repos spends per job today — while adding a new cross-repo
dependency, a `needs:`-name input-surface problem, and (per `rust-pr-engine-design.md` §5's
already-documented trap) a new place where reusable-workflow check-run-name prefixing could
silently break a required context if a future implementer folds a gate job into it. None of the
four required-status-check sets read live (`mecha10-nodes`/`mecha10-assets`: `CI required
checks`; `mecha10`: `CI required checks`, `Security Scan required checks`; `mecha10-dashboard`:
`required-checks`) include anything release-job-related, so there's no required-check upside to
offset that cost either — the risk is pure downside with no corresponding payoff.

## 4. Estimated line reduction (for completeness, matching the rust-pr doc's format)

| Repo | Release surface lines | Lines a hypothetical bump+writeback wrapper could touch | Estimated reduction |
|---|---|---|---|
| mecha10-nodes | 990 | 0 (no CalVer version concept at all) | 0% |
| mecha10-assets | 560 | ~40 (version-bump's compute+push steps only; validate/publish/release-creation/status-table-content untouched) | ~7% |
| mecha10 | 2082 (whole main.yml; release-specific subset is most of it) | 0 (framework bump isn't CalVer; all 7 publish jobs are business logic) | 0% |
| mecha10-dashboard | 688 | ~35 (version-bump's compute+push steps only; status-table writeback already uses the composite action directly, nothing left to extract there) | ~5% |

Every number here is at or below the lowest figure the rust-pr-engine-design.md doc found for its
*worst* candidate (mecha10 at ~13%) — and that doc still recommended against building for two of
three repos at that figure. A release engine clears none of those repos' bars.

## 5. Recommendation

**Don't build `release.yml`.** The release surface is, as expected, the most divergent of the
three engines considered, and the evidence here is stronger than a "low ROI" call — it's closer
to "there is nothing left to extract":

- The only two concepts that are genuinely shared in *shape* across more than one repo (CalVer
  version-bump math, writeback-to-protected-main mechanics) are **already extracted**, as
  composite actions (`calver-version-bump`, `commit-and-push-writeback`), not missing. The real
  gap is an **adoption gap, not a missing-engine gap**: `mecha10-assets`' and `mecha10-dashboard`'s
  `version-bump` jobs, and `mecha10-nodes`'/`mecha10-assets`' status-table jobs, still hand-roll
  logic those actions already replace. That's a separate, cheap, low-risk follow-up (swap
  hand-rolled steps for the existing action calls, no new workflow, no new cross-repo coupling) —
  worth flagging to the team, but it is explicitly not "build a reusable `release.yml`."
- Everything else — publish targets, tag/release-creation philosophy, change detection — is
  either out-of-scope business logic per the task brief, or confirmed genuinely divergent by
  direct read, exactly as the task's own framing predicted.
- `security-scan.yml` and `rust-pr.yml`'s success pattern is "a workflow that owns several jobs
  which are *structurally identical* across callers." No such cluster exists on the release
  surface — the best candidate (version-bump) only reaches 2 of 5 surfaces and even there differs
  in version-source command, changelog mechanics, and upstream `needs:` sequencing enough that a
  reusable workflow would mostly be passing through caller-specific strings, not sharing logic.

If this is revisited later, the trigger condition is a *fourth* repo independently growing a
CalVer-shaped `version-bump` job with the same hand-rolled shape — at that point revisit whether
a thin `release.yml` wrapping `calver-version-bump` + `commit-and-push-writeback` pays for itself.
Today, with 2 of 5 surfaces as the addressable set and an existing two-action adoption gap as the
cheaper fix, it does not.
