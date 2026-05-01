# Shared CI / Security Workflows

Reusable GitHub Actions for `bulud-gmbh` Node.js webapp repos. Designed for **bun + Next.js / Cloudflare Workers** projects (e.g., [`bulud-gmbh/base`](https://github.com/bulud-gmbh/base)).

## What's here

| Path | Type | Use |
|---|---|---|
| `.github/workflows/security-daily.yml` | Reusable workflow | Daily `bun audit` + gitleaks history sweep, opens issue on findings |
| `.github/workflows/codeql.yml` | Reusable workflow | CodeQL SAST for JS/TS |
| `audit-suite/action.yml` | Composite action | `bun audit` + gitleaks PR-diff + dependency-review (drop into existing CI job) |
| `templates/dependabot.yml` | Copy-paste template | Dependabot config (no central support — must be copied per-repo) |

Versioning: pin to `@v1`. Breaking changes get `@v2`.

## One-time org setup

In `bulud-gmbh/.github` repo → **Settings → Actions → General → Access**: select **"Accessible from repositories in the bulud-gmbh organization"**. Required for private downstream repos to consume these workflows.

In **org Settings → Code security**: enable Dependabot alerts, Dependabot security updates, Secret scanning, and Push protection as defaults for all repos.

## Consuming from a downstream repo

### 1. Add the audit suite to your existing CI

In `.github/workflows/ci.yml`, after `bun install --frozen-lockfile`:

```yaml
- uses: actions/checkout@v6
  with:
    fetch-depth: 0  # required for gitleaks PR-diff

# ... setup-bun, bun install ...

- name: Security checks
  uses: bulud-gmbh/.github/audit-suite@v1
```

### 2. Add CodeQL

`.github/workflows/codeql.yml`:

```yaml
name: CodeQL

on:
  push: { branches: [main] }
  pull_request: { branches: [main] }
  schedule:
    - cron: "0 3 * * 1"
  workflow_dispatch:

jobs:
  analyze:
    uses: bulud-gmbh/.github/.github/workflows/codeql.yml@v1
```

### 3. Add daily sweep

`.github/workflows/security-daily.yml`:

```yaml
name: Security Daily

on:
  schedule:
    - cron: "0 4 * * *"
  workflow_dispatch:

jobs:
  scan:
    uses: bulud-gmbh/.github/.github/workflows/security-daily.yml@v1
```

### 4. Copy Dependabot config

Copy `templates/dependabot.yml` to `.github/dependabot.yml` in the consumer repo. Adjust ecosystems if the project isn't npm-based.

## Inputs

`audit-suite` action:
- `audit-level` (default `high`) — bun audit severity threshold
- `fail-on-severity` (default `high`) — dependency-review threshold

`security-daily.yml`:
- `bun-version` (default `latest`)
- `audit-level` (default `low` — full sweep)

`codeql.yml`:
- `languages` (default `javascript-typescript`)
- `queries` (default `security-extended`)

## Notes

- CodeQL requires GitHub Advanced Security on private repos.
- `dependency-review-action` (inside `audit-suite`) is marked `continue-on-error` so it doesn't block PRs if GHAS isn't enabled.
- Gitleaks runs as the OSS CLI (curl-installed), not the action — the action requires a paid license for org accounts.
