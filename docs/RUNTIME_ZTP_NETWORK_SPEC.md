# Runtime ZTP Network Configuration — Feature Specification

**Branch:** `feature/runtime-ztp-network`  
**Status:** Draft — farm-out tracked in [GitHub #60](https://github.com/coreyhines/ztpbootstrap/issues/60)  
**Last updated:** 2026-06-20  
**Related:** Kea DHCP (`docs/DHCP_IMPLEMENTATION_PLAN.md`), `webui/dhcp_deploy.py`, `update-config.sh`

---

## 1. Problem statement

Kea DHCP and ZTP bootstrap must be **L2-adjacent** to Arista switches on the ZTP VLAN (e.g. VLAN 5 / `10.0.5.0/24`). Today:

| Layer | Current behavior | Gap |
|-------|------------------|-----|
| Install time | `setup-interactive.sh` may create a macvlan network and write `ztpbootstrap.pod` | No runtime path after install |
| Config | `config.yaml` → `network.ipv4`, `network.network` | Assumes network already exists on host |
| DHCP UI | Subnet, pools, OUI filter, enable/disable Kea | Does **not** create or move the pod onto the ZTP segment |
| Pod network | Single `Network=` in `ztpbootstrap.pod` | Changing VLAN requires manual `podman network create`, quadlet edit, and host SSH |

Operators need to point the **entire ztpbootstrap pod** (nginx + webui + Kea) at the ZTP segment from the Web UI, with **one controlled restart** — not a shell session on the host.

### Production example (freeblizz lab)

- Switches ZTP on **VLAN 5** (`10.0.5.0/24`, gw `10.0.5.1`, IPv6 `2601:441:8483:b505::/64`)
- Hypervisor host (`fedora1`) has trunk/access plumbing on `enp7s0` (or a VLAN subinterface such as `enp7s0.5`)
- Service must listen on that segment so Kea answers DISCOVER and switches fetch `https://ztpboot.example.com/bootstrap.py` without relying on cross-VLAN routing quirks

---

## 2. Goals

1. **UI-driven ZTP network profile** — VLAN id (logical label), IPv4/IPv6 subnet, gateway, pod IP, parent interface, optional DNS domain alignment.
2. **Runtime podman macvlan lifecycle** — create, validate, attach, and (when needed) replace the Podman network that backs the pod.
3. **Runtime quadlet sync** — update `ztpbootstrap.pod` (`Network=`, `IP=`, `IP6=`) from saved config.
4. **Single restart action** — “Apply & restart” from the UI performs ordered stop → network/quadlet apply → `daemon-reload` → start, with progress and error reporting.
5. **DHCP integration** — after the pod moves, Kea config is regenerated so `interfaces-config` and subnet options match the new segment (existing `dhcp_config.py` path).
6. **Host plumbing is assumed** — the UI does **not** create physical VLANs, NM connections, or switch port modes; it documents prerequisites and validates that the chosen **parent** exists and is oper-up.

## 3. Non-goals (v1)

- Automatic creation of `ip link add … type vlan` or NetworkManager profiles on the host (document + validate only).
- Multi-homed pod (two macvlan networks on one pod) — Podman pods support one network namespace; management VLAN and ZTP VLAN on different L2 segments require routing between them, not dual attachment.
- Moving only Kea to a second network while nginx stays elsewhere (would need a second pod or host-network split; out of scope).
- DNS provider integration (OPNsense/Pi-hole updates remain manual or a future feature).
- Zero-downtime migration — a full pod restart is expected and acceptable.

---

## 4. Architecture

### 4.1 Network roles

```text
┌─────────────────────────────────────────────────────────────────┐
│ Host (fedora1, strongpod, …)                                    │
│  Prerequisites (out of band):                                   │
│    enp7s0.5  OR  enp7s0 on trunk with VLAN 5                   │
│    optional: macvlan-host@parent (bridge) for host→pod access     │
├─────────────────────────────────────────────────────────────────┤
│  Podman network: ztp-net-5  (macvlan, parent=enp7s0.5)         │
│    subnet 10.0.5.0/24, gw 10.0.5.1                              │
│    subnet 2601:441:8483:b505::/64, gw …::1                      │
├─────────────────────────────────────────────────────────────────┤
│  Pod: ztpbootstrap  (Network=ztp-net-5, IP=10.0.5.10, IP6=…)   │
│    ├─ ztpbootstrap-nginx   (bootstrap.py, TLS)                 │
│    ├─ ztpbootstrap-webui    (Flask UI — same L2 as switches)    │
│    └─ ztpbootstrap-dhcp     (Kea — DHCP on ZTP VLAN)            │
└─────────────────────────────────────────────────────────────────┘
         ▲ L2
         │  Arista switches (ZTP DHCP / HTTPS bootstrap)
```

**Operator access:** Admins reach the Web UI via routed access to the pod IP (e.g. from VLAN 10 → `10.0.5.10`) or via `macvlan-host` bridge on the host. The UI does not require the operator to sit on the ZTP VLAN.

**Switches:** Must be on the **same L2 segment** as the pod (ZTP VLAN). That is the whole point of this feature.

### 4.2 Control plane vs data plane

| Component | Runs where | Privilege |
|-----------|------------|-----------|
| Flask API (`network_deploy.py`) | webui container | Invokes `podman` via mounted socket; may need host helper for writes under `/etc/containers/systemd` |
| Config source of truth | `config.yaml` on NFS/`ZTP_CONFIG_DIR` | Read/write from webui |
| Quadlet files | `/etc/containers/systemd/ztpbootstrap/` | Same pattern as `dhcp_deploy.py` (temp file + copy or direct write) |
| Podman networks | Host Podman | `podman network create/rm/inspect` |
| systemd | Host | `systemctl daemon-reload`, stop/start unit files |

### 4.3 Relationship to existing DHCP module

1. User configures **ZTP Network** (this feature) — pod IP, subnet, parent, VLAN label.
2. User configures **DHCP** (existing) — pools, options, OUI filter; subnet should match ZTP network (auto-fill encouraged).
3. User clicks **Apply & restart** — network module runs first; DHCP config regeneration runs before pod start if DHCP enabled.
4. User enables DHCP (existing flow) — Kea starts inside pod already on correct macvlan.

`detect_networking_mode()` today returns `host` vs `macvlan` from `container.host_network`. After this feature, production ZTP deployments should use **`container.host_network: false`** with an explicit `network.ztp` profile (see schema). Host-network mode remains for lab/VM quickstart only.

---

## 5. Configuration schema

Extend `config.yaml` with a dedicated ZTP network block. Keep backward compatibility with flat `network.ipv4` / `network.network` by treating them as aliases until migration.

```yaml
network:
  domain: "ztpboot.freeblizz.com"

  # Legacy fields (still written by setup; mirrored from ztp.* when applied via UI)
  ipv4: "10.0.5.10"
  ipv6: "2601:441:8483:b505::10"
  network: "ztp-net-5"

  # NEW: ZTP segment definition (source of truth when present)
  ztp:
    enabled: true                    # false = host network lab mode
    vlan_id: 5                       # informational + default network name
    parent_interface: "enp7s0.5"     # macvlan parent (must exist on host)
    podman_network: "ztp-net-5"      # Podman network name (auto: ztp-net-<vlan_id>)

    ipv4:
      address: "10.0.5.10"           # pod static IP
      subnet: "10.0.5.0/24"
      gateway: "10.0.5.1"

    ipv6:
      address: "2601:441:8483:b505::10"
      subnet: "2601:441:8483:b505::/64"
      gateway: "2601:441:8483:b505::1"

    # Optional: macvlan mode (default bridge)
    macvlan_mode: "bridge"           # bridge | private | vepa | passthru

    # Last apply metadata (written by backend)
    applied_at: ""
    applied_parent: ""
    applied_network: ""
    status: "pending"                # pending | applied | error | drift
    last_error: ""

  https_port: 443
  http_port: 80
  http_only: false

container:
  host_network: false                # must be false when network.ztp.enabled
```

**DHCP alignment:** When `dhcp.ipv4.subnet` is empty and user applies ZTP network, auto-populate from `network.ztp.ipv4.subnet`. DHCP gateway/range validation already lives in `dhcp_validation.py`.

**Naming convention:** Default `podman_network` = `ztp-net-<vlan_id>` (e.g. `ztp-net-5`). User may override if recreating on same host with different parent.

---

## 6. Host prerequisites (documented, not automated)

The UI shows a **Prerequisites** panel:

1. Parent interface exists, `operstate up` (e.g. `enp7s0.5`).
2. Switch port carries the ZTP VLAN (access or tagged trunk) — operator responsibility.
3. Pod IP is not used by another host/container on that segment (ARP conflict check optional v1.1).
4. For host→pod debugging: optional `macvlan-host` in bridge mode on same parent (existing NM pattern on fedora1).
5. Firewall allows UDP 67/68 and TCP 443 to pod IP from ZTP VLAN.

**Discovery API** lists candidate parents:

- Physical interfaces: `enp*`, `eth*`, `ens*`
- VLAN subinterfaces: `*.@*` from `ip -d link show type vlan`
- Annotate with IPv4 if assigned (helps operator pick the right uplink)

Do **not** auto-pick the first `enp*` (current `auto_create_macvlan_network` weakness).

---

## 7. Runtime operations

New module: **`webui/network_deploy.py`** (mirrors `dhcp_deploy.py` patterns).

### 7.1 Functions

| Function | Description |
|----------|-------------|
| `discover_parent_interfaces()` | List host interfaces suitable as macvlan parent |
| `inspect_podman_network(name)` | Return subnets, parent, containers attached |
| `validate_ztp_profile(config)` | Schema + IP in subnet + parent exists + no pool overlap with pod IP |
| `plan_network_changes(current, desired)` | Create / replace / no-op |
| `ensure_podman_network(profile)` | `podman network create -d macvlan …` or skip if matching inspect |
| `remove_stale_network(name)` | Only if no foreign containers attached |
| `sync_pod_quadlet(profile)` | Write `Network=`, `IP=`, `IP6=` to `ztpbootstrap.pod` |
| `apply_ztp_network(config, restart=True)` | Orchestrator |
| `restart_ztp_stack()` | Ordered systemd restart |
| `get_network_status()` | Drift detection: config vs podman vs quadlet |

### 7.2 Podman network create (reference)

```bash
podman network create -d macvlan \
  --subnet 10.0.5.0/24 --gateway 10.0.5.1 \
  --subnet 2601:441:8483:b505::/64 --gateway 2601:441:8483:b505::1 \
  -o parent=enp7s0.5 \
  -o mode=bridge \
  ztp-net-5
```

**Replace semantics:** Podman cannot change subnet/parent in place. Plan:

1. Stop pod (and DHCP first).
2. If old network exists and only ztpbootstrap used it → `podman network rm <old>`.
3. Create new network.
4. Update quadlet.
5. Start pod.

If old network is shared (e.g. `net-10` with grafana), **refuse** removal and warn.

### 7.3 Quadlet sync

Update `/etc/containers/systemd/ztpbootstrap/ztpbootstrap.pod`:

```ini
[Pod]
PodName=ztpbootstrap
Network=ztp-net-5
IP=10.0.5.10
IP6=2601:441:8483:b505::10
```

Also set `container.host_network: false` in config when ZTP profile enabled.

Reuse logic from `update-config.sh` `update_pod_file()` — prefer extracting shared Python implementation to avoid shell/Python drift.

### 7.4 Restart orchestration

**Trigger:** UI button **Apply & restart** (and optional **Restart only** if config already applied).

```text
1. Validate config (blocking errors → 400, no changes)
2. Write config.yaml (atomic rename)
3. stop ztpbootstrap-dhcp.service     (if active)
4. stop ztpbootstrap-webui.service
5. stop ztpbootstrap-nginx.service
6. stop ztpbootstrap-pod.service
7. ensure_podman_network()
8. sync_pod_quadlet()
9. regenerate Kea configs (if dhcp.enabled)
10. systemctl daemon-reload
11. start ztpbootstrap-pod.service
12. start ztpbootstrap-nginx.service
13. start ztpbootstrap-webui.service
14. start ztpbootstrap-dhcp.service   (if enabled)
15. poll health: /health, /api/dhcp/status
16. update network.ztp.status / applied_at
```

**Concurrency:** Mutex lock file `/opt/containerdata/ztpbootstrap/.network-apply.lock` to prevent parallel applies.

**Failure recovery:** On failure after step 6, set `status: error`, `last_error`, attempt start with **previous** quadlet snapshot if new network create failed (keep `.ztpbootstrap-backups/network/` copy).

### 7.5 Drift detection

`GET /api/network/status` compares:

- `config.yaml` `network.ztp.*`
- `podman network inspect`
- `grep` quadlet `Network=/IP=`
- Running pod addresses (`podman pod inspect`)

Return `drift: true` with human-readable diff so UI can show “Config pending — restart required”.

---

## 8. REST API

| Method | Path | Purpose |
|--------|------|---------|
| `GET` | `/api/network/status` | Current profile, apply state, drift, running pod IPs |
| `GET` | `/api/network/parents` | Discover parent interfaces |
| `GET` | `/api/network/podman` | List podman networks (filter ztp-net-*) |
| `POST` | `/api/network/validate` | Dry-run validation + change plan |
| `PUT` | `/api/network/ztp` | Save ZTP profile to config (no restart) |
| `POST` | `/api/network/apply` | Save + `apply_ztp_network(restart=True)` |
| `POST` | `/api/network/restart` | Restart stack only (no config change) |
| `POST` | `/api/network/auto-detect` | Suggest subnet/gw from parent IPv4 / routes (helper) |

**Auth:** Same session auth as DHCP mutations (`@require_auth`).

**Response example (`/api/network/status`):**

```json
{
  "ztp": {
    "enabled": true,
    "vlan_id": 5,
    "parent_interface": "enp7s0.5",
    "podman_network": "ztp-net-5",
    "ipv4": { "address": "10.0.5.10", "subnet": "10.0.5.0/24", "gateway": "10.0.5.1" },
    "status": "applied",
    "applied_at": "2026-06-17T12:00:00Z",
    "drift": false
  },
  "running": {
    "pod_ip": "10.0.5.10",
    "pod_network": "ztp-net-5",
    "pod_state": "running"
  },
  "prerequisites": {
    "parent_exists": true,
    "parent_oper_up": true,
    "podman_network_exists": true
  }
}
```

---

## 9. Web UI

### 9.0 Tab model

ZTP Network is a **top-level application tab**, peer to the existing **ZTP Bootstrap Service** and **DHCP Server** tabs (not a sub-tab inside DHCP).

```text
┌──────────────────────────────────────────────────────────────────────┐
│  [ ZTP Bootstrap Service ]  [ ZTP Network ]  [ DHCP Server ]       │
└──────────────────────────────────────────────────────────────────────┘
```

**Rationale:** Network placement affects the entire pod (nginx, webui, Kea). It is infrastructure configuration, not DHCP policy. Keeping it separate avoids burying L2/macvlan settings under DHCP and makes the dependency order obvious: configure **ZTP Network** first, then **DHCP Server**.

**Alpine.js state** (extends current `activeApplication` pattern in `index.html`):

| Key | Values | Persisted |
|-----|--------|-----------|
| `activeApplication` | `'ztpbootstrap'` \| `'ztp-network'` \| `'dhcp'` | `localStorage` (`ztpbootstrap-activeApplication`) |

No sub-tabs required for v1 — the ZTP Network tab is a single scrollable panel (status cards + form + actions). Sub-tabs (e.g. “Advanced”) can be added later if needed.

**Tab content layout:**

1. **Status row** — apply state (`applied` / `pending` / `error` / `drift`), running pod IP, podman network name, parent interface oper state.
2. **Prerequisites checklist** — parent exists, oper-up, no shared-network conflict.
3. **Configuration form** — fields in §9.1.
4. **Actions** — Validate, Save, Apply & restart, Restart only.
5. **Cross-links** — when DHCP subnet mismatches ZTP profile, show a warning banner on the **DHCP Server** tab with link “Fix in ZTP Network →”.

**Auth:** Mutating actions require admin session (same as Configuration and DHCP tabs).

**Init / polling:** On switch to `activeApplication === 'ztp-network'`, call `GET /api/network/status` and `GET /api/network/parents`. Optional 30s poll while tab is active and `status === 'pending'` or apply in progress.

### 9.1 Fields

| Field | Control | Notes |
|-------|---------|-------|
| Enable ZTP macvlan | Toggle | Off → lab host-network warning |
| VLAN ID | Number | Drives default network name label |
| Parent interface | Dropdown + manual | From `/api/network/parents` |
| Pod IPv4 | Text | e.g. `10.0.5.10` |
| IPv4 subnet | CIDR | e.g. `10.0.5.0/24` |
| IPv4 gateway | Text | e.g. `10.0.5.1` |
| Pod IPv6 | Text | Optional |
| IPv6 subnet / gateway | Text | Optional pair |
| Podman network name | Text | Default `ztp-net-<vlan>` |
| Domain | Read/write | Sync with existing `network.domain` |

### 9.2 Actions

- **Validate** — calls `/api/network/validate`, shows errors/warnings inline.
- **Save** — persist without restart (status → `pending`).
- **Apply & restart** — primary action; confirm modal (“ZTP and DHCP will be unavailable ~30s”).
- **Restart only** — when drift detected.

### 9.3 Status UX

- Banner: `Applied` / `Pending restart` / `Error` / `Drift detected`
- Prerequisites checklist (green/red)
- Link to docs anchor for host VLAN setup
- After apply: show pod IP and remind to update DNS A/AAAA if domain should resolve to new IP

### 9.4 DHCP tab integration (cross-tab, not embedded)

The DHCP Server tab does **not** host ZTP Network controls. Integration is via shared config and cross-tab UX only:

- When ZTP profile is saved/applied, pre-fill `dhcp.ipv4.subnet` / gateway if DHCP fields are empty.
- On the **DHCP Server → Configuration** sub-tab, show a banner if `dhcp.ipv4.subnet` ≠ `network.ztp.ipv4.subnet` with link to the **ZTP Network** tab.
- On the **ZTP Network** tab, show a reminder if DHCP is enabled but subnets disagree.
- Hide or de-emphasize the DHCP “host networking” info banner when `network.ztp.enabled` (macvlan is the production path).

---

## 10. Implementation phases

### Phase 1 — Core backend (MVP)

- [ ] `network_utils.py` — parent discovery, podman inspect helpers
- [ ] `network_validation.py` — schema validation, conflict checks
- [ ] `network_deploy.py` — create network, sync quadlet, restart orchestration
- [ ] API routes in `app.py`
- [ ] Extend `config.yaml.template`
- [ ] Unit tests (validation, plan_network_changes mock podman)

### Phase 2 — UI

- [ ] Add **ZTP Network** top-level tab in `index.html` (`activeApplication === 'ztp-network'`)
- [ ] Status cards + configuration panel for ZTP Network tab
- [ ] Wire validate / save / apply / status polling on tab enter
- [ ] Drift banner and prerequisite checklist
- [ ] Cross-tab DHCP subnet mismatch banner (DHCP tab → link to ZTP Network tab)

### Phase 3 — Integration & hardening

- [ ] DHCP auto-fill from ZTP profile
- [ ] Backup/restore quadlet + config snapshot before apply (`.ztpbootstrap-backups/network/`)
- [ ] Integration test (BATS): mock podman socket or test VM with macvlan parent
- [ ] Update `setup-interactive.sh` to seed `network.ztp` from install prompts
- [ ] Update `update-config.sh` to call shared quadlet sync or deprecate duplicate sed logic

### Phase 4 — Docs & ops

- [ ] `docs/ZTP_NETWORK_HOST_SETUP.md` — VLAN subinterface examples (Fedora NM, ip-link)
- [ ] AGENTS.md / README pointer
- [ ] Migration note: moving from `net-10` @ `10.0.10.10` to `ztp-net-5` @ `10.0.5.10`

### 10.1 Farm-out buckets & PR stack

Phases above are **sequential milestones**. Buckets below are **parallel work units** for separate PRs or agents. Each bucket has explicit deliverables, dependencies, and acceptance checks.

#### Dependency graph

```text
B0 (Contract) → B1 (Validation) → B2 (Deploy) ─┬→ B3 (API) → B4 (UI tab)
                                                │              → B5 (DHCP glue)
                                                ├→ B6 (Hardening)
                                                └→ B7 (Install scripts)
B0 → B8 (Unit tests)     B3+B4 → B9 (Integration)     B0 → B10 (Ops docs)
```

**Merge train:** B0 → B1 → B2 (+ B6) → B3 → B4 ∥ B5 → B7 → B8/B9 → B10

#### Bucket map

| Bucket | Name | Depends on | Parallel with |
|--------|------|------------|---------------|
| **B0** | Contract & schema | — | — |
| **B1** | Discovery & validation | B0 | B8 (stubs) |
| **B2** | Deploy orchestrator | B1 | B6 |
| **B3** | REST API | B2 | B8 |
| **B4** | ZTP Network UI tab | B3 | B5, B10 |
| **B5** | DHCP cross-tab glue | B3 | B4 |
| **B6** | Hardening | B2 | — |
| **B7** | Install alignment | B2 | B10 |
| **B8** | Unit tests | B0, B1 | B1, B3 |
| **B9** | Integration tests | B3, B4 | B8 |
| **B10** | Ops docs | B0 | B4, B7 |

GitHub issues use labels `network/B0` … `network/B10` and epic label `runtime-ztp-network`.

| Bucket | GitHub issue |
|--------|--------------|
| Epic | [#60](https://github.com/coreyhines/ztpbootstrap/issues/60) |
| B0 | [#49](https://github.com/coreyhines/ztpbootstrap/issues/49) |
| B1 | [#50](https://github.com/coreyhines/ztpbootstrap/issues/50) |
| B2 | [#51](https://github.com/coreyhines/ztpbootstrap/issues/51) |
| B3 | [#53](https://github.com/coreyhines/ztpbootstrap/issues/53) |
| B4 | [#52](https://github.com/coreyhines/ztpbootstrap/issues/52) |
| B5 | [#56](https://github.com/coreyhines/ztpbootstrap/issues/56) |
| B6 | [#54](https://github.com/coreyhines/ztpbootstrap/issues/54) |
| B7 | [#57](https://github.com/coreyhines/ztpbootstrap/issues/57) |
| B8 | [#55](https://github.com/coreyhines/ztpbootstrap/issues/55) |
| B9 | [#58](https://github.com/coreyhines/ztpbootstrap/issues/58) |
| B10 | [#59](https://github.com/coreyhines/ztpbootstrap/issues/59) |

#### B0 — Contract & schema

**Deliverables**

- `config.yaml.template` — add `network.ztp` block (§5)
- Shared read/write helpers; legacy alias (`network.ipv4` ↔ `network.ztp.ipv4.address`)
- API contract appendix (request/response shapes for all §8 endpoints)

**Done when:** Empty/default and legacy-only configs load without regression.

**Out of scope:** Podman calls, UI.

#### B1 — Discovery & validation

**Deliverables**

- `webui/network_utils.py` — `discover_parent_interfaces()`, `inspect_podman_network()`, quadlet parse; reuse `get_podman_cmd()` from `dhcp_deploy.py`
- `webui/network_validation.py` — `validate_ztp_profile()`, `plan_network_changes()`; shared-network removal guard

**Done when:** Validate returns `{ errors[], warnings[], plan }` with no side effects.

**Out of scope:** Flask, UI, pod restart.

#### B2 — Deploy orchestrator

**Deliverables**

- `webui/network_deploy.py` — `ensure_podman_network()`, `remove_stale_network()`, `sync_pod_quadlet()`, `apply_ztp_network()`, `restart_ztp_stack()`, `get_network_status()`
- Mirror legacy `network.ipv4` / `network.network` on apply; Kea regen when `dhcp.enabled`

**Done when:** Manual call moves pod to new macvlan on test VM.

**Out of scope:** HTTP routes, UI, backup/rollback (B6).

#### B3 — REST API

**Deliverables** — `webui/app.py`, all mutations `@require_auth`:

| Method | Path |
|--------|------|
| GET | `/api/network/status` |
| GET | `/api/network/parents` |
| GET | `/api/network/podman` |
| POST | `/api/network/validate` |
| PUT | `/api/network/ztp` |
| POST | `/api/network/apply` |
| POST | `/api/network/restart` |
| POST | `/api/network/auto-detect` |

**Done when:** `curl` exercises happy path and 400 on invalid CIDR.

#### B4 — ZTP Network UI tab

**Deliverables** — `webui/templates/index.html`:

- Third top-level tab: `activeApplication === 'ztp-network'` (+ `localStorage`)
- Prerequisites, status cards, config form, Validate / Save / Apply & restart / Restart only
- Tab enter: status + parents; poll while pending or apply in progress

**Done when:** Full operator flow in browser without SSH.

**Out of scope:** DHCP mismatch banner (B5).

#### B5 — DHCP cross-tab glue

**Deliverables**

- Auto-fill `dhcp.ipv4.subnet` / gateway from ZTP profile when empty
- DHCP Configuration sub-tab mismatch banner + link to ZTP Network tab
- ZTP Network tab reminder when DHCP enabled but subnets disagree
- De-emphasize DHCP host-network banner when `network.ztp.enabled`

**Done when:** Mismatch visible on both tabs; tab switch works.

#### B6 — Hardening (lock, backup, rollback)

**Deliverables**

- Mutex: `/opt/containerdata/ztpbootstrap/.network-apply.lock`
- Pre-apply snapshot: `.ztpbootstrap-backups/network/`
- Failure after pod stop: restore quadlet, attempt start, set `status: error` + `last_error`
- Resolve §15 sudo-helper decision (polkit script vs mounted systemd dir)

**Done when:** Simulated network-create failure leaves pod on old network.

#### B7 — Install script alignment

**Deliverables**

- Extract quadlet sync from `update-config.sh` into shared Python (or document runtime-only path)
- `setup-interactive.sh` seeds `network.ztp` from install prompts
- `update-config.sh` delegates to shared sync

**Done when:** Fresh install + UI apply produce identical quadlet; host-network lab mode unchanged when `network.ztp.enabled: false`.

#### B8 — Unit tests

**Deliverables**

- `tests/unit/test_network_validation.py`
- `tests/unit/test_network_deploy.py` (quadlet text, planner; mocked podman)
- `tests/unit/test_network_utils.py`

**Done when:** `make test-unit` passes without Podman.

#### B9 — Integration tests

**Deliverables**

- `tests/integration/test_network_api.bats` — validate → save → apply → status → drift
- Scenario: create → apply → health → dhcp enable (§12)
- Regression: host-network mode

**Done when:** Passes on VM with macvlan parent or documented mock.

#### B10 — Ops docs

**Deliverables**

- `docs/ZTP_NETWORK_HOST_SETUP.md` — VLAN subinterface, macvlan-host bridge, firewall
- Migration note: `net-10` → `ztp-net-5`
- `AGENTS.md` / `webui/README.md` pointers

**Done when:** Operator can complete host plumbing from docs alone.

#### Suggested PR stack

| PR | Buckets | Title |
|----|---------|-------|
| PR-1 | B0 + B1 + B8 (validation) | feat(network): schema, validation, and discovery |
| PR-2 | B2 + B6 | feat(network): deploy orchestrator with backup/rollback |
| PR-3 | B3 | feat(network): REST API |
| PR-4 | B4 | feat(network): ZTP Network UI tab |
| PR-5 | B5 | feat(network): DHCP subnet alignment and cross-tab UX |
| PR-6 | B7 + B9 | feat(network): install script sync and integration tests |
| PR-7 | B10 | docs(network): host setup and migration guide |

PR-4 and PR-5 can merge in either order after PR-3. PR-7 can open anytime after B0.

#### Pre-flight decisions (before B2+)

1. **Sudo / systemd writes** — mounted `/etc/containers/systemd/ztpbootstrap` vs polkit helper?
2. **IPv6** — required field or “disabled” toggle in UI?
3. **Branch base** — confirm `main` (Kea merged) as integration target.

#### Acceptance criteria → bucket owner

| Criterion (§16) | Primary bucket |
|-----------------|----------------|
| Configure VLAN 5 from UI | B4 + B3 |
| Apply & restart moves pod | B2 + B3 |
| Kea on ZTP VLAN after apply | B2 + B5 |
| Switch ZTP lab test | Manual / B9 |
| Drift & errors in UI | B2 + B4 |
| Host-network lab unchanged | B0 + B7 + B9 |

#### Agent dispatch cheat sheet

```text
Agent A (B0+B1+B8): config schema, network_utils.py, network_validation.py, unit tests. No Flask, no restart.
Agent B (B2+B6): network_deploy.py, lock, backup/restore. Mirror dhcp_deploy.py.
Agent C (B3): Flask /api/network/* only.
Agent D (B4): index.html ZTP Network tab only. Mock API until B3 lands.
Agent E (B5): DHCP auto-fill + mismatch banners only.
Agent F (B7+B9): setup-interactive, update-config, BATS integration tests.
Agent G (B10): ZTP_NETWORK_HOST_SETUP.md + migration doc.
```

---

## 11. Security & permissions

- **Podman socket** — webui container already mounts `/run/podman/podman.sock`; network create requires sufficient API privileges (rootful podman on host).
- **systemd writes** — same privilege model as `dhcp_deploy.py`; may require polkit rule or sudo helper script `ztpbootstrap-apply-network` (document if manual copy still needed).
- **Input validation** — strict CIDR/MAC/interface name regex; reject shell metacharacters in interface names.
- **Auth** — all mutating endpoints require admin session.

---

## 12. Testing strategy

| Level | Scope |
|-------|--------|
| Unit | `network_validation`, change planner, IPv6 suffix remap (reuse `scripts/network-ipv6.sh` logic) |
| Unit | Quadlet text generation |
| Integration | Parent discovery on VM with dummy vlan iface |
| Integration | create → apply → health → dhcp enable on `feature/runtime-ztp-network` branch |
| Manual | fedora1: `enp7s0.5` + `ztp-net-5` + switch ZTP on VLAN 5 |
| Regression | Host-network lab mode still works when `network.ztp.enabled: false` |

---

## 13. Migration from current deployments

**Example: fedora1 today (`net-10`, `10.0.10.10`) → ZTP VLAN 5**

1. Operator creates `enp7s0.5` on host (out of band).
2. In UI: VLAN 5, parent `enp7s0.5`, pod `10.0.5.10`, subnet `10.0.5.0/24`.
3. Apply & restart — creates `ztp-net-5`, moves pod.
4. Update DNS `ztpboot` A/AAAA to `10.0.5.10` / `::10` in `b505::/64`.
5. Enable DHCP with subnet `10.0.5.0/24`, pool excluding `.10`.
6. Deprecate old `net-10` attachment for ztpbootstrap only (do not remove if other containers use `net-10`).

**Backward compatibility:** If `network.ztp` absent, behavior unchanged (read `network.ipv4`, `network.network`).

---

## 14. Risks & mitigations

| Risk | Mitigation |
|------|------------|
| Macvlan host isolation — host cannot curl pod IP | Document; optional `macvlan-host` bridge; health check from inside pod |
| Wrong parent interface | Prerequisites checklist; validate oper-up; no auto-guess |
| Shared podman network removal | Inspect attached containers before `network rm` |
| Apply failure leaves pod down | Quadlet snapshot restore; clear error in UI |
| Duplicate IP on segment | Validate + optional ARP probe (v1.1) |
| NFS config shared across hosts | `network.ztp.status` per-host metadata; warn if multiple hosts mount same config (existing duplicate-IP issue) |
| systemd transient units | Use `systemctl start ztpbootstrap-pod.service` not `enable` for generated units |

---

## 15. Open questions

1. **Sudo helper** — Should we ship `scripts/ztpbootstrap-apply-network.sh` (setuid/polkit) for reliable `/etc/containers` writes, or rely on mounted systemd dir?
2. **IPv6 required?** — Make optional in UI with “IPv6 disabled” toggle (already supported in quadlet).
3. **DNS auto-update** — OPNsense/Pi-hole API integration deferred?
4. **Branch base** — Build on `main` (Kea merged) or long-lived `feature/dhcp-implementation`?

---

## 16. Acceptance criteria

- [ ] Operator can configure VLAN 5 ZTP network entirely from Web UI without SSH.
- [ ] Apply & restart creates macvlan, updates quadlet, pod comes up on new IP.
- [ ] Kea (when enabled) serves DHCP on ZTP VLAN after apply.
- [ ] Switch can complete ZTP bootstrap from same VLAN (manual lab test).
- [ ] Drift and error states visible in UI.
- [ ] Host-network lab mode unchanged when ZTP profile disabled.

---

## Appendix A — File map (planned)

| File | Action |
|------|--------|
| `webui/network_deploy.py` | **New** — orchestration |
| `webui/network_utils.py` | **New** — discovery |
| `webui/network_validation.py` | **New** — validation |
| `webui/app.py` | Add `/api/network/*` routes |
| `webui/templates/index.html` | **ZTP Network** top-level app tab + `activeApplication` state |
| `config.yaml.template` | `network.ztp` block |
| `tests/unit/test_network_*.py` | **New** |
| `tests/integration/test_network_api.bats` | **New** |
| `docs/ZTP_NETWORK_HOST_SETUP.md` | **New** — host plumbing guide |

## Appendix B — Related commands (operator reference)

```bash
# Host VLAN subinterface (example — not run by ztpbootstrap)
sudo ip link add link enp7s0 name enp7s0.5 type vlan id 5
sudo ip link set enp7s0.5 up

# Manual podman network (what the UI automates)
sudo podman network create -d macvlan \
  --subnet 10.0.5.0/24 --gateway 10.0.5.1 \
  -o parent=enp7s0.5 ztp-net-5
```
