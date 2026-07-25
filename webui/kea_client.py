#!/usr/bin/env python3
"""
Kea Control Agent Client
Communicates with Kea Control Agent API for DHCP management
"""

import logging
import os
from typing import Dict, List, Optional

import requests

logger = logging.getLogger(__name__)

# Kea Control Agent default (pod network / shared pod localhost)
DEFAULT_KEA_CTRL_AGENT_URL = "http://127.0.0.1:8000"
KEA_CTRL_AGENT_TIMEOUT = 5


def get_kea_ctrl_agent_url() -> str:
    """Return Kea Control Agent base URL from KEA_CTRL_AGENT_URL or default."""
    url = os.environ.get("KEA_CTRL_AGENT_URL", "").strip()
    if not url:
        return DEFAULT_KEA_CTRL_AGENT_URL
    return url.rstrip("/")


def kea_request(command: str, service: str, arguments: Optional[Dict] = None) -> Dict:
    """
    Send JSON-RPC request to Kea Control Agent.

    Args:
        command: Kea command (e.g., "lease-get", "statistic-get-all")
        service: Service name ("dhcp4" or "dhcp6")
        arguments: Optional command arguments

    Returns:
        Response dict from Kea
    """
    payload = {
        "command": command,
        "service": [service],
    }
    # Kea 3.x treats `"arguments": {}` differently from omitting the key entirely
    # (e.g. lease4-get-all fails with "'subnets' parameter not specified").
    if arguments:
        payload["arguments"] = arguments

    try:
        response = requests.post(
            get_kea_ctrl_agent_url(),
            json=payload,
            timeout=KEA_CTRL_AGENT_TIMEOUT,
        )
        response.raise_for_status()
        result = response.json()
        # Kea Control Agent returns a list of responses, get the first one
        if isinstance(result, list) and len(result) > 0:
            return result[0]
        return result
    except requests.exceptions.RequestException as e:
        logger.error(f"Kea Control Agent request failed: {e}")
        raise


def get_leases(service: str = "dhcp4") -> List[Dict]:
    """
    Get current DHCP leases.

    First tries the Kea Control Agent (requires lease_cmds hook loaded).
    Falls back to reading the memfile CSV for backward compatibility with
    dev/memfile-only installs.

    Args:
        service: "dhcp4" or "dhcp6"

    Returns:
        List of lease dicts
    """
    try:
        command = "lease4-get-all" if service == "dhcp4" else "lease6-get-all"
        response = kea_request(command, service)
        # Kea returns result 0 when leases exist; result 3 when the query succeeds but
        # the list is empty. Both must use the API — memfile fallback has stale rows.
        if response.get("result") in (0, 3):
            raw = response.get("arguments", {}).get("leases", [])
            active = [lease for lease in raw if _lease_is_active(lease)]
            return _dedupe_leases_by_mac(active or raw)
    except Exception as e:
        logger.debug(f"Control Agent lease fetch failed, falling back to memfile: {e}")

    try:
        raw = _read_memfile_leases(service)
        active = [lease for lease in raw if _lease_is_active(lease)]
        return _dedupe_leases_by_mac(active)
    except Exception as e:
        logger.error(f"Failed to get leases: {e}")
        return []


def get_lease(mac: str, service: str = "dhcp4") -> Optional[Dict]:
    """
    Get specific lease by MAC address.

    Args:
        mac: MAC address
        service: "dhcp4" or "dhcp6"

    Returns:
        Lease dict or None
    """
    try:
        command = "lease4-get" if service == "dhcp4" else "lease6-get"
        mac_norm = _normalize_mac(mac)
        response = kea_request(
            command,
            service,
            {"identifier-type": "hw-address", "identifier": mac_norm},
        )
        if response.get("result") == 0:
            leases = response.get("arguments", {}).get("leases", [])
            if leases:
                return leases[0]
        return None
    except Exception as e:
        logger.error(f"Failed to get lease for {mac}: {e}")
        return None


def _normalize_mac(mac: str) -> str:
    return mac.lower().replace("-", ":").strip()


