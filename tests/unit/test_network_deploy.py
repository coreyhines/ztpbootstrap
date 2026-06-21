#!/usr/bin/env python3
"""Unit tests for network_deploy quadlet rendering."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent.parent / "webui"))

from network_deploy import render_pod_quadlet_content


class TestNetworkDeploy(unittest.TestCase):
    def test_render_macvlan_quadlet(self):
        profile = {
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
            "ipv6": {
                "address": "2601:441:8483:b505::10",
                "subnet": "2601:441:8483:b505::/64",
                "gateway": "2601:441:8483:b505::1",
            },
        }
        content = render_pod_quadlet_content(profile)
        self.assertIn("Network=ztp-net-5", content)
        self.assertIn("IP=10.0.5.10", content)
        self.assertIn("IP6=2601:441:8483:b505::10", content)

    def test_render_host_when_disabled(self):
        content = render_pod_quadlet_content({"enabled": False})
        self.assertIn("Network=host", content)
        self.assertNotIn("IP=", content)


if __name__ == "__main__":
    unittest.main()
