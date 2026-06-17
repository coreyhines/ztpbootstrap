#!/usr/bin/env python3
"""
Unit tests for dhcp_config.py
"""

# Import DHCP modules
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

# Add webui to path
sys.path.insert(0, str(Path(__file__).parent.parent.parent / "webui"))

from dhcp_config import (
    configure_giaddr_matching,
    generate_client_classes,
    generate_ctrl_agent_config,
    generate_custom_options,
    generate_dhcp4_config,
    generate_dhcp6_config,
    generate_dhcp_options,
    generate_kea_config,
    generate_lease_database,
    generate_pxe_options,
    generate_relay_subnets,
)


class TestDHCPConfig(unittest.TestCase):
    """Test DHCP configuration generation"""

    def setUp(self):
        """Set up test fixtures"""
        self.minimal_config = {
            "dhcp": {
                "enabled": True,
                "server": "kea",
                "ipv4": {
                    "subnet": "10.0.0.0/24",
                    "range_start": "10.0.0.50",
                    "range_end": "10.0.0.250",
                    "gateway": "10.0.0.1",
                    "dns_servers": ["8.8.8.8", "8.8.4.4"],
                    "domain": "example.com",
                    "ntp_servers": ["time.nist.gov"],
                },
                "ipv6": {
                    "subnet": "2001:db8::/64",
                    "range_start": "2001:db8::50",
                    "range_end": "2001:db8::ff00",
                    "gateway": "2001:db8::1",
                    "dns_servers": ["2001:4860:4860::8888"],
                    "domain": "example.com",
                },
                "oui_filtering": {
                    "arista_only_mode": False,
                    "allowed_ouis": [],
                    "blocked_ouis": [],
                },
                "options": {
                    "standard": {
                        "dns_servers": [],
                        "ntp_servers": [],
                        "domain": "",
                    },
                    "custom": [],
                },
                "pxe": {
                    "enabled": False,
                    "boot_file_source": "local",
                    "boot_server_url": "",
                    "boot_file_name": "",
                },
                "relay": {
                    "enabled": False,
                    "subnets": [],
                },
                "backend": {
                    "type": "memfile",
                },
            },
            "container": {
                "host_network": False,
            },
        }

    @patch("dhcp_config.detect_networking_mode")
    @patch("dhcp_config.get_interfaces_for_kea")
    def test_generate_kea_config_disabled(self, mock_interfaces, mock_networking):
        """Test that disabled DHCP returns empty config"""
        config = {"dhcp": {"enabled": False}}
        result = generate_kea_config(config)
        self.assertEqual(result, {})

    @patch("dhcp_config.detect_networking_mode")
    @patch("dhcp_config.get_interfaces_for_kea")
    def test_generate_kea_config_ipv4_only(self, mock_interfaces, mock_networking):
        """Test IPv4-only configuration"""
        mock_networking.return_value = "macvlan"
        mock_interfaces.return_value = ["eth0"]

        config = self.minimal_config.copy()
        config["dhcp"]["ipv6"] = {}  # Remove IPv6

        result = generate_kea_config(config)
        self.assertIn("Dhcp4", result)
        self.assertNotIn("Dhcp6", result)
        self.assertIn("Control-agent", result)

    @patch("dhcp_config.detect_networking_mode")
    @patch("dhcp_config.get_interfaces_for_kea")
    def test_generate_kea_config_ipv6_only(self, mock_interfaces, mock_networking):
        """Test IPv6-only configuration"""
        mock_networking.return_value = "macvlan"
        mock_interfaces.return_value = ["eth0"]

        config = self.minimal_config.copy()
        config["dhcp"]["ipv4"] = {}  # Remove IPv4

        result = generate_kea_config(config)
        self.assertNotIn("Dhcp4", result)
        self.assertIn("Dhcp6", result)
        self.assertIn("Control-agent", result)

    @patch("dhcp_config.detect_networking_mode")
    @patch("dhcp_config.get_interfaces_for_kea")
    def test_generate_dhcp4_config_basic(self, mock_interfaces, mock_networking):
        """Test basic DHCPv4 configuration generation"""
        mock_networking.return_value = "macvlan"
        mock_interfaces.return_value = ["eth0"]

        dhcp_config = self.minimal_config["dhcp"]
        result = generate_dhcp4_config(dhcp_config, "macvlan", self.minimal_config)

        self.assertIn("subnet4", result)
        self.assertIn("lease-database", result)
        self.assertEqual(len(result["subnet4"]), 1)
        subnet = result["subnet4"][0]
        self.assertEqual(subnet["subnet"], "10.0.0.0/24")
        self.assertEqual(len(subnet["pools"]), 1)
        self.assertEqual(subnet["pools"][0]["pool"], "10.0.0.50 - 10.0.0.250")

    @patch("dhcp_config.detect_networking_mode")
    @patch("dhcp_config.get_interfaces_for_kea")
    def test_generate_dhcp4_config_with_dns(self, mock_interfaces, mock_networking):
        """Test DHCPv4 configuration with DNS servers"""
        mock_networking.return_value = "macvlan"
        mock_interfaces.return_value = ["eth0"]

        dhcp_config = self.minimal_config["dhcp"]
        result = generate_dhcp4_config(dhcp_config, "macvlan", self.minimal_config)

        subnet = result["subnet4"][0]
        self.assertIn("option-data", subnet)
        dns_options = [opt for opt in subnet["option-data"] if opt["name"] == "domain-name-servers"]
        self.assertEqual(len(dns_options), 1)
        self.assertIn("8.8.8.8", dns_options[0]["data"])
        self.assertIn("8.8.4.4", dns_options[0]["data"])

    @patch("dhcp_config.detect_networking_mode")
    @patch("dhcp_config.get_interfaces_for_kea")
    def test_generate_client_classes_arista_only(self, mock_interfaces, mock_networking):
        """Test Arista-only OUI filtering"""
        oui_config = {
            "arista_only_mode": True,
            "allowed_ouis": [],
            "blocked_ouis": [],
        }
        classes = generate_client_classes(oui_config, "ipv4")
        self.assertEqual(len(classes), 1)
        self.assertEqual(classes[0]["name"], "ARISTA_ONLY")
        self.assertIn("test", classes[0])

    @patch("dhcp_config.detect_networking_mode")
    @patch("dhcp_config.get_interfaces_for_kea")
    def test_generate_client_classes_allowed_ouis(self, mock_interfaces, mock_networking):
        """Test allowed OUIs filtering"""
        oui_config = {
            "arista_only_mode": False,
            "allowed_ouis": ["00:1C:73", "00:1E:0D"],
            "blocked_ouis": [],
        }
        classes = generate_client_classes(oui_config, "ipv4")
        self.assertEqual(len(classes), 1)
        self.assertEqual(classes[0]["name"], "ALLOWED_OUI")

    @patch("dhcp_config.detect_networking_mode")
    @patch("dhcp_config.get_interfaces_for_kea")
    def test_generate_pxe_options(self, mock_interfaces, mock_networking):
        """Test PXE options generation"""
        pxe_config = {
            "enabled": True,
            "boot_file_source": "local",
            "boot_server_url": "http://10.0.0.1",
            "boot_file_name": "pxelinux.0",
        }
        options = generate_pxe_options(pxe_config, "ipv4")
        self.assertGreater(len(options), 0)
        # Check for boot server option (66)
        boot_server = [opt for opt in options if opt.get("name") == "boot-server-hostname"]
        self.assertGreater(len(boot_server), 0)

    @patch("dhcp_config.detect_networking_mode")
    @patch("dhcp_config.get_interfaces_for_kea")
    def test_generate_relay_subnets(self, mock_interfaces, mock_networking):
        """Test relay subnet generation"""
        relay_config = {
            "enabled": True,
            "subnets": [
                {
                    "subnet": "10.0.1.0/24",
                    "relay_agent": "10.0.1.1",
                    "range_start": "10.0.1.100",
                    "range_end": "10.0.1.200",
                }
            ],
        }
        subnets = generate_relay_subnets(relay_config, "ipv4")
        self.assertEqual(len(subnets), 1)
        self.assertEqual(subnets[0]["subnet"], "10.0.1.0/24")

    @patch("dhcp_config.detect_networking_mode")
    @patch("dhcp_config.get_interfaces_for_kea")
    def test_generate_dhcp6_config_basic(self, mock_interfaces, mock_networking):
        """Test basic DHCPv6 configuration generation"""
        mock_networking.return_value = "macvlan"
        mock_interfaces.return_value = ["eth0"]

        dhcp_config = self.minimal_config["dhcp"]
        result = generate_dhcp6_config(dhcp_config, "macvlan", self.minimal_config)

        self.assertIn("subnet6", result)
        self.assertIn("lease-database", result)
        self.assertEqual(len(result["subnet6"]), 1)
        subnet = result["subnet6"][0]
        self.assertEqual(subnet["subnet"], "2001:db8::/64")
        self.assertEqual(len(subnet["pools"]), 1)
        self.assertEqual(subnet["pools"][0]["pool"], "2001:db8::50 - 2001:db8::ff00")

    @patch("dhcp_config.detect_networking_mode")
    @patch("dhcp_config.get_interfaces_for_kea")
    def test_generate_dhcp6_config_with_dns(self, mock_interfaces, mock_networking):
        """Test DHCPv6 configuration with DNS servers"""
        mock_networking.return_value = "macvlan"
        mock_interfaces.return_value = ["eth0"]

        dhcp_config = self.minimal_config["dhcp"]
        result = generate_dhcp6_config(dhcp_config, "macvlan", self.minimal_config)

        subnet = result["subnet6"][0]
        self.assertIn("option-data", subnet)
        dns_options = [opt for opt in subnet["option-data"] if opt["name"] == "dns-servers"]
        self.assertEqual(len(dns_options), 1)
        self.assertIn("2001:4860:4860::8888", dns_options[0]["data"])

    @patch("dhcp_config.detect_networking_mode")
    @patch("dhcp_config.get_interfaces_for_kea")
    def test_generate_dhcp4_config_with_custom_options(self, mock_interfaces, mock_networking):
        """Test DHCPv4 configuration with custom options"""
        mock_networking.return_value = "macvlan"
        mock_interfaces.return_value = ["eth0"]

        config = self.minimal_config.copy()
        config["dhcp"]["options"]["custom"] = [
            {"name": "tftp-server-name", "data": "10.0.0.1", "code": 66},
            {"name": "boot-file-name", "data": "pxelinux.0", "code": 67},
        ]

        dhcp_config = config["dhcp"]
        result = generate_dhcp4_config(dhcp_config, "macvlan", config)

        subnet = result["subnet4"][0]
        self.assertIn("option-data", subnet)
        custom_opts = [
            opt for opt in subnet["option-data"] if opt.get("name") == "tftp-server-name"
        ]
        self.assertGreater(len(custom_opts), 0)

    @patch("dhcp_config.detect_networking_mode")
    @patch("dhcp_config.get_interfaces_for_kea")
    def test_generate_dhcp4_config_with_oui_filtering(self, mock_interfaces, mock_networking):
        """Test DHCPv4 configuration with OUI filtering"""
        mock_networking.return_value = "macvlan"
        mock_interfaces.return_value = ["eth0"]

        config = self.minimal_config.copy()
        config["dhcp"]["oui_filtering"]["arista_only_mode"] = True

        dhcp_config = config["dhcp"]
        result = generate_dhcp4_config(dhcp_config, "macvlan", config)

        self.assertIn("client-classes", result)
        self.assertEqual(len(result["client-classes"]), 1)
        self.assertEqual(result["client-classes"][0]["name"], "ARISTA_ONLY")

    def test_generate_dhcp_options(self):
        """Test DHCP options generation"""
        options_config = {
            "standard": {
                "dns_servers": ["8.8.8.8"],
                "ntp_servers": ["time.nist.gov"],
                "domain": "example.com",
            }
        }
        options = generate_dhcp_options(options_config)
        self.assertGreater(len(options), 0)
        dns_opts = [opt for opt in options if opt["name"] == "domain-name-servers"]
        self.assertEqual(len(dns_opts), 1)

    def test_generate_custom_options(self):
        """Test custom DHCP options generation"""
        custom_options = [
            {"name": "option-66", "data": "10.0.0.1", "code": 66},
            {"name": "option-67", "data": "pxelinux.0", "code": 67},
        ]
        options = generate_custom_options(custom_options)
        self.assertEqual(len(options), 2)
        self.assertEqual(options[0]["name"], "option-66")
        self.assertEqual(options[0]["code"], 66)

    def test_configure_giaddr_matching(self):
        """Test giaddr matching configuration"""
        relay_config = {
            "subnets": [
                {"relay_agent": "10.0.1.1"},
                {"relay_agent": "10.0.2.1"},
            ]
        }
        result = configure_giaddr_matching(relay_config)
        self.assertIn("client-classes", result)
        self.assertEqual(len(result["client-classes"]), 2)

    def test_generate_lease_database_memfile(self):
        """Test memfile lease database generation"""
        backend_config = {"type": "memfile"}
        result = generate_lease_database(backend_config)
        self.assertEqual(result["type"], "memfile")
        self.assertIn("name", result)

    def test_generate_lease_database_postgresql(self):
        """Test PostgreSQL lease database generation"""
        backend_config = {
            "type": "postgresql",
            "postgresql": {
                "host": "localhost",
                "port": 5432,
                "database": "kea",
                "user": "kea",
                "password": "secret",
            },
        }
        result = generate_lease_database(backend_config)
        self.assertEqual(result["type"], "postgresql")
        self.assertEqual(result["host"], "localhost")
        self.assertEqual(result["port"], 5432)
        self.assertEqual(result["name"], "kea")

    def test_generate_ctrl_agent_config(self):
        """Test Control Agent configuration generation"""
        result = generate_ctrl_agent_config()
        self.assertIn("http-host", result)
        self.assertIn("http-port", result)
        self.assertIn("control-sockets", result)
        self.assertEqual(result["http-port"], 8000)

    @patch("dhcp_config.detect_networking_mode")
    @patch("dhcp_config.get_interfaces_for_kea")
    def test_generate_client_classes_blocked_ouis(self, mock_interfaces, mock_networking):
        """Test blocked OUIs filtering"""
        oui_config = {
            "arista_only_mode": False,
            "allowed_ouis": [],
            "blocked_ouis": ["00:11:22", "00:33:44"],
        }
        classes = generate_client_classes(oui_config, "ipv4")
        self.assertEqual(len(classes), 1)
        self.assertEqual(classes[0]["name"], "BLOCKED_OUI")

    @patch("dhcp_config.detect_networking_mode")
    @patch("dhcp_config.get_interfaces_for_kea")
    def test_generate_pxe_options_ipv6(self, mock_interfaces, mock_networking):
        """Test PXE options generation for IPv6 (should return empty)"""
        pxe_config = {
            "enabled": True,
            "boot_file_source": "local",
            "boot_server_url": "http://10.0.0.1",
            "boot_file_name": "pxelinux.0",
        }
        options = generate_pxe_options(pxe_config, "ipv6")
        # PXE is IPv4 only, so should return empty for IPv6
        self.assertEqual(len(options), 0)


if __name__ == "__main__":
    unittest.main()
