# Architecture

Diagrams are hand-maintained PlantUML under [`docs/`](docs/), rendered live via the
[PlantUML proxy](https://plantuml.com/) off the GitHub-hosted `.puml` source — each carries
a `footer` with its own repo path, so the render is self-identifying. Every file names the
workflow it describes at the top; when that workflow changes, the diagram is what you update.

> **Seeing "Welcome to PlantUML!" instead of a diagram?** The proxy fetches each `.puml`
> from `raw.githubusercontent.com/…/main/…`. Until that file exists **on `main`**, the fetch
> 404s and the proxy renders its built-in sample instead. Merge `docs/` to `main` and the
> images appear — nothing else to fix. To preview before merging, see
> [Rendering notes](#rendering-notes).

### Pattern

This is the **template pattern** — reusable workflows composed with `workflow_call` at
every level — and not the orchestrator pattern. Nothing here dispatches a workflow and
polls it for completion; each edge in the diagrams below is a `uses:` reference that
GitHub's own scheduler resolves into the run graph.

That choice is what buys the properties the rest of this document describes: each leaf
surfaces as an independent status check, `permissions` intersect from caller down to leaf
so a leaf can only ever *lose* privilege, and the whole tree runs on the caller's
`GITHUB_TOKEN` with no PAT. An orchestrator would need a PAT (`GITHUB_TOKEN` cannot
trigger workflows recursively), would collapse the fan-out into one opaque job, and would
report failures against the poller rather than the job that failed.

Depth is not a constraint: consumer caller → master pipeline → grouping layer → leaf is
4 of the 10 connected levels GitHub allows (top-level caller plus up to 9 nested).
`build-gate` aggregates the phases' results but coordinates nothing — it is a gate, not
an orchestrator.

#### Pipeline — Java (logical architecture)
![Java pipeline](https://www.plantuml.com/plantuml/proxy?cache=no&src=https://raw.githubusercontent.com/Bigorno12/ci-cd-templates/main/docs/pipeline-java.puml)

The nesting shown there is not documentation — it is the `uses:` graph. GitHub forbids
subdirectories under `.github/workflows`, so the files are flat and this diagram is the only
place the hierarchy is visible at a glance. Every Java workflow carries a `java-` prefix and
every Python one a `python-`; the two unprefixed leaves (`tag.yml`, `deploy-gitops.yml`) are
unprefixed *because* they are shared.

#### Pipeline — Python
![Python pipeline](https://www.plantuml.com/plantuml/proxy?cache=no&src=https://raw.githubusercontent.com/Bigorno12/ci-cd-templates/main/docs/pipeline-python.puml)

`master-python-pipeline.yml` is the same three-level tree with the Java leaves swapped for
pip/pytest/ruff/pack equivalents. `tag.yml` and `deploy-gitops.yml` are **shared, not
duplicated** — they are language-agnostic, so both entry points call the same two files.

The three diagrams below are drawn from the Java tree but now carry the Python deltas
inline: `inputs.puml` lists the input renames, `egress.puml` has a Python phase package, and
`sequence-release.puml` notes that `python-docker.yml` runs the identical release sequence.

#### Input, secret and permission plumbing
![Inputs](https://www.plantuml.com/plantuml/proxy?cache=no&src=https://raw.githubusercontent.com/Bigorno12/ci-cd-templates/main/docs/inputs.puml)

#### Sequence — push to main (build → sign → verify → promote)
![Release sequence](https://www.plantuml.com/plantuml/proxy?cache=no&src=https://raw.githubusercontent.com/Bigorno12/ci-cd-templates/main/docs/sequence-release.puml)

#### Egress allowlists
![Egress](https://www.plantuml.com/plantuml/proxy?cache=no&src=https://raw.githubusercontent.com/Bigorno12/ci-cd-templates/main/docs/egress.puml)

Enforced for real by `step-security/harden-runner` as the first step of every job, with
`egress-policy: block` by default.

#### C4 — System Context
![C4 System Context](https://www.plantuml.com/plantuml/proxy?cache=no&src=https://raw.githubusercontent.com/Bigorno12/ci-cd-templates/main/docs/c4/C1-Context.puml)

---

### Deployment topology

This repo ships nothing runnable — it ships *workflow references*. A consumer pins
`uses: Bigorno12/ci-cd-templates/.github/workflows/master-java-pipeline.yml@<sha>` (or
`master-python-pipeline.yml`), so a
merge here reaches them only on their next pin bump; `auto-release.yml` patch-bumps a tag and
release on every green merge to `main` (keeping the 10 newest), but pins are what consumers
actually track.

Internally, workflows reference each other by local path (`./.github/workflows/java-lint.yml`,
effective on the same commit) while the four composite actions under
[`.github/actions/`](.github/actions/) are referenced by **SHA-pinned self-reference**
(`Bigorno12/ci-cd-templates/.github/actions/java-setup@<sha>`, 7 call sites;
`python-setup@<sha>`, 5; `ghcr-cleanup@<sha>`, 2 — `cache-cleanup` is not wired into the
master pipeline and has none) — so editing an action does nothing until a second commit
bumps every pin.

On the consumer side the pipeline publishes `ghcr.io/<owner>/<repo>:main-<sha7>`, signs it
keylessly, then commits that tag into their k8s manifest for Argo CD to sync. Retention on
that package keeps the 3 most recent **tagged** versions while excluding the `sha256-*`
referrer tags that `cosign sign`/`attest` publish as siblings — otherwise signatures fill the
quota and evict the image the manifest just pinned — and a best-effort step prunes referrers
whose subject image is already gone. See
[CLAUDE.md → Supply-chain Security](CLAUDE.md#supply-chain-security) and
[CLAUDE.md → Consumer Contract](CLAUDE.md#consumer-contract).

### Proposed: split the composite actions into their own repo

**Status: not started — a plan, not a description of the repo today.**

The SHA-pinned self-reference (`Bigorno12/ci-cd-templates/.github/actions/java-setup@<sha>`)
is forced, not chosen: inside a reusable workflow a relative action path resolves against
the *consumer's* checkout, so `uses: ./` would break every caller. The cost is structural
rather than cosmetic:

- editing an action is a **two-commit change** — merge, then bump every pin — and the edit
  is inert in between;
- a **brand-new** action is worse than inert, because its first pins necessarily name a
  commit that predates it and every job using them fails with "action not found";
- Dependabot cannot advance a self-reference, so those 14 pins move by hand, which is the
  one place this repo tolerates a manual SHA bump.

Moving the four actions to a sibling repo (`Bigorno12/ci-cd-actions`) dissolves all three:
the pins become ordinary third-party pins that Dependabot advances in its existing grouped
weekly PR, and an action can never be referenced by a commit that predates it because the
two repos version independently.

Cutover order, which matters — every step keeps `main` green:

1. Create `Bigorno12/ci-cd-actions` and copy `.github/actions/*` across unchanged, keeping
   the `java-setup` / `python-setup` / `ghcr-cleanup` / `cache-cleanup` directory names so
   only the owner/repo half of each `uses:` changes.
2. Tag a first release there and record its SHA.
3. In **one** PR here, repoint all 14 call sites to
   `Bigorno12/ci-cd-actions/<name>@<sha>`. This is the only risky step: the pins must be
   verified against the new repo with `git cat-file -e <sha>:<name>/action.yml` in a clone
   of it, since `post-workflow-edit.sh` resolves pins against *this* repo and will report
   a false dangling pin for every one of them.
4. Delete `.github/actions/` here, and teach `post-workflow-edit.sh` to resolve
   `ci-cd-actions` pins against the sibling clone (or drop that check and let Dependabot
   own pin currency).
5. Add `ci-cd-actions` to `.github/dependabot.yml`'s `github-actions` group.

Not breaking for consumers: they pin *workflows*, and the actions are an implementation
detail resolved at run time. But it does add a second repo to the trust boundary, which is
the trade to weigh — today one CODEOWNERS file governs everything a consumer executes.

### Rendering notes

- A diagram renders **only once its `.puml` is on `main`** — on a feature branch the proxy
  falls back to the PlantUML welcome sample (see the note at the top).
- `cache=no` forces a fresh render on every page load; drop it to let the proxy cache.
- **Preview before merging**, without pushing anything:
  ```sh
  docker run -d -p 8080:8080 plantuml/plantuml-server   # then open http://localhost:8080
  ```
  or use the IntelliJ PlantUML plugin, which previews the file in the editor.
- Rendering locally with `plantuml.jar` needs Graphviz for everything except the sequence
  diagram (`brew install graphviz`). Without it, use PlantUML's bundled layout engine:
  ```sh
  java -jar plantuml.jar -Playout=smetana -tpng docs/*.puml docs/c4/*.puml
  java -jar plantuml.jar -checkonly docs/*.puml docs/c4/*.puml   # syntax only, no Graphviz
  ```
- `c4/C1-Context.puml` uses the PlantUML stdlib C4 bundle (`!include <C4/C4_Context>`), so
  it needs no network include and works on any PlantUML server.

### Making these generated

These diagrams are written by hand, which means they are only as current as the last person
who touched them. Deriving them from the workflow YAML is what keeps them honest — concrete
routes:

| Diagram | How it could be generated |
|---|---|
| Pipeline | Parse every `uses:`/`needs:`/`if:` out of `.github/workflows/*.yml` and emit `.puml` |
| Inputs | Diff the `workflow_call.inputs` keys across the three levels — divergence *is* the bug |
| Sequence | Replay a real run: `gh run view --json jobs,steps` against a merged pipeline |
| Egress | Emit the `allowed-endpoints` defaults directly; the asymmetries would then be visible in review |
| C4 | A Structurizr DSL workspace, exported to `.puml` at build time |

Until then, treat them as reviewed documentation: **a stale diagram is worse than none**, so
update the `.puml` in the same commit as the workflow it describes.
