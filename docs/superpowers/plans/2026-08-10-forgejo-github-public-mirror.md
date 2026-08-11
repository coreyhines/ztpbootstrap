# Forgejo → GitHub Public Mirror Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Forgejo the only development remote and CI system, and publish only `main` plus `v*` tags to GitHub after Forgejo CI (including secret-scan) passes.

**Architecture:** Delete GitHub Actions workflows. Extend Forgejo CI with a gated `publish-github` job that uses `scripts/publish-github-mirror.sh` and a Forgejo-only `GITHUB_MIRROR_TOKEN`. Scrub the GitHub repo (close PRs, delete extra branches, disable Actions), remove the local `github` remote, then flip the GitHub repo public only after a clean publish.

**Tech Stack:** Forgejo Actions (strongpod runner), bash + git, GitHub fine-grained PAT, `gh` CLI for one-time scrub.

**Spec:** `docs/superpowers/specs/2026-08-10-forgejo-github-public-mirror-design.md`

## Global Constraints

- Publish refs: `main` and release tags matching `v*` only — never feature branches
- Auth: Forgejo secret `GITHUB_MIRROR_TOKEN` only; never commit tokens
- No force-push to GitHub `main` in normal operation (fast-forward only)
- GitHub stays private until first green publish + confirmed clean secret-scan on that tip
- Local clones must not have a `github` push remote after Task 5
- Podman, not Docker, for any container work in this repo (unchanged)

## File map

| Path | Responsibility |
|------|----------------|
| `.github/workflows/ci.yml` | **Delete** |
| `.github/workflows/dhcp-integration-test.yml` | **Delete** |
| `.github/workflows/secret-scan.yml` | **Delete** |
| `.github/` (dir) | Remove if empty after workflow deletes |
| `.forgejo/workflows/ci.yml` | CI jobs + `on.tags` + `publish-github` job; fix header comments |
| `scripts/publish-github-mirror.sh` | **Create** — push `main` and optional tag to GitHub over HTTPS |
| `docs/FORGEJO_GITHUB_MIRROR.md` | **Create** — operator/developer mirror policy |
| `README.md` | Point clone at GitHub; point contribute/CI at Forgejo; link mirror doc |
| `docs/QUICK_START.md` | Keep public clone URL on GitHub; note development is on Forgejo |
| `docs/CI_TESTING.md` | Replace “GitHub Actions secrets” with Forgejo CI wording where needed |

---

### Task 1: Remove GitHub Actions workflows

**Files:**
- Delete: `.github/workflows/ci.yml`
- Delete: `.github/workflows/dhcp-integration-test.yml`
- Delete: `.github/workflows/secret-scan.yml`
- Delete: `.github/workflows/` (and `.github/` if empty)

**Interfaces:**
- Consumes: none
- Produces: repo with no GitHub workflow YAML for Actions to run after scrub/disable

- [ ] **Step 1: Confirm files exist**

```bash
ls -la .github/workflows/
```

Expected: `ci.yml`, `dhcp-integration-test.yml`, `secret-scan.yml`

- [ ] **Step 2: Delete the workflows and empty dirs**

```bash
rm -f .github/workflows/ci.yml \
      .github/workflows/dhcp-integration-test.yml \
      .github/workflows/secret-scan.yml
rmdir .github/workflows 2>/dev/null || true
# Remove .github only if nothing else remains (e.g. DEPENDABOT, CODEOWNERS)
find .github -type f 2>/dev/null
# If only empty dirs, remove:
rm -rf .github
```

- [ ] **Step 3: Verify gone**

```bash
test ! -e .github/workflows && echo "workflows removed"
git status -sb
```

Expected: deleted workflow files staged or unstaged; no `.github/workflows` path

- [ ] **Step 4: Commit**

```bash
git add -A .github
git commit -m "$(cat <<'EOF'
ci: remove GitHub Actions workflows

CI runs on Forgejo only; GitHub is a public mirror face and must not
execute Actions from mirrored pushes.
EOF
)"
```

---

### Task 2: Add publish script (testable without pushing)

**Files:**
- Create: `scripts/publish-github-mirror.sh`
- Test: run with `--dry-run` and `shellcheck`

