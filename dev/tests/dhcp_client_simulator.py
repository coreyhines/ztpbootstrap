#!/usr/bin/env python3
"""
DHCP Client Simulator for Testing
Simulates a DHCP client to test DHCP server functionality
"""

import argparse
import json
import random
import socket
import struct
import time
from typing import Dict, Optional, Tuple

try:
    from scapy.all import BOOTP, DHCP, IP, UDP, Ether, get_if_raw_hwaddr, sendp, sniff, srp1

    SCAPY_AVAILABLE = True
except ImportError:
    SCAPY_AVAILABLE = False
    print("Warning: scapy not available, using alternative method")


def generate_mac() -> str:
    """Generate a random MAC address for testing"""
    return ":".join([f"{random.randint(0, 255):02x}" for _ in range(6)])


def create_dhcp_discover(mac_address: str, xid: Optional[int] = None) -> bytes:
    """
    Create a DHCP DISCOVER packet (without scapy)

    Args:
        mac_address: MAC address in format "aa:bb:cc:dd:ee:ff"
        xid: Transaction ID (random if not provided)

    Returns:
        Raw packet bytes
    """
    if xid is None:
        xid = random.randint(1, 0xFFFFFFFF)

    # Convert MAC to bytes
    mac_bytes = bytes.fromhex(mac_address.replace(":", ""))

    # BOOTP header
    # op (1) = BOOTREQUEST (1)
    # htype (1) = Ethernet (1)
    # hlen (1) = 6
    # hops (1) = 0
    # xid (4) = transaction ID
    # secs (2) = 0
    # flags (2) = 0
    # ciaddr (4) = 0
    # yiaddr (4) = 0
    # siaddr (4) = 0
    # giaddr (4) = 0
    # chaddr (16) = MAC + padding
    # sname (64) = 0
    # file (128) = 0
    # options (variable)

    bootp = struct.pack("!BBBB", 1, 1, 6, 0)  # op, htype, hlen, hops
    bootp += struct.pack("!I", xid)  # xid
    bootp += struct.pack("!HH", 0, 0)  # secs, flags
    bootp += struct.pack("!IIII", 0, 0, 0, 0)  # ciaddr, yiaddr, siaddr, giaddr
    bootp += mac_bytes + b"\x00" * (16 - len(mac_bytes))  # chaddr
    bootp += b"\x00" * 64  # sname
    bootp += b"\x00" * 128  # file

    # DHCP options
    # Magic cookie: 99.130.83.99
    options = struct.pack("!I", 0x63825363)
    # Option 53: DHCP Message Type = DISCOVER (1)
    options += struct.pack("!BB", 53, 1) + struct.pack("!B", 1)
    # Option 55: Parameter Request List
    options += struct.pack("!BB", 55, 4) + struct.pack("!BBBB", 1, 3, 6, 15)
    # Option 61: Client Identifier
    options += struct.pack("!BB", 61, 7) + struct.pack("!B", 1) + mac_bytes
    # Option 255: End
    options += struct.pack("!B", 255)

    return bootp + options


def send_dhcp_discover_scapy(
    interface: str, mac_address: str, xid: Optional[int] = None
) -> Optional[Dict]:
    """
    Send DHCP DISCOVER using scapy and wait for OFFER

    Args:
        interface: Network interface name
        mac_address: MAC address
        xid: Transaction ID

    Returns:
        Dict with lease information or None
    """
    if not SCAPY_AVAILABLE:
        return None

    if xid is None:
        xid = random.randint(1, 0xFFFFFFFF)

    mac_bytes = bytes.fromhex(mac_address.replace(":", ""))

    # Create DHCP DISCOVER
    discover = (
        Ether(src=mac_address, dst="ff:ff:ff:ff:ff:ff")
        / IP(src="0.0.0.0", dst="255.255.255.255")
        / UDP(sport=68, dport=67)
        / BOOTP(
            op=1,  # BOOTREQUEST
            chaddr=mac_bytes,
            xid=xid,
        )
        / DHCP(
            options=[
                ("message-type", "discover"),
                ("param_req_list", [1, 3, 6, 15]),  # subnet, router, dns, domain
                ("client_id", b"\x01" + mac_bytes),
                ("end"),
            ]
        )
    )

    # Send and receive
    try:
        response = srp1(
            discover,
            iface=interface,
            timeout=5,
            verbose=0,
        )

        if response and response.haslayer(DHCP):
            dhcp_layer = response[DHCP]
            bootp_layer = response[BOOTP]

            # Extract lease information
            lease_info = {
                "mac": mac_address,
                "ip": bootp_layer.yiaddr,
                "server_ip": bootp_layer.siaddr,
                "xid": xid,
            }

            # Extract options
            for option in dhcp_layer.options:
                if isinstance(option, tuple):
                    if option[0] == "message-type":
                        lease_info["message_type"] = option[1]
                    elif option[0] == "server_id":
                        lease_info["server_id"] = option[1]
                    elif option[0] == "lease_time":
                        lease_info["lease_time"] = option[1]
                    elif option[0] == "router":
                        lease_info["router"] = option[1]
                    elif option[0] == "name_server":
                        lease_info["dns_servers"] = option[1]
                    elif option[0] == "domain":
                        lease_info["domain"] = option[1]

            return lease_info

    except Exception as e:
        print(f"Error sending DHCP DISCOVER with scapy: {e}")
        return None

    return None


