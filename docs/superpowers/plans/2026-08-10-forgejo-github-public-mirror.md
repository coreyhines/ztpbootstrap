# Forgejo → GitHub Public Mirror Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Forgejo the only development remote and CI system, and publish only `main` plus `v*` tags to GitHub after Forgejo CI (including secret-scan) passes.

**Architecture:** Delete GitHub Actions workflows and Dependabot config. Extend Forgejo CI with a gated `publish-github` job that uses `scripts/publish-github-mirror.sh` and Forgejo secret `MIRROR_GITHUB_TOKEN`. Scrub the GitHub repo (close PRs, delete extra branches, disable Actions and Issues), remove the local `github` remote, then flip the GitHub repo public only after a clean publish.

**Tech Stack:** Forgejo Actions (strongpod runner), bash + git, GitHub fine-grained PAT, `gh` CLI for one-time scrub.

**Spec:** `docs/superpowers/specs/2026-08-10-forgejo-github-public-mirror-design.md`

## Global Constraints

- Publish refs: `main` and release tags matching `v*` only — never feature branches
- Auth: Forgejo secret `MIRROR_GITHUB_TOKEN` only (Forgejo rejects names starting with `GITHUB_`); never commit tokens; never put the token on the process command line
- Tag publish pushes the tag only; main publish pushes `main` only
- Publish gate = jobs in `.forgejo/workflows/ci.yml` only — **not** `dhcp-integration-test.yml`
- No force-push to GitHub `main` in the automated job (fast-forward only)
- GitHub stays private until first green publish + confirmed clean secret-scan on that tip
- GitHub Issues disabled; Forgejo is the issue/MR SoT
- Local clones must not have a `github` push remote after Task 6
- Podman, not Docker, for any container work in this repo (unchanged)

## File map

| Path | Responsibility |
|------|----------------|
| `.github/workflows/ci.yml` | **Delete** |
| `.github/workflows/dhcp-integration-test.yml` | **Delete** |
| `.github/workflows/secret-scan.yml` | **Delete** |
| `.github/dependabot.yml` | **Delete** (Dependabot off; avoid silent `rm -rf`) |
| `.github/` (dir) | Remove after the above deletes leave it empty |
| `.forgejo/workflows/ci.yml` | CI jobs + `on.tags` + `publish-github` job; fix header comments |
| `.forgejo/workflows/dhcp-integration-test.yml` | **Unchanged** — still runs on Forgejo; does **not** gate publish |
| `scripts/publish-github-mirror.sh` | **Create** — FF-push `main` **or** push one `v*` tag (distinct modes) |
| `docs/FORGEJO_GITHUB_MIRROR.md` | **Create** — operator/developer mirror policy + break-glass note |
| `README.md` | Point clone at GitHub; contribute/CI/issues at Forgejo; link mirror doc |
| `docs/QUICK_START.md` | Keep public clone URL on GitHub; note development is on Forgejo |
| `docs/CI_TESTING.md` | Replace “GitHub Actions secrets” with Forgejo CI wording where needed |
| Other `*.md` with “GitHub Actions as CI” | Grep sweep in Task 4; update operational docs only |

---

### Task 1: Remove GitHub Actions workflows and Dependabot

**Files:**
- Delete: `.github/workflows/ci.yml`
- Delete: `.github/workflows/dhcp-integration-test.yml`
- Delete: `.github/workflows/secret-scan.yml`
- Delete: `.github/dependabot.yml`
- Delete: `.github/` (empty after the above)

**Interfaces:**
- Consumes: none
- Produces: repo with no GitHub workflow YAML and no Dependabot config

- [ ] **Step 1: Confirm files exist**

```bash
ls -la .github/workflows/
ls -la .github/dependabot.yml
```

Expected: three workflow files + `dependabot.yml`

- [ ] **Step 2: Delete each path explicitly**

```bash
rm -f .github/workflows/ci.yml \
      .github/workflows/dhcp-integration-test.yml \
      .github/workflows/secret-scan.yml \
      .github/dependabot.yml
rmdir .github/workflows
rmdir .github
```