**Interfaces:**
- Consumes: env `GITHUB_MIRROR_TOKEN` (required unless `--dry-run`); optional `GITHUB_MIRROR_OWNER` (default `coreyhines`), `GITHUB_MIRROR_REPO` (default `ztpbootstrap`)
- Produces: executable script that fast-forward pushes `main` and optionally one tag ref to GitHub; exits non-zero on non-ff or missing token

- [ ] **Step 1: Write the script**

Create `scripts/publish-github-mirror.sh`:

```bash
#!/usr/bin/env bash
# Push Forgejo main (and optional v* tag) to GitHub after CI gates.
# Usage:
#   publish-github-mirror.sh [--dry-run] [--tag v1.2.3]
# Env:
#   GITHUB_MIRROR_TOKEN  required unless --dry-run
#   GITHUB_MIRROR_OWNER  default coreyhines
#   GITHUB_MIRROR_REPO   default ztpbootstrap
set -euo pipefail

DRY_RUN=0
TAG_REF=""

usage() {
  printf 'Usage: %s [--dry-run] [--tag vX.Y.Z]\n' "$(basename "$0")" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --tag)
      [[ $# -ge 2 ]] || usage
      TAG_REF="$2"
      shift 2
      ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

OWNER="${GITHUB_MIRROR_OWNER:-coreyhines}"
REPO="${GITHUB_MIRROR_REPO:-ztpbootstrap}"
TOKEN="${GITHUB_MIRROR_TOKEN:-}"

if [[ "${DRY_RUN}" -eq 0 && -z "${TOKEN}" ]]; then
  printf 'error: GITHUB_MIRROR_TOKEN is required (or pass --dry-run)\n' >&2
  exit 1
fi

if [[ -n "${TAG_REF}" && ! "${TAG_REF}" =~ ^v[0-9] ]]; then
  printf 'error: --tag must look like a release tag (v…), got %s\n' "${TAG_REF}" >&2
  exit 1
fi

# Mask token in Actions logs if present
if [[ -n "${TOKEN}" ]]; then
  printf '::add-mask::%s\n' "${TOKEN}"
fi

WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "${WORKDIR}"; }
trap cleanup EXIT

# Clone the already-checked-out SHA from the Actions workspace when possible;
# otherwise expect to be run from a full git checkout.
ROOT="$(git rev-parse --show-toplevel)"
MAIN_SHA="$(git -C "${ROOT}" rev-parse refs/heads/main 2>/dev/null || git -C "${ROOT}" rev-parse HEAD)"

printf 'Publishing main=%s to github.com/%s/%s\n' "${MAIN_SHA}" "${OWNER}" "${REPO}"

if [[ "${DRY_RUN}" -eq 1 ]]; then
  printf 'dry-run: would push %s:refs/heads/main\n' "${MAIN_SHA}"
  if [[ -n "${TAG_REF}" ]]; then
    TAG_SHA="$(git -C "${ROOT}" rev-parse "${TAG_REF}")"
    printf 'dry-run: would push %s:refs/tags/%s\n' "${TAG_SHA}" "${TAG_REF}"
  fi
  exit 0
fi

REMOTE_URL="https://x-access-token:${TOKEN}@github.com/${OWNER}/${REPO}.git"

git init --quiet "${WORKDIR}/mirror"
git -C "${WORKDIR}/mirror" remote add origin "${REMOTE_URL}"
# Fetch GitHub main to verify fast-forward
git -C "${WORKDIR}/mirror" fetch --depth=1 origin main
GITHUB_MAIN="$(git -C "${WORKDIR}/mirror" rev-parse FETCH_HEAD)"

# Ensure local object exists in temp repo via fetch from workspace
git -C "${ROOT}" push --force "${WORKDIR}/mirror" "${MAIN_SHA}:refs/heads/local-main" 2>/dev/null \
  || {
    # Fallback: add local path remote
    git -C "${WORKDIR}/mirror" remote add local "${ROOT}"
    git -C "${WORKDIR}/mirror" fetch local "${MAIN_SHA}"
    git -C "${WORKDIR}/mirror" update-ref refs/heads/local-main "${MAIN_SHA}"
  }

# Fast-forward check: GITHUB_MAIN must be ancestor of MAIN_SHA
if ! git -C "${ROOT}" merge-base --is-ancestor "${GITHUB_MAIN}" "${MAIN_SHA}"; then
  printf 'error: GitHub main (%s) is not an ancestor of Forgejo tip (%s); refusing non-ff push\n' \
    "${GITHUB_MAIN}" "${MAIN_SHA}" >&2
  exit 1
fi

git -C "${WORKDIR}/mirror" push origin "${MAIN_SHA}:refs/heads/main"

if [[ -n "${TAG_REF}" ]]; then
  TAG_SHA="$(git -C "${ROOT}" rev-parse "${TAG_REF}")"
  git -C "${WORKDIR}/mirror" push origin "${TAG_SHA}:refs/tags/${TAG_REF}"
  printf 'Published tag %s (%s)\n' "${TAG_REF}" "${TAG_SHA}"
fi

printf 'Published main (%s)\n' "${MAIN_SHA}"
```

