# ci-cd-templates

Reusable GitHub Actions CI/CD templates for Java (Maven + Spring Boot) and Python (pip + pytest) projects. Consuming repos call these workflows instead of duplicating pipeline logic. Every job runs behind `step-security/harden-runner` with a configurable egress policy and `disable-sudo: true`, third-party actions are pinned to commit SHAs, checkouts use `persist-credentials: false` unless the job genuinely pushes, and per-job `permissions` are scoped to least privilege.

## Status

| Pipeline | Status |
|---|---|
| **Java** (`master-java-pipeline.yml`) | ✅ **Fully tested.** Runs in production against a real consumer (`Bigorno12/monolith-architecture`); every egress allowlist below was derived from observed harden-runner denials. |
| **Python** (`master-python-pipeline.yml`) | ⚠️ **Not yet validated end-to-end.** The workflows lint clean (`actionlint`, `yamllint`, `zizmor`, `gitleaks`) and the call graph resolves, but **no Python pipeline has completed a real run.** Treat it as a reviewed draft, not a proven path. |

**What "not yet validated" means concretely.** Linting proves structure, not behaviour — none
of these can be confirmed without a runner:

- **The egress allowlists are reasoned, not observed.** The Java lists were built by reading
  real harden-runner denial summaries. The Python ones were written from documentation, so
  `pypi.org`, `files.pythonhosted.org`, the four Docker Hub hosts and especially
  `deps.paketo.io` are *predictions*. A missing host fails closed and blocks the job; a host
  that is never reached is dead weight in the allowlist.
- **The Paketo `pack build` path is unproven** — including whether the digest read-back via
  `docker buildx imagetools inspect` behaves as expected, since `pack --publish` leaves
  nothing in the local daemon.
- **`test-services`, the CodeQL `build-mode: none` job, and the pip dependency submission**
  have never executed.

**How to run it safely today.** Start with `build-egress-policy: "audit"` and
`release-egress-policy: "audit"`. Audit mode reports what a job reached instead of blocking
it, so the first run's harden-runner summary tells you exactly which HTTPS endpoints the
pipeline actually needs. Move to `"block"` once the summary is clean and you have fed any
missing host into the matching `extra-*-endpoints` input.

**Planned:** two throwaway reference consumers — a Django project and a FastAPI project — to
exercise `master-python-pipeline.yml` end to end and turn each list above from a prediction
into an observation. Until those exist and pass, the Python tree carries the warning above.
The frameworks were chosen deliberately: Django exercises the database path
(`postgres-image`, migrations, `pytest-django`) and FastAPI the minimal ASGI path, and the
two together cover both `Procfile` shapes (`gunicorn ... wsgi` and `uvicorn`).

## Usage

Pick the entry point for your language — `master-java-pipeline.yml` or
`master-python-pipeline.yml` — and call it from a workflow in your repo. Grant the caller
the full set of permissions the pipeline needs — GitHub defaults an unset permission to
`none`, so a missing `id-token: write` silently breaks keyless signing:

### Java

```yaml
name: Main CI Orchestrator
on:
  push:
    branches: [ "main" ]
  pull_request:
    branches: [ "main" ]

permissions:
  contents: write        # PR build tags + GitOps commit
  packages: write        # push image to GHCR
  security-events: write # CodeQL SARIF upload
  id-token: write        # cosign keyless signing (REQUIRED — defaults to none)
  actions: read
  checks: write
  pull-requests: write

jobs:
  run-entire-pipeline:
    uses: Bigorno12/ci-cd-templates/.github/workflows/master-java-pipeline.yml@<sha>
    secrets: inherit
    with:
      java-version: "25"
      cache-type: "maven"
      build-egress-policy: "block"
      release-egress-policy: "block"   # drop to "audit" while tuning buildpack egress
      spring-boot-args: "-P dev -pl rest -am"
      test-args: "-Dspring.profiles.active=dev"
      gitops-manifest-path: "infra/k8s/manifest/api.yaml"
      # Verify gate: the image is signed inside THIS reusable workflow, so the
      # Cosign certificate identity is always the template repo — pin it here
      # unless your repo is under the Bigorno12 org (see Cross-org verification).
      signer-identity-regexp: "^https://github.com/Bigorno12/ci-cd-templates/"
```

