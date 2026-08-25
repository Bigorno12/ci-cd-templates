# Project Memory

Coding agents auto-load this file in any new conversation in this folder.
It's the most important file in any repo, pushed on git, added to on any AI failure/slop, carefully 👱🏻‍♂️-curated every retrospective.
CLAUDE.md is symlinked to [standard](https://agents.md) AGENTS.md, as GitHub Copilot prefers it.
Copilot: use this file over your proprietary .github/copilot-instructions.md
These workflows are the trust boundary for every repo that calls them — a sloppy edit here ships to every consumer at once.

## Project Overview

Reusable **GitHub Actions CI/CD templates** for Java (Maven + Spring Boot 4, Java 25) and Python (pip + pytest + ruff, CPython 3.14) consumers. There is **no application code and no test suite** — every file is CI configuration, so "build" and "test" here mean *lint the YAML and reason about what happens on a runner*. Consumers call one entry point (`master-java-pipeline.yml` or `master-python-pipeline.yml`) instead of duplicating pipeline logic; `Bigorno12/monolith-architecture` is the reference consumer.

**Structure:** GitHub forbids subdirectories under `.github/workflows`, so the workflow files are necessarily flat — the hierarchy lives in `uses:` edges, not in folders.
- `.github/workflows/` — 24 workflows: 2 entry points (Java, Python), 4 grouping layers, 16 leaf modules, 2 for this repo's own CI. `tag.yml` and `deploy-gitops.yml` are language-agnostic and shared by both entry points rather than duplicated.
- `.github/actions/` — 4 composite actions (`java-setup`, `python-setup`, `ghcr-cleanup`, `cache-cleanup`), consumed by **SHA-pinned self-reference**, not by path
- `.githook/` — `pre-commit` (gitleaks) + `pre-push` (actionlint + yamllint), mirroring CI so failures surface before a runner
- `docs/` — 6 hand-maintained PlantUML diagrams (incl. `docs/c4/`), rendered in [ARCHITECTURE.md](ARCHITECTURE.md) via the PlantUML proxy
- `.claude/` — agent config: 3 single-focus reviewers, the `/my-command` gate, the workflow rule, and 2 vendored hooks wired by `settings.json`
- Each leaf workflow is deliberately self-contained: its own `harden-runner` allowlist, its own checkout/JDK preamble, readable end-to-end without following indirection

The Python tree mirrors the Java one file-for-file (`python-*.yml`), with these deliberate asymmetries: `python-security.yml` takes **no** `python-version`/`cache-type` (CodeQL uses `build-mode: none`, nothing there runs an interpreter); `python-docker.yml` drives the `pack` CLI instead of `spring-boot:build-image` and resolves its digest via `docker buildx imagetools` because `pack --publish` leaves nothing in the local daemon; `python-setup` writes nothing to `$GITHUB_ENV`, so it needs no `github-env` ignore.

**Companion docs — read the one that matches the task:**

| File | When it applies |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) + [`docs/*.puml`](docs/) | Pipeline call graph, input/permission plumbing, release sequence, egress allowlists, C4 context. Hand-maintained: update the `.puml` in the same commit as the workflow it describes. |
| [README.md](README.md) | The **consumer-facing** contract: usage snippet, pipeline mermaid diagram, supply-chain rationale, cross-org verification. Update it in the same commit as any input/behavior change. |
| [`.claude/rules/workflow-rule.md`](.claude/rules/workflow-rule.md) | **Before touching any workflow or composite action.** Where a value is allowed to live (pin / input default / inline), the two gates that reject the alternatives, and the current known deviations. Auto-loads from `.claude/rules/`, so treat it as always in effect — not as optional reading. |
| [`.yamllint.yml`](.yamllint.yml) | Before reformatting YAML. Line length 200, 2-space indent, `truthy`/`key-ordering` disabled. |
| [`.github/dependabot.yml`](.github/dependabot.yml) | How SHA pins advance: one grouped weekly `github-actions` PR, `ci(deps)` prefix, cooldown before fresh releases. |
| [`.github/CODEOWNERS`](.github/CODEOWNERS) | `@Bigorno12` reviews every PR — nothing merges unreviewed. |
| [`.claude/agents/reviewer-*.md`](.claude/agents/) | Three single-focus reviewers (reuse / simplification / efficiency), run in parallel as one pass. Scoped to workflow YAML and `run:` shell — they know which controls are off-limits. |
| [`.claude/commands/my-command.md`](.claude/commands/my-command.md) | `/my-command` — the local gate (actionlint → yamllint → zizmor → gitleaks), which findings are mechanical repairs, and which are design decisions to stop and ask about. |
| [`.claude/hooks/`](.claude/hooks/) | Two vendored Claude Code hooks: `post-workflow-edit.sh` (stale pins, **dangling pins**, `uses: ./` for actions, unpinned refs, control coverage, actionlint/yamllint) and `detect-concurrent-sessions.sh` (worktree nudge). Read-only — neither rewrites a file. |
| [`.claude/settings.json`](.claude/settings.json) | Shared hook wiring: `PostToolUse` on `Edit\|Write` and `SessionStart`. Commit changes here — they apply to every teammate. Personal allowlists go in `settings.local.json` (gitignored globally, not by this repo's `.gitignore`). |

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
grep -rn "Bigorno12/ci-cd-templates" .github/   # all 13 composite-action pins (8 java-setup, 5 python-setup)
grep -rn "uses: \./" .github/                   # both workflow_call call graphs
grep -rn "allowed-endpoints" .github/workflows/ # every egress allowlist

# Does a pinned commit actually contain the action? Non-zero = dangling pin,
# which lints clean and fails at runtime with "action not found".
git cat-file -e <pinned-sha>:.github/actions/python-setup/action.yml
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

Two parallel trees, one per language. The Python one is the same shape with `python-`
leaves; `tag.yml` and `deploy-gitops.yml` are shared, not forked.

```
master-java-pipeline.yml        one of two entry points consumers call
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

```
master-python-pipeline.yml       the Python entry point
├─ python-build.yml              compileall · reject tracked .env             [contents: read]
├─ python-dependency-graph.yml    needs: build · push only · pip graph          [contents: write]
├─ python-verify.yml  ────►  python-lint · python-unit-tests · python-integration-tests · python-security
├─ python-release.yml ────►  tag.yml (shared) · python-docker.yml ──► deploy-gitops.yml (shared)
└─ build-gate                    identical twin of the Java one
```
- `python-security.yml` takes **no** `python-version`/`cache-type`: CodeQL runs `build-mode: none`, so unlike the Java SAST job there is no compile to set an interpreter up for.
- `python-docker.yml` drives the `pack` CLI instead of `spring-boot:build-image`, and resolves its digest with `docker buildx imagetools inspect` because `pack --publish` leaves nothing in the local daemon.
- `python-integration-tests.yml` treats pytest exit code 5 ("no tests collected") as a pass — a repo with no `integration`-marked tests is valid. The unit job does not.

### Two reference styles — and why it matters
- **Workflows** reference each other locally: `uses: ./.github/workflows/java-lint.yml`. Changes take effect on the same commit.
- **Composite actions** use an absolute SHA-pinned self-reference: `uses: Bigorno12/ci-cd-templates/.github/actions/java-setup@<sha>` (8 call sites; `python-setup@<sha>`, 5). **Editing `.github/actions/*/action.yml` has no effect until the pins are bumped** — merge the action change, then a second commit bumping every pin to the new SHA.
- A **new** action makes that worse than inert: the 5 `python-setup` pins currently carry a SHA that predates the action, so they resolve to nothing and every Python job fails with "action not found" until the post-merge bump. `post-workflow-edit.sh` now flags this; `git cat-file -e <sha>:<path>` confirms it.

### Input plumbing
Every leaf exposes the same egress trio: `egress-policy` (default `"block"`), `allowed-endpoints` (the base allowlist, held as the input's *default* — this is where hosts actually live), and `extra-allowed-endpoints` (appended by the caller; the base stays intact). The master pipeline fans this into phase-scoped inputs.

Adding an input means editing the leaf, the grouping layer, **and** the master pipeline. A consumer passing an input that their pinned SHA doesn't declare fails with "invalid input" — so input additions are effectively breaking changes for old pins.

`permissions` are re-declared at every level and **intersect**: a reusable workflow can never exceed what the caller granted, and an unset permission defaults to `none`. Widening a leaf's needs means widening `java-verify.yml`/`java-release.yml`, `master-java-pipeline.yml`, *and* the consumer's caller workflow.

### The digest chain — do not break this
`java-docker.yml`'s `Resolve image reference` step turns the pushed tag into an immutable `name@sha256:...` via `docker inspect` and exports it as the `image-digest` output. Every downstream step — Trivy, Syft, `cosign sign`, `cosign attest`, and the deploy gate — operates on `steps.ref.outputs.ref`, **never a mutable tag**, so a tag repointed between build and deploy cannot slip through.

`deploy-gitops.yml`'s **first steps** are GHCR login + `cosign verify`, before any checkout or commit; an empty digest exits 1 rather than promoting an unverified artifact. On PRs nothing is pushed, so `digest` is empty, `ref` is the local tag, and signing is skipped.

`cosign sign` runs *inside this repo's* workflow, so the Sigstore certificate identity (SAN) is always `.../Bigorno12/ci-cd-templates/...` regardless of caller — which is why `signer-identity-regexp` exists and why cross-org consumers must pin it.

## Configuration & Inputs

`master-java-pipeline.yml` is one of the two public APIs. Its surface:

| Input | Default | Notes |
|---|---|---|
| `java-version` / `cache-type` | `"25"` / `"maven"` | Threaded to every leaf's `java-setup` |
| `build-egress-policy` | `"block"` | Covers build **and** verify (test/security) phases |
| `release-egress-policy` | `"block"` | Docker publish + gitops. Drop to `"audit"` while tuning buildpack egress |
| `extra-build-endpoints` · `extra-test-endpoints` · `extra-security-endpoints` · `extra-docker-endpoints` · `extra-gitops-endpoints` | `""` | Per-phase allowlist extensions |
| `spring-boot-args` | `""` | Appended to `package spring-boot:build-image` (e.g. `-P dev -pl rest -am`) |
| `test-args` | `""` | Appended to the integration-test `verify` run |
| `gitops-manifest-path` | `"k8s/api.yaml"` | File whose `image:` line gets bumped |
| `signer-identity-regexp` | `""` → `^https://github\.com/<owner>/[^/]+/\.github/workflows/` | The default only lines up inside the `Bigorno12` org |

`master-python-pipeline.yml` is the second public API. It shares the egress trio, `test-args`, `gitops-manifest-path` and `signer-identity-regexp` verbatim; these differ:

| Input | Default | Notes |
|---|---|---|
| `python-version` / `cache-type` | `"3.14"` / `"pip"` | Threaded to every leaf's `python-setup`; also passed to the buildpack as `BP_CPYTHON_VERSION` |
| `requirements` | `"requirements.txt"` | Must exist even if empty — it keys the pip cache, and `setup-python` errors when the glob matches nothing |
| `dev-requirements` | `"requirements-dev.txt"` | Must provide `pytest` and `ruff`. `python-dependency-graph.yml` passes `""` so dev tooling stays out of the shipped graph |
| `builder-image` | `"paketobuildpacks/builder-jammy-base"` | Deliberately a mutable tag — Paketo republishes it for CVE fixes. Pin a digest for reproducibility |
| `pack-args` | `""` | Appended to `pack build` (replaces `spring-boot-args`) |

Secrets are all optional and fall back to `github.token`: `CR_PAT` (GHCR push + cleanup), `GITOPS_PAT` (manifest push), `extra-secrets` (JSON object → env vars for integration tests; `github_token` is filtered out, and `toJSON(secrets)` must never be passed). Both pipelines take the same three.

Concurrency: `${{ github.workflow }}-${{ github.ref }}`, `cancel-in-progress` everywhere **except** `main`.

**Tuning an allowlist:** a host every consumer needs goes into that leaf's `allowed-endpoints` default; a consumer-specific host goes in their `extra-*` input. Denied hosts appear in the harden-runner run summary — watch the first run after any policy change rather than guessing.

## Supply-chain Security

Non-negotiable controls; a PR that weakens one needs an explicit reason.

- **harden-runner first** — every job's first step, `disable-sudo: true`, with an explicit allowlist when the policy is `block`.
- **SHA-pinned actions** — no tags, no branches, including the self-references. Dependabot advances them.
- **`persist-credentials: false`** on checkout unless the job genuinely pushes. Only `tag.yml` and `deploy-gitops.yml` use `true`.
- **Least-privilege `permissions`** on every job, including `permissions: {}` on `build-gate`.
- **Keyless signing** via GitHub OIDC (`id-token: write`) — no long-lived keys — plus a Syft CycloneDX SBOM uploaded as a 30-day artifact *and* bound to the digest as an in-toto attestation.
- **Fail closed, never silently skip** — `java-security.yml`'s `codeql` job probes the Code Scanning API: 200/404 runs the analysis, 403 skips with a warning, anything else **errors** rather than silently skipping SAST.
- **Trivy, two passes** — blocking on fixable `CRITICAL,HIGH`; then a non-blocking `vuln,secret,misconfig` report down to `MEDIUM` including unfixed, for visibility. DB cached per UTC date, saved only on `main`.
- **`$GITHUB_ENV` writes need a guard and a justified `# zizmor: ignore[github-env]`** — `java-setup` rejects multi-line `maven-opts`; `java-integration-tests.yml` filters `github_token` and uses a random heredoc delimiter (`EOF_$(openssl rand -hex 16)`).
- **Never interpolate `${{ github.event.* }}` or secrets into a `run:` body** — bind to `env:` and reference `"$VAR"`. This is a template-injection sink zizmor flags.

## Consumer Contract

What the templates assume of a calling repo — breaking any of these breaks every consumer:

- `mvnw` + `pom.xml` at the root; a Spotless-configured build (`spotless:check` is the whole lint job)
- Test reports at `**/target/*-reports/TEST-*.xml`
- Optional root `.trivyignore`, honored by the image scan in `java-docker.yml`
- For GitOps: a manifest at `gitops-manifest-path` containing an `image: ghcr.io/<owner>/<repo>:...` line (updated by `sed`)
- No tracked `*.env` files except `.env.example` — `java-build.yml` fails the build on any other
- The caller must grant every permission the pipeline needs; a missing `id-token: write` silently breaks keyless signing

| Workflow | Purpose |
|---|---|
| `java-build.yml` | `mvnw clean test-compile`, reject tracked `.env` |
| `java-lint.yml` | `mvnw spotless:check` |
| `java-unit-tests.yml` | `mvnw test` + JUnit report |
| `java-integration-tests.yml` | `mvnw verify -Dsurefire.skip=true` + curated `extra-secrets` |
| `java-security.yml` | CodeQL (`java-kotlin`, manual build) · Gitleaks · Trivy fs scan |
| `java-dependency-graph.yml` | Submit the Maven dependency graph (push only) |
| `tag.yml` | Tag PR builds `pr-<n>-run-<run>`, keep 4 newest per PR |
| `java-docker.yml` | Paketo buildpack image → GHCR, Trivy, SBOM, sign, attest, keep 3 newest |
| `deploy-gitops.yml` | `cosign verify`, then bump the manifest tag and commit `[skip ci]` |

For the **Python** pipeline the first four assumptions become: `requirements.txt` at the root (must exist — it keys the pip cache), a `requirements-dev.txt` providing `pytest` + `ruff`, tests split by a registered `integration` pytest marker, and no Dockerfile (the Paketo builder must be able to detect the app). Test reports land at `reports/TEST-*.xml`. The `.env`, `.trivyignore` and GitOps-manifest rules are unchanged.

| Workflow | Purpose |
|---|---|
| `python-build.yml` | `python -m compileall`, reject tracked `.env` |
| `python-lint.yml` | `ruff check` + `ruff format --check` |
| `python-unit-tests.yml` | `pytest -m "not integration"` + JUnit report |
| `python-integration-tests.yml` | `pytest -m integration` + curated `extra-secrets`; exit code 5 is a pass |
| `python-security.yml` | CodeQL (`python`, build-mode `none`) · Gitleaks · Trivy fs |
| `python-dependency-graph.yml` | Submit the pip dependency graph (push only) |
| `python-docker.yml` | `pack build` → GHCR, Trivy, SBOM, sign, attest, keep 3 newest |

Image tags: `pr-<n>` (built, **not** pushed, not signed) and `main-<sha7>` (pushed, signed, attested, promoted).

## Releasing These Templates

- `auto-release.yml` runs on every push to `main`: patch-bump semver tag, GitHub release with generated notes, delete all but the 10 newest releases. There is no manual release step.
- Consumers pin `@<sha>`, not a tag — so a change is only live for them once they bump. Old pins keep working, which is why input renames are breaking. One release covers both pipelines; there is no per-language versioning.
- Commits follow `type(scope): subject`; history is PR merges only, no direct pushes to `main`.
- **Renaming a workflow file is a breaking change for consumers, and a silent one.** Unlike an input rename (which fails with "invalid input"), a moved entry point fails with "workflow was not found" only once the consumer bumps their pin. The `master-maven-pipeline.yml` → `master-java-pipeline.yml` + `java-*` leaf rename is exactly this; `tag.yml` and `deploy-gitops.yml` were left alone because both trees share them.

## Development Notes

### Workflow Style
- Match the existing shape: `on: workflow_call` → inputs (egress trio first, then `java-version`/`cache-type`, then behavior) → `secrets` with a `description` explaining the fallback → one job with `name`, `runs-on: ubuntu-latest`, `timeout-minutes`, `permissions`.
- `timeout-minutes` on **every** job (5 for gates/tagging, 10–15 for builds, 30 for CodeQL).
- Maven is always `./mvnw -B -ntp -T 1C ...`, preceded by `chmod +x mvnw`. Python leaves have no wrapper step — `python-setup` leaves `pytest`/`ruff` on `PATH`, so the run line is just `pytest …` / `ruff check .`.
- Image/packaging runs skip the quality plugins the dedicated jobs already cover: `-Dmaven.test.skip -Denforcer.skip -Dspotless.check.skip -Djacoco.skip -Dcheckstyle.skip`.
- Shell idioms to reuse rather than reinvent: `set -euo pipefail`, lowercase repo via `tr '[:upper:]' '[:lower:]'`, 7-char SHA via `cut -c1-7`, `# shellcheck disable=SC2086` where word-splitting an args string is intentional, `::error::`/`::warning::` for annotations.
- Comments explain **why** a structure exists (why a gate runs first, why a job isn't nested). Keep them; they're the reason this repo is auditable.

## Task Modifiers
- Never bump a `uses:` SHA by hand as a "fix" — either it's a Dependabot PR, or it's the deliberate second commit after editing a composite action
- Never add a step above `harden-runner`, and never above the `cosign verify` gate in `deploy-gitops.yml`
- Never set `persist-credentials: true` (or add a `token:`) on a checkout in a job that doesn't push
- Never pass `toJSON(secrets)` into `extra-secrets`; prefer Testcontainers so tests need no secrets at all
- Never fork a `python-tag.yml` or `python-deploy-gitops.yml` — those two are language-agnostic and shared by both entry points on purpose
- Never add an input to a leaf just to restore symmetry between the two trees; `python-security.yml` takes no `python-version` because nothing in it runs an interpreter
- Never widen an allowlist by switching a phase to `audit` as the fix — add the specific host
- Run `actionlint` **and** `yamllint --strict .` before committing; run `zizmor` before pushing any workflow change
- Update `README.md` in the same commit as any input, permission, or behavior change — it is the consumer's only contract
- Keep comments concise, prefer explanatory names; don't leave tombstone comments when deleting or moving code
- Keep explanations concise; challenge ambiguous prompts rather than guessing