> **Note for implementer:** If the “push into temp repo” dance is awkward on the runner, simplify to: from `${ROOT}`, `git push "https://x-access-token:${TOKEN}@github.com/${OWNER}/${REPO}.git" "${MAIN_SHA}:refs/heads/main"` after a `git ls-remote` / merge-base check. Prefer the simpler form if Step 2 dry-run + a manual token test succeed. Keep the fast-forward ancestor check either way.

- [ ] **Step 2: Prefer simplified push implementation if needed**

If Step 1’s temp-repo approach is brittle, replace the body after token checks with:

```bash
ROOT="$(git rev-parse --show-toplevel)"
MAIN_SHA="$(git rev-parse refs/heads/main 2>/dev/null || git rev-parse HEAD)"
OWNER="${GITHUB_MIRROR_OWNER:-coreyhines}"
REPO="${GITHUB_MIRROR_REPO:-ztpbootstrap}"
REMOTE_URL="https://x-access-token:${TOKEN}@github.com/${OWNER}/${REPO}.git"

if [[ "${DRY_RUN}" -eq 1 ]]; then
  printf 'dry-run: would push %s → github.com/%s/%s main\n' "${MAIN_SHA}" "${OWNER}" "${REPO}"
  [[ -z "${TAG_REF}" ]] || printf 'dry-run: would push tag %s\n' "${TAG_REF}"
  exit 0
fi

GITHUB_MAIN="$(git ls-remote "${REMOTE_URL}" refs/heads/main | awk '{print $1}')"
if [[ -n "${GITHUB_MAIN}" ]]; then
  if ! git merge-base --is-ancestor "${GITHUB_MAIN}" "${MAIN_SHA}"; then
    printf 'error: refusing non-fast-forward publish (%s ↛ %s)\n' "${GITHUB_MAIN}" "${MAIN_SHA}" >&2
    exit 1
  fi
fi

git push "${REMOTE_URL}" "${MAIN_SHA}:refs/heads/main"
if [[ -n "${TAG_REF}" ]]; then
  git push "${REMOTE_URL}" "refs/tags/${TAG_REF}:refs/tags/${TAG_REF}"
fi
```

Use this simplified version as the **canonical** script content to commit if the first draft fails local dry-run logic tests.

- [ ] **Step 3: Make executable and dry-run**

```bash
chmod +x scripts/publish-github-mirror.sh
shellcheck -S error scripts/publish-github-mirror.sh
./scripts/publish-github-mirror.sh --dry-run
./scripts/publish-github-mirror.sh --dry-run --tag v0.0.0-test 2>&1 | head -5 || true
```

Expected: shellcheck clean; dry-run without tag prints would-push main; fake tag may fail rev-parse — that is OK. For tag dry-run, use an existing tag or omit `--tag` until a real tag exists:

```bash
./scripts/publish-github-mirror.sh --dry-run
```

Expected exit 0 and a “dry-run: would push …” line.

- [ ] **Step 4: Commit**