Pin `@<sha>` to a template commit that includes the folded verification gate and the
`signer-identity-regexp` / `release-egress-policy` inputs — passing them against
an older pin fails with "invalid input". Individual workflows can also be called
on their own via `workflow_call`.

### Python

`master-python-pipeline.yml` is the same pipeline with the Java leaves swapped for
pip/pytest/ruff/pack. The permissions block above is unchanged — only the `with:` differs.

⚠️ Read [Status](#status) first: this pipeline has not completed a real run. The snippet
below starts both phases in `"audit"` deliberately — switch to `"block"` once a run has
confirmed the allowlists.

```yaml
jobs:
  run-entire-pipeline:
    uses: Bigorno12/ci-cd-templates/.github/workflows/master-python-pipeline.yml@<sha>
    secrets: inherit
    with:
      python-version: "3.14"
      cache-type: "pip"
      requirements: "requirements.txt"
      dev-requirements: "requirements-dev.txt"   # must provide pytest + ruff
      build-egress-policy: "audit"     # see Status — start here, tighten to "block"
      release-egress-policy: "audit"   # buildpack egress is unverified
      pack-args: "--env BP_PIP_VERSION=latest"
      test-args: "-k not_slow"
      postgres-image: "postgres:17-alpine"   # omit for a SQLite/no-DB suite
      redis-image: ""                        # omit unless your tests need Redis
      gitops-manifest-path: "infra/k8s/manifest/api.yaml"
      signer-identity-regexp: "^https://github.com/Bigorno12/ci-cd-templates/"
```

The Java and Python entry points share `tag.yml` and `deploy-gitops.yml` verbatim — those
two are language-agnostic — so the signing, verification and GitOps promotion behaviour is
identical for both.

### What your repo must provide

The templates make these assumptions; a pipeline that fails immediately is usually
one of them:

- `mvnw` and `pom.xml` at the repository root (every job runs `chmod +x mvnw` first).
- A Spotless-configured build — `java-lint.yml` is exactly `./mvnw spotless:check`.
- Surefire/Failsafe reports at `**/target/*-reports/TEST-*.xml` for the JUnit annotations.
- No tracked `*.env` files other than `.env.example` — `java-build.yml` fails the build on one.
- For GitOps: a manifest at `gitops-manifest-path` containing an
  `image: ghcr.io/<owner>/<repo>:...` line, which `deploy-gitops` rewrites with `sed`.
- Optional: a root `.trivyignore`. `java-docker.yml` always passes `trivyignores: .trivyignore`
  to the image scan, so that is where CVE suppressions belong.

For the **Python** pipeline, substitute the first three:

- `requirements.txt` at the repository root (or point `requirements` elsewhere). It keys the
  pip cache, so it must exist even if it is empty.
- A `requirements-dev.txt` providing `pytest` and `ruff` — `python-lint.yml` is exactly
  `ruff check` + `ruff format --check`, the way `java-lint.yml` is exactly `spotless:check`.
- Tests split by a `pytest` marker named `integration`: the unit job runs
  `-m "not integration"`, the integration job runs `-m integration`. Register the marker in
  your `pyproject.toml`/`pytest.ini`. A repo with no integration-marked tests passes — that
  job treats pytest's exit code 5 ("no tests collected") as a pass, not a failure.
- `python-docker.yml` needs no Dockerfile: `pack build` uses the Paketo builder named by
  `builder-image`. Your app must be something that builder can detect (a `requirements.txt`
  plus an entrypoint it recognises).

#### Django and FastAPI

Everything in this subsection is derived from the Paketo buildpack sources and the framework
docs, **not** from a green pipeline run — see [Status](#status). The two reference projects
planned there exist precisely to prove or disprove it. The point that bites hardest is
silent:

**A `Procfile` is mandatory for any web app.** Paketo's `python-start` buildpack sets the
default process to a bare `python` REPL — not gunicorn, not uvicorn. Without one, the image
builds, scans, signs, gets attested and is promoted by `deploy-gitops`, and then serves
nothing. No gate in this pipeline can detect that, so `python-docker.yml` emits a build
warning when it finds neither a `Procfile` nor a `project.toml` process type.

```
# Django — add gunicorn to requirements.txt
web: gunicorn myproject.wsgi --bind :$PORT

# FastAPI — add uvicorn to requirements.txt
web: uvicorn main:app --host 0.0.0.0 --port $PORT
```

**FastAPI** needs nothing else: `pytest` + `ruff` in `requirements-dev.txt`, the
`integration` marker registered, and the Procfile above. It has no framework-level database
requirement — a `TestClient` suite over SQLite or fakes needs no container at all, so leave
`postgres-image` empty unless your own integration tests genuinely talk to Postgres.

**Django** additionally needs:

- **`pytest-django`** in `requirements-dev.txt` and `DJANGO_SETTINGS_MODULE` set in your
  `pyproject.toml`/`pytest.ini`. Plain `pytest` on a Django project raises
  `ImproperlyConfigured`. If your suite runs under `manage.py test` (unittest) rather than
  pytest, these leaves will not run it — pytest collects nothing and exits 5, which the unit
  job treats as a failure. That is deliberate: a test job that silently runs zero tests is
  worse than one that fails.
- **A database — only if your settings point at one.** Django's test runner always creates
  a test database, but with the `sqlite3` backend that is in-memory and needs no container.
  Set `postgres-image` only when your test settings actually target Postgres (worth doing if
  you rely on `JSONField`, `ArrayField` or database constraints, which behave differently on
  SQLite). It applies to the **unit** job as well as integration, because Django builds that
  test database whatever the tests touch.

  When set, the container is bound to `127.0.0.1` with a password generated per run and
  masked in the logs, and the job gets `DATABASE_URL` plus the individual `POSTGRES_*`
  variables. When empty **nothing is exported at all**, so a `os.environ.get("DATABASE_URL",
  <sqlite fallback>)` in your settings still returns your fallback.
- **`psycopg2-binary`, not `psycopg2`.** The default `builder-jammy-base` ships Python
  *without common C libraries*, so the non-binary package cannot compile. The alternative is
  `builder-image: "paketobuildpacks/builder-jammy-full"`.
- **Migrations and `collectstatic` are not run** by the buildpack. Handle static files with
  WhiteNoise, and run migrations from your Procfile or as a deploy step.

## Pipeline

```mermaid
flowchart TD
    subgraph s1["① Build + Verify — every job starts at t=0"]
        B["build<br/>test-compile · reject .env"]
        L["lint"]
        U["unit-tests"]
        I["integration-tests"]
        SEC["security<br/>CodeQL · Gitleaks · Trivy"]
    end

    DG["dependency-graph<br/>needs build only · push events · off critical path"]

    subgraph s2["② Release"]
        direction LR
        T["tag<br/>PRs to main"]
        subgraph s2b["push to main"]
            direction TB
            D["docker-publish<br/>build · Trivy · SBOM · sign"]
            G["deploy-gitops<br/>cosign verify gate · bump k8s manifest"]
            D --> G
        end
    end

    GATE["③ build-gate<br/>fails if any job failed / cancelled"]

    B --> DG
    s1 --> s2
    s1 -.-> GATE
    DG -.-> GATE
    s2 -.-> GATE

    classDef build  fill:#1f6feb,stroke:#0b3a8f,color:#fff;
    classDef verify fill:#8957e5,stroke:#3d1f7a,color:#fff;
    classDef supply fill:#2da44e,stroke:#116329,color:#fff;
    classDef gate   fill:#bf8700,stroke:#7a5600,color:#fff;

    class B,DG build;
    class L,U,I,SEC,T verify;
    class D,G supply;
    class GATE gate;
```

Solid arrows are the run order; dotted arrows feed `build-gate`, which
depends on every phase and runs with `if: always()`. Green nodes are the
supply-chain controls (sign → verify → promote). [ARCHITECTURE.md](ARCHITECTURE.md)
carries the same graph with per-job permissions, plus the input-plumbing, release-sequence
and egress diagrams.

Stage ① is a grouping, not a single workflow: `build` and `verify` are separate
caller jobs in `master-java-pipeline.yml`, and `verify` fans out into `lint`,
`unit-tests`, `integration-tests` and `security`. All five start at t=0 — verify
has no `needs: build`, because nothing in it consumes build's output (every job
checks out and compiles for itself). `dependency-graph` is the one job with a
narrower dependency: it needs `build` alone, and nothing needs it back, so it
hangs off the side rather than sitting on the critical path. `release` gates on
both `build` and `verify`, so nothing publishes unless the compile gate and
every verification job passed.

| Workflow | Purpose |
|----------|---------|
| `master-java-pipeline.yml` | The entry point consumers call; owns every input, plus `build-gate` |
| `java-verify.yml` / `java-release.yml` | Grouping layers — no steps, only job plumbing and permission narrowing |
| `java-build.yml` | Fail-fast `test-compile`, reject committed `.env` |
| `java-dependency-graph.yml` | Submit the Maven dependency graph (push events only) |
| `java-lint.yml` | Spotless / Ktlint formatting checks |
| `java-unit-tests.yml` | Unit tests + JUnit reports |
| `java-integration-tests.yml` | Integration tests (curated secrets via `extra-secrets`) |
| `java-security.yml` | `codeql` SAST + `gitleaks` secret scan + `trivy-deps` dependency scan |
| `tag.yml` | Tag PR builds `pr-<n>-run-<run>` (keeps 4 newest per PR) |
| `java-docker.yml` | Buildpack image → GHCR (`pr-<n>` / `main-<sha7>`, keeps 3 newest); Trivy scan, SBOM, keyless Cosign signature + SBOM attestation |
| `deploy-gitops.yml` | Verify the image's Cosign signature, then bump its tag in a k8s manifest on push to `main` |
| `auto-release.yml` | Auto-bump semver tag + GitHub release on push to `main` (keeps 10 newest) |

The Python tree mirrors it file-for-file, minus the two it shares:

| Workflow | Purpose |
|----------|---------|
| `master-python-pipeline.yml` | Python entry point; owns every input, plus `build-gate` |
| `python-verify.yml` / `python-release.yml` | Grouping layers |
| `python-build.yml` | `python -m compileall` fail-fast, reject committed `.env` |
| `python-dependency-graph.yml` | Submit the pip dependency graph (push events only) |
| `python-lint.yml` | `ruff check` + `ruff format --check` |
| `python-unit-tests.yml` | `pytest -m "not integration"` + JUnit reports |
| `python-integration-tests.yml` | `pytest -m integration`; optional Postgres/Redis via `postgres-image`/`redis-image`, curated secrets via `extra-secrets` |
| `python-security.yml` | CodeQL (`python`, `build-mode: none`) + Gitleaks + Trivy fs scan |
| `python-docker.yml` | `pack build` → GHCR; Trivy scan, SBOM, Cosign signature + attestation |
| `tag.yml` · `deploy-gitops.yml` | **Shared with the Java pipeline — not duplicated** |

`tag` runs only on PRs to `main`; `deploy-gitops` only on push to `main`. `build-gate` fails if any job failed or was cancelled.

`dependency-graph` is a separate workflow, not a job inside `java-build.yml`, for two
reasons. It keeps `build` at `contents: read` — only the graph submission needs
`contents: write`. And it stays **off the critical path**: a `needs:` on a
reusable workflow waits for *every* job inside it, so a graph submission living
in `java-build.yml` would make `release` wait on bookkeeping nothing downstream
consumes. `build-gate` still reports its result, and it is skipped on pull
requests (a skipped job is not a failure).

`build` runs `test-compile` rather than `package`. Its output is discarded —
nothing is shared downstream — so jar assembly and `spring-boot:repackage` were
pure cost on the serial path ahead of the entire verify phase. `test-compile`
still fails fast on both main and test sources; a genuine packaging failure now
surfaces in `docker-publish` instead of here.

`java-security.yml`'s `codeql` job probes the Code Scanning API first and fails
closed: HTTP 200/404 runs the analysis, 403 (Code Scanning disabled) skips it
with a warning, and any other status **errors** rather than silently skipping
SAST. `trivy-deps` runs a blocking filesystem scan for fixable `CRITICAL,HIGH`
vulnerabilities, then a non-blocking full report (`vuln,secret,misconfig` down
to `MEDIUM`, including unfixed) for visibility without failing the build.

## Supply-chain security

The release phase applies zero-trust controls between building and promoting an image:

- **Digest pinning** — a `Resolve image reference` step turns the pushed tag into an immutable `name@sha256:...` digest, and every downstream step (Trivy, Syft, `cosign sign`, `cosign attest`, and the deploy gate) operates on that digest. Nothing in the release path trusts a mutable tag, so a tag repointed between build and deploy cannot slip through. On PR builds nothing is pushed, so the local tag is scanned and no signing happens.
- **Keyless signing** — every published image is signed with Cosign via GitHub OIDC (`java-docker.yml`), no long-lived keys.
- **Signature verification gate** — `deploy-gitops` runs `cosign verify` on the pushed digest as its **first steps**, before any checkout or commit. An unsigned or tampered image aborts the job with the manifest untouched. An empty digest fails closed rather than promoting an unverified artifact.
- **SBOM + vulnerability scan** — a Syft CycloneDX SBOM and a Trivy `CRITICAL,HIGH` scan run against the built image. The SBOM is uploaded as a 30-day artifact **and** bound to the digest as a signed in-toto attestation, so consumers can verify provenance directly from the registry:

  ```bash
  cosign verify-attestation --type cyclonedx \
    --certificate-identity-regexp "^https://github.com/Bigorno12/ci-cd-templates/" \
    --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
    ghcr.io/<owner>/<repo>@sha256:<digest>
  ```

- **Egress `block`** — build, verify, and release phases default to a blocking harden-runner policy with explicit host allowlists (tune via the `extra-*-endpoints` inputs).

### Cross-org verification

`cosign sign` runs inside this reusable workflow, so the Sigstore certificate
identity (SAN) is always the **template** repo —
`https://github.com/Bigorno12/ci-cd-templates/...` — regardless of which repo
calls the pipeline. The `deploy-gitops` gate matches that identity against
`signer-identity-regexp`.

The input defaults to any workflow under the **caller's** repository owner
(`^https://github.com/<owner>/`), which only lines up when your repo is under the
`Bigorno12` org. If you call these templates from **any other org**, set it
explicitly or the deploy gate fails closed:

```yaml
    with:
      signer-identity-regexp: "^https://github.com/Bigorno12/ci-cd-templates/"
```

Pinning it explicitly is always correct, so it is recommended even within the
same org.

## Shared actions

GitHub does not allow subdirectories under `.github/workflows`, so the workflow
files are necessarily flat. Each workflow is self-contained: it declares its own
`harden-runner` allowlist and its own checkout/JDK preamble, so a job can be read
end-to-end without following indirection.

- `.github/actions/java-setup` — installs Temurin JDK, configures Maven cache, sets `MAVEN_OPTS` (rejects multi-line values so nothing extra can be injected into `GITHUB_ENV`).
- `.github/actions/python-setup` — installs CPython, configures the pip cache (keyed on both requirements files), and installs them. Unlike `java-setup` it writes nothing to `GITHUB_ENV`.
- `.github/actions/test-services` — starts the optional Postgres/Redis containers the test leaves expose via `postgres-image`/`redis-image` and waits on each container's own health check. Credentials are generated per run and masked, ports are bound to `127.0.0.1` rather than `0.0.0.0`, and the connection variables are exported **only** for services that actually started. Uses `docker run` behind a step `if:` rather than a job-level `services:` block, because a service container's image cannot be conditionally omitted and a reusable workflow cannot accept one from its caller.
- `.github/actions/ghcr-cleanup` — retains the 3 most recent GHCR images (with retry).
- `.github/actions/cache-cleanup` — deletes Actions caches outside the retention policy: anything not on `keep-ref` (PR/feature branches) plus `keep-ref` caches older than `retention-days`. Not wired into the master pipeline; call it from your own scheduled workflow with a token that has `actions: write`.

## Maintaining this repo

These templates are the trust boundary for every repo that calls them, so the
repo runs checks on its own CI code.

**`workflow-lint.yml`** runs on every push to `main` and every pull request
(and is exposed via `workflow_call` if a consumer wants to reuse it):

| Job | What it catches |
|-----|-----------------|
| `actionlint` | Structural errors across all workflows — bad `needs:`, invalid expressions, unknown `runs-on` labels, shellcheck findings inside `run:` blocks. The binary is checksum-verified against a pinned SHA-256 before it executes. |
| `zizmor` | Actions-specific security findings at `medium`+ — unpinned action refs, template injection via `${{ github.event.* }}`, credential persistence, over-broad `permissions`. |

Neither job is path-filtered, and deliberately so: a required check skipped by a
path filter stays permanently pending and blocks the merge instead of passing.
Everything these jobs actually lint lives under `.github/`, so the filter would
buy little even setting that aside.

Both are worth setting as required status checks on `main`; the contexts are
`actionlint` and `zizmor`.

**Local hooks** in `.githook/` mirror the CI checks so failures surface before
they reach a runner. Enable them once per clone:

```bash
git config core.hooksPath .githook
```

- `pre-commit` — `gitleaks protect --staged`, blocking the commit on a detected secret.
- `pre-push` — skips unless the pushed commits touch YAML, then runs `actionlint` and
  `yamllint --strict`. It deliberately passes no `-d`: the ruleset comes from the repo's
  [`.yamllint.yml`](.yamllint.yml) (200 columns, 2-space indent), so the hook and CI share
  one config.

Both hooks degrade to a warning when the tool is not installed
(`brew install gitleaks actionlint yamllint`), so CI remains the enforcement
point — and because `pre-push` is path-gated, a docs-only push runs neither linter
and still reports success.

**Dependabot** (`.github/dependabot.yml`) opens one grouped `github-actions` PR
weekly, with a cooldown before a fresh release is proposed. Because every `uses:`
is SHA-pinned, these PRs are how pins get advanced.

**Editing a composite action is a two-commit change.** The five actions under
`.github/actions/` are consumed by SHA-pinned *self-reference*
(`Bigorno12/ci-cd-templates/.github/actions/java-setup@<sha>`), because inside a reusable
workflow a relative action path resolves against the caller's checkout rather than this
repo. Merge the action change first, then a second commit bumping every pin — until then
the edit is inert. `grep -rn "Bigorno12/ci-cd-templates" .github/` lists all 16 call sites
(7 `java-setup`, 5 `python-setup`, 2 `ghcr-cleanup`, 2 `test-services`).

### Further reading

| Doc | Contents |
|-----|----------|
| [ARCHITECTURE.md](ARCHITECTURE.md) | The `uses:` call graph, input/permission plumbing, the release sequence, and per-phase egress allowlists as rendered PlantUML diagrams ([`docs/`](docs/)) |
| [CLAUDE.md](CLAUDE.md) | Maintainer guide: house rules for workflow edits, the consumer contract, and where each value is allowed to live |
| [`.claude/rules/workflow-rule.md`](.claude/rules/workflow-rule.md) | The pin / input-default / inline decision, the two gates that reject the alternatives, and current known deviations |
