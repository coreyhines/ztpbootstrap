#!/usr/bin/env python3
"""
Kea DHCP Configuration Generator
Generates Kea JSON configuration from YAML config
"""

import ipaddress
import logging
import os
from typing import Dict, List, Optional

from dhcp_utils import detect_networking_mode, get_interfaces_for_kea

logger = logging.getLogger(__name__)

# Kea Control Agent default port
KEA_CTRL_AGENT_PORT = 8000

# Host offset used as the default relay agent (giaddr) on a /24. Switch SVIs
# that relay DHCP are conventionally the last usable host in the subnet.
DEFAULT_RELAY_HOST_OFFSET = 254


def resolve_relay_agents(ip_config: Dict, subnet: str, gateway: str) -> List[str]:
    """
    Determine the relay agent (giaddr) addresses to advertise for a subnet.

    An explicit ``relay_agents`` list in the config always wins. Otherwise, for
    an IPv4 /24 with a gateway configured, default to the last usable host (the
    SVI that typically relays DHCP) plus the gateway itself. Without this, Kea
    only selects the subnet for on-link Discovers and NAKs relayed ones with
    "failed to select a subnet".

    Kea treats ``relay.ip-addresses`` as an additional way to select the subnet,
    so listing these addresses never narrows normal subnet selection.

    Args:
        ip_config: The ipv4 or ipv6 section of the DHCP config
        subnet: Subnet in CIDR notation
        gateway: Gateway address, or "" if unset

    Returns:
        Relay agent addresses, or an empty list if none apply
    """
    configured = ip_config.get("relay_agents") or []
    if isinstance(configured, str):
        configured = [part.strip() for part in configured.split(",")]
    agents = [str(agent).strip() for agent in configured if str(agent).strip()]
    if agents:
        return agents

    if not gateway:
        return []

    try:
        network = ipaddress.ip_network(subnet, strict=False)
    except ValueError:
        logger.warning("Cannot parse subnet %r; skipping relay agent defaults", subnet)
        return []

    # Only IPv4 /24 has a safe "last usable host is the relay" convention.
    if network.version != 4 or network.prefixlen != 24:
        return []

    defaults = [str(network.network_address + DEFAULT_RELAY_HOST_OFFSET), gateway]
    # dict.fromkeys preserves order while dropping the duplicate when the
    # gateway already is the relay host.
    return list(dict.fromkeys(defaults))


# Default subnet IDs — match generate_dhcp4/6_config "id" fields
DEFAULT_DHCP4_SUBNET_ID = 1
DEFAULT_DHCP6_SUBNET_ID = 1


def dhcp_service_for_ip(ip: str) -> str:
    """Return Kea service name for an IP address."""
    return "dhcp6" if ":" in str(ip) else "dhcp4"


def _normalize_mac(mac: str) -> str:
    return str(mac).lower().replace("-", ":").strip()


def _build_kea_subnet_reservations(dhcp_config: Dict, ip_version: int) -> List[Dict]:
    """Build Kea subnet reservation rows from config.yaml dhcp.reservations."""
    rows: List[Dict] = []
    for item in dhcp_config.get("reservations") or []:
        mac = item.get("hw-address") or item.get("hwaddr") or item.get("mac")
        ip = item.get("ip-address") or item.get("ip") or item.get("address")
        if not mac or not ip:
            continue
        ip_str = str(ip).strip()
        is_v6 = ":" in ip_str
        if ip_version == 4 and is_v6:
            continue
        if ip_version == 6 and not is_v6:
            continue
        entry: Dict = {"hw-address": _normalize_mac(mac), "ip-address": ip_str}
        hostname = (item.get("hostname") or item.get("host") or "").strip()
        if hostname:
            entry["hostname"] = hostname
        rows.append(entry)
    return rows


