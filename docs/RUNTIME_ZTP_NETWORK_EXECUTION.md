# Runtime ZTP Network — Execution Ledger

**Epic:** [#60](https://github.com/coreyhines/ztpbootstrap/issues/60)  
**Branch:** `feature/runtime-ztp-network`  
**Strategy:** Keep first-pass code (Auto); re-run buckets with assigned models; stack PR-1…PR-7.

---

## Model roster

| Bucket | Model | Task slug | PR |
|--------|-------|-----------|-----|
| B0, B1, B8 | GPT-5.3 Codex | `gpt-5.3-codex` | PR-1 |
| B2, B6 | Claude Opus 4.8 | `claude-opus-4-8-thinking-high` | PR-2 |
| B3 | GPT-5.3 Codex | `gpt-5.3-codex` | PR-3 |
| B4, B5 | Composer 2.5 Fast | `composer-2.5-fast` | PR-4 |
| B7, B9 | GPT-5.3 Codex | `gpt-5.3-codex` | PR-6 |
| B10 | Claude Sonnet 4.6 | `claude-4.6-sonnet-medium-thinking` | PR-7 |

---

## Who did what (full attribution)

### Pass 1 — initial implementation (no model assignment)

| Bucket | Executor | Model | Agent ID |
|--------|----------|-------|----------|
| Epic, §10.1, GitHub #49–#60 | Parent | **Cursor Agent (Auto)** | — |
| B0, B1, B2, B3, B4, B5, B6, B7 partial, B8, B9 stub | Parent | **Cursor Agent (Auto)** | — |
| B10 (first draft) | Subagent | **Composer 2.5 Fast** | `51145899-0eb0-482a-8ef0-038ecc2502c5` |

### Pass 2 — re-run with assigned models (keep current code)

| Bucket | Executor | Model | Agent ID | Outcome |
|--------|----------|-------|----------|---------|
| **B0+B1+B8** | Parent (follow-up) | **Auto** | — | B1 fix: podman container **names** in `network_utils.py` (Opus-flagged) |
| **B2+B6** | Subagent | **Claude Opus 4.8** | `643ccc47-10f4-4702-b825-75c831a84524` | Atomic quadlet write; backup under lock; macvlan mode match fix |
| **B3** | Parent (unchanged) | **Auto** | — | No re-run subagent; API from pass 1 |
| **B4+B5** | Subagent | **Composer 2.5 Fast** | `3bcbeafc-8069-49d5-a717-a347665c18b6` | Init tab load, mismatch helper, duplicate watcher removed |
| **B7+B9** | Subagent | **GPT-5.3 Codex** | `0ca54c47-c70f-4d78-8dbc-42327e9dbd6f` | `setup-interactive.sh` seeds `network.ztp`; expanded BATS |
| **B10** | Subagent | **Claude Sonnet 4.6** | `eb2a002f-0195-47f0-a4bb-d2e111fa7d07` | Review only — no edits needed |

---

## PR stack

| PR | Branch | Base | Buckets | Owner model(s) |
|----|--------|------|---------|----------------|
| PR-1 | `network/pr-1-schema-validation` | `feature/runtime-ztp-network` | B0, B1, B8 | Codex + Auto (B1 fix) |
| PR-2 | `network/pr-2-deploy` | PR-1 branch | B2, B6 | Opus |
| PR-3 | `network/pr-3-api` | PR-2 branch | B3 | Auto (pass 1) |
| PR-4 | `network/pr-4-ui` | PR-3 branch | B4, B5 | Composer |
| PR-6 | `network/pr-6-install-tests` | PR-4 branch | B7, B9 | Codex |
| PR-7 | `network/pr-7-docs` | PR-6 branch | B10 + this ledger | Sonnet + Composer (first draft) |

**Excluded from network PRs:** `systemd/ztpbootstrap-webui.container` (unrelated WIP), `.playwright-mcp/`

---

## Gates

| Gate | Check |
|------|--------|
| G1 | 13 network unit tests pass |
| G2 | Opus deploy review merged |
| G3 | 8 `/api/network/*` routes |
| G4 | ZTP Network tab + DHCP banners |
| G5 | Lab test fedora1 + switch ZTP |