def send_dhcp_discover_socket(
    interface: str, mac_address: str, xid: Optional[int] = None
) -> Optional[Dict]:
    """
    Send DHCP DISCOVER using raw sockets (requires root)

    Args:
        interface: Network interface name
        mac_address: MAC address
        xid: Transaction ID

    Returns:
        Dict with lease information or None
    """
    if xid is None:
        xid = random.randint(1, 0xFFFFFFFF)

    # Create raw socket (requires root)
    try:
        sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW)
        sock.bind((interface, 0))
    except PermissionError:
        print("Error: Raw socket requires root privileges")
        return None
    except Exception as e:
        print(f"Error creating socket: {e}")
        return None

    # Create packet
    packet = create_dhcp_discover(mac_address, xid)

    # Send packet
    try:
        sock.send(packet)
        sock.settimeout(5.0)

        # Receive response
        response = sock.recv(2048)
        if response:
            # Parse response (simplified)
            # In a real implementation, you'd parse the BOOTP/DHCP response
            return {
                "mac": mac_address,
                "ip": "parsed_from_response",
                "xid": xid,
            }
    except socket.timeout:
        print("Timeout waiting for DHCP OFFER")
        return None
    except Exception as e:
        print(f"Error sending/receiving: {e}")
        return None
    finally:
        sock.close()

    return None


def simulate_dhcp_client(
    interface: str = "eth0",
    mac_address: Optional[str] = None,
    use_scapy: bool = True,
) -> Optional[Dict]:
    """
    Simulate a DHCP client and get a lease

    Args:
        interface: Network interface to use
        mac_address: MAC address (random if not provided)
        use_scapy: Use scapy if available

    Returns:
        Dict with lease information or None
    """
    if mac_address is None:
        mac_address = generate_mac()

    print(f"Simulating DHCP client with MAC: {mac_address}")
    print(f"Interface: {interface}")

    if use_scapy and SCAPY_AVAILABLE:
        print("Using scapy for DHCP simulation")
        return send_dhcp_discover_scapy(interface, mac_address)
    else:
        print("Using raw sockets for DHCP simulation (requires root)")
        return send_dhcp_discover_socket(interface, mac_address)


def main():
    """Main function for CLI usage"""
    parser = argparse.ArgumentParser(description="DHCP Client Simulator")
    parser.add_argument(
        "--interface",
        "-i",
        default="eth0",
        help="Network interface to use",
    )
    parser.add_argument(
        "--mac",
        "-m",
        help="MAC address (random if not provided)",
    )
    parser.add_argument(
        "--no-scapy",
        action="store_true",
        help="Don't use scapy (use raw sockets)",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Output result as JSON",
    )

    args = parser.parse_args()

    result = simulate_dhcp_client(
        interface=args.interface,
        mac_address=args.mac,
        use_scapy=not args.no_scapy,
    )

    if result:
        if args.json:
            print(json.dumps(result, indent=2))
        else:
            print(f"DHCP lease obtained:")
            print(f"  MAC: {result.get('mac')}")
            print(f"  IP: {result.get('ip')}")
            if "lease_time" in result:
                print(f"  Lease Time: {result['lease_time']} seconds")
        return 0
    else:
        print("Failed to obtain DHCP lease")
        return 1


if __name__ == "__main__":
    exit(main())
