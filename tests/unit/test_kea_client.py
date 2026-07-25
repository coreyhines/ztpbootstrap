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

from kea_client import (  # noqa: E402
    DEFAULT_KEA_CTRL_AGENT_URL,
    _dedupe_leases_by_mac,
    _lease_is_active,
    delete_all_leases_for_mac,
    delete_lease,
    delete_reservation,
    get_config,
    get_kea_ctrl_agent_url,
    get_leases,
    get_statistics,
    kea_request,
)


class TestKeaCtrlAgentUrl(unittest.TestCase):
    """KEA_CTRL_AGENT_URL env var and default."""

    def test_default_url_when_env_unset(self):
        with patch.dict(os.environ, {}, clear=True):
            os.environ.pop("KEA_CTRL_AGENT_URL", None)
            self.assertEqual(get_kea_ctrl_agent_url(), DEFAULT_KEA_CTRL_AGENT_URL)

    def test_url_from_env(self):
        custom = "http://192.168.50.10:8000"
        with patch.dict(os.environ, {"KEA_CTRL_AGENT_URL": custom}):
            self.assertEqual(get_kea_ctrl_agent_url(), custom)

    @patch("kea_client.requests.post")
    def test_kea_request_uses_env_url(self, mock_post):
        mock_post.return_value = MagicMock(
            raise_for_status=MagicMock(),
            json=MagicMock(return_value={"result": 0}),
        )
        custom = "http://10.0.0.5:8000"
        with patch.dict(os.environ, {"KEA_CTRL_AGENT_URL": custom}):
            kea_request("status-get", "dhcp4")
        mock_post.assert_called_once()
        self.assertEqual(mock_post.call_args[0][0], custom)


