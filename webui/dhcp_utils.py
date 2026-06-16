#!/usr/bin/env python3
"""
DHCP Utility Functions
Network detection, validation, and helper functions for DHCP configuration
"""

import ipaddress
import json
import logging
import re
import socket
import subprocess
from pathlib import Path
from typing import Dict, List, Optional, Tuple

logger = logging.getLogger(__name__)


def detect_subnet(ip_address: str) -> str:
    """
    Detect subnet from IP address.
    Assumes /24 for IPv4, /64 for IPv6 (common defaults).

    Args:
        ip_address: IP address in string format

    Returns:
        CIDR notation subnet string (e.g., "10.0.0.0/24" or "2001:db8::/64")
    """
    try:
        ip = ipaddress.ip_address(ip_address)
        if isinstance(ip, ipaddress.IPv4Address):
            # For IPv4, assume /24 unless it's a /16 or /8 network
            network = ipaddress.IPv4Network(f"{ip}/24", strict=False)
            return str(network)
        else:
            # For IPv6, assume /64
            network = ipaddress.IPv6Network(f"{ip}/64", strict=False)
            return str(network)
    except ValueError as e:
        logger.error(f"Invalid IP address for subnet detection: {ip_address}: {e}")
        return ""


def detect_gateway(
    ipv4_address: Optional[str] = None, ipv6_address: Optional[str] = None
) -> Dict[str, Optional[str]]:
    """
    Detect gateway from host routes.
    Checks:
    1. Default route (ip route | grep default)
    2. Route for pod network
    3. Network interface configuration

    Args:
        ipv4_address: Optional IPv4 address to check routes for
        ipv6_address: Optional IPv6 address to check routes for

    Returns:
        Dict with 'ipv4_gateway' and 'ipv6_gateway' keys
    """
    result = {"ipv4_gateway": None, "ipv6_gateway": None}

    try:
        # Try to get default route using 'ip route'
        # First try /usr/sbin/ip (common location), then just 'ip'
        ip_cmd = None
        for ip_path in ["/usr/sbin/ip", "/sbin/ip", "ip"]:
            try:
                version_check = subprocess.run(
                    [ip_path, "--version"],
                    capture_output=True,
                    timeout=1,
                )
                if version_check.returncode == 0:
                    ip_cmd = ip_path
                    break
            except (FileNotFoundError, subprocess.TimeoutExpired):
                continue

        if not ip_cmd:
            logger.warning("ip command not found, skipping gateway detection")
            return result

        ipv4_route_result = subprocess.run(
            [ip_cmd, "route", "show", "default"],
            capture_output=True,
            text=True,
            timeout=2,
        )
        if ipv4_route_result.returncode == 0 and ipv4_route_result.stdout:
            # Parse default route: "default via 10.0.0.1 dev eth0"
            match = re.search(r"default via (\S+)", ipv4_route_result.stdout)
            if match:
                result["ipv4_gateway"] = match.group(1)

        # Try IPv6 default route
        ipv6_route_result = subprocess.run(
            [ip_cmd, "-6", "route", "show", "default"],
            capture_output=True,
            text=True,
            timeout=2,
        )
        if ipv6_route_result.returncode == 0 and ipv6_route_result.stdout:
            match = re.search(r"default via (\S+)", ipv6_route_result.stdout)
            if match:
                result["ipv6_gateway"] = match.group(1)

    except (subprocess.TimeoutExpired, FileNotFoundError, subprocess.SubprocessError) as e:
        logger.warning(f"Failed to detect gateway via ip route: {e}")

    # Fallback: try 'route -n' for IPv4
    if not result["ipv4_gateway"]:
        try:
            route_result = subprocess.run(
                ["route", "-n"],
                capture_output=True,
                text=True,
                timeout=2,
            )
            if route_result.returncode == 0:
                # Parse route table for default gateway
                for line in route_result.stdout.split("\n"):
                    if line.startswith("0.0.0.0"):
                        parts = line.split()
                        if len(parts) >= 2:
                            result["ipv4_gateway"] = parts[1]
                            break
        except (subprocess.TimeoutExpired, FileNotFoundError, subprocess.SubprocessError) as e:
            logger.warning(f"Failed to detect gateway via route -n: {e}")

    return result


