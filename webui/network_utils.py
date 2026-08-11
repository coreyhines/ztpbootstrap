#!/usr/bin/env python3
"""
ZTP network discovery and Podman/quadlet inspection helpers.
"""

from __future__ import annotations

import ipaddress
import json
import logging
import re
import subprocess
from pathlib import Path
from typing import Any, Dict, List, Optional

logger = logging.getLogger(__name__)

SYSTEMD_DIR = Path("/etc/containers/systemd/ztpbootstrap")
POD_FILE = SYSTEMD_DIR / "ztpbootstrap.pod"
POD_NAME = "ztpbootstrap"

INTERFACE_NAME_RE = re.compile(r"^[a-zA-Z][a-zA-Z0-9._-]{0,30}$")
PHYSICAL_IFACE_RE = re.compile(r"^(enp|eth|ens|eno|em|bond|br)\S+", re.I)
VLAN_IFACE_RE = re.compile(r"^(.+)\.(\d+)$")


def get_podman_cmd() -> List[str]:
    """Reuse dhcp_deploy podman resolution when available."""
    try:
        from dhcp_deploy import get_podman_cmd as _get_podman_cmd

        return _get_podman_cmd()
    except ImportError:
        return ["podman"]


def _run_cmd(cmd: List[str], timeout: int = 15) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def _find_ip_cmd() -> Optional[str]:
    for ip_path in ("/usr/sbin/ip", "/sbin/ip", "ip"):
        try:
            result = _run_cmd([ip_path, "--version"], timeout=2)
            if result.returncode == 0:
                return ip_path
        except (FileNotFoundError, subprocess.TimeoutExpired):
            continue
    return None


def _interface_operstate(ip_cmd: str, iface: str) -> str:
    try:
        path = Path(f"/sys/class/net/{iface}/operstate")
        if path.exists():
            return path.read_text().strip()
        result = _run_cmd([ip_cmd, "link", "show", iface], timeout=2)
        if result.returncode == 0 and "state UP" in result.stdout:
            return "up"
    except OSError:
        pass
    return "unknown"


def _interface_ipv4(ip_cmd: str, iface: str) -> Optional[str]:
    try:
        result = _run_cmd([ip_cmd, "-4", "addr", "show", iface], timeout=2)
        if result.returncode != 0:
            return None
        for line in result.stdout.splitlines():
            match = re.search(r"inet\s+(\d+\.\d+\.\d+\.\d+)", line)
            if match:
                return match.group(1)
    except subprocess.TimeoutExpired:
        pass
    return None


def discover_parent_interfaces() -> List[Dict[str, Any]]:
    """
    List candidate macvlan parent interfaces with operstate and optional IPv4.
    """
    ip_cmd = _find_ip_cmd()
    if not ip_cmd:
        logger.warning("ip command not found; cannot discover parent interfaces")
        return []

    parents: List[Dict[str, Any]] = []
    seen = set()

    try:
        result = _run_cmd([ip_cmd, "-d", "link", "show", "type", "vlan"], timeout=5)
        if result.returncode == 0:
            current = None
            for line in result.stdout.splitlines():
                header = re.match(r"^\d+:\s+(\S+):", line)
                if header:
                    current = header.group(1).rstrip("@")
                    if current.endswith(":"):
                        current = current[:-1]
                if current and "vlan id" in line.lower():
                    vid_match = re.search(r"vlan id\s+(\d+)", line, re.I)
                    if vid_match and current not in seen:
                        seen.add(current)
                        parents.append(
                            {
                                "name": current,
                                "kind": "vlan",
                                "vlan_id": int(vid_match.group(1)),
                                "operstate": _interface_operstate(ip_cmd, current),
                                "ipv4": _interface_ipv4(ip_cmd, current),
                            }
                        )
    except subprocess.TimeoutExpired:
        logger.warning("Timeout listing VLAN interfaces")

    try:
        result = _run_cmd([ip_cmd, "link", "show"], timeout=5)
        if result.returncode == 0:
            for line in result.stdout.splitlines():
                match = re.match(r"^\d+:\s+(\S+):", line)
                if not match:
                    continue
                iface = match.group(1).rstrip("@")
                if iface.endswith(":"):
                    iface = iface[:-1]
                if iface in ("lo",) or iface.startswith(("veth", "docker", "podman", "cni")):
                    continue
                if iface in seen:
                    continue
                if not (PHYSICAL_IFACE_RE.match(iface) or VLAN_IFACE_RE.match(iface)):
                    continue
                seen.add(iface)
                kind = "vlan" if VLAN_IFACE_RE.match(iface) else "physical"
                vlan_id = None
                vlan_match = VLAN_IFACE_RE.match(iface)
                if vlan_match:
                    vlan_id = int(vlan_match.group(2))
                parents.append(
                    {
                        "name": iface,
                        "kind": kind,
                        "vlan_id": vlan_id,
                        "operstate": _interface_operstate(ip_cmd, iface),
                        "ipv4": _interface_ipv4(ip_cmd, iface),
                    }
                )
    except subprocess.TimeoutExpired:
        logger.warning("Timeout listing network interfaces")

    parents.sort(key=lambda item: item["name"])
    return parents


