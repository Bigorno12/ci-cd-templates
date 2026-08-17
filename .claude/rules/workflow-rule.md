---
paths:
  - ".github/workflows/*.yml"
  - ".github/actions/*/action.yml"
---

# Workflow values: let the inputs and the pins own them

**Never hardcode a value inline that an input default or a pinned SHA already owns.**
An inline copy silently forks the source of truth: the next Dependabot bump, or the next
allowlist fix, stops applying to it — and because these workflows are the trust boundary for
every consuming repo, the drift ships to all of them at once.

This repo is a **three-level `workflow_call` tree**: `master-maven-pipeline.yml` (the only
entry point) → `verify.yml` / `release.yml` (grouping layers, no steps) → 9 leaf workflows
that hold the actual steps, plus 3 composite actions under `.github/actions/`.
**Hosts live in the leaf's `allowed-endpoints` default; action versions live in the pin;
per-phase knobs live in the master pipeline's inputs.** Keep it that way.

## Rules

1. **Third-party action → a full 40-character commit SHA. Never a tag, never a branch.**
   Dependabot advances them in one grouped weekly `github-actions` PR (`ci(deps)` prefix,
   see `.github/dependabot.yml`). A hand-bump in an unrelated PR conflicts with its open PR.

2. **Composite action → the absolute pinned self-reference. Never `./`.**

   ```yaml
   - uses: Bigorno12/ci-cd-templates/.github/actions/java-setup@<sha>   # correct
   - uses: ./.github/actions/java-setup                                  # breaks every caller
   ```

   Inside a reusable workflow, a relative *action* path resolves against the checked-out
   workspace — the **consumer's** repo — not this one. This also makes editing an action a
   **two-commit change**: merge the action, then bump every pin. Until the second commit, the
   edit is inert.

3. **Workflow-to-workflow → the local path, never the pinned form.**

   ```yaml
   uses: ./.github/workflows/lint.yml    # correct: the tree under review is what runs
   ```

   The absolute pinned form here would make a PR test the *old* workflow, not your change.

4. **Egress hosts → the leaf's `allowed-endpoints` default.** Not inline in the
   `harden-runner` step, and not appended by the consumer when every consumer needs them —
   that is what `extra-*-endpoints` is for. **Never** make a denial go away by flipping a
   phase to `audit`; add the specific host that the harden-runner run summary named.

5. **A new input goes into all three levels or none.** Leaf → grouping layer → master
   pipeline. A half-threaded input is invisible until a consumer passes it, and adding one is
   a **breaking change for old pins**: a consumer passing an input their pinned SHA does not
   declare fails with "invalid input".

6. **Context values → an `env:` binding. Never inline `${{ }}` in a `run:` body.**

   ```yaml
   env:
     PR_NUMBER: ${{ github.event.pull_request.number }}
   run: echo "$PR_NUMBER"
   ```

   Inline interpolation is a template-injection sink; zizmor fails the build on it.

7. **Writes to `$GITHUB_ENV` need a guard, then a justified `# zizmor: ignore[github-env]`.**
   The two precedents both close the sink before ignoring the rule: `java-setup` rejects
   multi-line `maven-opts`; `integration-tests.yml` filters `github_token` out and uses a
   random heredoc delimiter. An ignore without a guard is a defect, not a suppression.

8. **`permissions` per job, least privilege, at every level.** They *intersect*: a leaf can
   only lose what the caller granted, and an unset permission is `none`. Never widen a leaf
   to fix a caller's missing grant — fix the caller. `permissions: {}` on `build-gate` is
   deliberate.

9. **`persist-credentials: false` on every checkout** unless the job genuinely pushes (only
   `tag.yml` and `deploy-gitops.yml` do). Same for `fetch-depth: 0` — full history is needed
   only for the gitleaks history scan, `tag.yml`, and `auto-release.yml`.

10. **Never invent an allowlist host or a SHA.** Confirm it before writing anything (below).