def validate_dhcp_range(
    subnet: str,
    range_start: str,
    range_end: str,
    gateway: Optional[str] = None,
    pod_ip: Optional[str] = None,
) -> Tuple[bool, List[str], List[str]]:
    """
    Validate DHCP range:
    - Range is within subnet
    - Gateway is excluded
    - Pod IP is excluded
    - Broadcast address is excluded
    - Range is valid (start < end)

    Args:
        subnet: Subnet in CIDR notation
        range_start: Start of DHCP range
        range_end: End of DHCP range
        gateway: Optional gateway IP to exclude
        pod_ip: Optional pod IP to exclude

    Returns:
        Tuple of (is_valid, conflicts_list, warnings_list)
    """
    conflicts = []
    warnings = []
    is_valid = True

    try:
        network = ipaddress.ip_network(subnet, strict=False)
        start_ip = ipaddress.ip_address(range_start)
        end_ip = ipaddress.ip_address(range_end)

        # Check if range is valid (start < end)
        if start_ip >= end_ip:
            conflicts.append(
                f"Range start ({range_start}) must be less than range end ({range_end})"
            )
            is_valid = False
            return (is_valid, conflicts, warnings)

        # Check if both IPs are in the subnet
        if start_ip not in network:
            conflicts.append(f"Range start {range_start} is not in subnet {subnet}")
            is_valid = False

        if end_ip not in network:
            conflicts.append(f"Range end {range_end} is not in subnet {subnet}")
            is_valid = False

        # Check for conflicts with gateway
        if gateway:
            try:
                gateway_ip = ipaddress.ip_address(gateway)
                if gateway_ip in network:
                    if start_ip <= gateway_ip <= end_ip:
                        conflicts.append(f"Gateway {gateway} is within DHCP range")
                        is_valid = False
                    else:
                        warnings.append(f"Gateway {gateway} is in subnet but outside range")
            except ValueError:
                warnings.append(f"Invalid gateway address: {gateway}")

        # Check for conflicts with pod IP
        if pod_ip:
            try:
                pod_ip_addr = ipaddress.ip_address(pod_ip)
                if pod_ip_addr in network:
                    if start_ip <= pod_ip_addr <= end_ip:
                        conflicts.append(f"Pod IP {pod_ip} is within DHCP range")
                        is_valid = False
                    else:
                        warnings.append(f"Pod IP {pod_ip} is in subnet but outside range")
            except ValueError:
                warnings.append(f"Invalid pod IP address: {pod_ip}")

        # Check for broadcast address conflict (IPv4 only)
        if isinstance(network, ipaddress.IPv4Network):
            broadcast = network.broadcast_address
            if start_ip <= broadcast <= end_ip:
                conflicts.append(f"Broadcast address {broadcast} is within DHCP range")
                is_valid = False

        # Check for network address conflict
        network_addr = network.network_address
        if start_ip <= network_addr <= end_ip:
            conflicts.append(f"Network address {network_addr} is within DHCP range")
            is_valid = False

    except ValueError as e:
        conflicts.append(f"Invalid subnet or IP address: {e}")
        is_valid = False

    return (is_valid, conflicts, warnings)


