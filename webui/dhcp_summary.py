#!/usr/bin/env python3
"""DHCP dashboard summary calculations for compact instrumentation cards."""

from __future__ import annotations

import ipaddress
import time
from typing import Any, Dict, List, Optional, Tuple

from dhcp_config import _normalize_mac


def normalize_lease_state(state: Any) -> str:
    """Map Kea lease state codes to readable labels."""
    if state in (0, "0", "active"):
        return "active"
    if state in (1, "1", "expired"):
        return "expired"
    if state in (2, "2", "reclaimed"):
        return "reclaimed"
    if state is None:
        return "unknown"
    return str(state)


def format_lease_for_api(lease: Dict[str, Any], ip_version: str = "ipv4") -> Dict[str, Any]:
    """Normalize a raw Kea lease dict for the Web UI lease table."""
    expires = lease.get("expire", 0)
    valid_lifetime = lease.get("valid-lifetime")
    if valid_lifetime is None:
        valid_lifetime = lease.get("valid-lft")
    if not expires and valid_lifetime:
        expires = int(time.time()) + int(valid_lifetime)

    ip = lease.get("ip-address", "")
    if ip_version == "ipv6" and not ip:
        addrs = lease.get("ip-addresses") or []
        ip = addrs[0] if addrs else ""

    return {
        "mac": lease.get("hw-address", ""),
        "ip": ip,
        "hostname": lease.get("hostname", "") or "",
        "type": ip_version,
        "state": normalize_lease_state(lease.get("state", "unknown")),
        "expires": expires,
        "cltt": lease.get("cltt"),
    }