def _build_kea_subnet6_reservations(dhcp_config: Dict) -> List[Dict]:
    """DHCPv6 reservations use ip-addresses (array), not ip-address."""
    rows: List[Dict] = []
    for item in dhcp_config.get("reservations") or []:
        mac = item.get("hw-address") or item.get("hwaddr") or item.get("mac")
        ip = item.get("ip-address") or item.get("ip") or item.get("address")
        if not mac or not ip:
            continue
        ip_str = str(ip).strip()
        if ":" not in ip_str:
            continue
        entry: Dict = {
            "hw-address": _normalize_mac(mac),
            "ip-addresses": [ip_str],
        }
        hostname = (item.get("hostname") or item.get("host") or "").strip()
        if hostname:
            entry["hostname"] = hostname
        rows.append(entry)
    return rows


def _apply_subnet_reservations(subnet_config: Dict, dhcp_config: Dict, ip_version: int) -> None:
    if ip_version == 6:
        reservations = _build_kea_subnet6_reservations(dhcp_config)
    else:
        reservations = _build_kea_subnet_reservations(dhcp_config, ip_version=4)
    if reservations:
        subnet_config["reservations"] = reservations


# Default Kea hook directory in the runtime image (RHEL/Fedora layout).
DEFAULT_HOOK_LIBRARY_PATH = "/usr/lib64/kea/hooks"


