#!/usr/bin/env python3
"""Unit tests for network_utils Podman inspect helpers."""

import json
import sys
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).parent.parent.parent / "webui"))

from network_utils import inspect_podman_network


class TestInspectPodmanNetwork(unittest.TestCase):
    @patch("network_utils._run_cmd")
    @patch("network_utils.get_podman_cmd", return_value=["podman"])
    def test_reads_network_interface_parent(self, _podman_cmd, mock_run):
        payload = {
            "name": "ztp-net-5",
            "driver": "macvlan",
            "network_interface": "enp9s0",
            "subnets": [{"subnet": "10.0.5.0/24", "gateway": "10.0.5.1"}],
            "options": {"mode": "bridge"},
            "containers": {},
        }
        mock_run.return_value = MagicMock(returncode=0, stdout=json.dumps(payload))
        info = inspect_podman_network("ztp-net-5")
        self.assertIsNotNone(info)
        assert info is not None
        self.assertEqual(info["parent"], "enp9s0")
        self.assertEqual(info["mode"], "bridge")

    @patch("network_utils._run_cmd")
    @patch("network_utils.get_podman_cmd", return_value=["podman"])
    def test_reads_options_parent_fallback(self, _podman_cmd, mock_run):
        payload = {
            "name": "ztp-net-5",
            "driver": "macvlan",
            "subnets": [],
            "options": {"mode": "bridge", "parent": "enp7s0.5"},
            "containers": {},
        }
        mock_run.return_value = MagicMock(returncode=0, stdout=json.dumps(payload))
        info = inspect_podman_network("ztp-net-5")
        self.assertIsNotNone(info)
        assert info is not None
        self.assertEqual(info["parent"], "enp7s0.5")


if __name__ == "__main__":
    unittest.main()
