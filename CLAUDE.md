# Project Memory

Coding agents auto-load this file in any new conversation in this folder.
It's the most important file in any repo, pushed on git, added to on any AI failure/slop, carefully 👱🏻‍♂️-curated every retrospective.
CLAUDE.md is symlinked to [standard](https://agents.md) AGENTS.md, as GitHub Copilot prefers it.
Copilot: use this file over your proprietary .github/copilot-instructions.md
These workflows are the trust boundary for every repo that calls them — a sloppy edit here ships to every consumer at once.
This file is deliberately lean: it holds only what is unique or a guardrail. Everything duplicated elsewhere is a pointer — follow the companion-docs table instead of loading every doc.

## Project Overview

Reusable **GitHub Actions CI/CD templates** for Java (Maven + Spring Boot 4, Java 25) consumers. There is **no application code and no test suite** — every file is CI configuration, so "build" and "test" here mean *lint the YAML and reason about what happens on a runner*. Consumers call one entry point, `master-java-pipeline.yml`, instead of duplicating pipeline logic; `Bigorno12/monolith-architecture` is the reference consumer.

The Python pipeline (`master-python-pipeline.yml` and its nine `python-*` workflows) has been **removed**. Only the `python-setup` composite action remains; nothing in this repo calls it.

**Pattern: templates, not an orchestrator.** Every level is `workflow_call` composition; GitHub's scheduler owns the dependency graph, each leaf is its own status check, `permissions` intersect down the tree, and no PAT is needed. Never introduce a dispatch-and-poll controller job — a new stage is another `workflow_call` leaf. `build-gate` aggregates results but coordinates nothing. Full rationale: [README → Design pattern](README.md#design-pattern-templates-not-an-orchestrator).

**Structure:** GitHub forbids subdirectories under `.github/workflows`, so the workflow files are necessarily flat — the hierarchy lives in `uses:` edges, not in folders.
- `.github/workflows/` — 14 workflows: 1 entry point, 2 grouping layers, 9 leaf modules, 2 for this repo's own CI. `tag.yml` and `deploy-gitops.yml` are language-agnostic, hence unprefixed.
- `.github/actions/` — 4 composite actions (`java-setup`, `python-setup`, `ghcr-cleanup`, `cache-cleanup`), consumed by **SHA-pinned self-reference**, not by path. `python-setup` and `cache-cleanup` have no call sites here.
- `.githook/` — `pre-commit` (gitleaks) + `pre-push` (actionlint + yamllint), mirroring CI so failures surface before a runner
- `docs/` — 5 hand-maintained PlantUML diagrams (incl. `docs/c4/`), rendered in [ARCHITECTURE.md](ARCHITECTURE.md) via the PlantUML proxy
- `.claude/` — agent config: 3 single-focus reviewers, the `/my-command` gate, the workflow rule, and 2 vendored hooks wired by `settings.json`
- Each leaf workflow is deliberately self-contained: its own `harden-runner` allowlist, its own checkout/JDK preamble, readable end-to-end without following indirection

**Companion docs — read the one that matches the task, not all of them:**

| File | When it applies |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) + [`docs/*.puml`](docs/) | Pipeline call graph, input/permission plumbing, release sequence, egress allowlists, C4 context. Hand-maintained: update the `.puml` in the same commit as the workflow it describes. |
| [README.md](README.md) | The **consumer-facing** contract: usage snippet, full input surface, per-workflow purpose tables, supply-chain rationale, cross-org verification. Update it in the same commit as any input/behavior change. |
| [`.claude/rules/workflow-rule.md`](.claude/rules/workflow-rule.md) | **Before touching any workflow or composite action.** Where a value is allowed to live (pin / input default / inline), the two gates that reject the alternatives, current pin state, and the known deviations. Path-gated: auto-loads when workflow files are in play, so treat it as always in effect there. |
| [`.yamllint.yml`](.yamllint.yml) | Before reformatting YAML. Line length 200, 2-space indent, `truthy`/`key-ordering` disabled. |
| [`.github/dependabot.yml`](.github/dependabot.yml) | How SHA pins advance: one grouped weekly `github-actions` PR, `ci(deps)` prefix, cooldown before fresh releases. |
| [`.github/CODEOWNERS`](.github/CODEOWNERS) | `@Bigorno12` reviews every PR — nothing merges unreviewed. |
| [`.claude/agents/reviewer-*.md`](.claude/agents/) | Three single-focus reviewers (reuse / simplification / efficiency), run in parallel as one pass. Scoped to workflow YAML and `run:` shell — they know which controls are off-limits. |
| [`.claude/commands/my-command.md`](.claude/commands/my-command.md) | `/my-command` — the local gate (actionlint → yamllint → zizmor → gitleaks), which findings are mechanical repairs, and which are design decisions to stop and ask about. |
| [`.claude/hooks/`](.claude/hooks/) | Two vendored Claude Code hooks: `post-workflow-edit.sh` (stale pins, **dangling pins**, `uses: ./` for actions, unpinned refs, control coverage, actionlint/yamllint) and `detect-concurrent-sessions.sh` (worktree nudge). Read-only — neither rewrites a file. |
| [`.claude/settings.json`](.claude/settings.json) | Shared hook wiring: `PostToolUse` on `Edit\|Write` and `SessionStart`. Commit changes here — they apply to every teammate. Personal allowlists go in `settings.local.json` (gitignored globally, not by this repo's `.gitignore`). |

## Token Discipline

Most work here is I/O over 14 small, similar YAML files — spend reasoning tokens, not reading tokens:

- Prefer the grep one-liners below over reading workflows wholesale; to change a leaf, read only that leaf, its grouping layer, and the master pipeline.
- Fan-out questions ("which leaves allowlist host X?", "where is input Y threaded?") go to the **Explore** subagent — bring back conclusions, not file dumps. The three reviewers already run as parallel subagents for the same reason.
- The `PostToolUse` hook lints each edited file and reports findings inline — iterate on that feedback rather than re-running linters per edit; run the full gate once before committing.
- README and ARCHITECTURE are consumer/human docs — read them on demand, never preemptively.

## Common Commands

### Local verification (repo root)
```sh
actionlint                                              # structural + shellcheck across all workflows
yamllint --strict .                                     # NEVER pass -d: it overrides .yamllint.yml
gitleaks protect --staged --redact --no-banner           # what pre-commit runs
pipx run zizmor --persona regular --min-severity medium . # zizmor is NOT installed locally
```
`actionlint` and `zizmor` are the required checks on `main` (contexts: `actionlint`, `zizmor`) and are intentionally **not** path-filtered — a skipped required check stays pending and blocks the merge.

### Git hooks (`.githook/`)
```sh
git config core.hooksPath .githook   # once per clone (already set in this working copy)
```
Both degrade to a warning when the tool is missing (`brew install gitleaks actionlint yamllint`), so CI stays the enforcement point. `pre-push` is also **path-gated**: it skips entirely unless the pushed commits touch `.yml`/`.yaml`, so a docs-only push runs nothing and still reports success.

Don't confuse these with `.claude/hooks/` — a different mechanism (Claude Code lifecycle hooks, wired in `.claude/settings.json`) that fires on edits and session start rather than on git operations.

### Finding what a change touches
```sh
grep -rn "Bigorno12/ci-cd-templates" .github/   # all 8 composite-action pins (7 java-setup, 1 ghcr-cleanup)
grep -rn "uses: \./" .github/                   # the workflow_call call graph
grep -rn "allowed-endpoints" .github/workflows/ # every egress allowlist

# Does a pinned commit actually contain the action? Non-zero = dangling pin,
# which lints clean and fails at runtime with "action not found".
git cat-file -e <pinned-sha>:.github/actions/java-setup/action.yml
```

### Verifying a published image (consumer side)
```sh
cosign verify --certificate-identity-regexp "^https://github.com/Bigorno12/ci-cd-templates/" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  ghcr.io/<owner>/<repo>@sha256:<digest>
cosign verify-attestation --type cyclonedx  ...same flags...  # the Syft SBOM
```

## Architecture

### Call graph — three levels of `workflow_call`

One tree. Counting the consumer's caller, a run is 4 of the 10 connected workflow levels GitHub allows — ample headroom.

```
master-java-pipeline.yml        the entry point consumers call
├─ java-build.yml                     test-compile · reject tracked .env          [contents: read]
├─ java-dependency-graph.yml           needs: build · push only · off critical path [contents: write]
├─ java-verify.yml   ─────────►  java-lint.yml · java-unit-tests.yml · java-integration-tests.yml · java-security.yml
├─ java-release.yml  ─────────►  tag.yml (PRs to main) · java-docker.yml ──► deploy-gitops.yml (push to main)
└─ build-gate                    if: always() · fails on any failure/cancelled
```
`java-verify.yml` and `java-release.yml` are **pure grouping layers** — no steps, only job plumbing and permission narrowing. All five stage-① jobs start at t=0: `verify` has no `needs: build`, because every job checks out and compiles for itself.

- `build` runs `test-compile`, not `package` — its output is discarded, so jar assembly was pure cost ahead of the serial verify phase. Real packaging failures surface in `docker-publish`.
- `dependency-graph` is its own workflow so `build` can stay `contents: read`, and so `release` doesn't wait on bookkeeping (`needs:` on a reusable workflow waits for *every* job inside it).
- `build-gate` treats `skipped` as a pass — `dependency-graph` is push-only and release jobs skip per-event.
- `auto-release.yml` and `workflow-lint.yml` are **this repo's** CI, not part of the consumer pipeline.
- `python-setup` (CPython + pip cache + requirements install) is the one remnant of the removed Python tree. It is unwired, like `cache-cleanup`, and writes nothing to `$GITHUB_ENV`. Don't wire it into a Java leaf, and don't delete it without asking.

### Reference styles, pins, plumbing
Workflows reference each other by **local path** (same-commit effect); composite actions by **SHA-pinned self-reference** (8 call sites, currently one shared SHA) — so editing an action is a **two-commit change** (merge, then bump every pin) and a brand-new action's first pins are dangling ("action not found"). Inputs thread through all three levels or none (a new input is breaking for old pins); `permissions` intersect down the tree, unset = `none`. The full rules, **current pin state**, and verify commands live in [`.claude/rules/workflow-rule.md`](.claude/rules/workflow-rule.md) — re-verify with `git log <sha>..HEAD -- .github/actions/<name>/` and `git cat-file -e` rather than trusting any prose snapshot.

## Configuration & Inputs

The master pipeline is the public API; the authoritative input surface is its `workflow_call.inputs` block, documented for consumers in the README. Non-obvious facts only:

- Defaults: `"25"`/`"maven"`.
- `build-egress-policy` covers build **and** verify; `release-egress-policy` covers docker + gitops (drop to `"audit"` only while tuning buildpack egress). Five `extra-*-endpoints` inputs extend per-phase allowlists.
- `signer-identity-regexp` defaults to the caller's owner, which only lines up inside the `Bigorno12` org.
- Secrets are all optional and fall back to `github.token`: `CR_PAT` (GHCR push + cleanup), `GITOPS_PAT` (manifest push), `extra-secrets` (JSON object → env vars for integration tests; `github_token` is filtered out, and `toJSON(secrets)` must never be passed).
- Concurrency: `${{ github.workflow }}-${{ github.ref }}`, `cancel-in-progress` everywhere **except** `main`.

**Tuning an allowlist:** a host every consumer needs goes into that leaf's `allowed-endpoints` default; a consumer-specific host goes in their `extra-*` input. Denied hosts appear in the harden-runner run summary — watch the first run after any policy change rather than guessing. `workflow-lint.yml`'s `allowlist-drift` job warns (never fails) when a leaf declares only part of a toolchain host group; widening still requires an observed denial, and the two known partial groups are recorded in `.claude/rules/workflow-rule.md`.

## Supply-chain Security

Non-negotiable controls; a PR that weakens one needs an explicit reason.

- **harden-runner first** — every job's first step, `disable-sudo: true`, with an explicit allowlist when the policy is `block`.
- **SHA-pinned actions** — no tags, no branches, including the self-references. Dependabot advances them.
- **`persist-credentials: false`** on checkout unless the job genuinely pushes. Only `tag.yml` and `deploy-gitops.yml` use `true`.
- **Least-privilege `permissions`** on every job, including `permissions: {}` on `build-gate`.
- **Keyless signing** via GitHub OIDC (`id-token: write`) — no long-lived keys — plus a Syft CycloneDX SBOM uploaded as a 30-day artifact *and* bound to the digest as an in-toto attestation.
- **The digest chain** — every release step (Trivy, Syft, sign, attest, deploy gate) operates on the resolved `name@sha256:...` digest, **never a mutable tag**; `deploy-gitops.yml` runs `cosign verify` *before* any checkout and an empty digest exits 1. Signing happens inside this repo's workflow, so the Sigstore identity is always `.../Bigorno12/ci-cd-templates/...` — hence `signer-identity-regexp`. Details: [README → Supply-chain security](README.md#supply-chain-security).
- **Retention never counts signatures as images** — `cosign` publishes `sha256-*` sibling tags, so `ghcr-cleanup` scopes retention to tagged versions excluding that pattern (counting them once evicted a live image) and prunes orphaned signature tags in a `continue-on-error` step; cleanup must never fail an already-promoted release.
- **Fail closed, never silently skip** — `java-security.yml`'s `codeql` job probes the Code Scanning API: 200/404 runs the analysis, 403 skips with a warning, anything else **errors** rather than silently skipping SAST.
- **Trivy, two passes** — blocking on fixable `CRITICAL,HIGH`; then a non-blocking `vuln,secret,misconfig` report down to `MEDIUM` including unfixed, for visibility. DB cached per UTC date, saved only on `main`.
- **`$GITHUB_ENV` writes need a guard and a justified `# zizmor: ignore[github-env]`** — `java-setup` rejects multi-line `maven-opts`; `java-integration-tests.yml` filters `github_token` and uses a random heredoc delimiter (`EOF_$(openssl rand -hex 16)`).
- **Never interpolate `${{ github.event.* }}` or secrets into a `run:` body** — bind to `env:` and reference `"$VAR"`. This is a template-injection sink zizmor flags.

## Consumer Contract

The full contract — per-workflow purpose tables and setup requirements — is in the [README](README.md); update it in the same commit as any behavior change. Breaking any of these breaks every consumer:

- `mvnw` + `pom.xml` at the root; a Spotless-configured build (`spotless:check` is the whole lint job); test reports at `**/target/*-reports/TEST-*.xml`
- No tracked `*.env` files except `.env.example` — `java-build.yml` fails on any other; optional root `.trivyignore` is honored by the image scan
- For GitOps: a manifest at `gitops-manifest-path` containing an `image: ghcr.io/<owner>/<repo>:...` line (updated by `sed`)
- The caller must grant every permission the pipeline needs; a missing `id-token: write` silently breaks keyless signing

Image tags: `pr-<n>` (built, **not** pushed, not signed) and `main-<sha7>` (pushed, signed, attested, promoted).

## Releasing These Templates

- `auto-release.yml` runs on every push to `main`: patch-bump semver tag, GitHub release with generated notes, delete all but the 10 newest releases. There is no manual release step.
- Consumers pin `@<sha>`, not a tag — so a change is only live for them once they bump. Old pins keep working, which is why input renames are breaking.
- Commits follow `type(scope): subject`; history is PR merges only, no direct pushes to `main`.
- **Renaming or deleting a workflow file is a breaking change for consumers, and a silent one** — it fails with "workflow was not found" only once the consumer bumps their pin. The `master-maven-pipeline.yml` → `master-java-pipeline.yml` rename and the removal of `master-python-pipeline.yml` are exactly this; both carry a README migration note.

## Development Notes

### Workflow Style
- Match the existing shape: `on: workflow_call` → inputs (egress trio first, then `java-version`/`cache-type`, then behavior) → `secrets` with a `description` explaining the fallback → one job with `name`, `runs-on: ubuntu-latest`, `timeout-minutes`, `permissions`.
- `timeout-minutes` on **every** job (5 for gates/tagging, 10–15 for builds, 30 for CodeQL).
- Maven is always `./mvnw -B -ntp -T 1C ...`, preceded by `chmod +x mvnw`.
- Image/packaging runs skip the quality plugins the dedicated jobs already cover: `-Dmaven.test.skip -Denforcer.skip -Dspotless.check.skip -Djacoco.skip -Dcheckstyle.skip`.
- Shell idioms to reuse rather than reinvent: `set -euo pipefail`, lowercase repo via `tr '[:upper:]' '[:lower:]'`, 7-char SHA via `cut -c1-7`, `# shellcheck disable=SC2086` where word-splitting an args string is intentional, `::error::`/`::warning::` for annotations.
- Comments explain **why** a structure exists (why a gate runs first, why a job isn't nested). Keep them; they're the reason this repo is auditable.

## Task Modifiers
- Never bump a `uses:` SHA by hand as a "fix" — either it's a Dependabot PR, or it's the deliberate second commit after editing a composite action
- Never add a step above `harden-runner`, and never above the `cosign verify` gate in `deploy-gitops.yml`
- Never set `persist-credentials: true` (or add a `token:`) on a checkout in a job that doesn't push
- Never pass `toJSON(secrets)` into `extra-secrets`; prefer Testcontainers so tests need no secrets at all
- Never fork a per-language copy of `tag.yml` or `deploy-gitops.yml` — they are language-agnostic; a future language tree calls the same two files
- Never add an input to a leaf that nothing in it reads
- Never widen an allowlist by switching a phase to `audit` as the fix — add the specific host
- Never widen an allowlist just because `allowlist-drift` warned; the job names a suspect, an observed harden-runner denial is what justifies the host
- Never add a controller job that dispatches workflows and polls them — this is the template pattern; a new stage is another `workflow_call` leaf, not an orchestrator
- Run `actionlint` **and** `yamllint --strict .` before committing; run `zizmor` before pushing any workflow change
- Update `README.md` in the same commit as any input, permission, or behavior change — it is the consumer's only contract
- Keep comments concise, prefer explanatory names; don't leave tombstone comments when deleting or moving code
- Keep explanations concise; challenge ambiguous prompts rather than guessing
