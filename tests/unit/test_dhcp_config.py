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
    build_oui_test,
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
    resolve_relay_agents,
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
    def test_generate_dhcp4_config_memfile_loads_lease_cmds(self, mock_interfaces, mock_networking):
        """Memfile must load lease_cmds so the Control Agent/Web UI can list leases."""
        mock_networking.return_value = "macvlan"
        mock_interfaces.return_value = ["eth0"]

        dhcp_config = self.minimal_config["dhcp"]
        result = generate_dhcp4_config(dhcp_config, "macvlan", self.minimal_config)

        libraries = [h["library"] for h in result.get("hooks-libraries", [])]
        self.assertTrue(any("libdhcp_lease_cmds.so" in lib for lib in libraries))
        self.assertFalse(any("libdhcp_host_cmds.so" in lib for lib in libraries))

    @patch("dhcp_config.detect_networking_mode")
    @patch("dhcp_config.get_interfaces_for_kea")
    def test_generate_dhcp4_config_postgres_loads_host_cmds(self, mock_interfaces, mock_networking):
        """PostgreSQL backend loads both lease_cmds and host_cmds."""
        mock_networking.return_value = "macvlan"
        mock_interfaces.return_value = ["eth0"]

        config = self.minimal_config.copy()
        config["dhcp"] = {**self.minimal_config["dhcp"], "backend": {"type": "postgresql"}}
        result = generate_dhcp4_config(config["dhcp"], "macvlan", config)

        libraries = [h["library"] for h in result.get("hooks-libraries", [])]
        self.assertTrue(any("libdhcp_lease_cmds.so" in lib for lib in libraries))
        self.assertTrue(any("libdhcp_host_cmds.so" in lib for lib in libraries))

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

    def test_generate_client_classes_covers_modern_arista_ouis(self):
        """CCS-710P and other modern Arista OUIs must be in ARISTA_ONLY"""
        classes = generate_client_classes({"arista_only_mode": True}, "ipv4")
        test_expr = classes[0]["test"]
        for oui in ["2CDDE9", "FCBD67", "E0FA5B", "28993A", "EC8A48", "001C73", "C0D682"]:
            self.assertIn(f"0x{oui}", test_expr, f"{oui} missing from ARISTA_ONLY")

    def test_generate_client_classes_excludes_non_arista_ouis(self):
        """ARISTA_ONLY must not admit other vendors.

        00:1E:0D-1F were listed as Arista for years but belong to Micran,
        Huawei, Cisco, Nortel and others -- the block was assumed contiguous.
        """
        expr = generate_client_classes({"arista_only_mode": True}, "ipv4")[0]["test"]
        for oui, owner in [
            ("001E10", "Huawei"),
            ("001E13", "Cisco"),
            ("001E14", "Cisco"),
            ("001E1F", "Nortel"),
            ("001E1E", "Honeywell"),
        ]:
            self.assertNotIn(f"0x{oui}", expr, f"{oui} ({owner}) must not be in ARISTA_ONLY")

    def test_oui_test_compares_binary_mac_to_hex_literal(self):
        """
        pkt4.mac is binary, so OUIs must be compared against an unquoted hex
        literal over 3 bytes. A quoted 6-char string never matches any client.
        """
        expr = build_oui_test(["2C:DD:E9"])
        self.assertEqual(expr, "substring(pkt4.mac,0,3) == 0x2CDDE9")
        self.assertNotIn("'", expr)

    def test_oui_test_accepts_separator_variants(self):
        """OUIs may be written with colons, dashes, or bare hex"""
        for oui in ["2C:DD:E9", "2c-dd-e9", "2cdde9"]:
            self.assertEqual(build_oui_test([oui]), "substring(pkt4.mac,0,3) == 0x2CDDE9")

    def test_oui_test_skips_malformed_entries(self):
        """Malformed OUIs are dropped rather than emitted as broken expressions"""
        self.assertEqual(build_oui_test(["zz:zz:zz", "00:1C"]), "")
        self.assertEqual(
            build_oui_test(["00:1C", "2C:DD:E9"]), "substring(pkt4.mac,0,3) == 0x2CDDE9"
        )

    def test_generate_client_classes_ipv6_returns_nothing(self):
        """DHCPv6 cannot match hardware addresses, so no pkt4 classes are emitted"""
        classes = generate_client_classes({"arista_only_mode": True}, "ipv6")
        self.assertEqual(classes, [])

    def test_relay_agents_default_for_slash_24(self):
        """A /24 with a gateway defaults to the last usable host plus gateway"""
        agents = resolve_relay_agents({}, "10.0.5.0/24", "10.0.5.1")
        self.assertEqual(agents, ["10.0.5.254", "10.0.5.1"])

    def test_relay_agents_explicit_config_wins(self):
        """An explicit relay_agents list overrides the /24 default"""
        agents = resolve_relay_agents(
            {"relay_agents": ["10.0.5.254", "10.0.5.253"]}, "10.0.5.0/24", "10.0.5.1"
        )
        self.assertEqual(agents, ["10.0.5.254", "10.0.5.253"])

    def test_relay_agents_deduplicates_gateway(self):
        """A gateway that is already the relay host is not listed twice"""
        agents = resolve_relay_agents({}, "10.0.5.0/24", "10.0.5.254")
        self.assertEqual(agents, ["10.0.5.254"])

    def test_relay_agents_skipped_without_gateway_or_slash_24(self):
        """No defaults are invented for other prefix lengths or missing gateways"""
        self.assertEqual(resolve_relay_agents({}, "10.0.5.0/24", ""), [])
        self.assertEqual(resolve_relay_agents({}, "10.0.0.0/16", "10.0.0.1"), [])
        self.assertEqual(resolve_relay_agents({}, "2001:db8::/64", "2001:db8::1"), [])
        self.assertEqual(resolve_relay_agents({}, "not-a-subnet", "10.0.5.1"), [])

    @patch("dhcp_config.detect_networking_mode")
    @patch("dhcp_config.get_interfaces_for_kea")
    def test_generate_dhcp4_config_sets_relay_addresses(self, mock_interfaces, mock_networking):
        """Generated DHCPv4 subnet carries relay addresses so relayed Discovers match"""
        mock_networking.return_value = "macvlan"
        mock_interfaces.return_value = ["eth0"]
        config = generate_dhcp4_config(self.minimal_config["dhcp"], "macvlan", self.minimal_config)
        self.assertEqual(config["subnet4"][0]["relay"]["ip-addresses"], ["10.0.0.254", "10.0.0.1"])

    @patch("dhcp_config.detect_networking_mode")
    @patch("dhcp_config.get_interfaces_for_kea")
    def test_generate_dhcp6_config_uses_ipv6_section(self, mock_interfaces, mock_networking):
        """DHCPv6 generation reads its own config section and adds no v4 relay defaults"""
        mock_networking.return_value = "macvlan"
        mock_interfaces.return_value = ["eth0"]
        config = generate_dhcp6_config(self.minimal_config["dhcp"], "macvlan", self.minimal_config)
        self.assertNotIn("relay", config["subnet6"][0])

    @patch("dhcp_config.detect_networking_mode")
    @patch("dhcp_config.get_interfaces_for_kea")
    def test_generate_dhcp6_config_omits_oui_class(self, mock_interfaces, mock_networking):
        """arista_only_mode must not guard a v6 subnet with an undefined class"""
        mock_networking.return_value = "macvlan"
        mock_interfaces.return_value = ["eth0"]
        dhcp = dict(self.minimal_config["dhcp"])
        dhcp["oui_filtering"] = {"arista_only_mode": True, "allowed_ouis": [], "blocked_ouis": []}
        config = generate_dhcp6_config(dhcp, "macvlan", self.minimal_config)
        self.assertNotIn("client-classes", config)
        self.assertNotIn("client-class", config["subnet6"][0])

    @patch("dhcp_config.detect_networking_mode")
    @patch("dhcp_config.get_interfaces_for_kea")
    def test_generate_dhcp6_config_names_interface_when_unrelayed(
        self, mock_interfaces, mock_networking
    ):
        """Direct DHCPv6 clients are only matched when subnet6 names an interface.

        Without it Kea has no giaddr to select on and answers NoAddrsAvail
        ("could not select subnet"), which is how the v6 subnet served nothing.
        """
        mock_networking.return_value = "macvlan"
        mock_interfaces.return_value = ["eth0"]
        config = generate_dhcp6_config(self.minimal_config["dhcp"], "macvlan", self.minimal_config)
        self.assertNotIn("relay", config["subnet6"][0])
        self.assertEqual(config["subnet6"][0]["interface"], "eth0")

    @patch("dhcp_config.detect_networking_mode")
    @patch("dhcp_config.get_interfaces_for_kea")
    def test_generate_dhcp6_config_defaults_interface_under_macvlan(
        self, mock_interfaces, mock_networking
    ):
        """Under macvlan no interface is detected, so the pod's eth0 is assumed"""
        mock_networking.return_value = "macvlan"
        mock_interfaces.return_value = []
        config = generate_dhcp6_config(self.minimal_config["dhcp"], "macvlan", self.minimal_config)
        self.assertEqual(config["subnet6"][0]["interface"], "eth0")

    @patch("dhcp_config.detect_networking_mode")
    @patch("dhcp_config.get_interfaces_for_kea")
    def test_generate_dhcp6_config_interface_is_overridable(self, mock_interfaces, mock_networking):
        """An explicit ipv6.interface wins over detection"""
        mock_networking.return_value = "macvlan"
        mock_interfaces.return_value = ["eth0"]
        dhcp = dict(self.minimal_config["dhcp"])
        dhcp["ipv6"] = dict(dhcp["ipv6"], interface="eth1")
        config = generate_dhcp6_config(dhcp, "macvlan", self.minimal_config)
        self.assertEqual(config["subnet6"][0]["interface"], "eth1")

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
        boot_server = [opt for opt in options if opt.get("code") == 66]
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

    @patch("dhcp_config.detect_networking_mode")
    @patch("dhcp_config.get_interfaces_for_kea")
    def test_generate_dhcp4_config_embeds_reservations(self, mock_interfaces, mock_networking):
        """Memfile Kea serves static hosts from subnet reservations in generated JSON."""
        mock_networking.return_value = "macvlan"
        mock_interfaces.return_value = ["eth0"]

        config = self.minimal_config.copy()
        config["dhcp"]["reservations"] = [
            {
                "hw-address": "00:1C:73-AA-BB-CC",
                "ip-address": "10.0.5.50",
                "hostname": "spine1",
            },
            {
                "hw-address": "00:1c:73:aa:bb:cc",
                "ip-address": "2601:441:8483:b505::50",
                "hostname": "spine1-v6",
            },
        ]

        result = generate_dhcp4_config(config["dhcp"], "macvlan", config)
        reservations = result["subnet4"][0]["reservations"]
        self.assertEqual(len(reservations), 1)
        self.assertEqual(reservations[0]["hw-address"], "00:1c:73:aa:bb:cc")
        self.assertEqual(reservations[0]["ip-address"], "10.0.5.50")
        self.assertEqual(reservations[0]["hostname"], "spine1")

    @patch("dhcp_config.detect_networking_mode")
    @patch("dhcp_config.get_interfaces_for_kea")
    def test_generate_dhcp6_config_embeds_reservations(self, mock_interfaces, mock_networking):
        """DHCPv6 reservations use ip-addresses arrays in generated Kea JSON."""
        mock_networking.return_value = "macvlan"
        mock_interfaces.return_value = ["eth0"]

        config = self.minimal_config.copy()
        config["dhcp"]["ipv6"] = {
            "subnet": "2601:441:8483:b505::/64",
            "range_start": "2601:441:8483:b505::220",
            "range_end": "2601:441:8483:b505::230",
            "gateway": "2601:441:8483:b505::1",
        }
        config["dhcp"]["reservations"] = [
            {
                "hw-address": "00:1c:73:aa:bb:cc",
                "ip-address": "2601:441:8483:b505::50",
                "hostname": "spine1-v6",
            }
        ]

        result = generate_dhcp6_config(config["dhcp"], "macvlan", config)
        reservations = result["subnet6"][0]["reservations"]
        self.assertEqual(len(reservations), 1)
        self.assertEqual(reservations[0]["ip-addresses"], ["2601:441:8483:b505::50"])

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