```bash
git add scripts/publish-github-mirror.sh
git commit -m "$(cat <<'EOF'
feat(ci): add GitHub mirror publish script

Pushes main (and optional v* tags) to GitHub after Forgejo CI gates,
with dry-run support and fast-forward checks.
EOF
)"
```

---

### Task 3: Wire `publish-github` into Forgejo CI

**Files:**
- Modify: `.forgejo/workflows/ci.yml` (header comments, `on:` tags, new job)

**Interfaces:**
- Consumes: `scripts/publish-github-mirror.sh`; jobs `secret-scan`, `lint`, `dependency-scan`, `sbom`, `test`; secret `GITHUB_MIRROR_TOKEN`
- Produces: CI workflow that publishes only on green `main` / `v*` tag pushes

- [ ] **Step 1: Update header comments**

Replace the top comment block in `.forgejo/workflows/ci.yml` with:

```yaml
---
# Forgejo-native CI for ztpbootstrap.
#
# GitHub is a public mirror face only (main + v* tags). It does not run CI.
# See docs/FORGEJO_GITHUB_MIRROR.md.
#
# Runtime notes for this Forgejo instance:
#   * runs-on targets the `strongpod` runner; `ubuntu-latest` matches no
#     runner on this instance.
#   * Actions are fully qualified to data.forgejo.org.
#   * Secret scanners / SBOM / dependency audit invoke underlying tools
#     directly (see scripts/secret-scan.sh).
#   * No upload-artifact steps: that action is known to fail against this
#     Forgejo instance, so reports are written to the job log instead.
```

- [ ] **Step 2: Extend `on:` for release tags**

Change the `on:` block to:

```yaml
on:
  push:
    branches:
      - main
      - develop
      - feature/*
    tags:
      - "v*"
  pull_request:
  workflow_dispatch:
```

- [ ] **Step 3: Append `publish-github` job at end of file**

```yaml
  publish-github:
    name: Publish main/tags to GitHub
    needs: [secret-scan, lint, dependency-scan, sbom, test]
    if: >
      github.event_name == 'push' &&
      (github.ref == 'refs/heads/main' || startsWith(github.ref, 'refs/tags/v'))
    runs-on: strongpod
    container:
      image: docker.io/library/python:3.12-bookworm
    timeout-minutes: 15
    env:
      GITHUB_MIRROR_TOKEN: ${{ secrets.GITHUB_MIRROR_TOKEN }}
    steps:
      - name: Install git
        run: apt-get update && apt-get install -y --no-install-recommends git ca-certificates

      - uses: https://data.forgejo.org/actions/checkout@v6
        with:
          fetch-depth: 0
          persist-credentials: false

      - name: Mask mirror token
        run: |
          if [ -n "${GITHUB_MIRROR_TOKEN:-}" ]; then
            printf '::add-mask::%s\n' "${GITHUB_MIRROR_TOKEN}"
          fi

      - name: Publish to GitHub
        run: |
          set -euo pipefail
          chmod +x scripts/publish-github-mirror.sh
          if [ "${GITHUB_REF_TYPE}" = "tag" ]; then
            ./scripts/publish-github-mirror.sh --tag "${GITHUB_REF_NAME}"
          else
            ./scripts/publish-github-mirror.sh
          fi
```

- [ ] **Step 4: Validate YAML locally**

```bash
yamllint .forgejo/workflows/ci.yml
python3 -c "import yaml; yaml.safe_load(open('.forgejo/workflows/ci.yml'))"
```

Expected: no errors (or only accepted yamllint warnings already used in repo)

- [ ] **Step 5: Commit**

```bash
git add .forgejo/workflows/ci.yml
git commit -m "$(cat <<'EOF'
ci(forgejo): publish main and v* tags to GitHub after green CI

Gate the public mirror on secret-scan and the full Forgejo CI suite so
GitHub only advances when checks pass.
EOF
)"
```

---

### Task 4: Documentation

**Files:**
- Create: `docs/FORGEJO_GITHUB_MIRROR.md`
- Modify: `README.md` (Quick start + Support)
- Modify: `docs/QUICK_START.md` (clone blurb)
- Modify: `docs/CI_TESTING.md` (Forgejo wording)

**Interfaces:**
- Consumes: policy from the design spec
- Produces: docs that state clone=GitHub, develop/CI=Forgejo