## Two gates that punish getting this wrong

Both are required status checks on `main` and neither is path-filtered — a required check
skipped by a path filter stays permanently pending and blocks the merge instead:

- **`actionlint`** — structural errors across all workflows (bad `needs:`, invalid
  expressions, unknown `runs-on`) plus shellcheck inside every `run:` block. In CI the binary
  is checksum-verified against a pinned SHA-256 before it executes.
- **`zizmor`** (`--persona regular --min-severity medium`) — Actions-specific findings:
  unpinned refs, template injection, credential persistence, over-broad `permissions`.

`.githook/pre-push` runs `actionlint` + `yamllint --strict` locally, but **path-gated**: it
skips entirely unless the pushed commits touch `.yml`/`.yaml`, and it degrades to a warning
when a tool is missing. A clean local run can be a run that checked nothing.

Rules 1–3 and 8–9 are also checked at edit time by `.claude/hooks/post-workflow-edit.sh`
(wired in `.claude/settings.json`): it reports stale composite-action pins, a `uses: ./` action
ref, an unpinned `uses:`, and harden-runner / `timeout-minutes` / `permissions` /
`persist-credentials` coverage. It is advisory and read-only — it never blocks or rewrites, so
the gates below are still the enforcement point.

## Check before you edit

```sh
# Every pin site for a composite action (what the second commit must bump)
grep -rn "ci-cd-templates/.github/actions/java-setup@" .github/

# Are the pins actually stale? Empty output = the actions have not changed since the pin.
git log --oneline <pinned-sha>..HEAD -- .github/actions/

# Is an input threaded through all three levels? Expect a hit in the leaf,
# the grouping layer, AND master-maven-pipeline.yml.
grep -rn "extra-docker-endpoints" .github/workflows/

# The gate, in the order the hooks run it
actionlint
yamllint --strict .                                        # never pass -d
pipx run zizmor --persona regular --min-severity medium .   # not installed locally
```

For a host: read the denial out of the harden-runner run summary of a real run (or set that
phase to `audit` **temporarily, on a branch**) — do not guess a hostname into the allowlist.

## State of this repo

**Composite-action pins:** all 8 call sites are on
`6f6e9d0ff799606a83ba2086a82e6e5954ba86a6`, and nothing under `.github/actions/` has changed
since that commit — the pins are current as of `HEAD` (`e6e3f5f`). Verify with the
`git log <sha>..HEAD -- .github/actions/` command above before assuming.

**Allowlist shape:** five hosts are common to all four configurable phases (`github.com`,
`api.github.com`, `objects.githubusercontent.com`,
`release-assets.githubusercontent.com`, `github-releases.githubusercontent.com`); everything
else is a per-phase delta. `tag.yml`, `auto-release.yml`, `workflow-lint.yml` and
`build-gate` hardcode `block` with no input — that is intentional, they take no consumer
configuration.

Known deviations, worth fixing when you are next in the file:

| where | issue | correct form |
| --- | --- | --- |
| `build.yml:64` | the `.env` check filters `.env.example` **twice** — pathspec `':!:.env.example'` *and* `grep -v '\.env\.example$'` — and since the pathspec is `*.env`, neither can ever match `.env.example` (verified: `git ls-files -- '*.env'` does not list it). Two dead exclusions in the one step whose job is to fail the build. | drop both exclusions, or narrow the pathspec to `'*.env*'` and keep exactly one |
| `security.yml` allowlist | omits `repo1.maven.org`, which the build/test phases include — the CodeQL job runs a full `mvnw compile`, so a resolution that reaches repo1 fails closed | confirm intentional; otherwise align with the build phase |
| `docker.yml` allowlist | omits `repo.spring.io` and `repository.jboss.org` although it runs a full `package` | same: confirm intentional |

Trimming each phase to the hosts it actually observed is the *right* instinct — that is why
the lists differ. The rows above ask you to confirm the trim was observed, not to re-widen
them by copying one list over another.
