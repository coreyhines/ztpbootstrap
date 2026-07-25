#!/usr/bin/env python3
"""
ZTP network profile helpers — config schema, legacy aliases, defaults.
"""

from __future__ import annotations

from copy import deepcopy
from datetime import datetime, timezone
from typing import Any, Dict, Optional

DEFAULT_MACVLAN_MODE = "bridge"
DEFAULT_PODMAN_NETWORK_PREFIX = "ztp-net-"


def default_ztp_profile() -> Dict[str, Any]:
    """Return an empty/disabled ZTP network profile."""
    return {
        "enabled": False,
        "vlan_id": None,
        "parent_interface": "",
        "podman_network": "",
        "ipv4": {
            "address": "",
            "subnet": "",
            "gateway": "",
        },
        "ipv6": {
            "address": "",
            "subnet": "",
            "gateway": "",
        },
        "macvlan_mode": DEFAULT_MACVLAN_MODE,
        "applied_at": "",
        "applied_parent": "",
        "applied_network": "",
        "status": "pending",
        "last_error": "",
    }


def get_ztp_profile(config: Dict[str, Any]) -> Dict[str, Any]:
    """Return network.ztp merged with defaults."""
    network = config.get("network") or {}
    ztp = deepcopy(default_ztp_profile())
    raw = network.get("ztp")
    if isinstance(raw, dict):
        for key, value in raw.items():
            if key in ("ipv4", "ipv6") and isinstance(value, dict):
                ztp[key].update(value)
            else:
                ztp[key] = value
    return ztp


def is_ztp_profile_active(config: Dict[str, Any]) -> bool:
    """True when network.ztp.enabled is explicitly set."""
    ztp = (config.get("network") or {}).get("ztp")
    return isinstance(ztp, dict) and bool(ztp.get("enabled"))


def resolve_effective_network(config: Dict[str, Any]) -> Dict[str, Any]:
    """
    Effective pod network settings: prefer network.ztp when enabled, else legacy fields.
    """
    network = config.get("network") or {}
    ztp = get_ztp_profile(config)
    host_network = bool((config.get("container") or {}).get("host_network", False))

    if ztp.get("enabled"):
        ipv4 = ztp.get("ipv4") or {}
        ipv6 = ztp.get("ipv6") or {}
        vlan_id = ztp.get("vlan_id")
        podman_network = (ztp.get("podman_network") or "").strip()
        if not podman_network and vlan_id is not None:
            podman_network = f"{DEFAULT_PODMAN_NETWORK_PREFIX}{vlan_id}"
        return {
            "mode": "macvlan",
            "host_network": False,
            "podman_network": podman_network,
            "parent_interface": (ztp.get("parent_interface") or "").strip(),
            "ipv4_address": (ipv4.get("address") or "").strip(),
            "ipv4_subnet": (ipv4.get("subnet") or "").strip(),
            "ipv4_gateway": (ipv4.get("gateway") or "").strip(),
            "ipv6_address": (ipv6.get("address") or "").strip(),
            "ipv6_subnet": (ipv6.get("subnet") or "").strip(),
            "ipv6_gateway": (ipv6.get("gateway") or "").strip(),
            "macvlan_mode": (ztp.get("macvlan_mode") or DEFAULT_MACVLAN_MODE).strip(),
            "vlan_id": vlan_id,
            "ztp": ztp,
        }

    ipv4 = (network.get("ipv4") or "").strip()
    ipv6 = (network.get("ipv6") or "").strip()
    podman_network = (network.get("network") or "").strip() or "ztpbootstrap-net"
    return {
        "mode": "host" if host_network else "macvlan",
        "host_network": host_network,
        "podman_network": podman_network if not host_network else "host",
        "parent_interface": "",
        "ipv4_address": ipv4,
        "ipv4_subnet": "",
        "ipv4_gateway": "",
        "ipv6_address": ipv6,
        "ipv6_subnet": "",
        "ipv6_gateway": "",
        "macvlan_mode": DEFAULT_MACVLAN_MODE,
        "vlan_id": None,
        "ztp": ztp,
    }


def sync_legacy_network_fields(config: Dict[str, Any]) -> Dict[str, Any]:
    """Mirror network.ztp into legacy network.* and container.host_network."""
    config = deepcopy(config)
    network = config.setdefault("network", {})
    ztp = get_ztp_profile(config)

    if not ztp.get("enabled"):
        return config

    ipv4 = ztp.get("ipv4") or {}
    ipv6 = ztp.get("ipv6") or {}
    vlan_id = ztp.get("vlan_id")
    podman_network = (ztp.get("podman_network") or "").strip()
    if not podman_network and vlan_id is not None:
        podman_network = f"{DEFAULT_PODMAN_NETWORK_PREFIX}{vlan_id}"

    if ipv4.get("address"):
        network["ipv4"] = ipv4["address"]
    if ipv6.get("address"):
        network["ipv6"] = ipv6["address"]
    if podman_network:
        network["network"] = podman_network

    container = config.setdefault("container", {})
    container["host_network"] = False
    return config


def merge_ztp_update(config: Dict[str, Any], ztp_data: Dict[str, Any]) -> Dict[str, Any]:
    """Merge incoming ZTP profile fields into config."""
    config = deepcopy(config)
    network = config.setdefault("network", {})
    current = get_ztp_profile(config)
    for key, value in (ztp_data or {}).items():
        if key in ("ipv4", "ipv6") and isinstance(value, dict):
            current.setdefault(key, {})
            current[key].update(value)
        else:
            current[key] = value
    network["ztp"] = current
    config["network"] = network
    if current.get("enabled"):
        config = sync_legacy_network_fields(config)
    return config


def default_podman_network_name(vlan_id: Optional[int]) -> str:
    if vlan_id is None:
        return ""
    return f"{DEFAULT_PODMAN_NETWORK_PREFIX}{vlan_id}"


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()