- [ ] **Step 1: Write `docs/FORGEJO_GITHUB_MIRROR.md`**

```markdown
# Forgejo → GitHub mirror

## Roles

| Host | Role |
|------|------|
| **Forgejo** (`forgejo.freeblizz.com/coreyhines/ztpbootstrap`) | Development: branches, merge requests, CI |
| **GitHub** (`github.com/coreyhines/ztpbootstrap`) | Public clone/fork face: `main` and `v*` tags only |

## What gets published

After Forgejo CI passes on a push to `main` or a `v*` tag (jobs: secret-scan, lint, dependency-scan, sbom, test), the `publish-github` job runs `scripts/publish-github-mirror.sh` and fast-forward updates GitHub.

Feature branches are **not** mirrored. Do not add a `github` git remote for day-to-day work.

## CI

All CI runs on Forgejo (`.forgejo/workflows/`). GitHub Actions are disabled and `.github/workflows/` is not present.

## Operator notes

- Forgejo Actions secret: `GITHUB_MIRROR_TOKEN` (fine-grained PAT, Contents: Read and write, this repo only).
- Normal publishes never force-push GitHub `main`.
- History rewrites on Forgejo `main` need a separate recovery procedure before GitHub can follow.
```

- [ ] **Step 2: Update README Quick start and Support**

In `README.md` Quick start block, keep the GitHub clone URL, then add one line after the clone commands:

```markdown
Public clones use GitHub. Development, merge requests, and CI run on
[Forgejo](https://forgejo.freeblizz.com/coreyhines/ztpbootstrap)
([mirror policy](docs/FORGEJO_GITHUB_MIRROR.md)).
```

In Support, change Issues to prefer Forgejo if that is where issues live; if issues remain on GitHub for public users, keep GitHub Issues but add Forgejo for maintainers:

```markdown
- **This project:** [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) · [GitHub Issues](https://github.com/coreyhines/ztpbootstrap/issues) · [Forgejo](https://forgejo.freeblizz.com/coreyhines/ztpbootstrap) ([mirror policy](docs/FORGEJO_GITHUB_MIRROR.md))
```

- [ ] **Step 3: Update `docs/QUICK_START.md` clone section**

After the `git clone https://github.com/coreyhines/ztpbootstrap.git` example, add:

```markdown
> Development happens on Forgejo; GitHub mirrors `main` and release tags after CI. See [FORGEJO_GITHUB_MIRROR.md](FORGEJO_GITHUB_MIRROR.md).
```

- [ ] **Step 4: Fix `docs/CI_TESTING.md` GitHub Actions line**

Replace any “Requires GitHub Actions secrets” with wording like “Requires Forgejo Actions secrets on the Forgejo CI runner.”

- [ ] **Step 5: Commit**

```bash
git add docs/FORGEJO_GITHUB_MIRROR.md README.md docs/QUICK_START.md docs/CI_TESTING.md
git commit -m "$(cat <<'EOF'
docs: document Forgejo development and GitHub mirror roles

Clarify that clones may use GitHub while CI and day-to-day development
stay on Forgejo.
EOF
)"
```

---

### Task 5: Create GitHub PAT and Forgejo secret (manual)

**Files:** none in git

**Interfaces:**
- Consumes: GitHub account with admin on `coreyhines/ztpbootstrap`
- Produces: Forgejo Actions secret `GITHUB_MIRROR_TOKEN`

- [ ] **Step 1: Create fine-grained PAT on GitHub**

1. GitHub → Settings → Developer settings → Fine-grained personal access tokens → Generate
2. Resource owner: your user; Repository access: **Only select** `ztpbootstrap`
3. Permissions: **Contents: Read and write**; Metadata: Read
4. Expiration: choose a remembered rotation date (e.g. 90 days)
5. Copy the token once; store in your password manager

- [ ] **Step 2: Add Forgejo Actions secret**

1. Open `https://forgejo.freeblizz.com/coreyhines/ztpbootstrap/settings/actions/secrets`
2. Add secret name exactly: `GITHUB_MIRROR_TOKEN`
3. Paste the PAT; save

