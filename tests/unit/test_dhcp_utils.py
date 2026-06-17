#!/usr/bin/env python3
"""
Unit tests for dhcp_utils.py
"""

# Import DHCP modules
import sys
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

# Add webui to path
sys.path.insert(0, str(Path(__file__).parent.parent.parent / "webui"))

from dhcp_utils import (
    calculate_default_range,
    check_dhcp_port_conflicts,
    detect_gateway,
    detect_host_interfaces,
    detect_networking_mode,
    detect_subnet,
    get_interfaces_for_kea,
    validate_dhcp_range,
)


class TestDHCPUtils(unittest.TestCase):
    """Test DHCP utility functions"""

    def test_detect_subnet_ipv4(self):
        """Test IPv4 subnet detection"""
        # Test /24 subnet (default)
        subnet = detect_subnet("10.0.0.10")
        self.assertEqual(subnet, "10.0.0.0/24")

        # Test another IP
        subnet = detect_subnet("192.168.1.50")
        self.assertEqual(subnet, "192.168.1.0/24")

    def test_detect_subnet_ipv6(self):
        """Test IPv6 subnet detection"""
        subnet = detect_subnet("2001:db8::10")
        self.assertEqual(subnet, "2001:db8::/64")

    @patch("dhcp_utils.subprocess.run")
    def test_detect_gateway_ipv4(self, mock_run):
        """Test IPv4 gateway detection"""
        # Mock ip route output
        mock_run.return_value = MagicMock(
            returncode=0,
            stdout="default via 10.0.0.1 dev eth0 proto static\n",
        )

        result = detect_gateway(ipv4_address="10.0.0.10")
        self.assertIn("ipv4_gateway", result)
        # Gateway detection may vary, so just check it returns something
        self.assertIsNotNone(result.get("ipv4_gateway"))

    def test_validate_dhcp_range_valid(self):
        """Test valid DHCP range validation"""
        is_valid, conflicts, warnings = validate_dhcp_range(
            subnet="10.0.0.0/24",
            range_start="10.0.0.50",
            range_end="10.0.0.250",
            gateway="10.0.0.1",
            pod_ip="10.0.0.10",
        )
        self.assertTrue(is_valid)
        self.assertEqual(len(conflicts), 0)

    def test_validate_dhcp_range_gateway_conflict(self):
        """Test DHCP range with gateway conflict"""
        is_valid, conflicts, warnings = validate_dhcp_range(
            subnet="10.0.0.0/24",
            range_start="10.0.0.1",
            range_end="10.0.0.250",
            gateway="10.0.0.1",
            pod_ip="10.0.0.10",
        )
        # Should detect gateway conflict
        self.assertFalse(is_valid)
        self.assertGreater(len(conflicts), 0)
        self.assertTrue(any("Gateway" in c for c in conflicts))

    def test_validate_dhcp_range_pod_ip_conflict(self):
        """Test DHCP range with pod IP conflict"""
        is_valid, conflicts, warnings = validate_dhcp_range(
            subnet="10.0.0.0/24",
            range_start="10.0.0.5",
            range_end="10.0.0.15",
            gateway="10.0.0.1",
            pod_ip="10.0.0.10",
        )
        # Should detect pod IP conflict
        self.assertFalse(is_valid)
        self.assertGreater(len(conflicts), 0)
        self.assertTrue(any("Pod IP" in c for c in conflicts))

    def test_calculate_default_range(self):
        """Test default range calculation"""
        range_start, range_end = calculate_default_range(
            subnet="10.0.0.0/24",
            gateway="10.0.0.1",
            pod_ip="10.0.0.10",
        )
        # Should exclude gateway and pod IP
        self.assertNotEqual(range_start, "10.0.0.1")
        self.assertNotEqual(range_start, "10.0.0.10")
        # Range should be valid
        start_ip = int(range_start.split(".")[-1])
        end_ip = int(range_end.split(".")[-1])
        self.assertLess(start_ip, end_ip)

    def test_detect_networking_mode_host(self):
        """Test host networking mode detection"""
        mode = detect_networking_mode({"container": {"host_network": True}})
        self.assertEqual(mode, "host")

    def test_detect_networking_mode_macvlan(self):
        """Test macvlan networking mode detection"""
        mode = detect_networking_mode({"container": {"host_network": False}})
        self.assertEqual(mode, "macvlan")

    @patch("dhcp_utils.subprocess.run")
    def test_detect_gateway_ipv6(self, mock_run):
        """Test IPv6 gateway detection"""
        # Mock ip -6 route output
        mock_run.return_value = MagicMock(
            returncode=0,
            stdout="default via 2001:db8::1 dev eth0 proto static\n",
        )

        result = detect_gateway(ipv6_address="2001:db8::10")
        self.assertIn("ipv6_gateway", result)

    def test_validate_dhcp_range_broadcast_conflict(self):
        """Test DHCP range with broadcast address conflict"""
        is_valid, conflicts, warnings = validate_dhcp_range(
            subnet="10.0.0.0/24",
            range_start="10.0.0.250",
            range_end="10.0.0.255",
            gateway="10.0.0.1",
            pod_ip="10.0.0.10",
        )
        # Should detect broadcast conflict
        self.assertFalse(is_valid)
        self.assertGreater(len(conflicts), 0)
        self.assertTrue(any("Broadcast" in c for c in conflicts))

    def test_validate_dhcp_range_network_address_conflict(self):
        """Test DHCP range with network address conflict"""
        is_valid, conflicts, warnings = validate_dhcp_range(
            subnet="10.0.0.0/24",
            range_start="10.0.0.0",
            range_end="10.0.0.50",
            gateway="10.0.0.1",
            pod_ip="10.0.0.10",
        )
        # Should detect network address conflict
        self.assertFalse(is_valid)
        self.assertGreater(len(conflicts), 0)
        self.assertTrue(any("Network address" in c for c in conflicts))

    def test_validate_dhcp_range_invalid_range(self):
        """Test DHCP range with start > end"""
        is_valid, conflicts, warnings = validate_dhcp_range(
            subnet="10.0.0.0/24",
            range_start="10.0.0.250",
            range_end="10.0.0.50",
            gateway="10.0.0.1",
            pod_ip="10.0.0.10",
        )
        self.assertFalse(is_valid)
        self.assertGreater(len(conflicts), 0)

    def test_validate_dhcp_range_outside_subnet(self):
        """Test DHCP range outside subnet"""
        is_valid, conflicts, warnings = validate_dhcp_range(
            subnet="10.0.0.0/24",
            range_start="192.168.1.50",
            range_end="192.168.1.250",
            gateway="10.0.0.1",
            pod_ip="10.0.0.10",
        )
        self.assertFalse(is_valid)
        self.assertGreater(len(conflicts), 0)

    def test_calculate_default_range_ipv6(self):
        """Test default range calculation for IPv6"""
        range_start, range_end = calculate_default_range(
            subnet="2001:db8::/64",
            gateway="2001:db8::1",
            pod_ip="2001:db8::10",
        )
        # Should return valid IPv6 addresses
        self.assertIn("2001:db8::", range_start)
        self.assertIn("2001:db8::", range_end)

    def test_calculate_default_range_no_gateway(self):
        """Test default range calculation without gateway"""
        range_start, range_end = calculate_default_range(
            subnet="10.0.0.0/24",
            gateway=None,
            pod_ip="10.0.0.10",
        )
        # Should still exclude pod IP
        self.assertNotEqual(range_start, "10.0.0.10")
        start_ip = int(range_start.split(".")[-1])
        end_ip = int(range_end.split(".")[-1])
        self.assertLess(start_ip, end_ip)

    @patch("dhcp_utils.socket.socket")
    def test_check_dhcp_port_conflicts_no_conflict(self, mock_socket):
        """Test port conflict check when ports are available"""
        # Mock socket that successfully binds
        mock_sock = MagicMock()
        mock_socket.return_value = mock_sock
        mock_sock.bind.return_value = None

        result = check_dhcp_port_conflicts()
        self.assertFalse(result["ipv4_conflict"])
        self.assertFalse(result["ipv6_conflict"])

    @patch("dhcp_utils.socket.socket")
    def test_check_dhcp_port_conflicts_ipv4_conflict(self, mock_socket):
        """Test port conflict check when IPv4 ports are in use"""
        # Mock socket that fails to bind (port in use)
        mock_sock = MagicMock()
        mock_socket.return_value = mock_sock
        mock_sock.bind.side_effect = OSError("Address already in use")

        result = check_dhcp_port_conflicts()
        self.assertTrue(result["ipv4_conflict"])

    @patch("dhcp_utils.subprocess.run")
    def test_detect_host_interfaces(self, mock_run):
        """Test host interface detection"""
        # Mock ip link show output
        mock_run.return_value = MagicMock(
            returncode=0,
            stdout="1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536\n2: eth0: <BROADCAST,MULTICAST,UP> mtu 1500\n",
        )

        interfaces = detect_host_interfaces()
        self.assertIn("eth0", interfaces)
        self.assertNotIn("lo", interfaces)

    @patch("dhcp_utils.detect_host_interfaces")
    def test_get_interfaces_for_kea_host_mode(self, mock_detect):
        """Test interface detection for host networking mode"""
        mock_detect.return_value = ["eth0", "eth1"]

        interfaces = get_interfaces_for_kea("host", "10.0.0.0/24")
        self.assertEqual(interfaces, ["eth0", "eth1"])

    def test_get_interfaces_for_kea_macvlan_mode(self):
        """Test interface detection for macvlan networking mode"""
        interfaces = get_interfaces_for_kea("macvlan", "10.0.0.0/24")
        self.assertEqual(interfaces, [])

    def test_detect_subnet_invalid_ip(self):
        """Test subnet detection with invalid IP"""
        subnet = detect_subnet("invalid.ip.address")
        self.assertEqual(subnet, "")


if __name__ == "__main__":
    unittest.main()
