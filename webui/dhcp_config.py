#!/usr/bin/env python3
"""
Kea DHCP Configuration Generator
Generates Kea JSON configuration from YAML config
"""

import ipaddress
import json
import logging
from typing import Dict, List, Optional

from dhcp_utils import detect_networking_mode, get_interfaces_for_kea

logger = logging.getLogger(__name__)

# Kea Control Agent default port
KEA_CTRL_AGENT_PORT = 8000


def generate_kea_config(config_yaml: Dict) -> Dict:
    """
    Main config generator - creates complete Kea configuration.

    Args:
        config_yaml: Parsed YAML config dict

    Returns:
        Dict with 'dhcp4', 'dhcp6', and 'ctrl-agent' configurations
    """
    dhcp_config = config_yaml.get("dhcp", {})
    if not dhcp_config or not dhcp_config.get("enabled", False):
        return {}

    networking_mode = detect_networking_mode(config_yaml)

    result = {}

    # Generate DHCPv4 config if IPv4 is configured
    ipv4_config = dhcp_config.get("ipv4", {})
    if (
        ipv4_config.get("subnet")
        and ipv4_config.get("range_start")
        and ipv4_config.get("range_end")
    ):
        result["Dhcp4"] = generate_dhcp4_config(dhcp_config, networking_mode, config_yaml)

    # Generate DHCPv6 config if IPv6 is configured
    ipv6_config = dhcp_config.get("ipv6", {})
    if (
        ipv6_config.get("subnet")
        and ipv6_config.get("range_start")
        and ipv6_config.get("range_end")
    ):
        result["Dhcp6"] = generate_dhcp6_config(dhcp_config, networking_mode, config_yaml)

    # Always generate Control Agent config
    result["Control-agent"] = generate_ctrl_agent_config()

    return result


def generate_dhcp4_config(dhcp_config: Dict, networking_mode: str, config_yaml: Dict) -> Dict:
    """
    Generate DHCPv4 (IPv4) configuration.

    Args:
        dhcp_config: DHCP section from config.yaml
        networking_mode: "host" or "macvlan"
        config_yaml: Full config for context

    Returns:
        Kea DHCPv4 configuration dict
    """
    ipv4_config = dhcp_config.get("ipv4", {})
    subnet = ipv4_config.get("subnet", "")
    range_start = ipv4_config.get("range_start", "")
    range_end = ipv4_config.get("range_end", "")
    gateway = ipv4_config.get("gateway", "")

    # Get interfaces for Kea to bind to
    interfaces = get_interfaces_for_kea(networking_mode, subnet)

    # Build interfaces-config
    interfaces_config = {}
    if interfaces:
        interfaces_config["interfaces"] = interfaces
    else:
        # If no specific interfaces, Kea will bind to all available interfaces
        interfaces_config["interfaces"] = ["*"]

    # Build subnet configuration
    subnet_config = {
        "subnet": subnet,
        "pools": [{"pool": f"{range_start} - {range_end}"}],
    }

    # Add gateway/router option
    if gateway:
        subnet_config["option-data"] = [{"name": "routers", "data": gateway}]

    # Add DNS servers
    dns_servers = ipv4_config.get("dns_servers", [])
    if dns_servers:
        if "option-data" not in subnet_config:
            subnet_config["option-data"] = []
        subnet_config["option-data"].append(
            {"name": "domain-name-servers", "data": ", ".join(dns_servers)}
        )

    # Add domain name
    domain = ipv4_config.get("domain", "")
    if domain:
        if "option-data" not in subnet_config:
            subnet_config["option-data"] = []
        subnet_config["option-data"].append({"name": "domain-name", "data": domain})

    # Add NTP servers
    ntp_servers = ipv4_config.get("ntp_servers", [])
    if ntp_servers:
        if "option-data" not in subnet_config:
            subnet_config["option-data"] = []
        subnet_config["option-data"].append({"name": "ntp-servers", "data": ", ".join(ntp_servers)})

    # Handle relay mode
    relay_config = dhcp_config.get("relay", {})
    if relay_config.get("enabled", False):
        relay_subnets = generate_relay_subnets(relay_config, "ipv4")
        if relay_subnets:
            subnet_config = relay_subnets[0]  # Use first relay subnet as primary
            # Add other relay subnets as shared networks if needed
            if len(relay_subnets) > 1:
                # For multiple relay subnets, we'd configure shared networks
                # For now, use the first one
                pass

    # Build main DHCPv4 config
    config = {
        "interfaces-config": interfaces_config,
        "lease-database": generate_lease_database(dhcp_config.get("backend", {})),
        "subnet4": [subnet_config],
        "valid-lifetime": 86400,  # 24 hours default
        "renew-timer": 43200,  # 12 hours
        "rebind-timer": 75600,  # 21 hours
    }

    # Add client classification for OUI filtering
    oui_config = dhcp_config.get("oui_filtering", {})
    if (
        oui_config.get("arista_only_mode")
        or oui_config.get("allowed_ouis")
        or oui_config.get("blocked_ouis")
    ):
        config["client-classes"] = generate_client_classes(oui_config, "ipv4")
        # Add classifier to subnet
        if oui_config.get("arista_only_mode"):
            subnet_config["client-class"] = "ARISTA_ONLY"

    # Add PXE configuration
    pxe_config = dhcp_config.get("pxe", {})
    if pxe_config.get("enabled", False):
        pxe_options = generate_pxe_options(pxe_config, "ipv4")
        if "option-data" not in subnet_config:
            subnet_config["option-data"] = []
        subnet_config["option-data"].extend(pxe_options)

    # Add custom DHCP options
    options_config = dhcp_config.get("options", {})
    custom_options = options_config.get("custom", [])
    if custom_options:
        if "option-data" not in subnet_config:
            subnet_config["option-data"] = []
        subnet_config["option-data"].extend(generate_custom_options(custom_options))

    return config