Do **not** use `rm -rf .github` as a shortcut that hides unexpected files. If `rmdir .github` fails, run `find .github -type f` and decide explicitly before deleting leftovers.

- [ ] **Step 3: Verify gone**

```bash
test ! -e .github && echo "github dir removed"
git status -sb
```

Expected: `.github` gone

- [ ] **Step 4: Commit**

```bash
git add -A .github
git commit -m "$(cat <<'EOF'
ci: remove GitHub Actions workflows and Dependabot

CI runs on Forgejo only; GitHub is a public mirror face and must not
execute Actions or open Dependabot PRs from mirrored pushes.
EOF
)"
```

---

### Task 2: Add publish script (simplified, dual-mode)

**Files:**
- Create: `scripts/publish-github-mirror.sh`
- Test: `--dry-run` + `shellcheck`

**Interfaces:**
- Consumes: env `MIRROR_GITHUB_TOKEN` (required unless `--dry-run`); optional `MIRROR_GITHUB_OWNER` (default `coreyhines`), `MIRROR_GITHUB_REPO` (default `ztpbootstrap`)
- Produces: script with two modes — default/main mode FF-pushes `main`; `--tag v…` mode pushes that tag only
- Auth: `http.extraHeader` with **Basic** `x-access-token:<PAT>` (GitHub's git-over-HTTPS scheme; Bearer is Azure DevOps and does not authenticate here), passed via `GIT_CONFIG_*` env so the PAT is never in the remote URL **or** in `ps` output

- [ ] **Step 1: Write the canonical script**

Create `scripts/publish-github-mirror.sh` with exactly this content (simplified implementation only — no temp-repo draft):

```bash
#!/usr/bin/env bash
# Push Forgejo main OR one v* tag to GitHub after CI gates.
# Modes are distinct: --tag never updates refs/heads/main.
# Usage:
#   publish-github-mirror.sh [--dry-run]
#   publish-github-mirror.sh [--dry-run] --tag v1.2.3
# Env:
#   MIRROR_GITHUB_TOKEN  required unless --dry-run
#   MIRROR_GITHUB_OWNER   default coreyhines
#   MIRROR_GITHUB_REPO    default ztpbootstrap
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

OWNER="${MIRROR_GITHUB_OWNER:-coreyhines}"
REPO="${MIRROR_GITHUB_REPO:-ztpbootstrap}"
TOKEN="${MIRROR_GITHUB_TOKEN:-}"

if [[ "${DRY_RUN}" -eq 0 && -z "${TOKEN}" ]]; then
  printf 'error: MIRROR_GITHUB_TOKEN is required (or pass --dry-run)\n' >&2
  exit 1
fi

if [[ -n "${TAG_REF}" && ! "${TAG_REF}" =~ ^v[0-9] ]]; then
  printf 'error: --tag must look like a release tag (v…), got %s\n' "${TAG_REF}" >&2
  exit 1
fi

if [[ -n "${TOKEN}" ]]; then
  printf '::add-mask::%s\n' "${TOKEN}"
fi

ROOT="$(git rev-parse --show-toplevel)"
cd "${ROOT}"

# Remote URL without credentials (token goes in http.extraHeader only).
REMOTE_URL="https://github.com/${OWNER}/${REPO}.git"

# GitHub's git-over-HTTPS wants Basic with the x-access-token: prefix — the
# same header actions/checkout writes. Bearer is an Azure DevOps convention
# and is NOT accepted here.
#
# The header goes through GIT_CONFIG_* env vars rather than `git -c`, because
# `git -c "http.extraHeader=…"` puts the PAT in argv, where any user on the
# runner can read it out of `ps`. Environment is not world-readable on Linux.
#
# `base64 | tr -d '\n'` instead of `base64 -w0`: macOS base64 has no -w flag
# and this script is also run by hand during setup.
git_auth() {
  local hdr
  hdr="AUTHORIZATION: basic $(printf 'x-access-token:%s' "${TOKEN}" | base64 | tr -d '\n')"
  GIT_CONFIG_COUNT=1 \
  GIT_CONFIG_KEY_0=http.extraHeader \
  GIT_CONFIG_VALUE_0="${hdr}" \
    git "$@"
}

if [[ -n "${TAG_REF}" ]]; then
  TAG_SHA="$(git rev-parse "refs/tags/${TAG_REF}" 2>/dev/null || git rev-parse "${TAG_REF}")"
  printf 'Publishing tag %s (%s) to github.com/%s/%s\n' \
    "${TAG_REF}" "${TAG_SHA}" "${OWNER}" "${REPO}"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    printf 'dry-run: would push %s:refs/tags/%s (main unchanged)\n' \
      "${TAG_SHA}" "${TAG_REF}"
    exit 0
  fi
  git_auth push "${REMOTE_URL}" "${TAG_SHA}:refs/tags/${TAG_REF}"
  printf 'Published tag %s (%s); GitHub main not modified\n' "${TAG_REF}" "${TAG_SHA}"
  exit 0
fi

# Main mode: resolve main explicitly — never use detached HEAD as main.
if git show-ref --verify --quiet refs/heads/main; then
  MAIN_SHA="$(git rev-parse refs/heads/main)"
elif git show-ref --verify --quiet refs/remotes/origin/main; then
  MAIN_SHA="$(git rev-parse refs/remotes/origin/main)"
else
  printf 'error: cannot resolve main (no refs/heads/main or origin/main)\n' >&2
  exit 1
fi

printf 'Publishing main=%s to github.com/%s/%s\n' "${MAIN_SHA}" "${OWNER}" "${REPO}"

if [[ "${DRY_RUN}" -eq 1 ]]; then
  printf 'dry-run: would push %s:refs/heads/main\n' "${MAIN_SHA}"
  exit 0
fi

GITHUB_MAIN="$(git_auth ls-remote "${REMOTE_URL}" refs/heads/main | awk '{print $1}')"
if [[ -n "${GITHUB_MAIN}" ]]; then
  # The first check fails harmlessly ("not a valid object name") when the
  # GitHub tip is absent locally, which is exactly the diverged case; fetch
  # it and re-check so the refusal below is a real ancestry verdict.
  #
  # No --depth here: a shallow fetch writes .git/shallow into whatever repo
  # this runs in, which would quietly truncate a developer's working clone.
  if ! git merge-base --is-ancestor "${GITHUB_MAIN}" "${MAIN_SHA}" 2>/dev/null; then
    CHECK_REF="refs/mirror-check/github-main"
    cleanup_check_ref() { git update-ref -d "${CHECK_REF}" 2>/dev/null || true; }
    trap cleanup_check_ref EXIT
    git_auth fetch --quiet "${REMOTE_URL}" "+refs/heads/main:${CHECK_REF}"
    GITHUB_MAIN="$(git rev-parse "${CHECK_REF}")"
    if ! git merge-base --is-ancestor "${GITHUB_MAIN}" "${MAIN_SHA}"; then
      printf 'error: refusing non-fast-forward publish (%s ↛ %s)\n' \
        "${GITHUB_MAIN}" "${MAIN_SHA}" >&2
      printf 'see docs/FORGEJO_GITHUB_MIRROR.md "Break-glass" before forcing anything\n' >&2
      exit 1
    fi
  fi
fi

git_auth push "${REMOTE_URL}" "${MAIN_SHA}:refs/heads/main"
printf 'Published main (%s)\n' "${MAIN_SHA}"
```

- [ ] **Step 2: Make executable and dry-run**

```bash
chmod +x scripts/publish-github-mirror.sh
shellcheck -S error scripts/publish-github-mirror.sh
./scripts/publish-github-mirror.sh --dry-run
```

Expected: shellcheck clean; exit 0; line containing `dry-run: would push` and `refs/heads/main`

- [ ] **Step 3: Dry-run tag mode without inventing a tag**

```bash
# If no v* tag exists, create a local annotated throwaway for dry-run only, then delete:
git tag -a v0.0.0-mirror-dryrun -m 'dry-run' HEAD
./scripts/publish-github-mirror.sh --dry-run --tag v0.0.0-mirror-dryrun
git tag -d v0.0.0-mirror-dryrun
```

Expected: `dry-run: would push …:refs/tags/v0.0.0-mirror-dryrun (main unchanged)`

- [ ] **Step 4: Commit**

```bash
git add scripts/publish-github-mirror.sh
git commit -m "$(cat <<'EOF'
feat(ci): add GitHub mirror publish script

Distinct main vs tag modes, fast-forward checks, and Basic auth via
http.extraHeader passed through GIT_CONFIG_* so the PAT reaches git
without landing in the remote URL or in ps output.
EOF
)"
```

---

### Task 3: Wire `publish-github` into Forgejo CI

**Files:**
- Modify: `.forgejo/workflows/ci.yml`

**Interfaces:**
- Consumes: `scripts/publish-github-mirror.sh`; jobs `secret-scan`, `lint`, `dependency-scan`, `sbom`, `test`; secret `MIRROR_GITHUB_TOKEN`
- Produces: CI workflow that publishes only on green `main` / `v*` tag pushes
- Does **not** `needs:` anything from `dhcp-integration-test.yml`

- [ ] **Step 1: Update header comments**

Replace the top comment block in `.forgejo/workflows/ci.yml` with:

```yaml
---
# Forgejo-native CI for ztpbootstrap.
#
# GitHub is a public mirror face only (main + v* tags). It does not run CI.
# See docs/FORGEJO_GITHUB_MIRROR.md.
#
# publish-github is gated on jobs in THIS file only. The separate
# dhcp-integration-test workflow does not block the public mirror.
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
      MIRROR_GITHUB_TOKEN: ${{ secrets.MIRROR_GITHUB_TOKEN }}
    steps:
      - name: Install git
        run: apt-get update && apt-get install -y --no-install-recommends git ca-certificates

      - uses: https://data.forgejo.org/actions/checkout@v6
        with:
          fetch-depth: 0
          persist-credentials: false

      - name: Mask mirror token
        run: |
          if [ -n "${MIRROR_GITHUB_TOKEN:-}" ]; then
            printf '::add-mask::%s\n' "${MIRROR_GITHUB_TOKEN}"
          fi

      - name: Publish to GitHub
        env:
          # Prefer context over env GITHUB_REF_TYPE (not reliably exported).
          REF: ${{ github.ref }}
          REF_NAME: ${{ github.ref_name }}
        run: |
          set -euo pipefail
          chmod +x scripts/publish-github-mirror.sh
          case "${REF}" in
            refs/tags/v*)
              ./scripts/publish-github-mirror.sh --tag "${REF_NAME}"
              ;;
            refs/heads/main)
              ./scripts/publish-github-mirror.sh
              ;;
            *)
              printf 'error: publish-github if: matched unexpected ref %s\n' "${REF}" >&2
              exit 1
              ;;
          esac
```

- [ ] **Step 4: Validate YAML locally**

```bash
yamllint .forgejo/workflows/ci.yml
python3 -c "import yaml; yaml.safe_load(open('.forgejo/workflows/ci.yml'))"
```

Expected: parse succeeds

- [ ] **Step 5: Commit**

```bash
git add .forgejo/workflows/ci.yml
git commit -m "$(cat <<'EOF'
ci(forgejo): publish main and v* tags to GitHub after green CI

Gate the public mirror on ci.yml jobs only; tag mode does not move main.
EOF
)"
```

---

### Task 4: Documentation

**Files:**
- Create: `docs/FORGEJO_GITHUB_MIRROR.md`
- Modify: `README.md`, `docs/QUICK_START.md`, `docs/CI_TESTING.md`
- Possibly modify (after grep): `docs/TESTING.md`, `docs/DHCP_AUTOMATED_TESTING.md`, `dhcp/README.md`, `TEST_AUTOMATION_SUMMARY.md`, `docs/KNOWN_ISSUES.md`

**Interfaces:**
- Consumes: amended design spec
- Produces: docs stating clone=GitHub; develop/CI/issues=Forgejo; Issues disabled on GitHub

- [ ] **Step 1: Write `docs/FORGEJO_GITHUB_MIRROR.md`**

```markdown
# Forgejo → GitHub mirror

## Roles

| Host | Role |
|------|------|
| **Forgejo** (`forgejo.freeblizz.com/coreyhines/ztpbootstrap`) | Development: branches, merge requests, issues, CI |
| **GitHub** (`github.com/coreyhines/ztpbootstrap`) | Public clone/fork face: `main` and `v*` tags only |

GitHub **Issues** and **Actions** are disabled. Do not file bugs on GitHub.

## What gets published

After Forgejo CI passes on a push to `main` or a `v*` tag (jobs in `.forgejo/workflows/ci.yml`: secret-scan, lint, dependency-scan, sbom, test), the `publish-github` job runs `scripts/publish-github-mirror.sh`:

- `main` push → fast-forward GitHub `main`
- `v*` tag push → publish that tag only (does not move GitHub `main`)

The separate `dhcp-integration-test` workflow does **not** gate the mirror.

Feature branches are not mirrored. Do not add a `github` git remote for day-to-day work.

## Operator notes

- Forgejo Actions secret: `MIRROR_GITHUB_TOKEN` (fine-grained PAT, Contents: Read and write, this repo only). Forgejo rejects secret names starting with `GITHUB_`, `GITEA_`, or `FORGEJO_`.
- **PAT expires: YYYY-MM-DD.** Rotate before then. On expiry, `publish-github` fails on every `main` push and GitHub stops advancing — the failure looks like a broken build, so check the token first.
- Normal publishes never force-push GitHub `main`.
- Auth uses Basic `x-access-token:<PAT>` in `http.extraHeader`, supplied through `GIT_CONFIG_*` environment variables — the PAT is in neither the remote URL nor `ps` output. (`git -c http.extraHeader=…` would put it in argv; don't.)

## Break-glass (history rewrite)

If Forgejo `main` is rewritten so GitHub `main` is no longer an ancestor, the automated job will refuse to publish. Recovery is manual and out of band:

1. Decide whether GitHub should be force-updated at all (usually only after coordinating consumers).
2. From a trusted machine with the PAT:  
   `git push --force-with-lease https://github.com/coreyhines/ztpbootstrap.git <forgejo-main-sha>:refs/heads/main`
3. Do **not** add a permanent force-push path to CI.
```

- [ ] **Step 2: Update README Quick start and Support**

After the clone commands in Quick start, add:

```markdown
Public clones use GitHub. Development, merge requests, issues, and CI run on
[Forgejo](https://forgejo.freeblizz.com/coreyhines/ztpbootstrap)
([mirror policy](docs/FORGEJO_GITHUB_MIRROR.md)).
```

Update Support to:

```markdown
- **This project:** [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) · [Forgejo](https://forgejo.freeblizz.com/coreyhines/ztpbootstrap) ([mirror policy](docs/FORGEJO_GITHUB_MIRROR.md))
```

(Remove or demote GitHub Issues links — Issues are disabled on GitHub.)

- [ ] **Step 3: Update `docs/QUICK_START.md`**

After the GitHub clone example, add:

```markdown
> Development happens on Forgejo; GitHub mirrors `main` and release tags after CI. See [FORGEJO_GITHUB_MIRROR.md](FORGEJO_GITHUB_MIRROR.md).
```

- [ ] **Step 4: Fix `docs/CI_TESTING.md`**

Replace “Requires GitHub Actions secrets” (and similar) with Forgejo Actions wording.

- [ ] **Step 5: Grep sweep**

```bash
rg -n -i 'GitHub Actions|\.github/workflows' --glob '*.md' \
  README.md docs/ dhcp/ TEST_AUTOMATION_SUMMARY.md CONTRIBUTING.md AGENTS.md
```

For each hit: update if it describes current CI procedure; leave historical epic/PR footnotes alone.

- [ ] **Step 6: Commit**

```bash
git add docs/FORGEJO_GITHUB_MIRROR.md README.md docs/QUICK_START.md docs/CI_TESTING.md
# plus any other files changed in the sweep
git commit -m "$(cat <<'EOF'
docs: document Forgejo development and GitHub mirror roles

Clone via GitHub; develop, issues, and CI stay on Forgejo. Record
break-glass for non-ff history without enabling CI force-push.
EOF
)"
```

---

### Task 5: Create GitHub PAT and Forgejo secret (manual)

**Files:** none in git

**Interfaces:**
- Consumes: GitHub account with admin on `coreyhines/ztpbootstrap`
- Produces: Forgejo Actions secret `MIRROR_GITHUB_TOKEN`

- [ ] **Step 1: Create fine-grained PAT on GitHub**

1. GitHub → Settings → Developer settings → Fine-grained personal access tokens → Generate
2. Repository access: **Only select** `ztpbootstrap`
3. Permissions: **Contents: Read and write**; Metadata: Read
4. Expiration: choose a remembered rotation date (e.g. 90 days)
5. Copy once; store in password manager

- [ ] **Step 2: Add Forgejo Actions secret**

1. Open repo → Settings → Actions → Secrets
2. Name **exactly**: `MIRROR_GITHUB_TOKEN` (must not start with `GITHUB_`)
3. Paste the PAT; save

- [ ] **Step 3: Prove the token actually authenticates**

`--dry-run` returns before any network call, so it cannot validate a token —
it exits 0 with a garbage value. Round-trip against GitHub instead. This one
command validates the auth scheme, the token, and the PAT's repo scope
together, which is the only check standing between here and a red
`publish-github` on `main`:

```bash
read -rs MIRROR_GITHUB_TOKEN   # paste from password manager; keeps it out of shell history
export MIRROR_GITHUB_TOKEN
hdr="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$MIRROR_GITHUB_TOKEN" | base64 | tr -d '\n')"
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraHeader GIT_CONFIG_VALUE_0="$hdr" \
  git ls-remote https://github.com/coreyhines/ztpbootstrap.git refs/heads/main
unset MIRROR_GITHUB_TOKEN hdr
```

Expected: one line, `<sha>\trefs/heads/main`.

- Empty output or `Repository not found` → PAT is not scoped to this repo (or
  the repo is still private to a PAT that lacks access).
- `could not read Username` / `Authentication failed` → wrong header scheme.
  GitHub's git endpoint wants Basic with the `x-access-token:` prefix; `Bearer`
  does not work here.

Then confirm the script's own plumbing separately:

```bash
./scripts/publish-github-mirror.sh --dry-run
```

Expected: exit 0, prints the `main` SHA it would push.

- [ ] **Step 4: Record completion without secret values**

Note in the MR: “`MIRROR_GITHUB_TOKEN` configured on Forgejo; `ls-remote` auth
probe passed.” Record the PAT's **expiry date** in
`docs/FORGEJO_GITHUB_MIRROR.md` (Operator notes) — when it lapses, every push
to `main` turns `publish-github` red and GitHub silently stops advancing, and
that symptom reads like a broken build rather than an expired credential.

---

### Task 6: Remove local `github` remote

**Files:** none (local git config only)

- [ ] **Step 1: Inspect remotes**

```bash
git remote -v
```

- [ ] **Step 2: Remove GitHub remote**

```bash
git remote remove github
git remote -v
```

Expected: only `origin` → `ssh://git@forgejo.freeblizz.com/coreyhines/ztpbootstrap.git`

- [ ] **Step 3: Repeat in other worktrees**

```bash
git worktree list
# for each path: git -C "$path" remote remove github 2>/dev/null || true
```

No commit.

---

### Task 7: Scrub GitHub (PRs, branches, Actions, Issues)

**Files:** none in git

- [ ] **Step 1: Close all open PRs dynamically**

```bash
gh pr list --repo coreyhines/ztpbootstrap --state open --json number,title
gh pr list --repo coreyhines/ztpbootstrap --state open --json number --jq '.[].number' \
  | while read -r n; do
      gh pr close "$n" --repo coreyhines/ztpbootstrap \
        --comment "Closed: development moved to Forgejo; GitHub is mirror-only (main + tags)."
    done
gh pr list --repo coreyhines/ztpbootstrap --state open
```

Expected: empty open list

- [ ] **Step 2: Delete non-`main` branches**

```bash
gh api repos/coreyhines/ztpbootstrap/branches --paginate --jq '.[].name' \
  | grep -v '^main$' \
  | while read -r b; do
      printf 'Deleting %s\n' "$b"
      gh api -X DELETE "repos/coreyhines/ztpbootstrap/git/refs/heads/${b}"
    done
gh api repos/coreyhines/ztpbootstrap/branches --jq '.[].name'
```

Expected: only `main`

- [ ] **Step 3: Disable GitHub Actions**

```bash
gh api -X PUT repos/coreyhines/ztpbootstrap/actions/permissions -F enabled=false
gh api repos/coreyhines/ztpbootstrap/actions/permissions
```

Expected: `"enabled": false`  
Do **not** send `allowed_actions` when disabling (causes 422).

- [ ] **Step 4: Disable GitHub Issues**

```bash
gh repo edit coreyhines/ztpbootstrap --disable-issues
gh api repos/coreyhines/ztpbootstrap --jq '{has_issues:.has_issues}'
```

Expected: `"has_issues": false`

- [ ] **Step 5: Disable Dependabot / vulnerability alerts if still on**

```bash
gh api -X DELETE repos/coreyhines/ztpbootstrap/vulnerability-alerts 2>/dev/null || true
```

Also confirm in GitHub UI: Settings → Code security → Dependabot off.

---

### Task 8: Land on Forgejo `main`, verify gates, first publish, go public

**Interfaces:**
- Consumes: Tasks 1–7; `MIRROR_GITHUB_TOKEN` set; Actions/Issues disabled
- Produces: GitHub `main` == Forgejo `main`; repo public after clean scan

- [ ] **Step 1: Ancestor pre-check (must pass before first publish)**

Run this as a script (it `exit`s on failure; pasting it into an interactive
shell will close the terminal):

```bash
#!/usr/bin/env bash
set -euo pipefail
forgejo_main=$(git ls-remote ssh://git@forgejo.freeblizz.com/coreyhines/ztpbootstrap.git refs/heads/main | awk '{print $1}')
github_main=$(git ls-remote https://github.com/coreyhines/ztpbootstrap.git refs/heads/main | awk '{print $1}')
printf 'forgejo=%s\ngithub=%s\n' "$forgejo_main" "$github_main"

# Fetch BOTH tips before comparing. Without the GitHub side present locally,
# merge-base fails with "not a valid object name" and the diverged-vs-
# not-fetched cases become indistinguishable.
git fetch -q origin main
git fetch -q https://github.com/coreyhines/ztpbootstrap.git \
  "+refs/heads/main:refs/mirror-check/github-main"

if git merge-base --is-ancestor "$github_main" "$forgejo_main"; then
  echo 'OK: GitHub main is an ancestor of Forgejo main; publish will fast-forward'
else
  echo 'STOP: histories diverged. Do not force-publish from CI.'
  echo 'See docs/FORGEJO_GITHUB_MIRROR.md "Break-glass".'
  exit 1
fi
git update-ref -d refs/mirror-check/github-main
```

Expected: `OK: …` (verified true as of design time: `04ce735` ⊂ `351984d`)

- [ ] **Step 2: Open Forgejo MR and verify the publish gate *before* merging**

```bash
git push -u origin HEAD
# Open MR: <branch> → main
```

On the MR's own CI run, confirm `publish-github` reports **Skipped**. This is
success criterion 3's only cheap test, and the MR run is the one place it can
be made: the job does not exist on any run predating Task 3, and after the
merge every run is a `main` push where the job is supposed to fire. Getting
the `if:` wrong is trivially fixable here and expensive to discover later.

If it shows anything other than Skipped, fix the `if:` in Task 3 Step 3 and
push again before merging.

Merge the MR once CI is green and the skip is confirmed.

- [ ] **Step 3: Confirm CI on `main` including `publish-github`**

All of `secret-scan`, `lint`, `dependency-scan`, `sbom`, `test`, `publish-github` green on the `main` push run.

- [ ] **Step 4: Verify GitHub `main` matches Forgejo**

```bash
forgejo_main=$(git ls-remote ssh://git@forgejo.freeblizz.com/coreyhines/ztpbootstrap.git refs/heads/main | awk '{print $1}')
github_main=$(git ls-remote https://github.com/coreyhines/ztpbootstrap.git refs/heads/main | awk '{print $1}')
test "$forgejo_main" = "$github_main" && echo MATCH
```

Expected: `MATCH`

- [ ] **Step 5: Confirm secret-scan clean on published tip**

Use the green `secret-scan` job on that same run. Optionally:

```bash
./scripts/secret-scan.sh ci
```

Expected: exit 0

- [ ] **Step 6: Make GitHub repository public**

```bash
gh repo edit coreyhines/ztpbootstrap --visibility public --accept-visibility-change-consequences
gh api repos/coreyhines/ztpbootstrap --jq '{private:.private,visibility:.visibility,has_issues:.has_issues}'
```

Expected: public, `has_issues: false`

- [ ] **Step 7: Final checklist**

| Criterion | Check | Kind |
|-----------|--------|------|
| No local `github` remote | `git remote -v` | tested |
| No `.github/` workflows/Dependabot | `test ! -e .github` | tested |
| Actions disabled | `gh api …/actions/permissions` | tested |
| Issues disabled | `has_issues: false` | tested |
| Publish skipped on PR/feature | Step 2 (MR run) | tested |
| FF publish on green main | Steps 3–4 | tested |
| Public after clean scan | Steps 5–6 | tested |
| Failing CI does not publish | `needs:` list in Task 3 Step 3 | **inspected only** |

The last row is deliberate: exercising it for real means landing a knowingly
broken commit on `main`. The `needs:` gate is verified by reading the workflow,
not by observation — don't record it as tested.

- [ ] **Step 8: Optional go-live note**

Add to `docs/FORGEJO_GITHUB_MIRROR.md`:

```markdown
## Status

GitHub public mirror enabled (CI-gated) as of YYYY-MM-DD. Issues disabled on GitHub.
```

```bash
git commit -am "docs: record GitHub public mirror go-live date"
```

---

## Spec coverage (self-review)

| Spec requirement | Task |
|------------------|------|
| CI-gated publish of `main` + `v*` with distinct modes | Tasks 2–3, 8 |
| Gate = ci.yml jobs only; not dhcp-integration | Tasks 3, Global Constraints, mirror doc |
| Delete workflows + dependabot; disable Actions | Tasks 1, 7 |
| Disable GitHub Issues | Task 7 Step 4 |
| Secret `MIRROR_GITHUB_TOKEN` | Tasks 2, 3, 5 |
| Remove local `github` remote | Task 6 |
| Close PRs dynamically / delete non-main branches | Task 7 |
| Docs + grep sweep | Task 4 |
| Public only after clean secret-scan | Task 8 |
| Ancestor pre-check | Task 8 Step 1 |
| Criterion 3 verified (skipped off-main) | Task 8 Step 2, on the MR run |
| FF only; break-glass out of CI | Task 2 script + Task 4 doc |
| Basic auth, token in neither URL nor `ps` | Task 2; probed in Task 5 Step 3 |

## Placeholder scan

No TBD left; secret rename applied throughout; single simplified script;
`gh -F enabled=false` only; tag/main modes distinct.

One intentional placeholder remains: the PAT expiry date in
`docs/FORGEJO_GITHUB_MIRROR.md` Operator notes reads `YYYY-MM-DD` and must be
filled with the real date during Task 5 Step 4. Same for the go-live date in
Task 8 Step 8, if that note is added.