def _lease_is_active(lease: Dict) -> bool:
    """True for leases Kea still considers in use (not expired/reclaimed)."""
    import time

    state = lease.get("state", "unknown")
    if state in (1, "1", "expired", 2, "2", "reclaimed"):
        return False
    valid_lifetime = lease.get("valid-lifetime")
    if valid_lifetime is None:
        valid_lifetime = lease.get("valid-lft")
    if valid_lifetime is not None and int(valid_lifetime) == 0:
        return False
    expire = lease.get("expire")
    if expire is not None and int(expire) > 0 and int(expire) < time.time():
        return False
    return True


def _lease_sort_key(lease: Dict) -> int:
    import time

    expire = lease.get("expire")
    if expire is not None and int(expire) > 0:
        return int(expire)
    valid_lifetime = lease.get("valid-lifetime")
    if valid_lifetime is None:
        valid_lifetime = lease.get("valid-lft")
    if valid_lifetime is not None and int(valid_lifetime) > 0:
        return int(time.time()) + int(valid_lifetime)
    return 0


def _dedupe_leases_by_mac(leases: List[Dict]) -> List[Dict]:
    """One lease per MAC — keep the newest (highest expire)."""
    best: Dict[str, Dict] = {}
    best_key: Dict[str, int] = {}
    for lease in leases:
        mac = _normalize_mac(lease.get("hw-address", ""))
        if not mac:
            continue
        sort_key = _lease_sort_key(lease)
        if mac not in best or sort_key >= best_key[mac]:
            best[mac] = lease
            best_key[mac] = sort_key
    return list(best.values())