def generate_dhcp6_config(dhcp_config: Dict, networking_mode: str, config_yaml: Dict) -> Dict:
    """
    Generate DHCPv6 (IPv6) configuration.

    Args:
        dhcp_config: DHCP section from config.yaml
        networking_mode: "host" or "macvlan"
        config_yaml: Full config for context

    Returns:
        Kea DHCPv6 configuration dict
    """
    ipv6_config = dhcp_config.get("ipv6", {})
    subnet = ipv6_config.get("subnet", "")
    range_start = ipv6_config.get("range_start", "")
    range_end = ipv6_config.get("range_end", "")
    gateway = ipv6_config.get("gateway", "")

    # Get interfaces for Kea to bind to
    interfaces = get_interfaces_for_kea(networking_mode, subnet)

    # Build interfaces-config
    interfaces_config = {}
    if interfaces:
        interfaces_config["interfaces"] = interfaces
    else:
        interfaces_config["interfaces"] = ["*"]

    # Build subnet configuration
    subnet_config = {
        "subnet": subnet,
        "pools": [{"pool": f"{range_start} - {range_end}"}],
    }

    # Add gateway/router option (option 3 for IPv6)
    if gateway:
        subnet_config["option-data"] = [{"name": "sntp-servers", "data": gateway}]

    # Add DNS servers (option 23)
    dns_servers = ipv6_config.get("dns_servers", [])
    if dns_servers:
        if "option-data" not in subnet_config:
            subnet_config["option-data"] = []
        subnet_config["option-data"].append({"name": "dns-servers", "data": ", ".join(dns_servers)})

    # Add domain name (option 24)
    domain = ipv6_config.get("domain", "")
    if domain:
        if "option-data" not in subnet_config:
            subnet_config["option-data"] = []
        subnet_config["option-data"].append({"name": "domain-search", "data": domain})

    # Handle relay mode
    relay_config = dhcp_config.get("relay", {})
    if relay_config.get("enabled", False):
        relay_subnets = generate_relay_subnets(relay_config, "ipv6")
        if relay_subnets:
            subnet_config = relay_subnets[0]

    # Build main DHCPv6 config
    config = {
        "interfaces-config": interfaces_config,
        "lease-database": generate_lease_database(dhcp_config.get("backend", {})),
        "subnet6": [subnet_config],
        "valid-lifetime": 86400,  # 24 hours default
        "renew-timer": 43200,  # 12 hours
        "rebind-timer": 75600,  # 21 hours
    }

    # Add client classification for OUI filtering
    oui_config = dhcp_config.get("oui_filtering", {})
    if (
        oui_config.get("arista_only_mode")
        or oui_config.get("allowed_ouis")
        or oui_config.get("blocked_ouis")
    ):
        config["client-classes"] = generate_client_classes(oui_config, "ipv6")
        if oui_config.get("arista_only_mode"):
            subnet_config["client-class"] = "ARISTA_ONLY"

    # Add custom DHCP options
    options_config = dhcp_config.get("options", {})
    custom_options = options_config.get("custom", [])
    if custom_options:
        if "option-data" not in subnet_config:
            subnet_config["option-data"] = []
        subnet_config["option-data"].extend(generate_custom_options(custom_options))

    return config


