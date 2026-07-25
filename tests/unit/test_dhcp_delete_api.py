#!/usr/bin/env python3
"""Flask route tests for DHCP lease DELETE (auth + CSRF + ?ip=)."""

import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../../webui"))

FLASK_AVAILABLE = importlib.util.find_spec("flask") is not None


@unittest.skipUnless(FLASK_AVAILABLE, "Flask not installed")
class TestDeleteDhcpLeaseRoute(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._tmpdir = tempfile.TemporaryDirectory()
        cls.config_dir = Path(cls._tmpdir.name)
        (cls.config_dir / "logs").mkdir(parents=True)
        cls.config_file = cls.config_dir / "config.yaml"
        cls.config_file.write_text("dhcp:\n  enabled: true\n")
        os.environ["ZTP_CONFIG_DIR"] = str(cls.config_dir)
        sys.modules.pop("app", None)
        import app as webapp

        cls.webapp = webapp

    @classmethod
    def tearDownClass(cls):
        cls._tmpdir.cleanup()
        os.environ.pop("ZTP_CONFIG_DIR", None)
        sys.modules.pop("app", None)

    def _client(self, *, authenticated=True):
        client = self.webapp.app.test_client()
        if authenticated:
            with client.session_transaction() as sess:
                sess["authenticated"] = True
                sess["expires_at"] = 9999999999
                sess["csrf_token"] = "test-csrf-token"
        return client

    @patch("app.delete_all_leases_for_mac", return_value=True)
    @patch("app.delete_lease")
    def test_delete_all_for_mac_without_ip_query(self, mock_delete_one, mock_delete_all):
        client = self._client()
        response = client.delete(
            "/api/dhcp/leases/aa:bb:cc:dd:ee:ff",
            headers={"X-CSRF-Token": "test-csrf-token"},
        )
        self.assertEqual(response.status_code, 200)
        mock_delete_all.assert_called()
        mock_delete_one.assert_not_called()

    @patch("app.delete_all_leases_for_mac")
    @patch("app.delete_lease", return_value=True)
    def test_delete_single_ip_when_query_param_set(self, mock_delete_one, mock_delete_all):
        client = self._client()
        response = client.delete(
            "/api/dhcp/leases/aa%3Abb%3Acc%3Add%3Aee%3Aff?ip=10.0.5.220",
            headers={"X-CSRF-Token": "test-csrf-token"},
        )
        self.assertEqual(response.status_code, 200)
        mock_delete_one.assert_called()
        mock_delete_all.assert_not_called()
        calls = mock_delete_one.call_args_list
        self.assertEqual(calls[0][0][0], "aa:bb:cc:dd:ee:ff")
        self.assertEqual(calls[0][1]["ip_address"], "10.0.5.220")

    @patch("app.delete_all_leases_for_mac")
    @patch("app.delete_lease", side_effect=[False, True])
    def test_delete_ipv6_ip_tries_dhcp6_after_dhcp4(self, mock_delete_one, mock_delete_all):
        client = self._client()
        response = client.delete(
            "/api/dhcp/leases/aa:bb:cc:dd:ee:ff?ip=2001:db8::1",
            headers={"X-CSRF-Token": "test-csrf-token"},
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(mock_delete_one.call_count, 2)
        mock_delete_one.assert_any_call("aa:bb:cc:dd:ee:ff", "dhcp4", ip_address="2001:db8::1")
        mock_delete_one.assert_any_call("aa:bb:cc:dd:ee:ff", "dhcp6", ip_address="2001:db8::1")
        mock_delete_all.assert_not_called()

    @patch("app.delete_all_leases_for_mac", return_value=True)
    @patch("app.delete_lease")
    def test_whitespace_ip_query_deletes_all_for_mac(self, mock_delete_one, mock_delete_all):
        client = self._client()
        response = client.delete(
            "/api/dhcp/leases/aa:bb:cc:dd:ee:ff?ip=%20%20",
            headers={"X-CSRF-Token": "test-csrf-token"},
        )
        self.assertEqual(response.status_code, 200)
        mock_delete_all.assert_called()
        mock_delete_one.assert_not_called()

    @patch("app.delete_all_leases_for_mac", return_value=False)
    def test_delete_failure_returns_500(self, _mock_delete_all):
        client = self._client()
        response = client.delete(
            "/api/dhcp/leases/aa:bb:cc:dd:ee:ff",
            headers={"X-CSRF-Token": "test-csrf-token"},
        )
        self.assertEqual(response.status_code, 500)
        data = json.loads(response.data)
        self.assertIn("error", data)

    def test_delete_requires_auth(self):
        client = self._client(authenticated=False)
        response = client.delete(
            "/api/dhcp/leases/aa:bb:cc:dd:ee:ff",
            headers={"X-CSRF-Token": "test-csrf-token"},
        )
        self.assertEqual(response.status_code, 401)
        data = json.loads(response.data)
        self.assertEqual(data.get("code"), "AUTH_REQUIRED")

    def test_delete_requires_csrf(self):
        client = self._client()
        response = client.delete("/api/dhcp/leases/aa:bb:cc:dd:ee:ff")
        self.assertEqual(response.status_code, 403)
        data = json.loads(response.data)
        self.assertEqual(data.get("code"), "CSRF_ERROR")


if __name__ == "__main__":
    unittest.main()
