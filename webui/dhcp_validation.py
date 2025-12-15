#!/usr/bin/env python3
"""
DHCP Configuration Validation
Addresses COMPREHENSIVE_AUDIT_REPORT.md Issue #5 (Insufficient Input Validation)
and Issue #7 (DHCP Option Validation)
"""

import ipaddress
import re
from typing import Dict, List, Optional, Tuple

# Protected DHCP options that should not be customizable
PROTECTED_DHCP_OPTIONS = {
    1: "subnet-mask",
    3: "routers",
    6: "domain-name-servers",
    15: "domain-name",
    51: "ip-address-lease-time",
    53: "dhcp-message-type",
    54: "dhcp-server-identifier",
    58: "renewal-time-value",
    59: "rebinding-time-value",
}


def validate_ip_address(ip_str: str, version: int = 4) -> Tuple[bool, Optional[str]]:
    """
    Validate IP address format.

    Args:
        ip_str: IP address string
        version: IP version (4 or 6)

    Returns:
        Tuple of (is_valid, error_message)
    """
    if not ip_str:
        return False, "IP address cannot be empty"

    try:
        ip = ipaddress.ip_address(ip_str)
        if version == 4 and not isinstance(ip, ipaddress.IPv4Address):
            return False, f"Expected IPv4 address, got IPv6: {ip_str}"
        if version == 6 and not isinstance(ip, ipaddress.IPv6Address):
            return False, f"Expected IPv6 address, got IPv4: {ip_str}"
        return True, None
    except ValueError as e:
        return False, f"Invalid IP address '{ip_str}': {str(e)}"


def validate_cidr(cidr_str: str, version: int = 4) -> Tuple[bool, Optional[str]]:
    """
    Validate CIDR notation.

    Args:
        cidr_str: CIDR string (e.g., "192.168.1.0/24")
        version: IP version (4 or 6)

    Returns:
        Tuple of (is_valid, error_message)
    """
    if not cidr_str:
        return False, "CIDR cannot be empty"

    try:
        network = ipaddress.ip_network(cidr_str, strict=False)
        if version == 4 and not isinstance(network, ipaddress.IPv4Network):
            return False, f"Expected IPv4 network, got IPv6: {cidr_str}"
        if version == 6 and not isinstance(network, ipaddress.IPv6Network):
            return False, f"Expected IPv6 network, got IPv4: {cidr_str}"

        # Check for reasonable prefix length
        if version == 4 and network.prefixlen < 8:
            return False, f"IPv4 prefix length too small (< /8): {network.prefixlen}"
        if version == 6 and network.prefixlen < 48:
            return False, f"IPv6 prefix length too small (< /48): {network.prefixlen}"

        return True, None
    except ValueError as e:
        return False, f"Invalid CIDR '{cidr_str}': {str(e)}"


def validate_dhcp_range(
    range_start: str, range_end: str, subnet: str, max_size: int = 65536
) -> Tuple[bool, Optional[str]]:
    """
    Validate DHCP range parameters.

    Args:
        range_start: Start IP address
        range_end: End IP address
        subnet: Subnet in CIDR notation
        max_size: Maximum allowed range size

    Returns:
        Tuple of (is_valid, error_message)
    """
    # Validate IP addresses
    is_valid, error = validate_ip_address(range_start)
    if not is_valid:
        return False, f"Invalid range_start: {error}"

    is_valid, error = validate_ip_address(range_end)
    if not is_valid:
        return False, f"Invalid range_end: {error}"

    # Validate subnet
    is_valid, error = validate_cidr(subnet)
    if not is_valid:
        return False, f"Invalid subnet: {error}"

    try:
        start_ip = ipaddress.ip_address(range_start)
        end_ip = ipaddress.ip_address(range_end)
        network = ipaddress.ip_network(subnet, strict=False)

        # Check range order
        if start_ip >= end_ip:
            return False, f"range_start ({range_start}) must be less than range_end ({range_end})"

        # Check IPs are in subnet
        if start_ip not in network:
            return False, f"range_start ({range_start}) is not in subnet ({subnet})"
        if end_ip not in network:
            return False, f"range_end ({range_end}) is not in subnet ({subnet})"

        # Check range size
        range_size = int(end_ip) - int(start_ip) + 1
        if range_size > max_size:
            return False, f"Range size ({range_size}) exceeds maximum ({max_size})"

        # Check for reserved IPs (network address and broadcast)
        if start_ip == network.network_address:
            return False, f"range_start cannot be network address ({network.network_address})"
        if end_ip == network.broadcast_address:
            return False, f"range_end cannot be broadcast address ({network.broadcast_address})"

        return True, None

    except Exception as e:
        return False, f"Range validation error: {str(e)}"


