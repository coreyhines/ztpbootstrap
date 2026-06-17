#!/usr/bin/env python3
"""Unit tests for kea_client.py — verifies correct Kea command names and argument shapes."""

import os
import sys
import unittest
from unittest.mock import MagicMock, patch

# Stub out requests before importing kea_client so tests run without the package installed.
_requests_stub = MagicMock()
sys.modules.setdefault("requests", _requests_stub)
sys.modules.setdefault("requests.exceptions", _requests_stub.exceptions)

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../../webui"))

from kea_client import delete_lease, delete_reservation, get_config, get_statistics  # noqa: E402


class TestKeaCommandNames(unittest.TestCase):
    """Assert the correct Kea command strings are used."""

    @patch("kea_client.kea_request")
    def test_delete_lease_uses_lease4_del_for_dhcp4(self, mock_req):
        mock_req.return_value = {"result": 0}
        delete_lease("aa:bb:cc:dd:ee:ff", "dhcp4")
        mock_req.assert_called_once_with("lease4-del", "dhcp4", {"hw-address": "aa:bb:cc:dd:ee:ff"})

    @patch("kea_client.kea_request")
    def test_delete_lease_uses_lease6_del_for_dhcp6(self, mock_req):
        mock_req.return_value = {"result": 0}
        delete_lease("aa:bb:cc:dd:ee:ff", "dhcp6")
        mock_req.assert_called_once_with("lease6-del", "dhcp6", {"hw-address": "aa:bb:cc:dd:ee:ff"})

    @patch("kea_client.kea_request")
    def test_get_statistics_returns_arguments_directly(self, mock_req):
        mock_req.return_value = {
            "result": 0,
            "arguments": {"pkt4-received": [[42, "integer", "2024-01-01"]]},
        }
        result = get_statistics("dhcp4")
        self.assertIn("pkt4-received", result)
        # Must NOT use .get("$") - the stats are directly in arguments
        mock_req.assert_called_once_with("statistic-get-all", "dhcp4")

    @patch("kea_client.kea_request")
    def test_get_config_returns_arguments_directly(self, mock_req):
        mock_req.return_value = {"result": 0, "arguments": {"Dhcp4": {"subnet4": []}}}
        result = get_config("dhcp4")
        self.assertIn("Dhcp4", result)
        mock_req.assert_called_once_with("config-get", "dhcp4")

    @patch("kea_client.kea_request")
    def test_delete_reservation_requires_subnet_id(self, mock_req):
        mock_req.return_value = {"result": 0}
        delete_reservation("aa:bb:cc:dd:ee:ff", subnet_id=1, service="dhcp4")
        mock_req.assert_called_once_with(
            "reservation-del",
            "dhcp4",
            {"identifier-type": "hw-address", "identifier": "aa:bb:cc:dd:ee:ff", "subnet-id": 1},
        )


class TestGetLeasesFallback(unittest.TestCase):
    """Assert get_leases tries Control Agent first, falls back to memfile."""

    @patch("kea_client.kea_request")
    def test_get_leases_uses_lease4_get_all(self, mock_req):
        mock_req.return_value = {
            "result": 0,
            "arguments": {
                "leases": [{"ip-address": "10.0.0.100", "hw-address": "aa:bb:cc:dd:ee:ff"}]
            },
        }
        from kea_client import get_leases

        leases = get_leases("dhcp4")
        mock_req.assert_called_once_with("lease4-get-all", "dhcp4")
        self.assertEqual(len(leases), 1)
        self.assertEqual(leases[0]["ip-address"], "10.0.0.100")

    @patch("kea_client.kea_request", side_effect=Exception("connection refused"))
    def test_get_leases_falls_back_to_memfile_on_ctrl_agent_failure(self, mock_req):
        from kea_client import get_leases

        # Should not raise — just return empty list when both ctrl-agent and memfile fail
        result = get_leases("dhcp4")
        self.assertIsInstance(result, list)


if __name__ == "__main__":
    unittest.main()