def _build_hooks_libraries(backend_config: Dict, backend_type: str) -> List[Dict]:
    """Build Kea hooks-libraries list.

    lease_cmds works with every backend (including memfile) and is required for
    the Control Agent / Web UI to enumerate and manage leases. host_cmds needs a
    database backend, so it is only loaded for PostgreSQL/MySQL.
    """
    hook_path = backend_config.get("hook_library_path", DEFAULT_HOOK_LIBRARY_PATH)
    hooks = [{"library": f"{hook_path}/libdhcp_lease_cmds.so"}]
    if backend_type in ["postgresql", "mysql"]:
        hooks.append({"library": f"{hook_path}/libdhcp_host_cmds.so"})
    return hooks


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
    subnet = str(ipv4_config.get("subnet", "")).strip()
    range_start = str(ipv4_config.get("range_start", "")).strip()
    range_end = str(ipv4_config.get("range_end", "")).strip()
    gateway = str(ipv4_config.get("gateway", "")).strip()

    # Validate required fields
    if not subnet or not range_start or not range_end:
        raise ValueError("IPv4 subnet, range_start, and range_end are required")

    # Get interfaces for Kea to bind to
    interfaces = get_interfaces_for_kea(networking_mode, subnet)

    # Build interfaces-config
    # Ensure interfaces is always a list of strings
    if not interfaces:
        interfaces = []
    elif not isinstance(interfaces, list):
        # If it's a string, convert to list
        interfaces = [str(interfaces)] if interfaces else []
    else:
        # Ensure all items are strings
        interfaces = [str(iface) for iface in interfaces if iface]

    # Filter out any None, empty, or invalid values
    interfaces = [
        iface.strip() for iface in interfaces if iface and iface.strip() and isinstance(iface, str)
    ]

    interfaces_config = {}
    if interfaces:
        interfaces_config["interfaces"] = interfaces
    else:
        # If no specific interfaces, Kea will bind to all available interfaces
        interfaces_config["interfaces"] = ["*"]

    # Build subnet configuration
    # Kea requires each subnet to have a unique id
    subnet_config = {
        "id": DEFAULT_DHCP4_SUBNET_ID,  # Use default constant
        "subnet": subnet,
        "pools": [{"pool": f"{range_start} - {range_end}"}],
    }

    relay_agents = resolve_relay_agents(ipv4_config, subnet, gateway)
    if relay_agents:
        subnet_config["relay"] = {"ip-addresses": relay_agents}

    # Add gateway/router option
    if gateway and gateway.strip():
        if "option-data" not in subnet_config:
            subnet_config["option-data"] = []
        subnet_config["option-data"].append({"name": "routers", "data": str(gateway).strip()})

    # Add DNS servers (option 6)
    # Note: Kea 3.0.2+ requires comma-separated string format, not array
    dns_servers = ipv4_config.get("dns_servers", [])
    if dns_servers:
        # Ensure dns_servers is a list
        if isinstance(dns_servers, str):
            # Split by comma and clean
            dns_servers = [s.strip().rstrip("., ") for s in dns_servers.split(",") if s.strip()]
        # Clean each IP address (remove trailing periods/commas)
        cleaned_dns = [ip.strip().rstrip("., ") for ip in dns_servers if ip.strip()]
        if cleaned_dns:
            if "option-data" not in subnet_config:
                subnet_config["option-data"] = []
            # Kea 3.0.2+ requires comma-separated string for multi-value options
            subnet_config["option-data"].append(
                {"name": "domain-name-servers", "data": ", ".join(cleaned_dns)}
            )

    # Add domain name
    domain = ipv4_config.get("domain", "")
    if domain:
        if "option-data" not in subnet_config:
            subnet_config["option-data"] = []
        subnet_config["option-data"].append({"name": "domain-name", "data": domain})

    # Add NTP servers (option 42)
    # Note: Kea 3.0.2+ requires comma-separated string format, not array
    ntp_servers = ipv4_config.get("ntp_servers", [])
    if ntp_servers:
        # Ensure ntp_servers is a list
        if isinstance(ntp_servers, str):
            # Split by comma and clean
            ntp_servers = [s.strip().rstrip("., ") for s in ntp_servers.split(",") if s.strip()]
        # Clean each IP address
        cleaned_ntp = [ip.strip().rstrip("., ") for ip in ntp_servers if ip.strip()]
        if cleaned_ntp:
            if "option-data" not in subnet_config:
                subnet_config["option-data"] = []
            # Kea 3.0.2+ requires comma-separated string for multi-value options
            subnet_config["option-data"].append(
                {"name": "ntp-servers", "data": ", ".join(cleaned_ntp)}
            )

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

    _apply_subnet_reservations(subnet_config, dhcp_config, ip_version=4)

    # Build main DHCPv4 config
    backend_config = dhcp_config.get("backend", {})
    backend_type = backend_config.get("type", "memfile")

    config = {
        "interfaces-config": interfaces_config,
        "lease-database": generate_lease_database(backend_config),
        "subnet4": [subnet_config],
        "valid-lifetime": 86400,  # 24 hours default
        "renew-timer": 43200,  # 12 hours
        "rebind-timer": 75600,  # 21 hours
        "control-socket": {
            "socket-type": "unix",
            "socket-name": "/var/run/kea/kea-dhcp4-ctrl.sock",
        },
    }

    # Only add hosts-database for PostgreSQL/MySQL (entrypoint script requirement)
    # For memfile, we omit it to avoid entrypoint script errors
    if backend_type in ["postgresql", "mysql"]:
        config["hosts-database"] = generate_lease_database(backend_config)

    # Always load lease_cmds (memfile-compatible) so the Control Agent / Web UI
    # can enumerate leases; host_cmds is added for DB backends inside the helper.
    config["hooks-libraries"] = _build_hooks_libraries(backend_config, backend_type)

    # Add client classification for OUI filtering
    oui_config = dhcp_config.get("oui_filtering", {})
    if (
        oui_config.get("arista_only_mode")
        or oui_config.get("allowed_ouis")
        or oui_config.get("blocked_ouis")
    ):
        client_classes = generate_client_classes(oui_config, "ipv4")
        if client_classes:
            config["client-classes"] = client_classes
        # Add classifier to subnet, but only if the class was actually defined
        if oui_config.get("arista_only_mode") and any(
            cls["name"] == "ARISTA_ONLY" for cls in client_classes
        ):
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
    subnet = str(ipv6_config.get("subnet", "")).strip()
    range_start = str(ipv6_config.get("range_start", "")).strip()
    range_end = str(ipv6_config.get("range_end", "")).strip()
    gateway = str(ipv6_config.get("gateway", "")).strip()

    # Validate required fields
    if not subnet or not range_start or not range_end:
        raise ValueError("IPv6 subnet, range_start, and range_end are required")

    # Get interfaces for Kea to bind to
    interfaces = get_interfaces_for_kea(networking_mode, subnet)

    # Build interfaces-config
    # Ensure interfaces is always a list of strings
    if not interfaces:
        interfaces = []
    elif not isinstance(interfaces, list):
        # If it's a string, convert to list
        interfaces = [str(interfaces)] if interfaces else []
    else:
        # Ensure all items are strings
        interfaces = [str(iface) for iface in interfaces if iface]

    # Filter out any None, empty, or invalid values
    interfaces = [
        iface.strip() for iface in interfaces if iface and iface.strip() and isinstance(iface, str)
    ]

    interfaces_config = {}
    if interfaces:
        interfaces_config["interfaces"] = interfaces
    else:
        # If no specific interfaces, Kea will bind to all available interfaces
        interfaces_config["interfaces"] = ["*"]

    # Build subnet configuration
    # Kea requires each subnet to have a unique id
    subnet_config = {
        "id": 1,  # Use 1 as default, can be made configurable if needed
        "subnet": subnet,
        "pools": [{"pool": f"{range_start} - {range_end}"}],
    }

    relay_agents = resolve_relay_agents(ipv6_config, subnet, gateway)
    if relay_agents:
        subnet_config["relay"] = {"ip-addresses": relay_agents}

    # Add gateway/router option (option 3 for IPv6)
    if gateway and gateway.strip():
        if "option-data" not in subnet_config:
            subnet_config["option-data"] = []
        subnet_config["option-data"].append({"name": "sntp-servers", "data": str(gateway).strip()})

    # Add DNS servers (option 23 - must be array of IP addresses)
    dns_servers = ipv6_config.get("dns_servers", [])
    if dns_servers:
        # Ensure dns_servers is a list
        if isinstance(dns_servers, str):
            # Split by comma and clean
            dns_servers = [s.strip().rstrip("., ") for s in dns_servers.split(",") if s.strip()]
        # Clean each IP address
        cleaned_dns = [ip.strip().rstrip("., ") for ip in dns_servers if ip.strip()]
        if cleaned_dns:
            if "option-data" not in subnet_config:
                subnet_config["option-data"] = []
            # Kea JSON config expects a string, not an array, for dns-servers.
            subnet_config["option-data"].append(
                {"name": "dns-servers", "data": ", ".join(cleaned_dns)}
            )

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

    _apply_subnet_reservations(subnet_config, dhcp_config, ip_version=6)

    # Build main DHCPv6 config
    backend_config = dhcp_config.get("backend", {})
    backend_type = backend_config.get("type", "memfile")

    # Generate lease database with correct filename for IPv6
    lease_db = generate_lease_database(backend_config)
    if lease_db.get("type") == "memfile":
        lease_db["name"] = "/var/lib/kea/dhcp6.leases"  # Use dhcp6.leases for IPv6

    config = {
        "interfaces-config": interfaces_config,
        "lease-database": lease_db,
        "subnet6": [subnet_config],
        "valid-lifetime": 86400,  # 24 hours default
        "renew-timer": 43200,  # 12 hours
        "rebind-timer": 75600,  # 21 hours
        "control-socket": {
            "socket-type": "unix",
            "socket-name": "/var/run/kea/kea-dhcp6-ctrl.sock",
        },
    }

    # Only add hosts-database for PostgreSQL/MySQL (entrypoint script requirement)
    # For memfile, we omit it to avoid entrypoint script errors
    if backend_type in ["postgresql", "mysql"]:
        config["hosts-database"] = generate_lease_database(backend_config)

    # Always load lease_cmds (memfile-compatible) so the Control Agent / Web UI
    # can enumerate leases; host_cmds is added for DB backends inside the helper.
    config["hooks-libraries"] = _build_hooks_libraries(backend_config, backend_type)

    # Add client classification for OUI filtering
    oui_config = dhcp_config.get("oui_filtering", {})
    if (
        oui_config.get("arista_only_mode")
        or oui_config.get("allowed_ouis")
        or oui_config.get("blocked_ouis")
    ):
        # DHCPv6 cannot classify on hardware address; generate_client_classes
        # returns nothing, and the subnet must not reference a class that the
        # config does not define.
        client_classes = generate_client_classes(oui_config, "ipv6")
        if client_classes:
            config["client-classes"] = client_classes

    # Add custom DHCP options
    options_config = dhcp_config.get("options", {})
    custom_options = options_config.get("custom", [])
    if custom_options:
        if "option-data" not in subnet_config:
            subnet_config["option-data"] = []
        subnet_config["option-data"].extend(generate_custom_options(custom_options))

    return config


