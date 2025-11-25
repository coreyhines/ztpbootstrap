#!/usr/bin/env python3
"""
Complete DHCP Handshake Simulator
Sends DISCOVER, receives OFFER, sends REQUEST, receives ACK
"""

import argparse
import random
import socket
import struct
import sys
import time


def create_dhcp_packet(message_type, mac_address, xid, requested_ip=None, server_ip=None):
    """
    Create a DHCP packet

    Args:
        message_type: DHCP message type (1=DISCOVER, 3=REQUEST)
        mac_address: MAC address in format "aa:bb:cc:dd:ee:ff"
        xid: Transaction ID
        requested_ip: IP address to request (for REQUEST)
        server_ip: Server IP address (for REQUEST)

    Returns:
        Raw packet bytes
    """
    mac_bytes = bytes.fromhex(mac_address.replace(":", ""))

    # BOOTP header
    bootp = struct.pack("!BBBB", 1, 1, 6, 0)  # op, htype, hlen, hops
    bootp += struct.pack("!I", xid)  # xid
    bootp += struct.pack("!HH", 0, 0)  # secs, flags
    bootp += struct.pack("!I", requested_ip or 0)  # ciaddr (for REQUEST)
    bootp += struct.pack("!I", 0)  # yiaddr
    bootp += struct.pack("!I", server_ip or 0)  # siaddr
    bootp += struct.pack("!I", 0)  # giaddr
    bootp += mac_bytes + b"\x00" * (16 - len(mac_bytes))  # chaddr
    bootp += b"\x00" * 64  # sname
    bootp += b"\x00" * 128  # file

    # DHCP options
    options = struct.pack("!I", 0x63825363)  # Magic cookie

    # Option 53: DHCP Message Type
    options += struct.pack("!BB", 53, 1) + struct.pack("!B", message_type)

    # Option 55: Parameter Request List
    options += struct.pack("!BB", 55, 4) + struct.pack("!BBBB", 1, 3, 6, 15)

    # Option 61: Client Identifier
    options += struct.pack("!BB", 61, 7) + struct.pack("!B", 1) + mac_bytes

    # For REQUEST, add requested IP and server identifier
    if message_type == 3:  # REQUEST
        if requested_ip:
            options += struct.pack("!BB", 50, 4) + struct.pack("!I", requested_ip)
        if server_ip:
            options += struct.pack("!BB", 54, 4) + struct.pack("!I", server_ip)

    # Option 255: End
    options += struct.pack("!B", 255)

    return bootp + options


def parse_dhcp_response(data):
    """Parse DHCP response packet"""
    if len(data) < 240:
        return None

    # Parse BOOTP header
    yiaddr = struct.unpack("!I", data[16:20])[0]
    siaddr = struct.unpack("!I", data[20:24])[0]
    xid = struct.unpack("!I", data[4:8])[0]

    # Find options (start at offset 240)
    options_start = 240
    if len(data) <= options_start:
        return None

    # Find magic cookie
    if data[options_start : options_start + 4] != struct.pack("!I", 0x63825363):
        return None

    # Parse options
    offset = options_start + 4
    message_type = None
    server_id = None
    lease_time = None
    router = None
    dns_servers = []
    domain = None

    while offset < len(data) - 1:
        option_code = data[offset]
        if option_code == 255:  # End
            break
        if option_code == 0:  # Pad
            offset += 1
            continue

        if offset + 1 >= len(data):
            break

        option_len = data[offset + 1]
        if offset + 2 + option_len > len(data):
            break

        option_data = data[offset + 2 : offset + 2 + option_len]

        if option_code == 53:  # Message Type
            if len(option_data) >= 1:
                message_type = option_data[0]
        elif option_code == 54:  # Server Identifier
            if len(option_data) >= 4:
                server_id = struct.unpack("!I", option_data[:4])[0]
        elif option_code == 51:  # Lease Time
            if len(option_data) >= 4:
                lease_time = struct.unpack("!I", option_data[:4])[0]
        elif option_code == 3:  # Router
            if len(option_data) >= 4:
                router = struct.unpack("!I", option_data[:4])[0]
        elif option_code == 6:  # DNS Servers
            for i in range(0, len(option_data), 4):
                if i + 4 <= len(option_data):
                    dns_servers.append(struct.unpack("!I", option_data[i : i + 4])[0])
        elif option_code == 15:  # Domain Name
            try:
                domain = option_data.decode("utf-8", errors="ignore").rstrip("\x00")
            except:
                pass

        offset += 2 + option_len

    return {
        "yiaddr": yiaddr,
        "siaddr": siaddr,
        "xid": xid,
        "message_type": message_type,
        "server_id": server_id,
        "lease_time": lease_time,
        "router": router,
        "dns_servers": dns_servers,
        "domain": domain,
    }


def ip_to_string(ip_int):
    """Convert IP integer to string"""
    return socket.inet_ntoa(struct.pack("!I", ip_int))


def string_to_ip(ip_str):
    """Convert IP string to integer"""
    return struct.unpack("!I", socket.inet_aton(ip_str))[0]