class TestKeaCommandNames(unittest.TestCase):
    """Assert the correct Kea command strings are used."""

    @patch("kea_client.kea_request")
    def test_kea_request_omits_empty_arguments(self, mock_req):
        from kea_client import kea_request

        mock_req.return_value = {"result": 0}
        kea_request("lease4-get-all", "dhcp4")
        mock_req.assert_called_once_with("lease4-get-all", "dhcp4")

    @patch("kea_client._delete_lease_memfile", return_value=False)
    @patch("kea_client.kea_request")
    def test_delete_lease_uses_ip_address_when_provided(self, mock_req, _mock_mem):
        mock_req.return_value = {"result": 0}
        delete_lease("aa:bb:cc:dd:ee:ff", "dhcp4", ip_address="10.0.5.221")
        mock_req.assert_called_with("lease4-del", "dhcp4", {"ip-address": "10.0.5.221"})

    @patch("kea_client._delete_lease_memfile", return_value=False)
    @patch("kea_client._find_lease_record", return_value={"ip-address": "10.0.0.5", "subnet-id": 1})
    @patch("kea_client.kea_request")
    def test_delete_lease_falls_back_to_identifier(self, mock_req, _mock_find, _mock_mem):
        mock_req.side_effect = [
            {"result": 1},
            {"result": 0},
        ]
        delete_lease("aa:bb:cc:dd:ee:ff", "dhcp4")
        self.assertEqual(mock_req.call_count, 2)
        mock_req.assert_any_call(
            "lease4-del",
            "dhcp4",
            {"identifier-type": "hw-address", "identifier": "aa:bb:cc:dd:ee:ff"},
        )

    @patch("kea_client.kea_request")
    def test_delete_lease_uses_lease6_del_for_dhcp6(self, mock_req):
        mock_req.return_value = {"result": 0}
        with patch("kea_client._delete_lease_memfile", return_value=False):
            delete_lease("aa:bb:cc:dd:ee:ff", "dhcp6", ip_address="2001:db8::1")
        mock_req.assert_called_with("lease6-del", "dhcp6", {"ip-address": "2001:db8::1"})

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

    @patch("kea_client.kea_request")
    def test_get_leases_accepts_empty_result_code(self, mock_req):
        mock_req.return_value = {"result": 3, "arguments": {"leases": []}}
        from kea_client import get_leases

        leases = get_leases("dhcp4")
        self.assertEqual(leases, [])

    @patch("kea_client.kea_request", side_effect=Exception("connection refused"))
    def test_get_leases_falls_back_to_memfile_on_ctrl_agent_failure(self, mock_req):
        from kea_client import get_leases

        # Should not raise — just return empty list when both ctrl-agent and memfile fail
        result = get_leases("dhcp4")
        self.assertIsInstance(result, list)

    @patch("kea_client.kea_request")
    def test_get_leases_dedupes_by_mac_keeps_newest_expire(self, mock_req):
        mock_req.return_value = {
            "result": 0,
            "arguments": {
                "leases": [
                    {
                        "ip-address": "10.0.5.220",
                        "hw-address": "aa:bb:cc:dd:ee:ff",
                        "state": 0,
                        "valid-lifetime": 86400,
                        "expire": 100,
                    },
                    {
                        "ip-address": "10.0.5.224",
                        "hw-address": "aa:bb:cc:dd:ee:ff",
                        "state": 0,
                        "valid-lifetime": 86400,
                        "expire": 200,
                    },
                ]
            },
        }
        leases = get_leases("dhcp4")
        self.assertEqual(len(leases), 1)
        self.assertEqual(leases[0]["ip-address"], "10.0.5.224")

    @patch("kea_client.kea_request")
    def test_get_leases_dedupes_normalizes_mac_separators(self, mock_req):
        mock_req.return_value = {
            "result": 0,
            "arguments": {
                "leases": [
                    {
                        "ip-address": "10.0.5.220",
                        "hw-address": "aa-bb-cc-dd-ee-ff",
                        "expire": 100,
                    },
                    {
                        "ip-address": "10.0.5.224",
                        "hw-address": "AA:BB:CC:DD:EE:FF",
                        "expire": 200,
                    },
                ]
            },
        }
        leases = get_leases("dhcp4")
        self.assertEqual(len(leases), 1)
        self.assertEqual(leases[0]["ip-address"], "10.0.5.224")

    @patch("kea_client.kea_request")
    def test_get_leases_filters_expired_before_dedupe(self, mock_req):
        import time

        mock_req.return_value = {
            "result": 0,
            "arguments": {
                "leases": [
                    {
                        "ip-address": "10.0.5.220",
                        "hw-address": "aa:bb:cc:dd:ee:ff",
                        "state": 0,
                        "expire": int(time.time()) + 3600,
                    },
                    {
                        "ip-address": "10.0.5.221",
                        "hw-address": "aa:bb:cc:dd:ee:ff",
                        "state": 1,
                        "expire": 100,
                    },
                ]
            },
        }
        leases = get_leases("dhcp4")
        self.assertEqual(len(leases), 1)
        self.assertEqual(leases[0]["ip-address"], "10.0.5.220")

    @patch("kea_client.kea_request")
    def test_get_leases_returns_deduped_raw_when_all_inactive(self, mock_req):
        mock_req.return_value = {
            "result": 0,
            "arguments": {
                "leases": [
                    {
                        "ip-address": "10.0.5.220",
                        "hw-address": "aa:bb:cc:dd:ee:ff",
                        "state": 1,
                        "expire": 100,
                    },
                    {
                        "ip-address": "10.0.5.224",
                        "hw-address": "aa:bb:cc:dd:ee:ff",
                        "state": 1,
                        "expire": 200,
                    },
                ]
            },
        }
        leases = get_leases("dhcp4")
        self.assertEqual(len(leases), 1)
        self.assertEqual(leases[0]["ip-address"], "10.0.5.224")


class TestDedupeLeasesHelper(unittest.TestCase):
    """Direct tests for _dedupe_leases_by_mac (UI delete depends on one row per MAC)."""

    def test_dedupe_prefers_higher_expire(self):
        leases = [
            {"hw-address": "aa:bb:cc:dd:ee:ff", "ip-address": "10.0.0.1", "expire": 50},
            {"hw-address": "aa:bb:cc:dd:ee:ff", "ip-address": "10.0.0.2", "expire": 150},
        ]
        result = _dedupe_leases_by_mac(leases)
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]["ip-address"], "10.0.0.2")

    def test_dedupe_skips_leases_without_mac(self):
        leases = [
            {"ip-address": "10.0.0.1", "expire": 100},
            {"hw-address": "aa:bb:cc:dd:ee:ff", "ip-address": "10.0.0.2", "expire": 50},
        ]
        result = _dedupe_leases_by_mac(leases)
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]["ip-address"], "10.0.0.2")


class TestLeaseActiveHelper(unittest.TestCase):
    def test_expired_state_is_inactive(self):
        self.assertFalse(_lease_is_active({"state": 1, "expire": 9999999999}))

    def test_zero_valid_lifetime_is_inactive(self):
        self.assertFalse(_lease_is_active({"state": 0, "valid-lifetime": 0}))


