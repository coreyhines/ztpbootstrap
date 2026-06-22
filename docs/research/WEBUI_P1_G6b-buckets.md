# WebUI P1 bug fix — G6b bucket plan

**Integration branch:** `feature/runtime-ztp-network`  
**Skill:** [`parallel-buckets`](../../../parallel-buckets/skill/SKILL.md)  
**Depends on:** G6 P0 merged or in flight

## Approval status

| Field | Value |
|-------|-------|
| Status | **`approved`** |
| Approved by | user |
| Approved waves | all (2026-06-22) |
| Notes | Executed inline by coordinator after approval |

## Bucket registry

| Wave | ID | Title | Profile | Owner | Backend | Model | Exec | Files (own) | Depends |
|------|-----|-------|---------|-------|---------|-------|------|-------------|---------|
| 0 | P1a | Auto-detect CSRF headers | `read_tools` | Ollama-local | ollama-local | qwen3.6:35b | farm | `index.html` | G6 |
| 0 | P1b | Client IPv6 validation parity | `pure_logic` | Ollama-local | ollama-local | qwen3.6:35b | farm | `index.html`, `dhcp_validation.py` | G6 |
| 0 | P1c | IPv6 DNS field load on config refresh | `read_tools` | Ollama-local | ollama-local | gemma4:12b | farm | `index.html` | G6 |
| 0 | P1d | Strip `enabled` from config PUT save | `serialize` | Claude | claude-cli | sonnet | farm | `index.html`, `app.py` | G6 |
| 1 | P1e | P1 unit tests | `mock_fixtures` | Ollama-local | ollama-local | gemma4:12b | farm | `tests/unit/` | P1a–P1d |

**Parallel W0:** P1a ∥ P1b ∥ P1c (P1d parallel if no file overlap — P1d touches app.py; run after P1c or parallel with P1a only)

## Execution status

| ID | Status | Resolved backend | Notes |
|----|--------|------------------|-------|
| P1a | done | cursor-auto | `getCsrfHeaders()` on auto-detect POSTs |
| P1b | done | cursor-auto | Server `_looks_like_hostname`; client `validateIpAddress` / `validateDhcpServerList` |
| P1c | done | cursor-auto | IPv6 `dns_servers_str` in `loadDhcpConfig` |
| P1d | done | cursor-auto | Client `delete config.enabled`; server preserves existing on PUT |
| P1e | done | cursor-auto | `tests/unit/test_dhcp_g6b.py`; hostname tests unblocked |

Session report: `docs/research/WEBUI_P1_G6b-session-2026-06-22.md`
