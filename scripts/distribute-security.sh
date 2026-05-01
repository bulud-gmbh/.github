#!/usr/bin/env bash
# Distribute the shared security stack (dependabot + audit-suite + codeql + daily sweep)
# into target bulud-gmbh webapp repos by opening a PR per repo.
#
# Usage:
#   ./scripts/distribute-security.sh [--dry-run] [repo ...]
#
# Defaults to all webapp repos if no repo args are given. Requires `gh` and `git`
# on PATH and an active gh auth identity with write access to the target repos.

set -euo pipefail

ORG="bulud-gmbh"
BRANCH="chore/security-stack"
DEFAULT_TARGETS=(bulud-invoice bulud-qr-menu GeoPDKS-Core)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORG_REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

DEPENDABOT_TEMPLATE="$ORG_REPO_DIR/templates/dependabot.yml"
CODEQL_TEMPLATE="$ORG_REPO_DIR/templates/codeql.yml"
SECURITY_DAILY_TEMPLATE="$ORG_REPO_DIR/templates/security-daily.yml"

for f in "$DEPENDABOT_TEMPLATE" "$CODEQL_TEMPLATE" "$SECURITY_DAILY_TEMPLATE"; do
  [[ -f "$f" ]] || { echo "missing template: $f" >&2; exit 1; }
done

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
  shift
fi

if [[ $# -eq 0 ]]; then
  TARGETS=("${DEFAULT_TARGETS[@]}")
else
  TARGETS=("$@")
fi

# Pattern-based patcher for ci.yml. Matches by step name/contents instead of
# line numbers, so it tolerates header comments and version-pin drift.
patch_ci_yml() {
  local file="$1"
  if grep -q "audit-suite@v1" "$file"; then
    return 2  # already patched, skip
  fi
  awk '
    BEGIN { done_checkout = 0; done_security = 0; saw_install = 0 }

    /^      - uses: actions\/checkout@/ && !done_checkout {
      print
      if ((getline nl) > 0) {
        if (nl !~ /^[[:space:]]+with:/) {
          print "        with:"
          print "          fetch-depth: 0"
        }
        print nl
      }
      done_checkout = 1
      next
    }

    /^        run: bun install --frozen-lockfile/ {
      saw_install = 1
    }

    saw_install && !done_security && /^      - name: Lint/ {
      print "      - name: Security checks"
      print "        uses: bulud-gmbh/.github/audit-suite@v1"
      print ""
      done_security = 1
    }

    { print }

    END {
      if (!done_checkout)  { print "patch_ci_yml: no actions/checkout step found"  > "/dev/stderr"; exit 1 }
      if (!done_security)  { print "patch_ci_yml: no Lint step found after bun install" > "/dev/stderr"; exit 1 }
    }
  ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

PR_BODY=$(cat <<'EOF'
Roll out the org-shared security stack from `bulud-gmbh/.github@v1`.

## Adds

- `.github/dependabot.yml` — daily npm + weekly github-actions update PRs
- `.github/workflows/codeql.yml` — CodeQL SAST on PR + weekly cron
- `.github/workflows/security-daily.yml` — daily `bun audit` + gitleaks history sweep at 04:00 UTC

## Modifies

- `.github/workflows/ci.yml` — adds `fetch-depth: 0` to the checkout step and inserts a `Security checks` step that calls the shared `bulud-gmbh/.github/audit-suite@v1` composite action (bun audit + gitleaks PR-diff + dependency-review).

## Reviewer checklist

- [ ] CI passes on this PR (the new audit-suite step runs against itself)
- [ ] Org Settings → Code security has Dependabot alerts + Secret scanning enabled
- [ ] After merge: trigger `Security Daily` once via `gh workflow run security-daily.yml` and confirm it succeeds

See `bulud-gmbh/.github/WORKFLOWS.md` for full docs.
EOF
)

run_one() {
  local repo="$1"
  local tmp
  tmp="$(mktemp -d -t "secstack-${repo}-XXXX")"
  trap 'rm -rf "$tmp"' RETURN

  echo
  echo "=== $repo ==="
  echo "tmp: $tmp"

  gh repo clone "$ORG/$repo" "$tmp/repo" -- --depth=1 --quiet

  pushd "$tmp/repo" > /dev/null

  if git ls-remote --exit-code --heads origin "$BRANCH" > /dev/null 2>&1; then
    echo "  branch '$BRANCH' already exists on remote — skipping (delete it on remote to retry)"
    popd > /dev/null
    return 0
  fi

  git checkout -q -b "$BRANCH"

  mkdir -p .github/workflows
  cp "$DEPENDABOT_TEMPLATE"      .github/dependabot.yml
  cp "$CODEQL_TEMPLATE"          .github/workflows/codeql.yml
  cp "$SECURITY_DAILY_TEMPLATE"  .github/workflows/security-daily.yml

  if [[ ! -f .github/workflows/ci.yml ]]; then
    echo "  no .github/workflows/ci.yml in this repo — security-checks step needs manual wiring" >&2
    popd > /dev/null
    return 1
  fi

  set +e
  patch_ci_yml .github/workflows/ci.yml
  rc=$?
  set -e
  if [[ $rc -eq 2 ]]; then
    echo "  ci.yml already references audit-suite@v1 — leaving it untouched"
  elif [[ $rc -ne 0 ]]; then
    echo "  ci.yml could not be patched automatically — finish this repo manually." >&2
    popd > /dev/null
    return 1
  fi

  if (( DRY_RUN )); then
    echo "  --- DRY RUN: diff ---"
    git --no-pager diff --stat
    git --no-pager diff
    popd > /dev/null
    return 0
  fi

  git add .github/dependabot.yml \
          .github/workflows/codeql.yml \
          .github/workflows/security-daily.yml \
          .github/workflows/ci.yml

  git commit -q -m "ci(security): adopt shared security stack from bulud-gmbh/.github@v1

- dependabot.yml: daily npm + weekly github-actions updates
- codeql.yml: caller for shared CodeQL workflow
- security-daily.yml: caller for shared daily sweep
- ci.yml: invoke audit-suite composite action after install"

  git push -u origin "$BRANCH" --quiet

  gh pr create \
    --repo "$ORG/$repo" \
    --base main \
    --head "$BRANCH" \
    --title "ci(security): adopt shared security stack" \
    --body "$PR_BODY"

  popd > /dev/null
}

failed=()
for repo in "${TARGETS[@]}"; do
  if ! run_one "$repo"; then
    failed+=("$repo")
  fi
done

if (( ${#failed[@]} > 0 )); then
  echo
  echo "FAILED on: ${failed[*]}" >&2
  exit 1
fi

echo
echo "Done. Targets processed: ${TARGETS[*]}"
