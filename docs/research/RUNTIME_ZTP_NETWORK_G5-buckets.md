# Runtime ZTP Network — G5 bucket plan

**Integration branch:** `feature/runtime-ztp-network` → `main` (P3)  
**Skill:** [`parallel-buckets`](../../../parallel-buckets/skill/SKILL.md)

## Approval status

| Field | Value |
|-------|-------|
| Status | **`approved`** |
| Approved by | user |
| Approved waves | all (rebalanced schedule 2026-06-21) |
| Notes | Farm Claude Sonnet for doc/code buckets; Cursor Auto for live MCP; Operator for Apply/switch |

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

† Claude CLI blocked (429) → **Cursor Auto inline** for W0; record reroute.  
‡ B12m optional fallback: manual OPNsense dnsmasq disable.

**Parallel W0:** B11 ∥ B12 ∥ B12m

## Execution status

| ID | Status | Resolved backend | Notes |
|----|--------|------------------|-------|
| B11 | running | cursor-auto | Claude 429; inline commit |
| B12 | running | cursor-auto | SSH audit fedora1 |
| B12m | running | cursor-auto | opnsense-mcp tool |
| B13–B19 | queued | — | — |