def inspect_podman_network(name: str) -> Optional[Dict[str, Any]]:
    """Return podman network inspect summary or None if missing."""
    if not name or name == "host":
        return None
    cmd = get_podman_cmd() + ["network", "inspect", name, "--format", "{{json .}}"]
    try:
        result = _run_cmd(cmd, timeout=15)
        if result.returncode != 0:
            return None
        data = json.loads(result.stdout.strip())
        subnets = []
        for subnet in data.get("subnets") or []:
            subnets.append(
                {
                    "subnet": subnet.get("subnet"),
                    "gateway": subnet.get("gateway"),
                }
            )
        options = data.get("options") or {}
        # Podman >= 4.x macvlan parent is top-level network_interface; older
        # versions may store it under options.parent / parent_interface.
        parent = (
            data.get("network_interface")
            or options.get("parent")
            or options.get("parent_interface")
        )
        containers = data.get("containers") or {}
        container_names: List[str] = []
        for cid, cinfo in containers.items():
            if isinstance(cinfo, dict):
                name = (cinfo.get("name") or cid).lstrip("/")
            else:
                name = str(cid)
            container_names.append(name)
        return {
            "name": data.get("name") or name,
            "driver": data.get("driver"),
            "subnets": subnets,
            "parent": parent,
            "mode": options.get("mode"),
            "container_count": len(container_names),
            "containers": container_names,
        }
    except (json.JSONDecodeError, subprocess.TimeoutExpired, FileNotFoundError) as exc:
        logger.warning(f"Failed to inspect podman network {name}: {exc}")
        return None


def list_ztp_podman_networks(prefix: str = "ztp-net-") -> List[Dict[str, Any]]:
    cmd = get_podman_cmd() + ["network", "ls", "--format", "{{.Name}}"]
    try:
        result = _run_cmd(cmd, timeout=15)
        if result.returncode != 0:
            return []
        names = [line.strip() for line in result.stdout.splitlines() if line.strip()]
        out = []
        for name in names:
            if name.startswith(prefix) or name == "ztpbootstrap-net":
                info = inspect_podman_network(name)
                if info:
                    out.append(info)
        return out
    except subprocess.TimeoutExpired:
        return []


def parse_pod_quadlet(path: Optional[Path] = None) -> Dict[str, Optional[str]]:
    """Parse Network=/IP=/IP6= from ztpbootstrap.pod quadlet."""
    pod_path = path or POD_FILE
    values: Dict[str, Optional[str]] = {
        "network": None,
        "ipv4": None,
        "ipv6": None,
        "path": str(pod_path),
        "exists": pod_path.exists(),
    }
    if not pod_path.exists():
        return values
    for line in pod_path.read_text().splitlines():
        line = line.strip()
        if line.startswith("Network="):
            values["network"] = line.split("=", 1)[1].strip()
        elif line.startswith("IP="):
            values["ipv4"] = line.split("=", 1)[1].strip()
        elif line.startswith("IP6="):
            values["ipv6"] = line.split("=", 1)[1].strip()
    return values


def inspect_running_pod() -> Dict[str, Any]:
    cmd = get_podman_cmd() + ["pod", "inspect", POD_NAME, "--format", "{{json .}}"]
    try:
        result = _run_cmd(cmd, timeout=15)
        if result.returncode != 0:
            return {"exists": False, "running": False}
        data = json.loads(result.stdout.strip())
        networks = data.get("Networks") or {}
        return {
            "exists": True,
            "running": (data.get("State") or "").lower() == "running",
            "networks": networks,
        }
    except (json.JSONDecodeError, subprocess.TimeoutExpired):
        return {"exists": False, "running": False}


def remap_ipv6_to_subnet(candidate: str, subnet_cidr: str) -> Optional[str]:
    """Preserve host suffix when mapping IPv6 onto a new prefix."""
    try:
        old = ipaddress.ip_address(candidate)
        net = ipaddress.ip_network(subnet_cidr, strict=False)
        if old in net:
            return str(old)
        host_bits = 128 - net.prefixlen
        if host_bits <= 0:
            return None
        host_mask = (1 << host_bits) - 1
        host_part = int(old) & host_mask
        new_ip = ipaddress.ip_address(int(net.network_address) | host_part)
        if new_ip not in net:
            return None
        return str(new_ip)
    except ValueError:
        return None


def resolve_ipv6_for_network(candidate: str, network_name: str) -> Optional[str]:
    """Validate or remap IPv6 for an existing podman network."""
    info = inspect_podman_network(network_name)
    if not info:
        return candidate or None
    ipv6_subnet = None
    for subnet in info.get("subnets") or []:
        cidr = subnet.get("subnet") or ""
        if ":" in cidr:
            ipv6_subnet = cidr
            break
    if not candidate:
        return None
    if not ipv6_subnet:
        return candidate
    try:
        if ipaddress.ip_address(candidate) in ipaddress.ip_network(ipv6_subnet, strict=False):
            return candidate
    except ValueError:
        return None
    return remap_ipv6_to_subnet(candidate, ipv6_subnet)


def is_valid_interface_name(name: str) -> bool:
    return bool(name and INTERFACE_NAME_RE.match(name))
