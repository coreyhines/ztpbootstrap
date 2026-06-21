#!/usr/bin/env python3
"""Unit tests for network_validation.py"""

import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent.parent.parent / "webui"))

from network_validation import plan_network_changes, validate_ztp_profile


class TestNetworkValidation(unittest.TestCase):
    def _enabled_config(self):
        return {
            "container": {"host_network": False},
            "network": {
                "ztp": {
                    "enabled": True,
                    "vlan_id": 5,
                    "parent_interface": "enp7s0.5",
                    "podman_network": "ztp-net-5",
                    "macvlan_mode": "bridge",
                    "ipv4": {
                        "address": "10.0.5.10",
                        "subnet": "10.0.5.0/24",
                        "gateway": "10.0.5.1",
                    },
                }
            },
        }

    def test_validate_enabled_profile_ok(self):
        errors, warnings = validate_ztp_profile(self._enabled_config())
        self.assertEqual(errors, [])

    def test_validate_requires_parent(self):
        config = self._enabled_config()
        config["network"]["ztp"]["parent_interface"] = ""
        errors, _warnings = validate_ztp_profile(config)
        self.assertTrue(any("parent_interface" in err for err in errors))

    def test_validate_rejects_host_network_conflict(self):
        config = self._enabled_config()
        config["container"]["host_network"] = True
        errors, _warnings = validate_ztp_profile(config)
        self.assertTrue(any("host_network" in err for err in errors))

    def test_validate_invalid_cidr(self):
        config = self._enabled_config()
        config["network"]["ztp"]["ipv4"]["subnet"] = "not-a-cidr"
        errors, _warnings = validate_ztp_profile(config)
        self.assertTrue(errors)

    @patch("network_validation.inspect_podman_network", return_value=None)
    @patch("network_validation.parse_pod_quadlet")
    def test_plan_create_when_network_missing(self, mock_quadlet, _mock_inspect):
        mock_quadlet.return_value = {"network": None, "ipv4": None, "ipv6": None, "exists": True}
        plan = plan_network_changes({}, self._enabled_config())
        self.assertTrue(plan["create_network"])
        self.assertEqual(plan["action"], "create")

    @patch("network_validation.inspect_podman_network")
    @patch("network_validation.parse_pod_quadlet")
    def test_plan_noop_when_matching(self, mock_quadlet, mock_inspect):
        mock_quadlet.return_value = {
            "network": "ztp-net-5",
            "ipv4": "10.0.5.10",
            "ipv6": None,
            "exists": True,
        }
        mock_inspect.return_value = {
            "name": "ztp-net-5",
            "parent": "enp7s0.5",
            "mode": "bridge",
            "subnets": [{"subnet": "10.0.5.0/24", "gateway": "10.0.5.1"}],
            "container_count": 0,
            "containers": [],
        }
        plan = plan_network_changes(self._enabled_config(), self._enabled_config())
        self.assertFalse(plan["create_network"])
        self.assertFalse(plan["replace_network"])


if __name__ == "__main__":
    unittest.main()
