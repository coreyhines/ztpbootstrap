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
        return response.json()
    except requests.exceptions.RequestException as e:
        logger.error(f"Kea Control Agent request failed: {e}")
        raise


def get_leases(service: str = "dhcp4") -> List[Dict]:
    """
    Get current DHCP leases.

    Args:
        service: "dhcp4" or "dhcp6"

    Returns:
        List of lease dicts
    """
    try:
        response = kea_request("lease-get-all", service)
        if response.get("result") == 0:
            leases = response.get("arguments", {}).get("leases", [])
            return leases
        else:
            logger.warning(f"Kea returned error: {response.get('text', 'Unknown error')}")
            return []
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
        response = kea_request("lease-get", service, {"hw-address": mac})
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