def calculate_default_range(
    subnet: str, gateway: Optional[str] = None, pod_ip: Optional[str] = None
) -> Tuple[str, str]:
    """
    Calculate default .50-.250 range excluding conflicts.
    Excludes gateway, pod IP, broadcast, and network addresses.

    Args:
        subnet: Subnet in CIDR notation
        gateway: Optional gateway IP to exclude
        pod_ip: Optional pod IP to exclude

    Returns:
        Tuple of (range_start, range_end)
    """
    try:
        network = ipaddress.ip_network(subnet, strict=False)

        # Get network and broadcast addresses
        network_addr = network.network_address
        broadcast_addr = (
            network.broadcast_address if isinstance(network, ipaddress.IPv4Network) else None
        )

        # Calculate default range (.50 to .250 for IPv4, similar for IPv6)
        if isinstance(network, ipaddress.IPv4Network):
            # For IPv4, use .50 to .250
            start_octet = 50
            end_octet = 250

            # Get first three octets from network
            network_parts = str(network_addr).split(".")
            range_start = f"{network_parts[0]}.{network_parts[1]}.{network_parts[2]}.{start_octet}"
            range_end = f"{network_parts[0]}.{network_parts[1]}.{network_parts[2]}.{end_octet}"

            # Adjust if conflicts exist
            start_ip = ipaddress.IPv4Address(range_start)
            end_ip = ipaddress.IPv4Address(range_end)

            # Exclude gateway if in range
            if gateway:
                try:
                    gateway_ip = ipaddress.IPv4Address(gateway)
                    if start_ip <= gateway_ip <= end_ip:
                        # Adjust range to exclude gateway
                        if gateway_ip == start_ip:
                            start_ip = ipaddress.IPv4Address(int(gateway_ip) + 1)
                        elif gateway_ip == end_ip:
                            end_ip = ipaddress.IPv4Address(int(gateway_ip) - 1)
                except ValueError:
                    pass

            # Exclude pod IP if in range
            if pod_ip:
                try:
                    pod_ip_addr = ipaddress.IPv4Address(pod_ip)
                    if start_ip <= pod_ip_addr <= end_ip:
                        # Adjust range to exclude pod IP
                        if pod_ip_addr == start_ip:
                            start_ip = ipaddress.IPv4Address(int(pod_ip_addr) + 1)
                        elif pod_ip_addr == end_ip:
                            end_ip = ipaddress.IPv4Address(int(pod_ip_addr) - 1)
                except ValueError:
                    pass

            # Ensure we don't include network or broadcast
            if start_ip <= network_addr:
                start_ip = ipaddress.IPv4Address(int(network_addr) + 1)
            if broadcast_addr and end_ip >= broadcast_addr:
                end_ip = ipaddress.IPv4Address(int(broadcast_addr) - 1)

            return (str(start_ip), str(end_ip))

        else:
            # For IPv6, use similar logic but with /64 subnet
            # Use last 16 bits for range (::50 to ::ff00)
            start_ip = ipaddress.IPv6Address(int(network.network_address) + 50)
            end_ip = ipaddress.IPv6Address(int(network.network_address) + 0xFF00)

            # Exclude gateway if in range
            if gateway:
                try:
                    gateway_ip = ipaddress.IPv6Address(gateway)
                    if start_ip <= gateway_ip <= end_ip:
                        if gateway_ip == start_ip:
                            start_ip = ipaddress.IPv6Address(int(gateway_ip) + 1)
                        elif gateway_ip == end_ip:
                            end_ip = ipaddress.IPv6Address(int(gateway_ip) - 1)
                except ValueError:
                    pass

            # Exclude pod IP if in range
            if pod_ip:
                try:
                    pod_ip_addr = ipaddress.IPv6Address(pod_ip)
                    if start_ip <= pod_ip_addr <= end_ip:
                        if pod_ip_addr == start_ip:
                            start_ip = ipaddress.IPv6Address(int(pod_ip_addr) + 1)
                        elif pod_ip_addr == end_ip:
                            end_ip = ipaddress.IPv6Address(int(pod_ip_addr) - 1)
                except ValueError:
                    pass

            return (str(start_ip), str(end_ip))

    except (ValueError, AttributeError) as e:
        logger.error(f"Failed to calculate default range for subnet {subnet}: {e}")
        return ("", "")


