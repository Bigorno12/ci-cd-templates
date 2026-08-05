# ci-cd-templates

Reusable GitHub Actions CI/CD templates for Java (Maven + Spring Boot) projects. Consuming repos call these workflows instead of duplicating pipeline logic. Every job runs behind `step-security/harden-runner` with a configurable egress policy and `disable-sudo: true`, third-party actions are pinned to commit SHAs, checkouts use `persist-credentials: false` unless the job genuinely pushes, and per-job `permissions` are scoped to least privilege.

## Usage

Call the master pipeline from a workflow in your repo. Grant the caller the full
set of permissions the pipeline needs — GitHub defaults an unset permission to
`none`, so a missing `id-token: write` silently breaks keyless signing:

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
    uses: Bigorno12/ci-cd-templates/.github/workflows/master-maven-pipeline.yml@<sha>
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

Pin `@<sha>` to a template commit that includes the `verify-image` job and the
`signer-identity-regexp` / `release-egress-policy` inputs — passing them against
an older pin fails with "invalid input". Individual workflows can also be called
on their own via `workflow_call`.

## Pipeline

```mermaid
flowchart TD
    subgraph s1["① Build"]
        direction TB
        B["build<br/>compile · package · reject .env"]
        DG["dependency-graph<br/>push events only"]
        B --> DG
    end

    subgraph s2["② Verify — parallel"]
        direction LR
        L["lint"]
        U["unit-tests"]
        I["integration-tests"]
        SEC["security<br/>CodeQL · Gitleaks · Trivy"]
    end

    subgraph s3["③ Release"]
        direction LR
        T["tag<br/>PRs to main"]
        subgraph s3b["push to main"]
            direction TB
            D["docker-publish<br/>build · Trivy · SBOM · sign"]
            V["verify-image<br/>cosign verify gate"]
            G["deploy-gitops<br/>bump k8s manifest"]
            D --> V --> G
        end
    end

    GATE["④ build-gate<br/>fails if any job failed / cancelled"]

    s1 --> s2
    s2 --> s3
    s1 -.-> GATE
    s2 -.-> GATE
    s3 -.-> GATE

    classDef build  fill:#1f6feb,stroke:#0b3a8f,color:#fff;
    classDef verify fill:#8957e5,stroke:#3d1f7a,color:#fff;
    classDef supply fill:#2da44e,stroke:#116329,color:#fff;
    classDef gate   fill:#bf8700,stroke:#7a5600,color:#fff;

    class B,DG build;
    class L,U,I,SEC,T verify;
    class D,V,G supply;
    class GATE gate;
```

Solid arrows are the run order; dotted arrows feed `build-gate`, which
depends on every phase and runs with `if: always()`. Green nodes are the
supply-chain controls (sign → verify → promote).

| Workflow | Purpose |
|----------|---------|
| `build.yml` | `build`: compile & package, reject committed `.env`. `dependency-graph`: submit the Maven dependency graph (push events only) |
| `lint.yml` | Spotless / Ktlint formatting checks |
| `unit-tests.yml` | Unit tests + JUnit reports |
| `integration-tests.yml` | Integration tests (curated secrets via `extra-secrets`) |
| `security.yml` | `codeql` SAST + `gitleaks` secret scan + `trivy-deps` dependency scan |
| `tag.yml` | Tag PR builds `pr-<n>-run-<run>` (keeps 4 newest per PR) |
| `docker.yml` | Buildpack image → GHCR (`pr-<n>` / `main-<sha>`, keeps 3 newest); Trivy scan, SBOM, keyless Cosign signature + SBOM attestation |
| `deploy-gitops.yml` | Bump image tag in a k8s manifest on push to `main` |
| `auto-release.yml` | Auto-bump semver tag + GitHub release on push to `main` (keeps 10 newest) |

`tag` runs only on PRs to `main`; `verify-image` and `deploy-gitops` only on push to `main`. `build-gate` fails if any job failed or was cancelled.

`build.yml` splits the dependency-graph submission into its own job so the
compile job can run at `contents: read` — only the submission step needs
`contents: write`. It is skipped on pull requests, where the graph API is not
writable anyway.

`security.yml`'s `codeql` job probes the Code Scanning API first and fails
closed: HTTP 200/404 runs the analysis, 403 (Code Scanning disabled) skips it
with a warning, and any other status **errors** rather than silently skipping
SAST. `trivy-deps` runs a blocking filesystem scan for fixable `CRITICAL,HIGH`
vulnerabilities, then a non-blocking full report (`vuln,secret,misconfig` down
to `MEDIUM`, including unfixed) for visibility without failing the build.

## Supply-chain security

The release phase applies zero-trust controls between building and promoting an image:

- **Digest pinning** — a `Resolve image reference` step turns the pushed tag into an immutable `name@sha256:...` digest, and every downstream step (Trivy, Syft, `cosign sign`, `cosign attest`, `verify-image`) operates on that digest. Nothing in the release path trusts a mutable tag, so a tag repointed between build and deploy cannot slip through. On PR builds nothing is pushed, so the local tag is scanned and no signing happens.
- **Keyless signing** — every published image is signed with Cosign via GitHub OIDC (`docker.yml`), no long-lived keys.
- **Signature verification gate** — `verify-image` runs `cosign verify` on the pushed digest before `deploy-gitops` promotes it, so an unsigned or tampered image blocks the deploy.
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
calls the pipeline. The `verify-image` gate matches that identity against
`signer-identity-regexp`.

The input defaults to any workflow under the **caller's** repository owner
(`^https://github.com/<owner>/`), which only lines up when your repo is under the
`Bigorno12` org. If you call these templates from **any other org**, set it
explicitly or `verify-image` fails closed:

```yaml
    with:
      signer-identity-regexp: "^https://github.com/Bigorno12/ci-cd-templates/"
```

Pinning it explicitly is always correct, so it is recommended even within the
same org.

## Shared actions

- `.github/actions/java-setup` — installs Temurin JDK, configures Maven cache, sets `MAVEN_OPTS` (rejects multi-line values so nothing extra can be injected into `GITHUB_ENV`).
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

Neither job is path-filtered. Nearly every file in this repo lives under
`.github/`, so a filter would save almost nothing — and a required check that is
skipped by a path filter stays permanently pending and blocks the merge instead.

Both are worth setting as required status checks on `main`; the contexts are
`actionlint` and `zizmor`.

**Local hooks** in `.githook/` mirror the CI checks so failures surface before
they reach a runner. Enable them once per clone:

```bash
git config core.hooksPath .githook
```

- `pre-commit` — `gitleaks protect --staged`, blocking the commit on a detected secret.
- `pre-push` — skips unless the pushed commits touch YAML, then runs `actionlint` and `yamllint -d relaxed`.

Both hooks degrade to a warning when the tool is not installed
(`brew install gitleaks actionlint yamllint`), so CI remains the enforcement
point.

**Dependabot** (`.github/dependabot.yml`) opens one grouped `github-actions` PR
weekly, with a cooldown before a fresh release is proposed. Because every `uses:`
is SHA-pinned, these PRs are how pins get advanced.
