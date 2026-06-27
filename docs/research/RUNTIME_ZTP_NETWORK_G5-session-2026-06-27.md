# Parallel bucket session — Runtime ZTP Network G5 (finish pass)

**Date:** 2026-06-27  
**Integration branch:** `feature/runtime-ztp-network`  
**Coordinator:** Cursor Auto (inline)  
**Tracker:** [RUNTIME_ZTP_NETWORK_G5-buckets.md](RUNTIME_ZTP_NETWORK_G5-buckets.md)

## Session summary

| Bucket | Owner | Planned backend | Resolved backend | Cost pool | Exec | Branch | Commit | Tests | Status |
|--------|-------|-----------------|------------------|-----------|------|--------|--------|-------|--------|
| B13 | Operator | operator | operator | — | manual | — | — | live verify | done |
| B14 | Cursor | cursor-auto | cursor-auto | cursor_included | inline | `feature/runtime-ztp-network` | _this pass_ | 7/7 BATS unauth + 5/5 in-container auth | done |
| B15 | Cursor | cursor-auto | cursor-auto | cursor_included | inline | — | — | Kea active; OPNsense 0 dynamic 10.0.5 leases | done |
| B16 | Operator | operator | operator | — | manual | — | — | DNS → `10.0.5.10`/`::10`; bootstrap HTTP 200 | done |
| B17 | Cursor | cursor-auto | cursor-auto | cursor_included | inline | `feature/runtime-ztp-network` | _this pass_ | unit | done |
| B18 | Cursor | cursor-auto | claude-cli | claude_pro | farm | `feature/runtime-ztp-network` | `6c85554` | n/a | done |
| B19 | Cursor | cursor-auto | cursor-auto | cursor_included | inline | `feature/runtime-ztp-network` | _this pass_ | make check | done |

## Live state (fedora1, 2026-06-27)

| Check | Result |
|-------|--------|
| Podman `ztp-net-5` | **exists** — macvlan parent `enp9s0`, pod `@ 10.0.5.10` |
| Quadlet `Network=ztp-net-5` / `IP=10.0.5.10` | **PASS** |
| Pod `ztpbootstrap` | **Running** (~5d) |
| ZTP config `status` | **applied** (`2026-06-22T03:00:00+00:00`) |
| Drift (post-fix) | **Clear** — `status: applied`, parent `enp9s0` |
| Kea DHCP | **active**, macvlan mode |
| `ztpboot.freeblizz.com` DNS | **Updated** — A `10.0.5.10`, AAAA `…b505::10` (OPNsense) |
| bootstrap.py HTTPS | **200** via `ztpboot.freeblizz.com` |

## B13 note

Apply was performed outside the original W0 session (2026-06-22). Tracker updated from `queued` → `done` based on live quadlet, podman network, and config `applied_at`.

## B18 note

Ledger commit `6c85554` was already on integration branch; session row updated from `running`/`_pending_` → `done`.

## Integration health

| Check | Result |
|-------|--------|
| `inspect_podman_network` parent fix | unit tests added |
| `make test-unit` (Python) | 149 passed, 15 skipped |
| BATS `test_network_api.bats` | 2/2 unauth on fedora1; auth via in-container client |
| OPNsense VLAN 5 DHCP handoff | Kea authoritative; OPNsense dynamic leases empty on `10.0.5` |