def check_dhcp_port_conflicts() -> Dict[str, bool]:
    """
    Check if ports 67/68 (IPv4) or 547/548 (IPv6) are already in use.
    Excludes our own DHCP container from conflict detection.

    Returns:
        Dict with 'ipv4_conflict' and 'ipv6_conflict' boolean keys
    """
    result = {"ipv4_conflict": False, "ipv6_conflict": False}

    # First, check if our own DHCP container is running
    # If it is, ports being in use by it is expected and not a conflict
    our_dhcp_running = False
    try:
        from dhcp_deploy import check_dhcp_container_status

        dhcp_status = check_dhcp_container_status()
        our_dhcp_running = dhcp_status.get("container_running", False) or dhcp_status.get(
            "service_active", False
        )
        if our_dhcp_running:
            logger.debug("Our DHCP container is running - port usage by it is expected")
    except Exception as e:
        logger.debug(f"Could not check our DHCP container status: {e}")

    # Check IPv4 ports (67, 68)
    for port in [67, 68]:
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                sock.bind(("0.0.0.0", port))
                sock.close()
                # Port is available - no conflict
            except OSError:
                # Port is in use - only report conflict if it's NOT our own container
                if not our_dhcp_running:
                    result["ipv4_conflict"] = True
                    logger.warning(f"Port {port} (IPv4) is already in use by another service")
                else:
                    logger.debug(f"Port {port} (IPv4) is in use by our DHCP container (expected)")
                break
        except Exception as e:
            logger.warning(f"Failed to check IPv4 port {port}: {e}")

    # Check IPv6 ports (547, 548)
    for port in [547, 548]:
        try:
            sock = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                sock.bind(("::", port))
                sock.close()
                # Port is available - no conflict
            except OSError:
                # Port is in use - only report conflict if it's NOT our own container
                if not our_dhcp_running:
                    result["ipv6_conflict"] = True
                    logger.warning(f"Port {port} (IPv6) is already in use by another service")
                else:
                    logger.debug(f"Port {port} (IPv6) is in use by our DHCP container (expected)")
                break
        except Exception as e:
            logger.warning(f"Failed to check IPv6 port {port}: {e}")

    return result


def detect_host_interfaces(subnet: Optional[str] = None) -> List[str]:
    """
    Detect available network interfaces on host (for host networking mode).

    Args:
        subnet: Optional subnet to filter interfaces by

    Returns:
        List of interface names
    """
    interfaces = []

    try:
        # Find ip command (try common locations)
        ip_cmd = None
        for ip_path in ["/usr/sbin/ip", "/sbin/ip", "ip"]:
            try:
                test_result = subprocess.run(
                    [ip_path, "--version"],
                    capture_output=True,
                    timeout=1,
                )
                if test_result.returncode == 0:
                    ip_cmd = ip_path
                    break
            except (FileNotFoundError, subprocess.TimeoutExpired):
                continue

        if not ip_cmd:
            logger.warning("ip command not found, cannot detect host interfaces")
            return interfaces

        # Use 'ip link show' to get interfaces
        result = subprocess.run(
            [ip_cmd, "link", "show"],
            capture_output=True,
            text=True,
            timeout=2,
        )
        if result.returncode == 0:
            # Parse output: "2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> ..."
            for line in result.stdout.split("\n"):
                match = re.match(r"^\d+:\s+(\S+):", line)
                if match:
                    iface = match.group(1)
                    # Skip loopback and virtual interfaces
                    if (
                        iface != "lo"
                        and not iface.startswith("veth")
                        and not iface.startswith("docker")
                    ):
                        interfaces.append(iface)

        # If subnet provided, filter interfaces that have addresses in that subnet
        if subnet and interfaces:
            try:
                network = ipaddress.ip_network(subnet, strict=False)
                filtered_interfaces = []
                for iface in interfaces:
                    # Get IP addresses for this interface
                    addr_result = subprocess.run(
                        [ip_cmd, "addr", "show", iface],
                        capture_output=True,
                        text=True,
                        timeout=1,
                    )
                    if addr_result.returncode == 0:
                        # Check if any address is in the subnet
                        for line in addr_result.stdout.split("\n"):
                            match = re.search(r"inet\s+(\S+)", line)
                            if match:
                                addr_str = match.group(1).split("/")[0]
                                try:
                                    addr = ipaddress.ip_address(addr_str)
                                    if addr in network:
                                        filtered_interfaces.append(iface)
                                        break
                                except ValueError:
                                    continue
                if filtered_interfaces:
                    return filtered_interfaces
            except ValueError:
                pass

    except (subprocess.TimeoutExpired, FileNotFoundError, subprocess.SubprocessError) as e:
        logger.warning(f"Failed to detect host interfaces: {e}")

    return interfaces


def detect_networking_mode(config_yaml: Dict) -> str:
    """
    Detect if host networking or macvlan mode from config.

    Args:
        config_yaml: Parsed YAML config dict

    Returns:
        "host" or "macvlan"
    """
    host_network = config_yaml.get("container", {}).get("host_network", False)
    return "host" if host_network else "macvlan"


