# Forgejo → GitHub public mirror design

**Date:** 2026-08-10  
**Status:** Approved  
**Repo:** `coreyhines/ztpbootstrap`

## Goal

Forgejo is the only development remote (branches, MRs, CI). GitHub is a public clone/fork face that receives `main` and release tags only after Forgejo CI (including secret scanning) has passed. Developers never push to GitHub from a local remote.

## Decisions (locked)

| Topic | Choice |
|-------|--------|
| Sync model | CI-gated Forgejo Actions job pushes to GitHub (not interval push-mirror) |
| Refs published | `main` + release tags (`v*`) |
| GitHub CI | Delete `.github/workflows/`; disable Actions in GitHub settings |
| Visibility | Keep private until first successful publish + clean secret-scan on that tip; then public |
| Existing GitHub noise | Close all open PRs; delete all non-`main` branches |
| Local git | Remove the `github` remote |

## Architecture

```
Forgejo push/merge to main  (or push tag v*)
        │
        ▼
Forgejo CI (secret-scan, lint, dependency-scan, sbom, test, …)
        │  all required jobs pass
        ▼
publish-github job
  • push refs/heads/main → GitHub main
  • push matching release tags (v*)
        │
        ▼
(after verified clean tip) set GitHub repo visibility to public
```

**Not mirrored:** feature branches, Dependabot branches, PR refs, Forgejo-only WIP.

## Components

### 1. Repo / CI

- Remove `.github/workflows/` entirely.
- Update `.forgejo/workflows/ci.yml` comments that describe GitHub as a “fallback.”
- Add a `publish-github` job (same workflow or sibling) that:
  - `needs:` every CI job that must be green before publish (`secret-scan`, `lint`, `dependency-scan`, `sbom`, `test`, and any later required jobs)
  - Runs only on `push` to `main` and on tag pushes matching `v*`
  - Does **not** run on pull requests or feature-branch pushes
  - Pushes to `github.com/coreyhines/ztpbootstrap` using a Forgejo-stored credential

### 2. Secrets

- Forgejo secret `GITHUB_MIRROR_TOKEN`: fine-grained PAT (or dedicated machine user) scoped to this one GitHub repo with **Contents: Read and write** (enough to update `main` and tags).
- Masked in logs; never committed; not used by GitHub Actions (Actions disabled).

### 3. Local developer setup

- `git remote remove github` in existing clones.
- Document: develop against Forgejo `origin` only; do not add GitHub as a push remote.

### 4. One-time GitHub scrub

1. Close open PRs (#43–#48 Dependabot; #68–#70 feature PRs already reflected on Forgejo `main`).
2. Delete all non-`main` remote branches.
3. Disable Actions in repository settings (`Actions: Disabled` / no workflows allowed).
4. After first green publish + confirmed clean secret-scan on the published tip, set visibility to **public**.

### 5. Docs

- README (or short ops note): public clone URL → GitHub; contribute / MRs / CI → Forgejo.
- State the mirror policy explicitly so forks are not surprised that GitHub has no Actions.

## Publish credentials and failure behavior

- Auth: HTTPS with PAT preferred for Actions simplicity; SSH deploy key is an acceptable alternative if the runner has key support.
- If publish fails, Forgejo CI is red; GitHub stays on the last successfully published tip (no partial branch flood).
- Force-push to GitHub `main` is **not** part of normal operation; publish is a fast-forward (or create/update tags). History rewrites on Forgejo `main` require an explicit, separate recovery procedure.

## Out of scope

- Mirroring issues/PRs between forges
- GitHub Releases UI automation (tags only for now; Releases can be added later)
- Cleaning up local Forgejo feature/bucket branches (orthogonal to the public mirror)
- Making Forgejo itself public

## Success criteria

1. No `github` remote in the primary clone; `origin` is Forgejo.
2. No `.github/workflows/`; GitHub Actions disabled; no CI runs on GitHub.
3. Push to Forgejo `main` with failing CI does not update GitHub.
4. Push to Forgejo `main` with green CI updates GitHub `main` only.
5. Pushing a `v*` tag with green CI publishes that tag to GitHub.
6. GitHub has no stale feature/Dependabot branches or open PRs after scrub.
7. Repo is public only after secret-scan clean confirmation on the published tip.