def build_oui_test(ouis: List[str]) -> str:
    """
    Build a Kea classification expression matching any of the given OUIs.

    ``pkt4.mac`` evaluates to the raw 6-byte hardware address, so the first
    3 bytes must be compared against a hex literal (``0x001C73``). Comparing
    them against a quoted string compares binary bytes to ASCII text and never
    matches, which silently rejects every client when the subnet is guarded by
    the resulting class.

    Args:
        ouis: OUI prefixes, with or without separators (e.g. "2C:DD:E9")

    Returns:
        Kea test expression, or "" if no usable OUIs were supplied
    """
    tests = []
    for oui in ouis:
        digits = str(oui).replace(":", "").replace("-", "").replace(".", "").strip()
        if len(digits) != 6:
            logger.warning("Skipping malformed OUI %r (expected 6 hex digits)", oui)
            continue
        try:
            int(digits, 16)
        except ValueError:
            logger.warning("Skipping non-hex OUI %r", oui)
            continue
        tests.append(f"substring(pkt4.mac,0,3) == 0x{digits.upper()}")

    return " or ".join(tests)


def generate_client_classes(oui_config: Dict, version: str) -> List[Dict]:
    """
    Generate client classification rules for OUI filtering.

    Only DHCPv4 is supported: DHCPv6 has no reliable way to observe a client's
    MAC address, and ``pkt4`` tokens are invalid in a Dhcp6 config, so a v6
    request returns no classes rather than emitting a config Kea cannot load.

    Args:
        oui_config: OUI filtering configuration
        version: "ipv4" or "ipv6"

    Returns:
        List of client class definitions
    """
    classes: List[Dict] = []

    if version != "ipv4":
        logger.warning(
            "OUI filtering is not supported for %s; DHCPv6 cannot match hardware addresses",
            version,
        )
        return classes

    # Arista-only mode
    if oui_config.get("arista_only_mode", False):
        # Known Arista OUIs (common prefixes). The 2C:DD:E9 block covers the
        # CCS-710P; omitting it caused Kea to NAK those switches on VLAN5.
        arista_ouis = [
            "00:1C:73",  # Arista Networks
            "2C:DD:E9",  # Arista Networks (CCS-710P and other modern platforms)
            "FC:BD:67",  # Arista Networks
            "E0:FA:5B",  # Arista Networks
            "28:99:3A",  # Arista Networks
            "EC:8A:48",  # Arista Networks
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

        test_expr = build_oui_test(arista_ouis)
        if test_expr:
            classes.append(
                {
                    "name": "ARISTA_ONLY",
                    "test": test_expr,
                    "option-data": [],
                }
            )

    # Allowed OUIs
    test_expr = build_oui_test(oui_config.get("allowed_ouis", []))
    if test_expr:
        classes.append(
            {
                "name": "ALLOWED_OUI",
                "test": test_expr,
                "option-data": [],
            }
        )

    # Blocked OUIs
    test_expr = build_oui_test(oui_config.get("blocked_ouis", []))
    if test_expr:
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
        # Ensure dns_servers is a list
        if isinstance(dns_servers, str):
            dns_servers = [s.strip().rstrip("., ") for s in dns_servers.split(",") if s.strip()]
        # Clean each IP address
        cleaned_dns = [ip.strip().rstrip("., ") for ip in dns_servers if ip.strip()]
        if cleaned_dns:
            # Kea expects DNS servers as an array
            options.append({"name": "domain-name-servers", "data": cleaned_dns})

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
        # Option 66: Boot server hostname/IP (use standard option name for Kea)
        boot_server_url = pxe_config.get("boot_server_url", "")
        if boot_server_url:
            options.append({"name": "option-66", "code": 66, "data": boot_server_url})

        # Option 67: Boot file name
        boot_file_name = pxe_config.get("boot_file_name", "")
        if boot_file_name:
            options.append({"name": "boot-file-name", "code": 67, "data": boot_file_name})

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
            "id": len(subnets) + 1,  # Unique ID for each relay subnet
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
        # Password sourced from env at config-render time (never hardcoded in config.yaml)
        password = postgresql_config.get("password") or os.environ.get("POSTGRES_PASSWORD", "")
        return {
            "type": "postgresql",
            "host": postgresql_config.get("host", "127.0.0.1"),
            "port": postgresql_config.get("port", 5432),
            "name": postgresql_config.get("database", "kea"),
            "user": postgresql_config.get("user", "kea"),
            "password": password,
        }
    else:
        # Default to memfile
        # Note: For hosts-database, we use the same memfile backend
        # but with a different filename for hosts reservations
        return {
            "type": "memfile",
            "name": "/var/lib/kea/dhcp4.leases",  # Will be overridden per service
            "persist": True,  # Enable lease persistence to disk
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
            "dhcp4": {"socket-type": "unix", "socket-name": "/var/run/kea/kea-dhcp4-ctrl.sock"},
            "dhcp6": {"socket-type": "unix", "socket-name": "/var/run/kea/kea-dhcp6-ctrl.sock"},
        },
    }