def get_interfaces_for_kea(networking_mode: str, subnet: Optional[str] = None) -> List[str]:
    """
    Get list of interfaces Kea should bind to based on networking mode.

    Args:
        networking_mode: "host" or "macvlan"
        subnet: Optional subnet to filter interfaces by

    Returns:
        List of interface names
    """
    if networking_mode == "host":
        # When using host networking, try to detect macvlan interface
        # for DHCP isolation while keeping web UI accessible
        macvlan_interface = detect_macvlan_interface(subnet)
        if macvlan_interface:
            # Bind to macvlan interface for DHCP isolation
            return [macvlan_interface]
        # Fallback to detecting all host interfaces
        return detect_host_interfaces(subnet)
    else:
        # For macvlan, Kea will bind to the pod's network interface
        # Return empty list to let Kea use default (all interfaces)
        return []


def detect_macvlan_interface(subnet: Optional[str] = None) -> Optional[str]:
    """
    Detect macvlan interface for DHCP isolation when using host networking.

    Args:
        subnet: Optional subnet to match against

    Returns:
        Interface name if found, None otherwise
    """
    try:
        # Find ip command
        ip_cmd = None
        for ip_path in ["/usr/sbin/ip", "/sbin/ip", "ip"]:
            try:
                test_result = subprocess.run(
                    [ip_path, "--version"],
                    capture_output=True,
                    timeout=1,
                )
                if test_result.returncode == 0:
                    ip_cmd = ip_path
                    break
            except (FileNotFoundError, subprocess.TimeoutExpired):
                continue

        if not ip_cmd:
            return None

        # Check if ztpbootstrap-net exists and get its subnet
        try:
            result = subprocess.run(
                ["podman", "network", "inspect", "ztpbootstrap-net"],
                capture_output=True,
                text=True,
                timeout=2,
            )
            if result.returncode == 0:
                network_info = json.loads(result.stdout)
                if network_info:
                    # Extract subnet from network config
                    network_config = network_info[0].get("subnets", [])
                    if network_config:
                        network_subnet = network_config[0].get("subnet", "")
                        if network_subnet:
                            # Find interface with IP in this subnet
                            addr_result = subprocess.run(
                                [ip_cmd, "addr", "show"],
                                capture_output=True,
                                text=True,
                                timeout=2,
                            )
                            if addr_result.returncode == 0:
                                current_interface = None
                                for line in addr_result.stdout.split("\n"):
                                    # Interface line: "2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP>"
                                    if_match = re.match(r"^\d+:\s+(\S+):", line)
                                    if if_match:
                                        current_interface = if_match.group(1)
                                    # IP line: "    inet 172.16.0.10/24 ..."
                                    elif current_interface and "inet" in line:
                                        ip_match = re.search(r"inet\s+(\S+)", line)
                                        if ip_match:
                                            ip_str = ip_match.group(1).split("/")[0]
                                            try:
                                                import ipaddress

                                                ip = ipaddress.ip_address(ip_str)
                                                network = ipaddress.ip_network(
                                                    network_subnet, strict=False
                                                )
                                                if ip in network:
                                                    # Found interface with IP in macvlan subnet
                                                    return current_interface
                                            except (ValueError, AttributeError):
                                                continue
        except (subprocess.TimeoutExpired, FileNotFoundError, json.JSONDecodeError):
            pass

        # Fallback: look for interfaces with "macvlan" in name or type
        link_result = subprocess.run(
            [ip_cmd, "link", "show"],
            capture_output=True,
            text=True,
            timeout=2,
        )
        if link_result.returncode == 0:
            for line in link_result.stdout.split("\n"):
                # Look for macvlan interfaces
                if "macvlan" in line.lower() or "@" in line:
                    match = re.match(r"^\d+:\s+(\S+):", line)
                    if match:
                        iface = match.group(1)
                        # Skip veth pairs (they're container interfaces)
                        if not iface.startswith("veth") and iface != "lo":
                            return iface

    except Exception as e:
        logger.debug(f"Failed to detect macvlan interface: {e}")

    return None
