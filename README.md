# ci-cd-templates

Reusable GitHub Actions CI/CD templates for Java (Maven + Spring Boot) projects. Consuming repos call these workflows instead of duplicating pipeline logic. Every job runs behind `step-security/harden-runner` with a configurable egress policy.

## Usage

Call the master pipeline from a workflow in your repo:

```yaml
name: CI
on: [push, pull_request]

jobs:
  pipeline:
    uses: Bigorno12/ci-cd-templates/.github/workflows/master-maven-pipeline.yml@main
    secrets: inherit
    with:
      java-version: "25"
      cache-type: "maven"
```

Individual workflows can also be called on their own via `workflow_call`.

## Pipeline

```
build → lint / unit-tests / integration-tests → security → tag / docker-publish → deploy-gitops → build-gate
```

| Workflow | Purpose |
|----------|---------|
| `build.yml` | Compile & package, reject committed `.env`, submit dependency graph |
| `lint.yml` | Spotless / Ktlint formatting checks |
| `unit-tests.yml` | Unit tests + JUnit reports |
| `integration-tests.yml` | Integration tests (curated secrets via `extra-secrets`) |
| `security.yml` | CodeQL analysis + Gitleaks secret scan |
| `tag.yml` | Tag PR builds `pr-<n>-run-<run>` (keeps 4 newest per PR) |
| `docker.yml` | Buildpack image → GHCR (`pr-<n>` / `main-<sha>`, keeps 3 newest) |
| `deploy-gitops.yml` | Bump image tag in a k8s manifest on push to `main` |
| `auto-release.yml` | Auto-bump semver tag + GitHub release on push to `main` |

`tag` runs only on PRs to `main`; `deploy-gitops` only on push to `main`. `build-gate` fails if any job failed or was cancelled.

## Shared actions

- `.github/actions/java-setup` — installs Temurin JDK, configures Maven cache, sets `MAVEN_OPTS`.
- `.github/actions/ghcr-cleanup` — retains the 3 most recent GHCR images (with retry).