- [ ] **Step 3: Smoke-test push auth without changing remotes permanently**

```bash
# From a throwaway clone or with env only — do NOT git remote add github
export GITHUB_MIRROR_TOKEN='…'   # from password manager; do not commit
./scripts/publish-github-mirror.sh --dry-run
# Optional live test ONLY after Task 6 scrub decision / when ready to sync main:
# ./scripts/publish-github-mirror.sh
unset GITHUB_MIRROR_TOKEN
```

Expected dry-run: exit 0. Live test (if run): GitHub `main` fast-forwards to Forgejo tip.

- [ ] **Step 4: Record completion in the MR/PR description** (no secret values)

Note: “`GITHUB_MIRROR_TOKEN` configured on Forgejo” — never paste the token.

---

### Task 6: Remove local `github` remote

**Files:** none (local git config only); mention in `docs/FORGEJO_GITHUB_MIRROR.md` already covers policy

**Interfaces:**
- Consumes: existing local remote named `github`
- Produces: only `origin` → Forgejo

- [ ] **Step 1: Inspect remotes**

```bash
git remote -v
```

Expected before: `origin` (Forgejo) and `github` (GitHub)

- [ ] **Step 2: Remove GitHub remote**

```bash
git remote remove github
git remote -v
```

Expected: only `origin` pointing at `ssh://git@forgejo.freeblizz.com/coreyhines/ztpbootstrap.git`

- [ ] **Step 3: Repeat in other worktrees if present**

```bash
git worktree list
# for each worktree path:
#   git -C "$path" remote remove github 2>/dev/null || true
```

No commit (local config only).

---

### Task 7: Scrub GitHub (PRs, branches, disable Actions)

**Files:** none in git

**Interfaces:**
- Consumes: `gh` authenticated to `coreyhines/ztpbootstrap`
- Produces: GitHub with only `main` (plus any tags later); Actions disabled; no open PRs

- [ ] **Step 1: Close open PRs**

```bash
gh pr list --repo coreyhines/ztpbootstrap --state open --json number,title
gh pr close 70 --repo coreyhines/ztpbootstrap --comment "Closed: development moved to Forgejo; GitHub is mirror-only (main + tags)."
gh pr close 69 --repo coreyhines/ztpbootstrap --comment "Closed: development moved to Forgejo; GitHub is mirror-only (main + tags)."
gh pr close 68 --repo coreyhines/ztpbootstrap --comment "Closed: development moved to Forgejo; GitHub is mirror-only (main + tags)."
gh pr close 48 --repo coreyhines/ztpbootstrap --comment "Closed: Dependabot disabled; CI runs on Forgejo only."
gh pr close 47 --repo coreyhines/ztpbootstrap --comment "Closed: Dependabot disabled; CI runs on Forgejo only."
gh pr close 45 --repo coreyhines/ztpbootstrap --comment "Closed: Dependabot disabled; CI runs on Forgejo only."
gh pr close 44 --repo coreyhines/ztpbootstrap --comment "Closed: Dependabot disabled; CI runs on Forgejo only."
gh pr close 43 --repo coreyhines/ztpbootstrap --comment "Closed: Dependabot disabled; CI runs on Forgejo only."
gh pr list --repo coreyhines/ztpbootstrap --state open
```

Expected: empty open list

- [ ] **Step 2: Delete non-`main` branches**

```bash
gh api repos/coreyhines/ztpbootstrap/branches --paginate --jq '.[].name' | grep -v '^main$' | while read -r b; do
  printf 'Deleting %s\n' "$b"
  gh api -X DELETE "repos/coreyhines/ztpbootstrap/git/refs/heads/${b}"
done
gh api repos/coreyhines/ztpbootstrap/branches --jq '.[].name'
```

Expected: only `main`

- [ ] **Step 3: Disable GitHub Actions**

```bash
gh api -X PUT repos/coreyhines/ztpbootstrap/actions/permissions \
  -f enabled=false \
  -f allowed_actions=selected
gh api repos/coreyhines/ztpbootstrap/actions/permissions
```

Expected: `"enabled": false`

- [ ] **Step 4: Disable Dependabot alerts/PRs if enabled (optional but recommended)**