def _read_memfile_leases(service: str) -> List[Dict]:
    import csv
    import os
    from pathlib import Path

    lease_file = None
    for path in _lease_file_candidates(service):
        if path.exists():
            lease_file = path
            break
    if not lease_file:
        return []

    leases = []
    with open(lease_file, newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            if not row.get("address") or row.get("address") == "address":
                continue
            leases.append(
                {
                    "ip-address": row.get("address", ""),
                    "hw-address": row.get("hwaddr", ""),
                    "client-id": row.get("client_id", ""),
                    "valid-lifetime": (
                        int(row.get("valid_lifetime", 0)) if row.get("valid_lifetime") else 0
                    ),
                    "expire": int(row.get("expire", 0)) if row.get("expire") else 0,
                    "subnet-id": int(row.get("subnet_id", 0)) if row.get("subnet_id") else 0,
                    "state": row.get("state", "unknown"),
                    "hostname": row.get("hostname", ""),
                }
            )
    return leases


def _lease_file_candidates(service: str):
    import os
    from pathlib import Path

    return [
        Path(f"/var/lib/kea/{service}.leases"),
        Path(f"/opt/containerdata/ztpbootstrap/dhcp/leases/{service}.leases"),
        Path(os.getenv("ZTP_CONFIG_DIR", "/opt/containerdata/ztpbootstrap"))
        / "dhcp"
        / "leases"
        / f"{service}.leases",
    ]


def _find_lease_record(mac: str, service: str) -> Optional[Dict]:
    """Find a lease dict for a MAC from Kea API or memfile."""
    mac_norm = _normalize_mac(mac)
    try:
        command = "lease4-get" if service == "dhcp4" else "lease6-get"
        response = kea_request(
            command,
            service,
            {"identifier-type": "hw-address", "identifier": mac_norm},
        )
        if response.get("result") == 0:
            leases = response.get("arguments", {}).get("leases", [])
            if leases:
                return leases[0]
    except Exception as e:
        logger.debug(f"Control Agent lease lookup failed for {mac}: {e}")

    for lease in get_leases(service):
        if _normalize_mac(lease.get("hw-address", "")) == mac_norm:
            return lease
    return None


KEA4_MEMFILE_FIELDS = [
    "address",
    "hwaddr",
    "client_id",
    "valid_lifetime",
    "expire",
    "subnet_id",
    "fqdn_fwd",
    "fqdn_rev",
    "hostname",
    "state",
    "user_context",
]


def _delete_lease_memfile(mac: str, service: str, ip_address: Optional[str] = None) -> bool:
    """Remove lease row(s) from the memfile CSV (fallback when API delete fails)."""
    import csv

    mac_norm = _normalize_mac(mac)
    ip = (ip_address or "").strip()
    fieldnames = KEA4_MEMFILE_FIELDS if service == "dhcp4" else None

    def _matches(row: Dict) -> bool:
        row_mac = _normalize_mac(row.get("hwaddr", ""))
        row_ip = row.get("address", "").strip()
        if ip:
            return row_ip == ip
        return row_mac == mac_norm

    for path in _lease_file_candidates(service):
        if not path.exists():
            continue
        try:
            with open(path, newline="") as f:
                rows = list(csv.DictReader(f))
            if not rows:
                continue
            if fieldnames is None:
                fieldnames = [name for name in KEA4_MEMFILE_FIELDS if name in rows[0]]
            kept = [row for row in rows if not _matches(row)]
            if len(kept) == len(rows):
                continue
            tmp_path = path.with_suffix(path.suffix + ".tmp")
            with open(tmp_path, "w", newline="") as f:
                writer = csv.DictWriter(f, fieldnames=fieldnames, extrasaction="ignore")
                writer.writeheader()
                writer.writerows(kept)
            tmp_path.replace(path)
            logger.info(f"Removed lease for {mac} from memfile {path}")
            return True
        except Exception as e:
            logger.error(f"Failed memfile lease delete in {path}: {e}")
    return False


def delete_lease(mac: str, service: str = "dhcp4", ip_address: Optional[str] = None) -> bool:
    """
    Delete/release a lease.

    Args:
        mac: MAC address
        service: "dhcp4" or "dhcp6"
        ip_address: Optional lease IP (preferred delete key for Kea)

    Returns:
        True if successful
    """
    mac_norm = _normalize_mac(mac)
    command = "lease4-del" if service == "dhcp4" else "lease6-del"
    lease = _find_lease_record(mac_norm, service)
    ip = ip_address or (lease.get("ip-address") if lease else None)

    attempts = []
    if ip:
        attempts.append({"ip-address": ip})
    attempts.append(
        {
            "identifier-type": "hw-address",
            "identifier": mac_norm,
        }
    )
    if lease and lease.get("subnet-id"):
        attempts.append(
            {
                "identifier-type": "hw-address",
                "identifier": mac_norm,
                "subnet-id": int(lease["subnet-id"]),
            }
        )

    for args in attempts:
        try:
            response = kea_request(command, service, args)
            result_code = response.get("result")
            if result_code == 0:
                return True
            # Kea returns 3 when the lease is already gone — treat as success.
            if result_code == 3:
                return True
        except Exception as e:
            logger.debug(f"Kea {command} failed with {args}: {e}")

    if not lease and not ip:
        return False

    return _delete_lease_memfile(mac_norm, service, ip_address=ip)


def _list_lease_ips_for_mac(mac: str, service: str) -> List[str]:
    """All IPs associated with a MAC in Kea memory or on-disk memfile."""
    mac_norm = _normalize_mac(mac)
    ips = set()
    try:
        command = "lease4-get-all" if service == "dhcp4" else "lease6-get-all"
        response = kea_request(command, service)
        if response.get("result") in (0, 3):
            for lease in response.get("arguments", {}).get("leases", []):
                if _normalize_mac(lease.get("hw-address", "")) == mac_norm:
                    ip = lease.get("ip-address")
                    if ip:
                        ips.add(ip)
    except Exception as e:
        logger.debug(f"Could not list Kea leases for {mac}: {e}")

    for lease in _read_memfile_leases(service):
        if _normalize_mac(lease.get("hw-address", "")) == mac_norm:
            ip = lease.get("ip-address")
            if ip:
                ips.add(ip)
    return sorted(ips)


def delete_all_leases_for_mac(mac: str, service: str = "dhcp4") -> bool:
    """Remove every lease row for a MAC (all IPs + stale memfile entries)."""
    mac_norm = _normalize_mac(mac)
    ips = _list_lease_ips_for_mac(mac_norm, service)
    if not ips:
        return True
    any_ok = False
    for ip in ips:
        if delete_lease(mac_norm, service, ip_address=ip):
            any_ok = True
    if _delete_lease_memfile(mac_norm, service, ip_address=None):
        any_ok = True
    return any_ok


def probe_lease_api_health(service: str = "dhcp4") -> Dict:
    """
    Check Kea Control Agent reachability and lease_cmds hook availability.

    Returns:
        Dict with reachable, lease_cmds_loaded, latency_ms, and optional error.
    """
    import time

    result: Dict = {
        "reachable": False,
        "lease_cmds_loaded": False,
        "latency_ms": None,
        "error": None,
    }
    command = "lease4-get-all" if service == "dhcp4" else "lease6-get-all"
    try:
        start = time.time()
        response = kea_request(command, service)
        result["latency_ms"] = int((time.time() - start) * 1000)
        if response.get("result") in (0, 3):
            result["reachable"] = True
        else:
            result["error"] = response.get("text") or f"Kea result {response.get('result')}"
    except Exception as exc:
        result["error"] = str(exc)

    try:
        cfg_response = kea_request("config-get", service)
        if cfg_response.get("result") == 0:
            key = "Dhcp4" if service == "dhcp4" else "Dhcp6"
            hooks = cfg_response.get("arguments", {}).get(key, {}).get("hooks-libraries", [])
            result["lease_cmds_loaded"] = any(
                "libdhcp_lease_cmds" in str(hook.get("library", "")) for hook in hooks
            )
    except Exception as exc:
        if not result["error"]:
            result["error"] = str(exc)

    return result


def get_statistics(service: str = "dhcp4") -> Dict:
    """
    Get DHCP server statistics.

    Args:
        service: "dhcp4" or "dhcp6"

    Returns:
        Statistics dict
    """
    try:
        response = kea_request("statistic-get-all", service)
        if response.get("result") == 0:
            return response.get("arguments", {})
        return {}
    except Exception as e:
        logger.error(f"Failed to get statistics: {e}")
        return {}


def add_reservation(reservation: Dict, service: str = "dhcp4") -> bool:
    """
    Add static reservation.

    Requires the host_cmds hook and a database backend (not memfile).
    The reservation dict MUST include "subnet-id" (int), "identifier-type"
    (e.g. "hw-address"), and "identifier" (the MAC address), along with
    "ip-address" and any desired options.

    Args:
        reservation: Full reservation dict conforming to Kea reservation-add spec.
        service: "dhcp4" or "dhcp6"

    Returns:
        True if successful
    """
    try:
        response = kea_request("reservation-add", service, reservation)
        return response.get("result") == 0
    except Exception as e:
        logger.error(f"Failed to add reservation: {e}")
        return False


def delete_reservation(mac: str, subnet_id: int, service: str = "dhcp4") -> bool:
    """
    Delete static reservation.

    Args:
        mac: MAC address
        subnet_id: Subnet ID the reservation belongs to
        service: "dhcp4" or "dhcp6"

    Returns:
        True if successful
    """
    try:
        response = kea_request(
            "reservation-del",
            service,
            {"identifier-type": "hw-address", "identifier": mac, "subnet-id": subnet_id},
        )
        return response.get("result") == 0
    except Exception as e:
        logger.error(f"Failed to delete reservation for {mac}: {e}")
        return False


def reload_config(service: str = "dhcp4") -> bool:
    """
    Reload Kea configuration.

    Args:
        service: "dhcp4" or "dhcp6"

    Returns:
        True if successful
    """
    try:
        response = kea_request("config-reload", service)
        return response.get("result") == 0
    except Exception as e:
        logger.error(f"Failed to reload config: {e}")
        return False


def get_config(service: str = "dhcp4") -> Dict:
    """
    Get current Kea configuration.

    Args:
        service: "dhcp4" or "dhcp6"

    Returns:
        Configuration dict
    """
    try:
        response = kea_request("config-get", service)
        if response.get("result") == 0:
            return response.get("arguments", {})
        return {}
    except Exception as e:
        logger.error(f"Failed to get config: {e}")
        return {}
