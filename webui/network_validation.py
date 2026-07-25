#!/usr/bin/env python3
"""
ZTP network profile validation and change planning.
"""

from __future__ import annotations

import ipaddress
from typing import Any, Dict, List, Optional, Tuple

from network_config import get_ztp_profile, resolve_effective_network
from network_utils import inspect_podman_network, is_valid_interface_name, parse_pod_quadlet

ALLOWED_MACVLAN_MODES = {"bridge", "private", "vepa", "passthru"}


def validate_ztp_profile(config: Dict[str, Any]) -> Tuple[List[str], List[str]]:
    """
    Validate network.ztp profile.

    Returns:
        (errors, warnings)
    """
    errors: List[str] = []
    warnings: List[str] = []
    ztp = get_ztp_profile(config)

    if not ztp.get("enabled"):
        return errors, warnings

    host_network = bool((config.get("container") or {}).get("host_network", False))
    if host_network:
        errors.append("container.host_network must be false when network.ztp.enabled is true")

    parent = (ztp.get("parent_interface") or "").strip()
    if not parent:
        errors.append("parent_interface is required when ZTP network is enabled")
    elif not is_valid_interface_name(parent):
        errors.append(f"Invalid parent_interface name: {parent}")

    vlan_id = ztp.get("vlan_id")
    if vlan_id is not None:
        try:
            vid = int(vlan_id)
            if vid < 1 or vid > 4094:
                errors.append("vlan_id must be between 1 and 4094")
        except (TypeError, ValueError):
            errors.append("vlan_id must be an integer")

    mode = (ztp.get("macvlan_mode") or "bridge").strip().lower()
    if mode not in ALLOWED_MACVLAN_MODES:
        errors.append(f"macvlan_mode must be one of: {', '.join(sorted(ALLOWED_MACVLAN_MODES))}")

    ipv4 = ztp.get("ipv4") or {}
    ipv4_addr = (ipv4.get("address") or "").strip()
    ipv4_subnet = (ipv4.get("subnet") or "").strip()
    ipv4_gateway = (ipv4.get("gateway") or "").strip()

    if not ipv4_addr:
        errors.append("ipv4.address is required")
    if not ipv4_subnet:
        errors.append("ipv4.subnet is required")
    else:
        err = _validate_cidr(ipv4_subnet, 4)
        if err:
            errors.append(f"ipv4.subnet: {err}")

    if ipv4_addr and ipv4_subnet:
        err = _address_in_subnet(ipv4_addr, ipv4_subnet, "ipv4.address")
        if err:
            errors.append(err)

    if ipv4_gateway:
        err = _validate_ip(ipv4_gateway, 4)
        if err:
            errors.append(f"ipv4.gateway: {err}")
        elif ipv4_subnet:
            err = _address_in_subnet(ipv4_gateway, ipv4_subnet, "ipv4.gateway")
            if err:
                warnings.append(err)

    ipv6 = ztp.get("ipv6") or {}
    ipv6_addr = (ipv6.get("address") or "").strip()
    ipv6_subnet = (ipv6.get("subnet") or "").strip()
    ipv6_gateway = (ipv6.get("gateway") or "").strip()
    ipv6_enabled = bool(ipv6_addr or ipv6_subnet or ipv6_gateway)

    if ipv6_enabled:
        if ipv6_subnet:
            err = _validate_cidr(ipv6_subnet, 6)
            if err:
                errors.append(f"ipv6.subnet: {err}")
        if ipv6_addr:
            err = _validate_ip(ipv6_addr, 6)
            if err:
                errors.append(f"ipv6.address: {err}")
            elif ipv6_subnet:
                err = _address_in_subnet(ipv6_addr, ipv6_subnet, "ipv6.address")
                if err:
                    errors.append(err)
        if ipv6_gateway:
            err = _validate_ip(ipv6_gateway, 6)
            if err:
                errors.append(f"ipv6.gateway: {err}")

    podman_network = (ztp.get("podman_network") or "").strip()
    if vlan_id is not None and not podman_network:
        podman_network = f"ztp-net-{vlan_id}"
    if podman_network and not podman_network.replace("-", "").replace("_", "").isalnum():
        errors.append(f"Invalid podman_network name: {podman_network}")

    dhcp = config.get("dhcp") or {}
    if dhcp.get("enabled"):
        dhcp_subnet = ((dhcp.get("ipv4") or {}).get("subnet") or "").strip()
        if dhcp_subnet and ipv4_subnet and dhcp_subnet != ipv4_subnet:
            warnings.append(
                f"dhcp.ipv4.subnet ({dhcp_subnet}) differs from network.ztp.ipv4.subnet ({ipv4_subnet})"
            )

    return errors, warnings