# ============================================================================
# DHCP Reservation Helpers (Bucket W4)
# ============================================================================


def dhcp_subnet_id_for_service(config: Dict, service: str) -> int:
    """Return configured Kea subnet id (matches generate_dhcp4/6_config id field)."""
    dhcp = config.get("dhcp") or {}
    if service == "dhcp6":
        return int(dhcp.get("ipv6_subnet_id") or DEFAULT_DHCP6_SUBNET_ID)
    return int(dhcp.get("ipv4_subnet_id") or DEFAULT_DHCP4_SUBNET_ID)


def find_reservation_in_config(config: Dict, mac: str) -> Optional[Dict]:
    """Find a reservation dict in config by MAC (normalized compare)."""
    target = _normalize_mac(mac)
    for row in (config.get("dhcp") or {}).get("reservations") or []:
        row_mac = row.get("hw-address") or row.get("mac") or ""
        if _normalize_mac(str(row_mac)) == target:
            return row
    return None


def build_kea_reservation_payload(
    mac: str,
    ip: str,
    config: Dict,
    hostname: Optional[str] = None,
):
    """
    Build reservation-add payload for Kea host_cmds API.

    Returns:
        (reservation dict, service name)
    """
    service = dhcp_service_for_ip(ip)
    reservation = {
        "subnet-id": dhcp_subnet_id_for_service(config, service),
        "identifier-type": "hw-address",
        "identifier": _normalize_mac(mac),
        "ip-address": str(ip).strip(),
    }
    if hostname:
        reservation["hostname"] = str(hostname).strip()
    return reservation, service