def generate_client_classes(oui_config: Dict, version: str) -> List[Dict]:
    """
    Generate client classification rules for OUI filtering.

    Args:
        oui_config: OUI filtering configuration
        version: "ipv4" or "ipv6"

    Returns:
        List of client class definitions
    """
    classes = []

    # Arista-only mode
    if oui_config.get("arista_only_mode", False):
        # Known Arista OUIs (common prefixes)
        arista_ouis = [
            "00:1C:73",  # Arista Networks
            "00:1E:0D",  # Arista Networks
            "00:1E:0E",  # Arista Networks
            "00:1E:0F",  # Arista Networks
            "00:1E:10",  # Arista Networks
            "00:1E:11",  # Arista Networks
            "00:1E:12",  # Arista Networks
            "00:1E:13",  # Arista Networks
            "00:1E:14",  # Arista Networks
            "00:1E:15",  # Arista Networks
            "00:1E:16",  # Arista Networks
            "00:1E:17",  # Arista Networks
            "00:1E:18",  # Arista Networks
            "00:1E:19",  # Arista Networks
            "00:1E:1A",  # Arista Networks
            "00:1E:1B",  # Arista Networks
            "00:1E:1C",  # Arista Networks
            "00:1E:1D",  # Arista Networks
            "00:1E:1E",  # Arista Networks
            "00:1E:1F",  # Arista Networks
        ]

        # Build test expression for Arista OUIs
        oui_tests = []
        for oui in arista_ouis:
            oui_upper = oui.upper().replace(":", "")
            oui_lower = oui.lower().replace(":", "")
            # Match first 6 characters of MAC address
            oui_tests.append(
                f"substring(pkt4.mac,0,6) == '{oui_upper}' or substring(pkt4.mac,0,6) == '{oui_lower}'"
            )

        test_expr = " or ".join(oui_tests)

        classes.append(
            {
                "name": "ARISTA_ONLY",
                "test": test_expr,
                "option-data": [],
            }
        )

    # Allowed OUIs
    allowed_ouis = oui_config.get("allowed_ouis", [])
    if allowed_ouis:
        oui_tests = []
        for oui in allowed_ouis:
            oui_upper = oui.upper().replace(":", "")
            oui_lower = oui.lower().replace(":", "")
            oui_tests.append(
                f"substring(pkt4.mac,0,6) == '{oui_upper}' or substring(pkt4.mac,0,6) == '{oui_lower}'"
            )

        test_expr = " or ".join(oui_tests)
        classes.append(
            {
                "name": "ALLOWED_OUI",
                "test": test_expr,
                "option-data": [],
            }
        )

    # Blocked OUIs
    blocked_ouis = oui_config.get("blocked_ouis", [])
    if blocked_ouis:
        oui_tests = []
        for oui in blocked_ouis:
            oui_upper = oui.upper().replace(":", "")
            oui_lower = oui.lower().replace(":", "")
            oui_tests.append(
                f"substring(pkt4.mac,0,6) == '{oui_upper}' or substring(pkt4.mac,0,6) == '{oui_lower}'"
            )

        test_expr = " or ".join(oui_tests)
        classes.append(
            {
                "name": "BLOCKED_OUI",
                "test": test_expr,
                "option-data": [],
            }
        )

    return classes


def generate_dhcp_options(options_config: Dict) -> List[Dict]:
    """
    Generate DHCP options from configuration.

    Args:
        options_config: Options configuration

    Returns:
        List of DHCP option definitions
    """
    options = []

    # Standard options
    standard = options_config.get("standard", {})
    dns_servers = standard.get("dns_servers", [])
    if dns_servers:
        options.append({"name": "domain-name-servers", "data": ", ".join(dns_servers)})

    ntp_servers = standard.get("ntp_servers", [])
    if ntp_servers:
        options.append({"name": "ntp-servers", "data": ", ".join(ntp_servers)})

    domain = standard.get("domain", "")
    if domain:
        options.append({"name": "domain-name", "data": domain})

    return options