def validate_gateway(gateway: str, subnet: str) -> Tuple[bool, Optional[str]]:
    """
    Validate gateway IP address.

    Args:
        gateway: Gateway IP address
        subnet: Subnet in CIDR notation

    Returns:
        Tuple of (is_valid, error_message)
    """
    if not gateway:
        return True, None  # Gateway is optional

    # Validate IP address
    is_valid, error = validate_ip_address(gateway)
    if not is_valid:
        return False, f"Invalid gateway: {error}"

    # Validate subnet
    is_valid, error = validate_cidr(subnet)
    if not is_valid:
        return False, f"Invalid subnet: {error}"

    try:
        gateway_ip = ipaddress.ip_address(gateway)
        network = ipaddress.ip_network(subnet, strict=False)

        # Check gateway is in subnet
        if gateway_ip not in network:
            return False, f"Gateway ({gateway}) is not in subnet ({subnet})"

        return True, None

    except Exception as e:
        return False, f"Gateway validation error: {str(e)}"


def validate_dns_servers(dns_servers: List[str]) -> Tuple[bool, Optional[str]]:
    """
    Validate DNS server IP addresses.

    Args:
        dns_servers: List of DNS server IP addresses

    Returns:
        Tuple of (is_valid, error_message)
    """
    if not dns_servers:
        return True, None  # DNS servers are optional

    if not isinstance(dns_servers, list):
        return False, "DNS servers must be a list"

    for i, dns in enumerate(dns_servers):
        is_valid, error = validate_ip_address(dns)
        if not is_valid:
            return False, f"Invalid DNS server #{i+1}: {error}"

    return True, None


def validate_domain_name(domain: str) -> Tuple[bool, Optional[str]]:
    """
    Validate domain name format.

    Args:
        domain: Domain name

    Returns:
        Tuple of (is_valid, error_message)
    """
    if not domain:
        return True, None  # Domain is optional

    # RFC 1035 domain name validation
    # Max 253 characters, labels max 63 characters, alphanumeric and hyphens
    if len(domain) > 253:
        return False, f"Domain name too long (max 253 characters): {len(domain)}"

    # Split into labels
    labels = domain.split(".")
    if not labels:
        return False, "Domain name cannot be empty"

    for label in labels:
        if not label:
            return False, "Domain name cannot have empty labels"
        if len(label) > 63:
            return False, f"Domain label too long (max 63 characters): {label}"
        if not re.match(r"^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$", label):
            return False, f"Invalid domain label: {label}"

    return True, None


def validate_port(
    port: int, min_port: int = 1, max_port: int = 65535
) -> Tuple[bool, Optional[str]]:
    """
    Validate port number.

    Args:
        port: Port number
        min_port: Minimum allowed port
        max_port: Maximum allowed port

    Returns:
        Tuple of (is_valid, error_message)
    """
    if not isinstance(port, int):
        return False, f"Port must be an integer, got {type(port).__name__}"

    if port < min_port or port > max_port:
        return False, f"Port {port} out of range ({min_port}-{max_port})"

    return True, None