```bash
gh api -X DELETE repos/coreyhines/ztpbootstrap/vulnerability-alerts 2>/dev/null || true
# Also turn off Dependabot in GitHub UI: Settings → Code security → Dependabot
```

---

### Task 8: Land on Forgejo `main`, first publish, then go public

**Files:** merge the feature branch via Forgejo MR (this plan’s commits)

**Interfaces:**
- Consumes: Tasks 1–7 complete; `GITHUB_MIRROR_TOKEN` set; GitHub Actions disabled
- Produces: GitHub `main` == Forgejo `main`; repo public after secret-scan confirmation

- [ ] **Step 1: Open / merge Forgejo MR**

Push branch (if not already) and merge into `main` on Forgejo:

```bash
git push -u origin HEAD
# Open MR: docs/forgejo-github-public-mirror (or implementation branch) → main
# Merge when CI on the MR is green
```

- [ ] **Step 2: Confirm CI on `main` including `publish-github`**

After merge, watch Forgejo Actions for the `main` push run. All of `secret-scan`, `lint`, `dependency-scan`, `sbom`, `test`, `publish-github` must be green.

If `publish-github` fails on missing secret, fix Task 5 and re-run workflow_dispatch or empty commit on `main` **only if necessary**.

- [ ] **Step 3: Verify GitHub `main` matches**

```bash
# Read-only compare without adding a remote:
forgejo_main=$(git ls-remote ssh://git@forgejo.freeblizz.com/coreyhines/ztpbootstrap.git refs/heads/main | awk '{print $1}')
github_main=$(git ls-remote https://github.com/coreyhines/ztpbootstrap.git refs/heads/main | awk '{print $1}')
printf 'forgejo=%s\ngithub=%s\n' "$forgejo_main" "$github_main"
test "$forgejo_main" = "$github_main" && echo MATCH
```

Expected: `MATCH`

- [ ] **Step 4: Confirm secret-scan clean on published tip**

Use the green `secret-scan` job on that same Forgejo run as the authority. Optionally re-run locally:

```bash
./scripts/secret-scan.sh ci
```

Expected: exit 0

- [ ] **Step 5: Make GitHub repository public**

```bash
gh repo edit coreyhines/ztpbootstrap --visibility public --accept-visibility-change-consequences
gh api repos/coreyhines/ztpbootstrap --jq '{private:.private,visibility:.visibility}'
```

Expected: `"private": false`, `"visibility": "public"`

- [ ] **Step 6: Final checklist against success criteria**

| Criterion | Check |
|-----------|--------|
| No local `github` remote | `git remote -v` |
| No `.github/workflows` | `test ! -e .github/workflows` |
| Actions disabled | `gh api …/actions/permissions` → enabled false |
| Green CI required to publish | documented + publish job `needs:` + `if:` |
| Only `main` (+ later tags) on GitHub | `gh api …/branches` |
| Public after clean scan | Steps 4–5 |

- [ ] **Step 7: Commit nothing further unless docs need a “went public on DATE” note**

Optional one-liner in `docs/FORGEJO_GITHUB_MIRROR.md`:

```markdown
## Status

GitHub public mirror enabled (CI-gated) as of YYYY-MM-DD.
```

Commit only if you add that note:

```bash
git commit -am "docs: record GitHub public mirror go-live date"
```

---

## Spec coverage (self-review)

| Spec requirement | Task |
|------------------|------|
| CI-gated publish of `main` + `v*` | Tasks 2–3, 8 |
| Delete `.github/workflows` + disable Actions | Tasks 1, 7 |
| Forgejo secret `GITHUB_MIRROR_TOKEN` | Task 5 |
| Remove local `github` remote | Task 6 |
| Close PRs / delete non-main branches | Task 7 |
| Docs clone=GitHub, develop=Forgejo | Task 4 |
| Public only after clean secret-scan | Task 8 |
| No force-push / FF only | Task 2 script |
| Out of scope: branch cleanup on Forgejo, Releases UI | Not in plan |

## Placeholder scan

No TBD/TODO left in task steps; scripts and YAML are inlined; scrub PR numbers are explicit.
