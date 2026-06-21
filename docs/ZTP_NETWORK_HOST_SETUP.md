# ZTP Network — Host Setup Guide

Operator-facing steps to prepare a Fedora (or RHEL-family) host **before** using the **ZTP Network** tab in the Web UI. The ztpbootstrap service does **not** create VLAN subinterfaces, switch port modes, or firewall rules automatically — it validates prerequisites and manages Podman macvlan networks at runtime.

For feature design, API, and UI behavior, see [RUNTIME_ZTP_NETWORK_SPEC.md](RUNTIME_ZTP_NETWORK_SPEC.md).

---

## Overview

Production ZTP requires the entire ztpbootstrap pod (nginx, Web UI, Kea) on the **same L2 segment** as Arista switches (for example VLAN 5 / `10.0.5.0/24`). The host must expose a suitable **parent interface** for Podman macvlan; the Web UI then creates `ztp-net-<vlan>` and moves the pod.

```text
Switch ZTP VLAN ── L2 ── enp7s0.5 (host) ── parent ── ztp-net-5 (macvlan) ── pod @ 10.0.5.10
```

---

## Prerequisites checklist

Complete these **before** clicking **Apply & restart** in the Web UI:

| # | Requirement | How to verify |
|---|-------------|---------------|
| 1 | Parent interface exists and is **oper-up** (e.g. `enp7s0.5`) | `ip link show enp7s0.5` → `state UP` |
| 2 | Switch port carries the ZTP VLAN (access or tagged trunk) | Switch config / LLDP |
| 3 | Pod IP is free on the segment (no ARP conflict) | Ping/ARP from another host on VLAN |
| 4 | (Optional) Host→pod path for debugging | `macvlan-host` bridge — see below |
| 5 | Firewall allows DHCP and HTTPS to the pod | UDP 67/68, TCP 443 — see below |

The Web UI **Prerequisites** panel checks parent existence and oper state; it does not configure the host for you.

---

## 1. VLAN subinterface on the host

The macvlan parent must be the interface that actually carries the ZTP VLAN on the hypervisor. Common pattern: physical NIC + VLAN subinterface.

**Example (freeblizz lab):** trunk/access on `enp7s0`, ZTP on VLAN 5 → parent `enp7s0.5`.

Replace `enp7s0` and VLAN ID `5` with your uplink and ZTP VLAN.

### Temporary setup (`ip link`)

Useful for testing; lost on reboot unless scripted.

```bash
# Create VLAN 5 subinterface on enp7s0
sudo ip link add link enp7s0 name enp7s0.5 type vlan id 5
sudo ip link set enp7s0.5 up

# Verify
ip -d link show enp7s0.5
```

The parent does **not** need an IP address for macvlan to work, but assigning one can help operators identify the correct interface in the Web UI parent dropdown.

### Persistent setup (NetworkManager on Fedora)

```bash
# VLAN subinterface connection
sudo nmcli connection add type vlan \
  con-name enp7s0.5 \
  ifname enp7s0.5 \
  dev enp7s0 id 5

# Optional: assign a host IP on the ZTP subnet for management/routing
sudo nmcli connection modify enp7s0.5 \
  ipv4.method manual \
  ipv4.addresses 10.0.5.2/24 \
  ipv4.gateway 10.0.5.1

sudo nmcli connection up enp7s0.5

# Verify
nmcli connection show enp7s0.5
ip link show enp7s0.5
```

**Notes:**

- If the physical port is an **access** port for VLAN 5 only, you may use `enp7s0` directly as the macvlan parent instead of a subinterface — match what your switch presents on the wire.
- Ensure the uplink (`enp7s0`) is up before bringing up the VLAN subinterface.

---

## 2. Optional: `macvlan-host` bridge (host → pod access)

Podman macvlan containers live on the segment but are **isolated from the host** by default: the host often cannot `curl https://10.0.5.10` on the pod IP. That is expected macvlan behavior.

**Operator access to the Web UI** usually comes from **routed** management networks (e.g. VLAN 10 → `10.0.5.10`). For **local debugging** on the hypervisor, add a macvlan interface on the **same parent** in **bridge** mode:

### Temporary (`ip link`)

```bash
sudo ip link add macvlan-host link enp7s0.5 type macvlan mode bridge
sudo ip addr add 10.0.5.254/24 dev macvlan-host
sudo ip link set macvlan-host up

# Test from host
curl -k https://10.0.5.10/health
```

Pick an address outside your DHCP pool and not equal to the pod IP (`10.0.5.10`).

### Persistent (NetworkManager)

```bash
sudo nmcli connection add type macvlan \
  con-name macvlan-host \
  ifname macvlan-host \
  dev enp7s0.5 \
  mode bridge

sudo nmcli connection modify macvlan-host \
  ipv4.method manual \
  ipv4.addresses 10.0.5.254/24 \
  ipv4.never-default yes

sudo nmcli connection up macvlan-host
```

Health checks from **inside** the pod (`podman exec …`) always work without this bridge.

---

## 3. Firewall

Switches on the ZTP VLAN must reach:

| Protocol | Port | Service |
|----------|------|---------|
| UDP | 67 | DHCP server (Kea) |
| UDP | 68 | DHCP client relay path |
| TCP | 443 | HTTPS bootstrap (`bootstrap.py`) |

Allow traffic **to the pod IP** (e.g. `10.0.5.10`) from the ZTP subnet. Management access from other VLANs is a separate policy choice.

