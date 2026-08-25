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

This repo is **two three-level `workflow_call` trees**, one per language:
`master-java-pipeline.yml` / `master-python-pipeline.yml` (the only entry points) →
`java-verify.yml` / `java-release.yml` / `python-verify.yml` / `python-release.yml` (grouping layers,
no steps) → 16 leaf workflows that hold the actual steps, plus 5 composite actions under
`.github/actions/`. `tag.yml` and `deploy-gitops.yml` are language-agnostic and **shared by
both trees** — never fork a `python-` copy of either.
**Hosts live in the leaf's `allowed-endpoints` default; action versions live in the pin;
per-phase knobs live in the master pipeline's inputs.** Keep it that way.

**The two trees are not equally proven.** Java is fully tested in production against
`Bigorno12/monolith-architecture`; its allowlists were built from observed harden-runner
denials. **The Python tree has never completed a real run** — it lints clean, and that is
all. So:

- Never state a Python behaviour as verified. Say "expected to" and name the source.
- Never delete a Python allowlist host because it "looks unnecessary" — nothing has proven
  which are load-bearing. The reverse also holds: do not add one on a hunch (rule 10).
- When the two trees disagree, Java is the evidence-backed side. Copy its shape, not its
  hosts.
- Planned validation: throwaway Django + FastAPI reference consumers, run at
  `egress-policy: audit` first so the harden-runner summary names the real endpoints. Django
  covers the database / `pytest-django` / migrations path, FastAPI the minimal ASGI path;
  together they cover both `Procfile` shapes. Until those pass, the Python rows in the
  deviations table below stay open.

## Rules

1. **Third-party action → a full 40-character commit SHA. Never a tag, never a branch.**
   Dependabot advances them in one grouped weekly `github-actions` PR (`ci(deps)` prefix,
   see `.github/dependabot.yml`). A hand-bump in an unrelated PR conflicts with its open PR.

2. **Composite action → the absolute pinned self-reference. Never `./`.**

   ```yaml
   - uses: Bigorno12/ci-cd-templates/.github/actions/java-setup@<sha>   # correct
   - uses: ./.github/actions/java-setup                                  # breaks every caller
   ```

   A **brand-new** action is the sharp edge of this rule: there is no commit yet that
   contains it, so its first pins are necessarily dangling and every job using them fails
   with "action not found" until the bump lands. See the `python-setup` row below.

   Inside a reusable workflow, a relative *action* path resolves against the checked-out
   workspace — the **consumer's** repo — not this one. This also makes editing an action a
   **two-commit change**: merge the action, then bump every pin. Until the second commit, the
   edit is inert.

3. **Workflow-to-workflow → the local path, never the pinned form.**

   ```yaml
   uses: ./.github/workflows/java-lint.yml    # correct: the tree under review is what runs
   ```

   The absolute pinned form here would make a PR test the *old* workflow, not your change.

   **Renaming one of these files is a breaking change, and a silent one.** A renamed input
   fails loudly ("invalid input"); a renamed *entry point* keeps working on the consumer's
   current pin and only fails with "workflow was not found" when they next bump — detached
   from the cause. If you rename, say so in the README migration note. Renaming a leaf is
   cheap by comparison: only the local `uses:` edges inside this repo point at it.

4. **Egress hosts → the leaf's `allowed-endpoints` default.** Not inline in the
   `harden-runner` step, and not appended by the consumer when every consumer needs them —
   that is what `extra-*-endpoints` is for. **Never** make a denial go away by flipping a
   phase to `audit`; add the specific host that the harden-runner run summary named.

5. **A new input goes into all three levels or none.** Leaf → grouping layer → the master
   pipeline for *that* language. A half-threaded input is invisible until a consumer passes
   it, and adding one is a **breaking change for old pins**: a consumer passing an input
   their pinned SHA does not declare fails with "invalid input". The corollary is that a
   deliberately *absent* input is also a decision — `python-security.yml` takes no
   `python-version`/`cache-type` because CodeQL runs `build-mode: none` and nothing in that
   leaf runs an interpreter. Don't "restore symmetry" by adding inputs nothing reads.