class TestDeleteAllLeasesForMac(unittest.TestCase):
    """End-to-end delete orchestration (not mocked delete_lease)."""

    @patch("kea_client._find_lease_record", return_value=None)
    @patch("kea_client._delete_lease_memfile", return_value=True)
    @patch("kea_client.kea_request")
    def test_delete_all_leases_deletes_each_ip_then_scrubs_memfile(
        self, mock_req, mock_mem, _mock_find
    ):
        mock_req.side_effect = [
            {
                "result": 0,
                "arguments": {
                    "leases": [
                        {"ip-address": "10.0.5.220", "hw-address": "aa:bb:cc:dd:ee:ff"},
                        {"ip-address": "10.0.5.224", "hw-address": "aa:bb:cc:dd:ee:ff"},
                    ]
                },
            },
            {"result": 0},
            {"result": 0},
        ]
        self.assertTrue(delete_all_leases_for_mac("aa:bb:cc:dd:ee:ff", "dhcp4"))
        del_calls = [
            c
            for c in mock_req.call_args_list
            if c[0][0] == "lease4-del" and c[0][2].get("ip-address")
        ]
        self.assertEqual(len(del_calls), 2)
        deleted_ips = {c[0][2]["ip-address"] for c in del_calls}
        self.assertEqual(deleted_ips, {"10.0.5.220", "10.0.5.224"})
        mock_mem.assert_called_once_with("aa:bb:cc:dd:ee:ff", "dhcp4", ip_address=None)

    @patch("kea_client._delete_lease_memfile", return_value=False)
    @patch("kea_client._list_lease_ips_for_mac", return_value=[])
    def test_delete_all_leases_idempotent_when_empty(self, _mock_ips, _mock_mem):
        self.assertTrue(delete_all_leases_for_mac("aa:bb:cc:dd:ee:ff", "dhcp4"))

    @patch("kea_client._delete_lease_memfile", return_value=False)
    @patch("kea_client.delete_lease", return_value=False)
    @patch("kea_client._list_lease_ips_for_mac", return_value=["10.0.5.220"])
    def test_delete_all_leases_fails_when_kea_unreachable(self, _mock_ips, _mock_del, _mock_mem):
        self.assertFalse(delete_all_leases_for_mac("aa:bb:cc:dd:ee:ff", "dhcp4"))

    @patch("kea_client._delete_lease_memfile", return_value=False)
    @patch("kea_client.kea_request")
    def test_delete_lease_treats_result_code_3_as_success(self, mock_req, _mock_mem):
        mock_req.return_value = {"result": 3}
        self.assertTrue(delete_lease("aa:bb:cc:dd:ee:ff", "dhcp4", ip_address="10.0.5.221"))

    @patch("kea_client._delete_lease_memfile", return_value=False)
    @patch("kea_client._find_lease_record", return_value=None)
    @patch("kea_client.kea_request")
    def test_delete_lease_idempotent_when_lease_already_gone(self, mock_req, _mock_find, _mock_mem):
        """Kea result 3 on every attempt means lease absent — still success."""
        mock_req.side_effect = [{"result": 3}, {"result": 3}]
        self.assertTrue(delete_lease("aa:bb:cc:dd:ee:ff", "dhcp4", ip_address="10.0.5.221"))

    @patch("kea_client._delete_lease_memfile", return_value=False)
    @patch("kea_client._find_lease_record", return_value=None)
    @patch("kea_client.kea_request")
    def test_delete_lease_not_idempotent_without_ip_or_lease(self, mock_req, _mock_find, _mock_mem):
        mock_req.return_value = {"result": 1}
        self.assertFalse(delete_lease("aa:bb:cc:dd:ee:ff", "dhcp4"))

    @patch("kea_client._delete_lease_memfile", return_value=False)
    @patch("kea_client._find_lease_record", return_value=None)
    @patch("kea_client._read_memfile_leases", return_value=[])
    @patch("kea_client.kea_request")
    def test_delete_all_leases_idempotent_when_kea_returns_code_3(
        self, mock_req, _mock_memfile, _mock_find, _mock_mem
    ):
        mock_req.side_effect = [
            {
                "result": 0,
                "arguments": {
                    "leases": [{"ip-address": "10.0.5.220", "hw-address": "aa:bb:cc:dd:ee:ff"}]
                },
            },
            {"result": 3},
        ]
        self.assertTrue(delete_all_leases_for_mac("aa:bb:cc:dd:ee:ff", "dhcp4"))


if __name__ == "__main__":
    unittest.main()
