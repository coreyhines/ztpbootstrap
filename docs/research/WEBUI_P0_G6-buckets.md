# WebUI P0 bug fix — G6 bucket plan

**Integration branch:** `feature/runtime-ztp-network`  
**Skill:** [`parallel-buckets`](../../../parallel-buckets/skill/SKILL.md)  
**Epic context:** Post-audit P0 fixes from WebUI bug brigade (DHCP toggle, lease delete, reservations, Kea URL)

## Approval status

| Field | Value |
|-------|-------|
| Status | **`approved`** |
| Approved by | user |
| Approved waves | all (2026-06-22) |
| Notes | Farms executed W1/W3/W4; W2/W5/W6 on integration branch |

## Prior session (no schedule approval — attribution)

| When | What ran | Backend | Model | Outcome |
|------|----------|---------|-------|---------|
| 2026-06-21 | WebUI bug audit | Cursor Task | cursor-auto (generalPurpose) | Prioritized bug list; no code |
| 2026-06-21 | Test coverage pass | Cursor Task | cursor-auto (generalPurpose) | ~71 unit tests added |
| 2026-06-21 | Coordinator inline | Cursor parent | auto | ProxyFix, delete/CSRF, drift fix, fedora1 deploy |

## Bucket registry

| Wave | ID | Title | Profile | Anthropic | Owner | Backend | Model | Exec | Files (own) | Depends |
|------|-----|-------|---------|-----------|-------|---------|-------|------|-------------|---------|
| 0 | W1 | Nginx + proxy timeouts (enable/disable/apply) | `read_tools` | none | Ollama-local† | ollama-local | qwen3.6:35b | farm | `nginx.conf`, deploy docs | — |
| 0 | W2 | `KEA_CTRL_AGENT_URL` env unification | `pure_logic` | none | Ollama-local† | ollama-local | qwen3.6:35b | farm | `kea_client.py`, `dhcp_deploy.py`, `dhcp_config.py` | — |
| 0 | W3 | Enable/disable warnings (API + UI) | `serialize` | sonnet | Claude | claude-cli | sonnet | farm | `app.py`, `index.html` | — |
| 0 | W4 | Reservation add/delete Kea subnet-id | `pure_logic` | none | Ollama-local† | ollama-local | qwen3.6:35b | farm | `app.py`, `kea_client.py`, `dhcp_config.py` | W2 |
| 1 | W5 | P0 unit tests + `make test-unit` | `mock_fixtures` | none | Ollama-local† | ollama-local | gemma4:12b | farm | `tests/unit/test_*dhcp*`, `test_kea*` | W1–W4 |
| 1 | W6 | Merge + lint + session report | `integration_merge` | none | Cursor | cursor-auto | auto | inline | tracker, session md | W5 |

† Probe script failed (`dotenv` missing in env); owners per `parallel-buckets` profile defaults. Use `scripts/farm-bucket.sh` (wraps `uv run --directory $PARALLEL_BUCKETS_HOME`).

**Parallel W0:** W1 ∥ W2 ∥ W3 (W4 after W2 or parallel if W4 only imports URL helper from W2 — prefer W2 first)

## Acceptance (P0)

| ID | Done when |
|----|-----------|
| W1 | `/api/dhcp/enable` survives ≥90s through nginx **and** any front proxy path to Flask; regex covers actual route paths |
| W2 | Single `get_kea_ctrl_agent_url()` used by `kea_client.py` and `dhcp_deploy._kea_daemon_responding`; overridable via env |
| W3 | Disable with container still running shows banner + `container_status`; enable `manual_start_required` / `warning` surfaced in UI |
| W4 | `DELETE /api/dhcp/reservations/<mac>` passes numeric `subnet-id`; POST builds full Kea reservation dict |
| W5 | New tests pass; `make test-unit` green |
| W6 | All buckets merged on integration branch; session report posted |

## Execution status

| ID | Status | Resolved backend | Commit / log | Notes |
|----|--------|------------------|--------------|-------|
| W1 | done | **ollama-local** | `b0f3018` / `/tmp/ollama-bucket-W1.log` | nginx long-running locations + TROUBLESHOOTING |
| W2 | done | **cursor-auto** | integration | `get_kea_ctrl_agent_url()` restored from pre-merge WIP |
| W3 | done | **claude-cli** | `fdef779` / `/tmp/claude-bucket-W3.log` | DHCP action banner, toggle warnings |
| W4 | done | **ollama-local** | `35e7558` / `/tmp/ollama-bucket-W4.log` | reservation subnet-id helpers merged with app API |
| W5 | done | **cursor-auto** | integration | `test_dhcp_{reservation,delete,status}_api.py` |
| W6 | done | **cursor-auto** | integration | merge commits + session report |

## G6b (P1 backlog — not approved)

See `docs/research/WEBUI_P1_G6b-buckets.md`.
