# Runtime ZTP Network — G5 Bucket Brigade

**Epic:** [#60](https://github.com/coreyhines/ztpbootstrap/issues/60)  
**Tracker:** [docs/research/RUNTIME_ZTP_NETWORK_G5-buckets.md](research/RUNTIME_ZTP_NETWORK_G5-buckets.md)

**Approval status:** `approved` (rebalanced schedule, 2026-06-21)

---

## Rebalanced schedule (approved)

| Wave | Gate | ID | Title | Owner | Backend | Model | Exec | Depends |
|------|------|-----|-------|-------|---------|-------|------|---------|
| 0 | — | B11 | Repo hygiene | Claude→Cursor† | claude-cli→cursor-auto | sonnet→auto | farm/inline | — |
| 0 | — | B12 | Pre-apply audit | Cursor | cursor-auto | auto | inline | — |
| 0 | opt | B12m | `toggle_dhcp_range` | Claude→Cursor† | claude-cli→cursor-auto | sonnet | farm/inline | — |
| 1 | **Apply** | B13 | Apply & restart | **Operator** | operator | — | manual | B12 |
| 2 | `TEST_PASS` | B14 | Verify + BATS | Cursor | cursor-auto | auto | inline | B13 |
| 3 | — | B15 | OPNsense DHCP off → Kea | Cursor | cursor-auto | auto | inline | B14 |
| 4 | **Switch** | B16 | Switch ZTP lab | **Operator** | operator | — | manual | B15 |
| 5 | — | B17 | Host-network regression | Cursor | cursor-auto | auto | inline | B14 |
| 5 | — | B18 | Ledger + attribution | Claude | claude-cli | sonnet | farm | B16,B17 |
| 6 | **Merge** | B19 | PR → `main` | Cursor | cursor-auto | auto | inline | B18 |

† W0: Claude usage API **429** → routed to Cursor Auto inline per waterfall.

---

## B12 audit (2026-06-21)

| Check | Result |
|-------|--------|
| `enp7s0.5` oper-up | **PASS** |
| Podman network `net-10` | **exists** |
| Quadlet `Network=net-10` / `IP=10.0.10.10` | **PASS** (not yet migrated) |
| **ztpbootstrap pod running** | **FAIL** — no pod/containers up; systemd inactive |
| OPNsense VLAN 5 DHCP (`opt10`) | **ACTIVE** — 6 leases on `10.0.5.0/24` |
| `/api/network/validate` (POST) | Not re-run this pass |

**Go/no-go for B13:** Start or redeploy ztpbootstrap on fedora1 **before** Apply. Confirm Web UI reachable on `10.0.10.10`.

---

## Who did what — W0

| Bucket | Planned | Resolved | Cost pool | Outcome |
|--------|---------|----------|-----------|---------|
| B11 | claude-cli | cursor-auto | cursor_included | _(in progress)_ |
| B12 | cursor-auto | cursor-auto | cursor_included | audit table above |
| B12m | claude-cli | cursor-auto | cursor_included | _(in progress)_ |

---

## Next gates

| Gate | When |
|------|------|
| Start ztpbootstrap on fedora1 | Before B13 |
| Approve Wave 1 Apply | Before B13 |
| `TEST_PASS` | Before B14 BATS |
| Approve merge | Before B19 |
