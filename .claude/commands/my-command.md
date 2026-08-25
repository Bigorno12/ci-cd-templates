---
description: Run this project's local quality gate (actionlint → yamllint → zizmor → gitleaks) and get it green
---

Run the same gate that `.githook/` and `workflow-lint.yml` run, from the repo root, and get
it green. There is no Maven build here — this repo is CI configuration only, so the gate is
four linters over YAML and the shell inside `run:` blocks.

1. **`actionlint`** — the one that catches real breakage: bad `needs:`, invalid expressions,
   unknown `runs-on` labels, and shellcheck findings inside every `run:` block. Run it with
   no arguments from the root so it discovers all workflows.
2. **`yamllint --strict .`** — uses `.yamllint.yml` (200 cols, 2-space indent, `truthy` and
   `key-ordering` off). **Never pass `-d`**: that overrides the repo config and the hook and
   CI stop agreeing.
3. **`pipx run zizmor --persona regular --min-severity medium .`** — the Actions-specific
   security audit, and the check most likely to be the one you haven't run: `zizmor` is not
   installed locally. These flags mirror `workflow-lint.yml`.
4. **`gitleaks protect --staged --redact --no-banner`** — what `pre-commit` runs, once
   anything is staged.

Fix what is mechanical and re-run until green:

- **shellcheck findings** → quote the expansion, add `set -euo pipefail`, or — where
  word-splitting an args string is the intent — `# shellcheck disable=SC2086` with the
  existing pattern (`$SPRING_BOOT_ARGS`, `$TEST_ARGS`, `$PACK_ARGS`, `$PUBLISH_FLAG`).
- **`zizmor: unpinned action`** → pin to a full commit SHA, never a tag.
- **`zizmor: template injection`** → move the `${{ … }}` out of the `run:` body into an
  `env:` binding and reference `"$VAR"`.
- **`zizmor: credential persistence`** → `persist-credentials: false`, unless the job
  genuinely pushes (only `tag.yml` and `deploy-gitops.yml` do).
- **`zizmor: excessive permissions`** → narrow the job's `permissions:` block. Remember they
  intersect across all four levels, so a leaf can only lose what the caller already granted.
- **yamllint** → trailing space, missing final newline, or a line over 200 columns.

Stop and ask when a fix is a design decision rather than a repair:

- A `# zizmor: ignore[rule]` is a design decision. It needs a real guard plus a comment
  explaining why the sink is closed — see `java-setup` rejecting multi-line `maven-opts`, and
  both `java-integration-tests.yml` leaves filtering `github_token` with a random heredoc
  delimiter. Don't add one to silence a finding you haven't closed. `python-setup` shows the
  better move: it writes nothing to `$GITHUB_ENV`, so it needs no ignore at all.
- An input that has to be threaded through a leaf, its grouping layer, **and** that
  language's master pipeline (`master-java-pipeline.yml` or `master-python-pipeline.yml`)
  is a public-API change: it breaks consumers still on an older pin with "invalid input".
- Never make an egress denial go away by flipping a phase to `audit` — add the specific
  host to that leaf's `allowed-endpoints` default.

Notes:
- The `pre-push` hook path-gates: it skips both linters unless the pushed commits touch
  `.yml`/`.yaml`. Docs-only changes pass without running anything — that is expected, not a
  green gate for a workflow change.
- Both hooks degrade to a warning when a tool is missing (`brew install gitleaks actionlint
  yamllint`), so a clean local run can still be a run that checked nothing. Verify the tools
  are actually present.
- If you edited `.github/actions/*/action.yml`, the linters passing is not enough: the 13
  SHA-pinned self-references (8 `java-setup`, 5 `python-setup`) still point at the old commit
  until a follow-up bump. A **green gate cannot see a dangling pin** either — a pin whose
  commit does not contain the action at all still lints fine and fails at runtime with
  "action not found". Check it directly:
  ```sh
  git cat-file -e <pinned-sha>:.github/actions/python-setup/action.yml
  ```
- `plantuml -checkonly docs/*.puml docs/c4/*.puml` if you touched a diagram (needs no
  Graphviz).
- Do not commit or push; leave that to the human.