def dedupe_formatted_leases(leases: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """Prefer active leases, then most recent expiry, per MAC+IP key."""
    seen: Dict[str, Dict[str, Any]] = {}
    for lease in leases:
        key = f"{lease.get('mac', '')}:{lease.get('ip', '')}"
        if key not in seen:
            seen[key] = lease
            continue
        existing = seen[key]
        if lease.get("state") == "active" and existing.get("state") != "active":
            seen[key] = lease
        elif int(lease.get("expires") or 0) > int(existing.get("expires") or 0):
            seen[key] = lease
    return list(seen.values())


def pool_address_count(range_start: str, range_end: str) -> int:
    """Inclusive count of assignable addresses in a DHCP pool range."""
    if not range_start or not range_end:
        return 0
    try:
        start_ip = ipaddress.ip_address(str(range_start).strip())
        end_ip = ipaddress.ip_address(str(range_end).strip())
        if start_ip > end_ip:
            return 0
        return int(end_ip) - int(start_ip) + 1
    except ValueError:
        return 0


def ip_in_range(ip: str, range_start: str, range_end: str) -> bool:
    if not ip or not range_start or not range_end:
        return False
    try:
        addr = ipaddress.ip_address(str(ip).strip())
        start_ip = ipaddress.ip_address(str(range_start).strip())
        end_ip = ipaddress.ip_address(str(range_end).strip())
        return start_ip <= addr <= end_ip
    except ValueError:
        return False


def _reservation_rows_by_mac(reservations: List[Dict[str, Any]]) -> Dict[str, Dict[str, List[str]]]:
    by_mac: Dict[str, Dict[str, List[str]]] = {}
    for row in reservations or []:
        mac = _normalize_mac(row.get("hw-address") or row.get("hwaddr") or row.get("mac") or "")
        ip = str(row.get("ip-address") or row.get("ip") or row.get("address") or "").strip()
        if not mac or not ip:
            continue
        entry = by_mac.setdefault(mac, {"ipv4": [], "ipv6": []})
        bucket = "ipv6" if ":" in ip else "ipv4"
        if ip not in entry[bucket]:
            entry[bucket].append(ip)
    return by_mac


def _count_reservation_stats(
    reservations: List[Dict[str, Any]],
    active_leases: List[Dict[str, Any]],
) -> Dict[str, Any]:
    by_mac = _reservation_rows_by_mac(reservations)
    ipv4_rows = 0
    ipv6_rows = 0
    for row in reservations or []:
        ip = str(row.get("ip-address") or row.get("ip") or row.get("address") or "")
        if ":" in ip:
            ipv6_rows += 1
        elif ip:
            ipv4_rows += 1

    active_matches = 0
    drift_count = 0
    for lease in active_leases:
        if lease.get("state") != "active":
            continue
        mac = _normalize_mac(lease.get("mac") or "")
        ip = str(lease.get("ip") or "").strip()
        if not mac or mac not in by_mac:
            continue
        bucket = "ipv6" if ":" in ip else "ipv4"
        reserved_ips = by_mac[mac].get(bucket) or []
        if not reserved_ips:
            continue
        if ip in reserved_ips:
            active_matches += 1
        else:
            drift_count += 1

    return {
        "total": len(reservations or []),
        "unique_hosts": len(by_mac),
        "ipv4": ipv4_rows,
        "ipv6": ipv6_rows,
        "active_matches": active_matches,
        "drift_count": drift_count,
    }


def _count_pool_usage(
    ipv4_config: Dict[str, Any],
    active_ipv4_leases: List[Dict[str, Any]],
    reservations: List[Dict[str, Any]],
) -> Dict[str, Any]:
    range_start = str(ipv4_config.get("range_start") or "").strip()
    range_end = str(ipv4_config.get("range_end") or "").strip()
    total = pool_address_count(range_start, range_end)

    reserved_in_pool = set()
    for row in reservations or []:
        ip = str(row.get("ip-address") or row.get("ip") or "").strip()
        if ip and ":" not in ip and ip_in_range(ip, range_start, range_end):
            reserved_in_pool.add(ip)

    used = 0
    for lease in active_ipv4_leases:
        if lease.get("state") != "active":
            continue
        ip = str(lease.get("ip") or "").strip()
        if ip_in_range(ip, range_start, range_end):
            used += 1

    percent = int(round((used / total) * 100)) if total else 0
    return {
        "range_start": range_start or None,
        "range_end": range_end or None,
        "total": total,
        "used": used,
        "percent": percent,
        "reserved_in_pool": len(reserved_in_pool),
    }


def _last_lease_activity(raw_leases: List[Dict[str, Any]]) -> Optional[Dict[str, Any]]:
    best: Optional[Dict[str, Any]] = None
    for lease in raw_leases:
        cltt = lease.get("cltt")
        if cltt is None:
            continue
        if best is None or int(cltt) > int(best["timestamp"]):
            ip = lease.get("ip-address", "")
            if not ip:
                addrs = lease.get("ip-addresses") or []
                ip = addrs[0] if addrs else ""
            best = {
                "timestamp": int(cltt),
                "hostname": lease.get("hostname") or "",
                "ip": ip,
                "mac": lease.get("hw-address") or "",
            }
    return best


def build_dhcp_summary(
    config: Dict[str, Any],
    ipv4_leases: List[Dict[str, Any]],
    ipv6_leases: List[Dict[str, Any]],
    kea_health: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    """Build compact dashboard summary JSON from config, leases, and Kea health."""
    dhcp_config = config.get("dhcp") or {}
    reservations = dhcp_config.get("reservations") or []

    formatted_v4 = dedupe_formatted_leases(
        [format_lease_for_api(lease, "ipv4") for lease in ipv4_leases]
    )
    formatted_v6 = dedupe_formatted_leases(
        [format_lease_for_api(lease, "ipv6") for lease in ipv6_leases]
    )
    all_formatted = formatted_v4 + formatted_v6
    active_leases = [lease for lease in all_formatted if lease.get("state") == "active"]

    ipv4_active = sum(1 for lease in formatted_v4 if lease.get("state") == "active")
    ipv6_active = sum(1 for lease in formatted_v6 if lease.get("state") == "active")

    pool = _count_pool_usage(dhcp_config.get("ipv4") or {}, formatted_v4, reservations)
    reservation_stats = _count_reservation_stats(reservations, active_leases)
    last_activity = _last_lease_activity(ipv4_leases + ipv6_leases)

    kea = kea_health or {
        "reachable": False,
        "lease_cmds_loaded": False,
        "latency_ms": None,
        "error": None,
    }

    return {
        "leases": {
            "total": len(active_leases),
            "ipv4": ipv4_active,
            "ipv6": ipv6_active,
            "active": len(active_leases),
        },
        "reservations": reservation_stats,
        "pool": {"ipv4": pool},
        "kea": kea,
        "last_activity": last_activity,
        "generated_at": int(time.time()),
    }