def plan_network_changes(
    current_config: Dict[str, Any], desired_config: Dict[str, Any]
) -> Dict[str, Any]:
    """
    Plan create/replace/no-op for podman network and quadlet updates.
    """
    current = resolve_effective_network(current_config)
    desired = resolve_effective_network(desired_config)
    plan: Dict[str, Any] = {
        "action": "noop",
        "create_network": False,
        "replace_network": False,
        "remove_networks": [],
        "update_quadlet": False,
        "restart_required": False,
        "warnings": [],
        "current": {
            "podman_network": current.get("podman_network"),
            "ipv4_address": current.get("ipv4_address"),
            "ipv6_address": current.get("ipv6_address"),
        },
        "desired": {
            "podman_network": desired.get("podman_network"),
            "ipv4_address": desired.get("ipv4_address"),
            "ipv6_address": desired.get("ipv6_address"),
        },
    }

    if not desired.get("ztp", {}).get("enabled"):
        plan["action"] = "noop"
        plan["warnings"].append("ZTP profile disabled; no macvlan changes planned")
        return plan

    desired_network = desired.get("podman_network") or ""
    current_network = current.get("podman_network") or ""
    quadlet = parse_pod_quadlet()

    desired_signature = _network_signature(desired)
    current_signature = _network_signature(current)
    existing = inspect_podman_network(desired_network) if desired_network else None

    if existing:
        ipv4_subnets = [
            s
            for s in existing.get("subnets") or []
            if s.get("subnet") and ":" not in str(s.get("subnet"))
        ]
        existing_ipv4_subnet = ipv4_subnets[0].get("subnet") if ipv4_subnets else None
        network_matches = (
            existing.get("name") == desired_network
            and (existing.get("parent") or "") == (desired.get("parent_interface") or "")
            and (existing_ipv4_subnet or "") == (desired.get("ipv4_subnet") or "")
            and (existing.get("mode") or "bridge") == (desired.get("macvlan_mode") or "bridge")
        )
        if not network_matches:
            plan["replace_network"] = True
            plan["action"] = "replace"
            if current_network and current_network != desired_network:
                plan["remove_networks"].append(current_network)
        else:
            plan["action"] = "noop"
    else:
        plan["create_network"] = True
        plan["action"] = "create"
        if current_network and current_network not in ("host", desired_network):
            plan["remove_networks"].append(current_network)

    quadlet_needs_update = (
        quadlet.get("network") != desired_network
        or quadlet.get("ipv4") != desired.get("ipv4_address")
        or quadlet.get("ipv6") != (desired.get("ipv6_address") or None)
    )
    plan["update_quadlet"] = quadlet_needs_update
    plan["restart_required"] = (
        plan["create_network"]
        or plan["replace_network"]
        or quadlet_needs_update
        or current_signature != desired_signature
    )

    for network_name in plan["remove_networks"]:
        info = inspect_podman_network(network_name)
        if info and info.get("container_count", 0) > 0:
            foreign = [c for c in info.get("containers") or [] if not c.startswith("ztpbootstrap")]
            if foreign or info.get("container_count", 0) > 3:
                plan["warnings"].append(
                    f"Refusing to remove shared network {network_name}: "
                    f"{info.get('container_count')} container(s) attached"
                )
                plan["remove_networks"] = [n for n in plan["remove_networks"] if n != network_name]

    return plan


def validate_ztp_profile_dict(
    ztp_data: Dict[str, Any], full_config: Optional[Dict[str, Any]] = None
) -> Tuple[bool, Optional[str]]:
    """Validate a ZTP profile update against a config dict."""
    config = dict(full_config or {})
    network = dict(config.get("network") or {})
    network["ztp"] = ztp_data
    config["network"] = network
    errors, _warnings = validate_ztp_profile(config)
    if errors:
        return False, "; ".join(errors)
    return True, None


def _validate_ip(value: str, version: int) -> Optional[str]:
    try:
        ip = ipaddress.ip_address(value)
        if version == 4 and not isinstance(ip, ipaddress.IPv4Address):
            return "expected IPv4"
        if version == 6 and not isinstance(ip, ipaddress.IPv6Address):
            return "expected IPv6"
        return None
    except ValueError as exc:
        return str(exc)


def _validate_cidr(value: str, version: int) -> Optional[str]:
    try:
        net = ipaddress.ip_network(value, strict=False)
        if version == 4 and not isinstance(net, ipaddress.IPv4Network):
            return "expected IPv4 CIDR"
        if version == 6 and not isinstance(net, ipaddress.IPv6Network):
            return "expected IPv6 CIDR"
        return None
    except ValueError as exc:
        return str(exc)


def _address_in_subnet(address: str, subnet: str, label: str) -> Optional[str]:
    try:
        ip = ipaddress.ip_address(address)
        net = ipaddress.ip_network(subnet, strict=False)
        if ip not in net:
            return f"{label} {address} is not inside subnet {subnet}"
    except ValueError as exc:
        return f"{label}: {exc}"
    return None


def _network_signature(profile: Dict[str, Any]) -> Tuple[Any, ...]:
    return (
        profile.get("podman_network"),
        profile.get("parent_interface"),
        profile.get("ipv4_address"),
        profile.get("ipv4_subnet"),
        profile.get("ipv4_gateway"),
        profile.get("ipv6_address"),
        profile.get("ipv6_subnet"),
        profile.get("ipv6_gateway"),
        profile.get("macvlan_mode"),
    )


def _inspect_signature(info: Dict[str, Any]) -> Tuple[Any, ...]:
    ipv4_subnet = None
    ipv4_gateway = None
    ipv6_subnet = None
    ipv6_gateway = None
    for subnet in info.get("subnets") or []:
        cidr = subnet.get("subnet") or ""
        if ":" in cidr:
            ipv6_subnet = cidr
            ipv6_gateway = subnet.get("gateway")
        else:
            ipv4_subnet = cidr
            ipv4_gateway = subnet.get("gateway")
    return (
        info.get("name"),
        info.get("parent"),
        None,
        ipv4_subnet,
        ipv4_gateway,
        None,
        ipv6_subnet,
        ipv6_gateway,
        info.get("mode"),
    )