### firewalld (Fedora default)

```bash
# Example: allow DHCP + HTTPS on the public zone (adjust zone to match your host)
sudo firewall-cmd --permanent --add-port=67/udp
sudo firewall-cmd --permanent --add-port=68/udp
sudo firewall-cmd --permanent --add-port=443/tcp
sudo firewall-cmd --reload
```

For tighter scope, use a rich rule limited to the ZTP source CIDR:

```bash
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="10.0.5.0/24" port port="67" protocol="udp" accept'
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="10.0.5.0/24" port port="68" protocol="udp" accept'
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="10.0.5.0/24" port port="443" protocol="tcp" accept'
sudo firewall-cmd --reload
```

If Kea binds inside the pod network namespace, ensure the host firewall (or lack thereof on the macvlan path) does not block L2-adjacent DHCP — in many macvlan deployments, DHCP is not filtered on the host because frames go parent ↔ container directly. Still verify with a switch or `tcpdump` on `enp7s0.5` during DISCOVER.

---

## 4. Manual Podman network commands (reference)

The **ZTP Network** tab automates these steps. Use manual commands for troubleshooting or when the UI is unavailable.

### Create macvlan network

```bash
sudo podman network create -d macvlan \
  --subnet 10.0.5.0/24 --gateway 10.0.5.1 \
  --subnet 2601:441:8483:b505::/64 --gateway 2601:441:8483:b505::1 \
  -o parent=enp7s0.5 \
  -o mode=bridge \
  ztp-net-5
```

IPv6 subnets are optional; omit the second `--subnet` / `--gateway` pair if unused.

### Inspect and list

```bash
sudo podman network inspect ztp-net-5
sudo podman network ls
sudo podman pod inspect ztpbootstrap --format '{{.InfraConfig.Networks}}'
```

### Remove (only when safe)

Podman cannot change subnet or parent in place. Removal is required before recreating with new parameters.

```bash
# Stop pod first
sudo systemctl stop ztpbootstrap-pod.service

# Only remove if no other containers use the network
sudo podman network rm ztp-net-5
```

**Warning:** Do not remove shared networks (e.g. `net-10` used by Grafana and ztpbootstrap). The Web UI refuses removal when foreign containers are attached.

### Quadlet alignment

After creating the network, the pod must reference it in `/etc/containers/systemd/ztpbootstrap/ztpbootstrap.pod`:

```ini
[Pod]
PodName=ztpbootstrap
Network=ztp-net-5
IP=10.0.5.10
IP6=2601:441:8483:b505::10
```

Then `sudo systemctl daemon-reload` and restart the stack. **Apply & restart** in the Web UI performs this sync automatically.

---

## 5. Migration: `net-10` @ `10.0.10.10` → `ztp-net-5` @ `10.0.5.10`

Typical fedora1-style lab migration from a management macvlan (`net-10`) to the ZTP segment (VLAN 5).

### Before you start

- Document current `config.yaml` (`network.ipv4`, `network.network`).
- Confirm whether `net-10` is shared with other containers — **do not** `podman network rm net-10` if so.
- Plan DNS updates for bootstrap hostname (e.g. `ztpboot.example.com`).

### Steps

1. **Create host plumbing (out of band)**  
   Bring up `enp7s0.5` (or your parent) per [§1](#1-vlan-subinterface-on-the-host). Confirm oper-up.

2. **Configure in Web UI — ZTP Network tab**  
   - VLAN ID: `5`  
   - Parent interface: `enp7s0.5`  
   - Pod IPv4: `10.0.5.10`  
   - Subnet: `10.0.5.0/24`, gateway: `10.0.5.1`  
   - Podman network name: `ztp-net-5` (default)

3. **Apply & restart**  
   Creates `ztp-net-5`, updates quadlet, restarts the pod (~30s outage). Old `net-10` attachment for ztpbootstrap is replaced; `net-10` itself remains if other services use it.

4. **Update DNS**  
   Point bootstrap A/AAAA records to `10.0.5.10` and the IPv6 address in your `/64` (e.g. `…::10`).

5. **Configure DHCP (DHCP Server tab)**  
   - Subnet: `10.0.5.0/24`  
   - Pool excluding `.10` (pod IP)  
   - Enable Kea after validation

6. **Verify**  
   - Web UI shows `status: applied`, no drift  
   - Switch on VLAN 5 receives DHCP and fetches `https://<domain>/bootstrap.py`  
   - Optional: `curl -k https://10.0.5.10/health` from a routed client or via `macvlan-host`

### Rollback

If apply fails, the Web UI records `status: error` and may restore a quadlet snapshot from `.ztpbootstrap-backups/network/`. Manual rollback: restore previous `ztpbootstrap.pod` (`Network=net-10`, `IP=10.0.10.10`), `daemon-reload`, restart pod.

### Backward compatibility

Installs without `network.ztp` in `config.yaml` continue using legacy `network.ipv4` and `network.network` until migrated through the UI.

---

## Related documentation

- [RUNTIME_ZTP_NETWORK_SPEC.md](RUNTIME_ZTP_NETWORK_SPEC.md) — feature spec, API, UI tabs
- [DHCP_IMPLEMENTATION_PLAN.md](DHCP_IMPLEMENTATION_PLAN.md) — Kea configuration
- [QUICK_START.md](QUICK_START.md) — lab mode with host networking (no macvlan)
