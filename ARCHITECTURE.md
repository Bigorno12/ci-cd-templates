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

> **Maturity:** the Java tree is fully tested in production; the **Python tree has never
> completed a real run**, so every diagram below describing it is a design record rather than
> observed behaviour — the egress lists especially. See [README → Status](README.md#status).

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
effective on the same commit) while the five composite actions under
[`.github/actions/`](.github/actions/) are referenced by **SHA-pinned self-reference**
(`Bigorno12/ci-cd-templates/.github/actions/java-setup@<sha>`, 8 call sites;
`python-setup@<sha>`, 5) — so editing an action does nothing until a second commit bumps
every pin.

On the consumer side the pipeline publishes `ghcr.io/<owner>/<repo>:main-<sha7>`, signs it
keylessly, then commits that tag into their k8s manifest for Argo CD to sync. See
[CLAUDE.md → Supply-chain Security](CLAUDE.md#supply-chain-security) and
[CLAUDE.md → Consumer Contract](CLAUDE.md#consumer-contract).

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
