#!/usr/bin/env python3
"""
Kea Control Agent Client
Communicates with Kea Control Agent API for DHCP management
"""

import json
import logging
from typing import Dict, List, Optional

import requests

logger = logging.getLogger(__name__)

# Kea Control Agent runs on port 8000 inside container
KEA_CTRL_AGENT_URL = "http://localhost:8000"
KEA_CTRL_AGENT_TIMEOUT = 5


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
    if arguments is None:
        arguments = {}

    payload = {
        "command": command,
        "service": [service],
        "arguments": arguments,
    }

    try:
        response = requests.post(
            KEA_CTRL_AGENT_URL,
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

    For memfile backend, reads directly from the lease file.
    For other backends, would use Kea API (but Kea doesn't support lease-get-all).

    Args:
        service: "dhcp4" or "dhcp6"

    Returns:
        List of lease dicts
    """
    try:
        # Kea doesn't support lease4-get-all command, so we read from the memfile directly
        import csv
        import os
        from pathlib import Path

        # Try multiple possible locations for the lease file
        # 1. Inside DHCP container: /var/lib/kea/{service}.leases
        # 2. Via shared volume: /opt/containerdata/ztpbootstrap/dhcp/leases/{service}.leases
        # 3. Via host mount (if WebUI has access)
        lease_file_paths = [
            Path(f"/var/lib/kea/{service}.leases"),
            Path(f"/opt/containerdata/ztpbootstrap/dhcp/leases/{service}.leases"),
            Path(os.getenv("ZTP_CONFIG_DIR", "/opt/containerdata/ztpbootstrap"))
            / "dhcp"
            / "leases"
            / f"{service}.leases",
        ]

        lease_file = None
        for path in lease_file_paths:
            if path.exists():
                lease_file = path
                break

        if not lease_file:
            logger.debug(f"Lease file not found in any of: {[str(p) for p in lease_file_paths]}")
            return []

        leases = []
        with open(lease_file, "r") as f:
            reader = csv.DictReader(f)
            for row in reader:
                # Skip header row if it appears as data
                if not row.get("address") or row.get("address") == "address":
                    continue
                # Convert CSV row to Kea API format
                lease = {
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
                # Only include leases with valid IP addresses
                if lease["ip-address"]:
                    leases.append(lease)

        return leases
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
        # Use service-specific command: lease4-get for dhcp4, lease6-get for dhcp6
        command = "lease4-get" if service == "dhcp4" else "lease6-get"
        response = kea_request(command, service, {"hw-address": mac})
        if response.get("result") == 0:
            leases = response.get("arguments", {}).get("leases", [])
            if leases:
                return leases[0]
        return None
    except Exception as e:
        logger.error(f"Failed to get lease for {mac}: {e}")
        return None


def delete_lease(mac: str, service: str = "dhcp4") -> bool:
    """
    Delete/release a lease.

    Args:
        mac: MAC address
        service: "dhcp4" or "dhcp6"

    Returns:
        True if successful
    """
    try:
        response = kea_request("lease-del", service, {"hw-address": mac})
        return response.get("result") == 0
    except Exception as e:
        logger.error(f"Failed to delete lease for {mac}: {e}")
        return False


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
            return response.get("arguments", {}).get("$", {})
        return {}
    except Exception as e:
        logger.error(f"Failed to get statistics: {e}")
        return {}


def add_reservation(reservation: Dict, service: str = "dhcp4") -> bool:
    """
    Add static reservation.

    Args:
        reservation: Reservation dict with hw-address, ip-address, etc.
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


def delete_reservation(mac: str, service: str = "dhcp4") -> bool:
    """
    Delete static reservation.

    Args:
        mac: MAC address
        service: "dhcp4" or "dhcp6"

    Returns:
        True if successful
    """
    try:
        response = kea_request("reservation-del", service, {"hw-address": mac})
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
            return response.get("arguments", {}).get("$", {})
        return {}
    except Exception as e:
        logger.error(f"Failed to get config: {e}")
        return {}