def validate_dhcp_option(option: Dict) -> Tuple[bool, Optional[str]]:
    """
    Validate custom DHCP option.

    Args:
        option: DHCP option dictionary with 'code', 'name', 'data'

    Returns:
        Tuple of (is_valid, error_message)
    """
    if not isinstance(option, dict):
        return False, "DHCP option must be a dictionary"

    # Validate option code
    if "code" not in option:
        return False, "DHCP option must have 'code' field"

    code = option["code"]
    if not isinstance(code, int):
        return False, f"DHCP option code must be an integer, got {type(code).__name__}"

    # Check for protected options
    if code in PROTECTED_DHCP_OPTIONS:
        return (
            False,
            f"DHCP option {code} ({PROTECTED_DHCP_OPTIONS[code]}) is protected and cannot be customized",
        )

    # Validate option code range (1-254, 255 is reserved)
    if code < 1 or code > 254:
        return False, f"DHCP option code {code} out of valid range (1-254)"

    # Validate name if provided
    if "name" in option:
        name = option["name"]
        if not isinstance(name, str):
            return False, f"DHCP option name must be a string, got {type(name).__name__}"
        if not name:
            return False, "DHCP option name cannot be empty"

    # Validate data if provided
    if "data" in option:
        data = option["data"]
        if not isinstance(data, str):
            return False, f"DHCP option data must be a string, got {type(data).__name__}"

    return True, None


def validate_dhcp_config(dhcp_config: Dict) -> Tuple[bool, Optional[str]]:
    """
    Validate complete DHCP configuration.

    Args:
        dhcp_config: DHCP configuration dictionary

    Returns:
        Tuple of (is_valid, error_message)
    """
    if not isinstance(dhcp_config, dict):
        return False, "DHCP config must be a dictionary"

    # Validate required fields for IPv4
    if "ipv4" in dhcp_config:
        ipv4 = dhcp_config["ipv4"]

        if "subnet" in ipv4:
            is_valid, error = validate_cidr(ipv4["subnet"], version=4)
            if not is_valid:
                return False, f"IPv4 subnet: {error}"

        if "range_start" in ipv4 and "range_end" in ipv4 and "subnet" in ipv4:
            is_valid, error = validate_dhcp_range(
                ipv4["range_start"], ipv4["range_end"], ipv4["subnet"]
            )
            if not is_valid:
                return False, f"IPv4 range: {error}"

        if "gateway" in ipv4 and "subnet" in ipv4:
            is_valid, error = validate_gateway(ipv4["gateway"], ipv4["subnet"])
            if not is_valid:
                return False, f"IPv4 gateway: {error}"

        if "dns_servers" in ipv4:
            is_valid, error = validate_dns_servers(ipv4["dns_servers"])
            if not is_valid:
                return False, f"IPv4 DNS: {error}"

        if "domain" in ipv4:
            is_valid, error = validate_domain_name(ipv4["domain"])
            if not is_valid:
                return False, f"IPv4 domain: {error}"

    # Validate required fields for IPv6
    if "ipv6" in dhcp_config:
        ipv6 = dhcp_config["ipv6"]

        if "subnet" in ipv6:
            is_valid, error = validate_cidr(ipv6["subnet"], version=6)
            if not is_valid:
                return False, f"IPv6 subnet: {error}"

        if "range_start" in ipv6 and "range_end" in ipv6 and "subnet" in ipv6:
            is_valid, error = validate_dhcp_range(
                ipv6["range_start"], ipv6["range_end"], ipv6["subnet"]
            )
            if not is_valid:
                return False, f"IPv6 range: {error}"

        if "dns_servers" in ipv6:
            # IPv6 DNS can be IPv4 or IPv6
            is_valid, error = validate_dns_servers(ipv6["dns_servers"])
            if not is_valid:
                return False, f"IPv6 DNS: {error}"

        if "domain" in ipv6:
            is_valid, error = validate_domain_name(ipv6["domain"])
            if not is_valid:
                return False, f"IPv6 domain: {error}"

    # Validate custom options if present
    if "custom" in dhcp_config:
        custom_options = dhcp_config["custom"]
        if not isinstance(custom_options, list):
            return False, "Custom options must be a list"

        for i, option in enumerate(custom_options):
            is_valid, error = validate_dhcp_option(option)
            if not is_valid:
                return False, f"Custom option #{i+1}: {error}"

    # Validate lease time if present
    if "lease_time" in dhcp_config:
        lease_time = dhcp_config["lease_time"]
        if not isinstance(lease_time, int):
            return False, f"Lease time must be an integer, got {type(lease_time).__name__}"
        if lease_time < 60 or lease_time > 86400 * 365:  # 1 minute to 1 year
            return False, f"Lease time {lease_time} out of reasonable range (60-31536000)"

    return True, None
