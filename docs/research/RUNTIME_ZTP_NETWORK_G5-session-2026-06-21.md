# Parallel bucket session — Runtime ZTP Network G5 (W0)

**Date:** 2026-06-21  
**Integration branch:** `feature/runtime-ztp-network` @ `f9d8ae1`  
**Coordinator:** Cursor Auto (inline)  
**Spec:** `docs/RUNTIME_ZTP_NETWORK_SPEC.md` §16  
**Tracker:** `docs/research/RUNTIME_ZTP_NETWORK_G5-buckets.md`

## Session summary

| Bucket | Owner | Planned backend | Resolved backend | Cost pool | Exec | Branch | Commit | Tests | Status |
|--------|-------|-----------------|------------------|-----------|------|--------|--------|-------|--------|
| B11 | Claude | claude-cli | cursor-auto | cursor_included | inline | `feature/runtime-ztp-network` | `f9d8ae1` — docs(g5): approve rebalanced… | n/a | done |
| B12 | Cursor | cursor-auto | cursor-auto | cursor_included | inline | — | — | n/a | done |
| B12m | Claude | claude-cli | cursor-auto | cursor_included | inline | opnsense-mcp `main` | `1605f13` — feat(dhcp): toggle_dhcp_range | 2 pass | done |

**Reroute:** Claude usage API returned **429** on both B11/B12m → Cursor Auto inline per waterfall.

## B12 audit (go/no-go)

| Check | Result |
|-------|--------|
| `enp7s0.5` | UP |
| Podman `net-10` | exists |
| Quadlet `Network=net-10` / `IP=10.0.10.10` | current (Apply not run) |
| **ztpbootstrap pod** | **NOT RUNNING** — start before B13 |
| OPNsense VLAN 5 DHCP | active on `opt10` (6 Arista/switch leases) |

## B12m deliverable

- `opnsense_mcp` tool **`toggle_dhcp_range`** (dnsmasq only)
- Usage: `toggle_dhcp_range(enabled=false, interface=opt10, apply=true)` before B15
- Restart OPNsense MCP server to load new tool

## Integration health

| Check | Result |
|-------|--------|
| ztpbootstrap W0 | docs committed |
| opnsense-mcp tests | `test_toggle_dhcp_range.py` 2 passed |
| Claude at farm | 429 — blocked |
| Next blocker | Start ztpbootstrap on fedora1 |

## Next buckets

| Bucket | Gate |
|--------|------|
| B13 Apply | Operator approve Wave 1 + pod running |
| B14 | `TEST_PASS` |
| B15 | B12m tool or manual dnsmasq off |
