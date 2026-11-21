# Design spec: shared `web-pr` (and `web-main`) reusable workflow

Status: design only, no workflow YAML proposed or changed by this document. Sources: the five
named candidate repos' current PR/main workflows as of this writing — `mecha10-dashboard`
`pr.yml` (474 lines) / `main.yml` (626 lines), `mecha10-rl` `pr.yml` (345) / `main.yml` (644),
`mecha10-deploy` `pr.yml` (264) / `main.yml` (380), `mecha10-e2e` `pr.yml` (359), `user-tools`
`ci.yml` (119) — read live from `main` via `gh api repos/mecha-industries/<repo>/contents/...`,
plus the 17 composite actions under `.github/actions/` in this repo. Methodology mirrors
`docs/rust-pr-engine-design.md`: build a per-job matrix, classify every job, then check whether
the matrix actually clears the adoption bar before writing any workflow.

## 0. The bar fails before the job matrix even starts

The task that scoped this candidate set called it "the mecha-industries Node/TypeScript repos."
Reading all five files end to end shows that framing doesn't hold:

| Repo | Actual stack | Node/TypeScript CI present? |
|---|---|---|
| `mecha10-dashboard` | Next.js/React, Yarn, Jest | **Yes** — `setup-node-yarn`, `cached-script` (lint/typecheck/build/test), `scan-with-report` ×6 |
| `mecha10-rl` | Python, `uv`, pytest, ruff | **No** — `grep -i 'yarn\|npm\|node\|package.json'` across both `pr.yml` and `main.yml` returns nothing but three unrelated comment mentions of a repo named `mecha10-nodes` |
| `mecha10-deploy` | Docker Compose / Caddyfile / Dockerfile / TOML validation | **No** — no Yarn/npm/package.json anywhere in either workflow; its only mecha10-actions dependency is the `actionlint` composite action |
| `mecha10-e2e` | Bash/bats harness, one syntax-checked `.js` file with no build step | **No** — `node --check` on a single script, no `package.json`-driven install/build/test |
| `user-tools` | POSIX/bash scripts distributed via `curl \| sh` | **No** — no Node/TS content at all |

Only **one of the five** named candidates — `mecha10-dashboard` — is actually a Node/TypeScript
web repo. The other four are Python, infra-validation, a bash test harness, and a shell-script
distribution repo, respectively. Their only shared surface with `mecha10-dashboard` is the
`actionlint` composite action (already shared, already adopted directly by all five — nothing to
abstract further) and the `required-checks` aggregator pattern, which `rust-pr-engine-design.md`
§5 already established must stay caller-side permanently, for every repo, regardless of stack.

The task's own instruction is to build the engine "only if it removes a majority of the lines
for at least THREE consumer repos." A `web-pr`/`web-main` pair scoped to this candidate set has
**at most one genuine consumer**. That fails the three-repo bar immediately, independent of how
much of `mecha10-dashboard`'s own file is shareable. No job matrix across these five repos can
change that outcome, so the rest of this document narrows to: (1) does `mecha10-dashboard` even
need an engine on its own, and (2) is there a real, out-of-scope Node/TS family elsewhere in the
org worth flagging for a future pass.

## 1. `mecha10-dashboard` on its own: already a thin orchestrator

Unlike every repo in the `rust-pr-engine-design.md` study (which were still carrying large
inlined job bodies), `mecha10-dashboard`'s `pr.yml`/`main.yml` already delegate essentially all
heavy lifting to this repo's existing composite actions:

| Job | Lines | What it actually runs | Verdict |
|---|---|---|---|
| `changes` | ~20 | checkout + `web-changes` composite action | Already a thin wrapper |
| `actionlint` | ~17 | checkout + `actionlint` composite action | Already a thin wrapper |
| `setup` | ~17 | checkout + `setup-node-yarn` composite action | Already a thin wrapper |
| `security-scan` / `secret-scan` | ~13 each | checkout + `trivy-scan` composite action | Already a thin wrapper |
| `lint` / `typecheck` / `build` / `test` | ~15-29 each | checkout + `cached-script` composite action, differing only in `script`/cache-key/args inputs | Already a thin wrapper; the per-job difference IS the entire job body |
| `design-system` / `dead-code` / `duplicate-code` / `react-tech-debt` / `max-lines` / `useless-tests` | ~15-39 each | checkout + `setup-node-yarn` + `scan-with-report`, differing only in `script`/`report-file`/`sticky-header`/`blocking` | Already a thin wrapper per scan |
| `file-linear-tickets` | ~34 | assembles a 7-entry JSON literal from the six scan jobs' own outputs, then calls `file-linear-tickets` | **CALLER-ONLY** — the JSON shape is hard-wired to this repo's own six job names/outputs, same classification `rust-pr-engine-design.md` §2 gave the equivalent mecha10/mecha10-api job |
| `required-checks` | ~32 | aggregates `needs.*.result` | **CALLER-ONLY**, permanently — see `rust-pr-engine-design.md` §5's naming-trap finding, which applies unchanged here |