def generate_custom_options(custom_options: List[Dict]) -> List[Dict]:
    """
    Generate custom DHCP options.

    Args:
        custom_options: List of custom option definitions

    Returns:
        List of Kea option-data dicts
    """
    options = []
    for opt in custom_options:
        option_data = {"name": opt.get("name", ""), "data": opt.get("data", "")}
        if "code" in opt:
            option_data["code"] = opt["code"]
        options.append(option_data)
    return options


def generate_pxe_options(pxe_config: Dict, version: str) -> List[Dict]:
    """
    Generate PXE boot options (66, 67).

    Args:
        pxe_config: PXE configuration
        version: "ipv4" or "ipv6"

    Returns:
        List of PXE option definitions
    """
    options = []

    if version == "ipv4":
        # Option 66: Boot server hostname/IP
        boot_server_url = pxe_config.get("boot_server_url", "")
        if boot_server_url:
            options.append({"name": "boot-server-hostname", "data": boot_server_url})
        elif pxe_config.get("boot_file_source") == "local":
            # Use local server IP (will be set by API)
            options.append({"name": "boot-server-hostname", "data": "0.0.0.0"})

        # Option 67: Boot file name
        boot_file_name = pxe_config.get("boot_file_name", "")
        if boot_file_name:
            options.append({"name": "boot-file-name", "data": boot_file_name})

    return options


def generate_relay_subnets(relay_config: Dict, version: str) -> List[Dict]:
    """
    Generate subnet configurations for each relay agent.

    Args:
        relay_config: Relay configuration
        version: "ipv4" or "ipv6"

    Returns:
        List of subnet configurations (one per relay agent)
    """
    subnets = []
    relay_subnets = relay_config.get("subnets", [])

    for relay_subnet in relay_subnets:
        subnet = relay_subnet.get("subnet", "")
        relay_agent = relay_subnet.get("relay_agent", "")
        range_start = relay_subnet.get("range_start", "")
        range_end = relay_subnet.get("range_end", "")

        if not subnet or not range_start or not range_end:
            continue

        subnet_config = {
            "subnet": subnet,
            "pools": [{"pool": f"{range_start} - {range_end}"}],
        }

        # Configure giaddr matching for relay
        if relay_agent:
            # Kea uses client-classes to match giaddr
            subnet_config["client-class"] = f"RELAY_{relay_agent.replace('.', '_')}"

        subnets.append(subnet_config)

    return subnets


def configure_giaddr_matching(relay_config: Dict) -> Dict:
    """
    Configure giaddr-based routing for relay agents.

    Args:
        relay_config: Relay configuration

    Returns:
        Client class configuration for giaddr matching
    """
    classes = []
    relay_subnets = relay_config.get("subnets", [])

    for relay_subnet in relay_subnets:
        relay_agent = relay_subnet.get("relay_agent", "")
        if relay_agent:
            class_name = f"RELAY_{relay_agent.replace('.', '_')}"
            # Match giaddr (relay agent IP)
            test_expr = f"pkt4.giaddr == '{relay_agent}'"
            classes.append({"name": class_name, "test": test_expr, "option-data": []})

    return {"client-classes": classes}


def generate_lease_database(backend_config: Dict) -> Dict:
    """
    Generate lease database configuration.

    Args:
        backend_config: Backend configuration

    Returns:
        Lease database configuration dict
    """
    backend_type = backend_config.get("type", "memfile")

    if backend_type == "postgresql":
        postgresql_config = backend_config.get("postgresql", {})
        return {
            "type": "postgresql",
            "host": postgresql_config.get("host", "localhost"),
            "port": postgresql_config.get("port", 5432),
            "name": postgresql_config.get("database", "kea"),
            "user": postgresql_config.get("user", "kea"),
            "password": postgresql_config.get("password", ""),
        }
    else:
        # Default to memfile
        return {
            "type": "memfile",
            "name": "/var/lib/kea/dhcp4.leases",  # Will be overridden per service
            "lfc-interval": 3600,
        }


def generate_ctrl_agent_config() -> Dict:
    """
    Generate Kea Control Agent configuration.

    Returns:
        Control Agent configuration dict
    """
    return {
        "http-host": "0.0.0.0",
        "http-port": KEA_CTRL_AGENT_PORT,
        "control-sockets": {
            "dhcp4": {"socket-type": "unix", "socket-name": "/run/kea/kea-dhcp4-ctrl.sock"},
            "dhcp6": {"socket-type": "unix", "socket-name": "/run/kea/kea-dhcp6-ctrl.sock"},
        },
    }