def complete_dhcp_handshake(interface="eth0", mac_address=None, timeout=10):
    """
    Complete full DHCP handshake: DISCOVER -> OFFER -> REQUEST -> ACK

    Returns:
        Dict with lease information or None
    """
    if mac_address is None:
        # Generate random MAC
        mac_address = ":".join([f"{random.randint(0, 255):02x}" for _ in range(6)])

    xid = random.randint(1, 0xFFFFFFFF)

    print(f"Starting DHCP handshake with MAC: {mac_address}, XID: 0x{xid:08x}")

    try:
        # Create raw socket (requires root)
        sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x0800))
        sock.bind((interface, 0))
        sock.settimeout(timeout)
    except PermissionError:
        print("Error: Raw socket requires root privileges")
        return None
    except Exception as e:
        print(f"Error creating socket: {e}")
        return None

    try:
        # Step 1: Send DISCOVER
        print("  [1/4] Sending DHCPDISCOVER...")
        discover = create_dhcp_packet(1, mac_address, xid)
        sock.send(discover)

        # Step 2: Receive OFFER
        print("  [2/4] Waiting for DHCPOFFER...")
        offer_data = None
        start_time = time.time()
        while time.time() - start_time < timeout:
            try:
                data, addr = sock.recvfrom(2048)
                # Check if it's a DHCP response (UDP port 67)
                # Skip Ethernet and IP headers (14 + 20 = 34 bytes)
                # Then check UDP header (sport should be 67)
                if len(data) >= 42:
                    udp_sport = struct.unpack("!H", data[34:36])[0]
                    if udp_sport == 67:
                        # Parse DHCP response
                        dhcp_data = data[42:]  # Skip Ethernet + IP + UDP headers
                        response = parse_dhcp_response(dhcp_data)
                        if (
                            response and response["xid"] == xid and response["message_type"] == 2
                        ):  # OFFER
                            offer_data = response
                            break
            except socket.timeout:
                continue
            except Exception as e:
                print(f"    Error receiving: {e}")
                continue

        if not offer_data:
            print("  [ERROR] No DHCPOFFER received")
            return None

        offered_ip = offer_data["yiaddr"]
        server_ip = offer_data["siaddr"] or offer_data["server_id"]
        print(
            f"  [SUCCESS] Received DHCPOFFER: IP={ip_to_string(offered_ip)}, Server={ip_to_string(server_ip) if server_ip else 'unknown'}"
        )

        # Step 3: Send REQUEST
        print("  [3/4] Sending DHCPREQUEST...")
        request = create_dhcp_packet(
            3, mac_address, xid, requested_ip=offered_ip, server_ip=server_ip
        )
        sock.send(request)

        # Step 4: Receive ACK
        print("  [4/4] Waiting for DHCPACK...")
        ack_data = None
        start_time = time.time()
        while time.time() - start_time < timeout:
            try:
                data, addr = sock.recvfrom(2048)
                if len(data) >= 42:
                    udp_sport = struct.unpack("!H", data[34:36])[0]
                    if udp_sport == 67:
                        dhcp_data = data[42:]
                        response = parse_dhcp_response(dhcp_data)
                        if (
                            response and response["xid"] == xid and response["message_type"] == 5
                        ):  # ACK
                            ack_data = response
                            break
            except socket.timeout:
                continue
            except Exception as e:
                print(f"    Error receiving: {e}")
                continue

        if not ack_data:
            print("  [ERROR] No DHCPACK received")
            return None

        print(f"  [SUCCESS] Received DHCPACK: IP={ip_to_string(ack_data['yiaddr'])}")

        # Return lease information
        return {
            "mac": mac_address,
            "ip": ip_to_string(ack_data["yiaddr"]),
            "server_ip": ip_to_string(server_ip) if server_ip else None,
            "lease_time": ack_data.get("lease_time"),
            "router": ip_to_string(ack_data["router"]) if ack_data.get("router") else None,
            "dns_servers": [ip_to_string(dns) for dns in ack_data.get("dns_servers", [])],
            "domain": ack_data.get("domain"),
            "xid": xid,
        }

    except Exception as e:
        print(f"Error during handshake: {e}")
        return None
    finally:
        sock.close()


def main():
    parser = argparse.ArgumentParser(description="Complete DHCP Handshake Simulator")
    parser.add_argument("-i", "--interface", default="eth0", help="Network interface")
    parser.add_argument("-m", "--mac", help="MAC address (random if not provided)")
    parser.add_argument(
        "-n", "--num-clients", type=int, default=3, help="Number of clients to simulate"
    )
    parser.add_argument("-t", "--timeout", type=int, default=10, help="Timeout per step (seconds)")

    args = parser.parse_args()

    print("=" * 50)
    print("DHCP Complete Handshake Simulator")
    print("=" * 50)
    print(f"Interface: {args.interface}")
    print(f"Number of clients: {args.num_clients}")
    print("=" * 50)
    print()

    successful_leases = []

    for i in range(1, args.num_clients + 1):
        print(f"\n[Client {i}/{args.num_clients}]")
        print("-" * 50)

        mac = args.mac
        if not mac:
            # Generate unique MAC for each client
            mac = f"02:00:00:00:00:{i:02x}"

        result = complete_dhcp_handshake(args.interface, mac, args.timeout)

        if result:
            successful_leases.append(result)
            print(f"\n✓ Client {i} successfully obtained lease:")
            print(f"  MAC: {result['mac']}")
            print(f"  IP: {result['ip']}")
            if result.get("lease_time"):
                print(f"  Lease Time: {result['lease_time']} seconds")
            if result.get("router"):
                print(f"  Router: {result['router']}")
            if result.get("dns_servers"):
                print(f"  DNS: {', '.join(result['dns_servers'])}")
            if result.get("domain"):
                print(f"  Domain: {result['domain']}")
        else:
            print(f"\n✗ Client {i} failed to obtain lease")

        # Small delay between clients
        if i < args.num_clients:
            time.sleep(1)

    print("\n" + "=" * 50)
    print(f"Summary: {len(successful_leases)}/{args.num_clients} clients obtained leases")
    print("=" * 50)

    return 0 if len(successful_leases) == args.num_clients else 1


if __name__ == "__main__":
    sys.exit(main())