Every job that is genuinely shareable in shape has already been factored out — one level below
the workflow, exactly the pattern `rust-pr-engine-design.md` §2 observed for `changes`/filter
jobs ("the underlying algorithm is already shared as a composite action/script, not as a
workflow job"). What remains in `pr.yml`/`main.yml` is: (a) the `needs:`/`if:` graph wiring
between those calls (genuinely caller-specific — which jobs gate on which `changes` outputs,
e.g. `react_ui` vs `web_source` vs `ls_lint`), and (b) `file-linear-tickets` and
`required-checks`, both independently established as permanently caller-only.

Wrapping steps (a)+(b) into a `web-pr.yml` reusable workflow would save close to nothing: the
composite-action *calls* are already one line each (`uses: .../cached-script@main` plus 4-6
`with:` keys), and a reusable workflow cannot remove the `needs:`/`if:` graph itself — GitHub
Actions has no mechanism for a reusable workflow to express "this job in the caller gates on
that job in the callee," so every one of `mecha10-dashboard`'s 20 jobs would still need its own
caller-side entry for sequencing, even if each entry's *body* moved into an engine. This is a
more severe version of the trap `rust-pr-engine-design.md` flagged for mecha10-api/mecha10: here
the "already-thin" jobs aren't a *subset* of the file, they're the *entire* file. There is
nothing left over for an engine to meaningfully extract.

## 2. What would happen if built anyway (for the record)

Forcing a `web-pr.yml` engine around `mecha10-dashboard`'s 11 already-thin jobs would need
roughly: `enable-{actionlint,security-scan,secret-scan,lint,typecheck,build,test}` (7 booleans),
per-scan `enable-{design-system,dead-code,duplicate-code,react-tech-debt,max-lines,useless-tests}`
(6 more booleans) plus each scan's `script`/`report-file`/`sticky-header`/`blocking` (4 inputs ×
6 scans, or one awkward "scan list" input that can't cleanly express per-scan `if:` gating on
different `changes` outputs), `working-directory`, `runner-label` variants (web/minimal/node),
cache-key prefixes per cached-script call, and the `file-linear-tickets` entries shape. That's
comfortably past the ~30-input smell threshold the task calls out — for a workflow with **one**
consumer. This is the same `develop-rust-ci.yml`-style "dozens of flags" failure mode
`rust-pr-engine-design.md` §3 was asked to watch for, arrived at faster here because there's no
second or third repo to force any genuine parameterization discipline.

## 3. Recommendation

**Do not build `web-pr.yml` or `web-main.yml`.** Two independent reasons, either one sufficient
on its own:

- Only one of the five named candidates is actually Node/TypeScript, so the three-repo bar for
  building anything is unreachable with this candidate set (§0).
- That one repo, `mecha10-dashboard`, is already a thin orchestrator over this repo's existing
  composite actions (§1) — there is no large inlined job body left to extract, unlike every case
  study in `rust-pr-engine-design.md`. An engine here would only wrap wrappers.

**Adopt the existing composite actions more widely where they're genuinely missing instead of
building a new workflow.** Concretely, of the four non-Node repos in this candidate set:
- `mecha10-rl`, `mecha10-deploy`, `mecha10-e2e`, and `user-tools` already call this repo's
  `actionlint` composite action directly — the one piece of shared surface that does apply to
  all five regardless of stack. No further action needed there.
- None of the four has a Node/TypeScript CI shape to adopt a `web-pr` engine into even if one
  existed — there's nothing missing for them in that direction.

**If a future pass wants a real `web-pr` engine, it needs a real candidate set.** The
mecha-industries org has other Node/TypeScript backend/web repos outside this task's five named
candidates — e.g. `auth-service`, `business-ops-service`, `gateway-service`, `payments-service`,
`api-components`, `laboratory-one-web` (per this session's indexed-project list) — that were not
read as part of this assessment and may or may not share enough CI shape with
`mecha10-dashboard` to clear the three-repo bar. That comparison is out of scope here (the task
named five specific repos, four of which turned out not to be Node/TS) and should be its own
follow-up with its own job-matrix read of those repos' actual workflow files, not assumed from
their tech stack alone.
