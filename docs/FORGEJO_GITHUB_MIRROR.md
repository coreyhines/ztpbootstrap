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
