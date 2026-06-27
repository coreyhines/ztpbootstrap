# Runtime ZTP Network — G5 bucket plan

**Integration branch:** `feature/runtime-ztp-network` → `main` (P3)  
**Skill:** [`parallel-buckets`](../../../parallel-buckets/skill/SKILL.md)

## Approval status

| Field | Value |
|-------|-------|
| Status | **`approved`** |
| Approved by | user |
| Approved waves | all (rebalanced schedule 2026-06-21) |
| Notes | Finish pass 2026-06-27 — B13 applied live; drift fix + acceptance |

## Bucket registry (rebalanced — approved)

| Wave | ID | Title | Profile | Anthropic | Owner | Backend | Model | Exec | Depends |
|------|-----|-------|---------|-----------|-------|---------|-------|------|---------|
| 0 | B11 | Repo hygiene + tracker | `coordinator` | none | Claude | claude-cli | sonnet | farm† | — |
| 0 | B12 | Pre-apply fedora1 audit | `live_mcp` | none | Cursor | cursor-auto | auto | inline | — |
| 0 | B12m | OPNsense `toggle_dhcp_range` | `mcp_wiring` | none | Claude | claude-cli | sonnet | farm† | — |
| 1 | B13 | Apply & restart → `ztp-net-5` | `live_mcp` | none | **Operator** | operator | — | manual | B12 |
| 2 | B14 | Post-apply verify + BATS | `live_mcp` | none | Cursor | cursor-auto | auto | inline | B13 |
| 3 | B15 | OPNsense DHCP off → Kea on | `live_mcp` | none | Cursor | cursor-auto | auto | inline | B14, B12m‡ |
| 4 | B16 | Switch ZTP manual lab | `live_mcp` | none | **Operator** | operator | — | manual | B15 |
| 5 | B17 | Host-network disabled regression | `live_mcp` | none | Cursor | cursor-auto | auto | inline | B14 |
| 5 | B18 | Ledger + attribution | `coordinator` | sonnet | Claude | claude-cli | sonnet | farm† | B16, B17 |
| 6 | B19 | PR → `main` + close #60 | `integration_merge` | none | Cursor | cursor-auto | auto | inline | B18 |

† Claude API 429 (weekly pro quota exhausted — probe, not hard block) → **Cursor Auto inline** for W0; record reroute. Claude CLI re-farm of B12m in progress on opnsense-mcp.  
‡ B12m optional fallback: manual OPNsense dnsmasq disable.

**Parallel W0:** B11 ∥ B12 ∥ B12m

## Execution status

| ID | Status | Resolved backend | Notes |
|----|--------|------------------|-------|
| B11 | done | cursor-auto | Claude API 429; rerouted inline (`f9d8ae1`) |
| B12 | done | cursor-auto | SSH audit fedora1 |
| B12m | done | cursor-auto | `toggle_dhcp_range` merged on opnsense-mcp |
| B13 | done | operator | Apply live 2026-06-22 — `ztp-net-5` @ `10.0.5.10` |
| B14 | done | cursor-auto | Drift false-positive fixed; BATS + unit |
| B15 | done | cursor-auto | OPNsense opt10 DHCP off; Kea authoritative |
| B16 | done | operator | bootstrap.py reachable on VLAN 5 profile |
| B17 | done | cursor-auto | Host-network quadlet regression unit tests |
| B18 | done | claude-cli | `6c85554` ledger + attribution |
| B19 | done | cursor-auto | `make check`; PR path documented |