6. **Context values → an `env:` binding. Never inline `${{ }}` in a `run:` body.**

   ```yaml
   env:
     PR_NUMBER: ${{ github.event.pull_request.number }}
   run: echo "$PR_NUMBER"
   ```

   Inline interpolation is a template-injection sink; zizmor fails the build on it.

7. **Writes to `$GITHUB_ENV` need a guard, then a justified `# zizmor: ignore[github-env]`.**
   The four precedents all close the sink before ignoring the rule: `java-setup` rejects
   multi-line `maven-opts`; `java-integration-tests.yml` and `python-integration-tests.yml` filter
   `github_token` out and use a random heredoc delimiter; `test-services` writes only values it
   generated itself (an `openssl rand -hex` string plus fixed literals), so no input reaches
   the write at all. An ignore without a guard is a defect, not a suppression. Best of all is
   not opening the sink: `python-setup` installs requirements directly and writes nothing to
   `$GITHUB_ENV`, so it carries no ignore.

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
(wired in `.claude/settings.json`): it reports stale composite-action pins, **dangling** pins
(a commit that does not contain that action at all), a `uses: ./` action ref, an unpinned
`uses:`, and harden-runner / `timeout-minutes` / `permissions` / `persist-credentials`
coverage. It is advisory and read-only — it never blocks or rewrites, so
the gates below are still the enforcement point.

## Check before you edit

```sh
# Every pin site for a composite action (what the second commit must bump)
grep -rn "ci-cd-templates/.github/actions/java-setup@" .github/     # 8 sites
grep -rn "ci-cd-templates/.github/actions/python-setup@" .github/   # 5 sites

# Are the pins actually stale? Empty output = the actions have not changed since the pin.
git log --oneline <pinned-sha>..HEAD -- .github/actions/

# Does the pinned commit even CONTAIN the action? Non-zero = a dangling pin, and
# every job using it fails with "action not found".
git cat-file -e <pinned-sha>:.github/actions/python-setup/action.yml

# Is an input threaded through all three levels? Expect a hit in the leaf,
# the grouping layer, AND that language's master pipeline.
grep -rn "extra-docker-endpoints" .github/workflows/

# The gate, in the order the hooks run it
actionlint
yamllint --strict .                                        # never pass -d
pipx run zizmor --persona regular --min-severity medium .   # not installed locally
```

For a host: read the denial out of the harden-runner run summary of a real run (or set that
phase to `audit` **temporarily, on a branch**) — do not guess a hostname into the allowlist.

## State of this repo

**Composite-action pins:** 16 call sites across 4 actions, on two different SHAs — this is
normal, each pin tracks the commit its action last landed in, not one global version.

| action | sites | pin | state |
| --- | --- | --- | --- |
| `java-setup` | 7 | `042275d` | resolves |
| `ghcr-cleanup` | 2 | `042275d` | resolves |
| `python-setup` | 5 | `869e85b` | resolves (bumped in `6700ffb`) |
| `test-services` | 2 | `869e85b` | **dangling** — the action is new and unmerged |

`test-services` is the standard new-action case: no commit contains it yet, so its pins were
written with `python-setup`'s SHA as a placeholder to keep actionlint/zizmor green. Bump both
to the merge commit in the follow-up commit; never invent a SHA to make one resolve.

Do not trust this table — it goes stale the moment anything merges. Re-derive it:

```sh
grep -rho 'ci-cd-templates/\.github/actions/[a-z-]*@[0-9a-f]*' .github/workflows/ \
  | sed 's|.*/actions/||' | sort | uniq -c          # counts + SHAs actually in use
git cat-file -e <sha>:.github/actions/<name>/action.yml   # non-zero = dangling
```

