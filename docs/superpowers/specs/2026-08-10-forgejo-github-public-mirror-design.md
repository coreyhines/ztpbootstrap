# Forgejo → GitHub public mirror design

**Date:** 2026-08-10  
**Status:** Approved (amended 2026-08-10 after review)  
**Repo:** `coreyhines/ztpbootstrap`

## Goal

Forgejo is the only development remote (branches, MRs, CI). GitHub is a public clone/fork face that receives `main` and release tags only after Forgejo CI (including secret scanning) has passed. Developers never push to GitHub from a local remote.

## Decisions (locked)

| Topic | Choice |
|-------|--------|
| Sync model | CI-gated Forgejo Actions job pushes to GitHub (not interval push-mirror) |
| Refs published | `main` + release tags (`v*`) |
| Publish modes | **main push:** update GitHub `main` only. **tag push (`v*`):** publish that tag only (do not move GitHub `main` from detached HEAD) |
| CI gate for publish | Jobs in `.forgejo/workflows/ci.yml` only (`secret-scan`, `lint`, `dependency-scan`, `sbom`, `test`). **Does not** wait on `.forgejo/workflows/dhcp-integration-test.yml` (separate workflow; cannot `needs:` across files) |
| GitHub CI | Delete `.github/workflows/` and `.github/dependabot.yml`; disable Actions in GitHub settings |
| GitHub Issues | **Disable** — Forgejo is the issue/MR source of truth; avoid a second public inbox |
| Visibility | Keep private until first successful publish + clean secret-scan on that tip; then public |
| Existing GitHub noise | Close all open PRs (dynamically); delete all non-`main` branches |
| Local git | Remove the `github` remote |
| Forgejo secret name | `MIRROR_GITHUB_TOKEN` (**not** `GITHUB_*` — Forgejo rejects secret names starting with `GITHUB_`, `GITEA_`, or `FORGEJO_`) |
| History rewrite recovery | Out of scope for automation; break-glass notes live in `docs/FORGEJO_GITHUB_MIRROR.md` only |

## Architecture

```
Forgejo push to main                    Forgejo push tag v*
        │                                       │
        ▼                                       ▼
Forgejo CI (ci.yml jobs)                Forgejo CI (ci.yml jobs)
        │  all required jobs pass               │  all required jobs pass
        ▼                                       ▼
publish-github                          publish-github
  • FF-push tip → GitHub main             • push that tag only
        │                                       │
        └───────────────┬───────────────────────┘
                        ▼
        (after verified clean tip) set GitHub repo public
```

**Not mirrored:** feature branches, Dependabot branches, PR refs, Forgejo-only WIP.

## Components

### 1. Repo / CI

- Remove `.github/workflows/` entirely and remove `.github/dependabot.yml` (then remove empty `.github/`).
- Update `.forgejo/workflows/ci.yml` comments that describe GitHub as a “fallback.”
- Add a `publish-github` job in `ci.yml` that:
  - `needs:` `secret-scan`, `lint`, `dependency-scan`, `sbom`, `test` (ci.yml only)
  - Runs only on `push` to `main` and on tag pushes matching `v*`
  - Does **not** run on pull requests or feature-branch pushes
  - On `main`: pushes GitHub `main` (fast-forward only)
  - On `v*` tag: pushes that tag only
  - Uses Forgejo secret `MIRROR_GITHUB_TOKEN`

### 2. Secrets

- Forgejo secret `MIRROR_GITHUB_TOKEN`: fine-grained PAT (or dedicated machine user) scoped to this one GitHub repo with **Contents: Read and write**.
- Masked in logs; never committed; never placed on process command lines (use `http.extraHeader` / credential helper).
- Not used by GitHub Actions (Actions disabled).

### 3. Local developer setup

- `git remote remove github` in existing clones.
- Document: develop against Forgejo `origin` only; do not add GitHub as a push remote.

### 4. One-time GitHub scrub

1. Close **all** currently open PRs via `gh pr list` (do not hardcode numbers).
2. Delete all non-`main` remote branches.
3. Disable Actions: `gh api -X PUT …/actions/permissions -F enabled=false` (typed boolean; do not send `allowed_actions` when disabling).
4. Disable GitHub Issues on the repo.
5. After first green publish + confirmed clean secret-scan on the published tip, set visibility to **public**.

### 5. Docs

- README (or short ops note): public clone URL → GitHub; contribute / MRs / CI / issues → Forgejo.
- State the mirror policy explicitly so forks are not surprised that GitHub has no Actions and no Issues.
- Grep sweep of remaining “GitHub Actions as CI” wording; update operational docs, leave clearly historical notes alone.

## Publish credentials and failure behavior

- Auth: HTTPS with PAT via git `http.extraHeader` (Authorization: Bearer), not token-in-URL.
- If publish fails, Forgejo CI is red; GitHub stays on the last successfully published tip.
- Force-push to GitHub `main` is **not** part of normal operation; publish is fast-forward only for `main`, and create/update for tags.
- Before the **first** publish, verify GitHub `main` is an ancestor of Forgejo `main` (expected today: yes). If not, stop and resolve manually — do not force-push from the automated job.

## Out of scope

- Mirroring issues/PRs between forges
- GitHub Releases UI automation (tags only for now; Releases can be added later)
- Cleaning up local Forgejo feature/bucket branches (orthogonal to the public mirror)
- Making Forgejo itself public
- Automated recovery after Forgejo `main` history rewrites (document break-glass only; no CI force-push path)

## Success criteria

1. No `github` remote in the primary clone; `origin` is Forgejo.
2. No `.github/workflows/` and no `.github/dependabot.yml`; GitHub Actions disabled; no CI runs on GitHub.
3. Push to Forgejo `main` with failing CI does not update GitHub; `publish-github` is **skipped** on PR and `feature/*` pushes (verified before going public).
4. Push to Forgejo `main` with green CI updates GitHub `main` only.
5. Pushing a `v*` tag with green CI publishes that tag to GitHub **without** moving `main` to the tag commit unless that commit already is `main`.
6. GitHub has no stale feature/Dependabot branches or open PRs after scrub; Issues disabled.
7. Repo is public only after secret-scan clean confirmation on the published tip.
