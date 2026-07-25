#!/usr/bin/env python3
"""Unit tests for network_config.py"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent.parent / "webui"))

from network_config import (
    default_ztp_profile,
    get_ztp_profile,
    merge_ztp_update,
    resolve_effective_network,
    sync_legacy_network_fields,
)


class TestNetworkConfig(unittest.TestCase):
    def test_default_ztp_profile_disabled(self):
        profile = default_ztp_profile()
        self.assertFalse(profile["enabled"])
        self.assertEqual(profile["status"], "pending")

    def test_resolve_legacy_macvlan(self):
        config = {
            "container": {"host_network": False},
            "network": {"ipv4": "10.0.0.10", "ipv6": "2001:db8::10", "network": "ztpbootstrap-net"},
        }
        effective = resolve_effective_network(config)
        self.assertEqual(effective["mode"], "macvlan")
        self.assertEqual(effective["ipv4_address"], "10.0.0.10")
        self.assertEqual(effective["podman_network"], "ztpbootstrap-net")

    def test_resolve_ztp_enabled(self):
        config = {
            "container": {"host_network": False},
            "network": {
                "ztp": {
                    "enabled": True,
                    "vlan_id": 5,
                    "parent_interface": "enp7s0.5",
                    "ipv4": {
                        "address": "10.0.5.10",
                        "subnet": "10.0.5.0/24",
                        "gateway": "10.0.5.1",
                    },
                }
            },
        }
        effective = resolve_effective_network(config)
        self.assertEqual(effective["podman_network"], "ztp-net-5")
        self.assertEqual(effective["ipv4_address"], "10.0.5.10")

    def test_sync_legacy_fields(self):
        config = merge_ztp_update(
            {"network": {}, "container": {"host_network": True}},
            {
                "enabled": True,
                "vlan_id": 5,
                "ipv4": {"address": "10.0.5.10", "subnet": "10.0.5.0/24", "gateway": "10.0.5.1"},
            },
        )
        config = sync_legacy_network_fields(config)
        self.assertEqual(config["network"]["ipv4"], "10.0.5.10")
        self.assertEqual(config["network"]["network"], "ztp-net-5")
        self.assertFalse(config["container"]["host_network"])

    def test_get_ztp_profile_merges_defaults(self):
        config = {"network": {"ztp": {"enabled": True, "vlan_id": 10}}}
        profile = get_ztp_profile(config)
        self.assertTrue(profile["enabled"])
        self.assertEqual(profile["vlan_id"], 10)
        self.assertIn("ipv4", profile)


if __name__ == "__main__":
    unittest.main()