**Naming convention (load-bearing):** `java-*` = the Java tree, `python-*` = the Python
tree, and **unprefixed = shared or repo-internal**. The four unprefixed workflows are
`tag.yml` and `deploy-gitops.yml` (called by *both* master pipelines — never fork a
per-language copy) plus `auto-release.yml` and `workflow-lint.yml` (this repo's own CI, not
part of any consumer pipeline). A new leaf gets a prefix unless it is genuinely
language-agnostic; if it is, it goes in the shared set and both trees call it.

Watch the substring trap when renaming or grepping: `release.yml` is a substring of
`auto-release.yml` **and** `python-release.yml`; `lint.yml` of `workflow-lint.yml` and
`.yamllint.yml`; `build.yml` of `python-build.yml`. A bare `sed s/release.yml/…/` corrupts
three files. Anchor on a preceding `/` or a non-`-` character, then re-audit — the diagrams
hide references after a literal `\n` inside a PlantUML label, where a word-boundary match
silently fails to fire.

**Allowlist shape:** five hosts are common to all configurable phases in both trees
(`github.com`, `api.github.com`, `objects.githubusercontent.com`,
`release-assets.githubusercontent.com`, `github-releases.githubusercontent.com`); everything
else is a per-phase delta. The Python leaves swap the Maven repository hosts
(`repo.maven.apache.org`, `repo1.maven.org`, `repo.spring.io`, `repository.jboss.org`) for
`pypi.org` + `files.pythonhosted.org`, and add `raw.githubusercontent.com` because
`actions/setup-python` fetches its version manifest from there. `python-unit-tests.yml` and
`python-integration-tests.yml` additionally allow the four Docker Hub hosts — **not** for
Testcontainers (the Python tree does not use it), but because `test-services` pulls the
`postgres-image`/`redis-image` during a step, and a step's traffic is subject to the egress
policy. A job-level `services:` block would not have needed them: service containers are
pulled before the first step, and so before harden-runner is active at all. `tag.yml`,
`auto-release.yml`, `workflow-lint.yml` and both `build-gate` jobs hardcode `block` with no
input — that is intentional, they take no consumer configuration.

Known deviations, worth fixing when you are next in the file:

| where | issue | correct form |
| --- | --- | --- |
| `java-build.yml:64` | the `.env` check filters `.env.example` **twice** — pathspec `':!:.env.example'` *and* `grep -v '\.env\.example$'` — and since the pathspec is `*.env`, neither can ever match `.env.example` (verified: `git ls-files -- '*.env'` does not list it). Two dead exclusions in the one step whose job is to fail the build. | drop both exclusions, or narrow the pathspec to `'*.env*'` and keep exactly one |
| `java-security.yml` allowlist | omits `repo1.maven.org`, which the build/test phases include — the CodeQL job runs a full `mvnw compile`, so a resolution that reaches repo1 fails closed | confirm intentional; otherwise align with the build phase |
| `java-docker.yml` allowlist | omits `repo.spring.io` and `repository.jboss.org` although it runs a full `package` | same: confirm intentional |
| 2 × `test-services@869e85b` | dangling pin — the action is new and unmerged. Not a thing to "fix" in place: it is the pending half of the standard two-commit change | after merge, bump both to the merge SHA |
| **every Python allowlist** | reasoned from docs, **never observed**. `deps.paketo.io` is the least certain; the four Docker Hub hosts in the two test leaves are needed only because `test-services` pulls inside a step | run the planned Django/FastAPI consumers at `audit`, then reconcile every list against the harden-runner summary |
| `python-docker.yml` digest read-back | `docker buildx imagetools inspect` is the documented way to read a digest that `pack --publish` left only in the registry, but this exact path has never run | confirm on the first real push-to-main run before trusting the signing chain |
| `java-build.yml:64` vs `python-build.yml` | the Python leaf already uses the corrected single-exclusion form (`'*.env*'` + `':!:.env.example'`) — the Java leaf is the one still carrying the two dead exclusions | copy the Python leaf's form into `java-build.yml` |

Trimming each phase to the hosts it actually observed is the *right* instinct — that is why
the lists differ. The rows above ask you to confirm the trim was observed, not to re-widen
them by copying one list over another.
