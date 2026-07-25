#!/usr/bin/env python3
"""Unit tests for DHCP reservation routes and Kea payload builders."""

import importlib.util
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../../webui"))

from dhcp_config import (  # noqa: E402
    build_kea_reservation_payload,
    dhcp_service_for_ip,
    find_reservation_in_config,
)

FLASK_AVAILABLE = importlib.util.find_spec("flask") is not None


class TestReservationHelpers(unittest.TestCase):
    def test_dhcp_service_for_ip(self):
        self.assertEqual(dhcp_service_for_ip("10.0.5.50"), "dhcp4")
        self.assertEqual(dhcp_service_for_ip("2001:db8::1"), "dhcp6")

    def test_build_kea_reservation_payload_ipv4(self):
        config = {"dhcp": {"ipv4_subnet_id": 1}}
        payload, service = build_kea_reservation_payload(
            "00:1c:73:aa:bb:cc", "10.0.5.50", config, hostname="sw1"
        )
        self.assertEqual(service, "dhcp4")
        self.assertEqual(payload["subnet-id"], 1)
        self.assertEqual(payload["identifier-type"], "hw-address")
        self.assertEqual(payload["identifier"], "00:1c:73:aa:bb:cc")
        self.assertEqual(payload["ip-address"], "10.0.5.50")
        self.assertEqual(payload["hostname"], "sw1")

    def test_find_reservation_in_config_normalizes_mac(self):
        config = {
            "dhcp": {
                "reservations": [{"hw-address": "00:1c:73:aa:bb:cc", "ip-address": "10.0.5.50"}]
            }
        }
        found = find_reservation_in_config(config, "00-1c-73-aa-bb-cc")
        self.assertIsNotNone(found)
        self.assertEqual(found["ip-address"], "10.0.5.50")


@unittest.skipUnless(FLASK_AVAILABLE, "Flask not installed")
class TestReservationRoutes(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._tmpdir = tempfile.TemporaryDirectory()
        cls.config_dir = Path(cls._tmpdir.name)
        (cls.config_dir / "logs").mkdir(parents=True)
        cls.config_file = cls.config_dir / "config.yaml"
        cls.config_file.write_text("dhcp:\n  enabled: true\n  reservations: []\n")
        os.environ["ZTP_CONFIG_DIR"] = str(cls.config_dir)
        sys.modules.pop("app", None)
        import app as webapp

        cls.webapp = webapp

    @classmethod
    def tearDownClass(cls):
        cls._tmpdir.cleanup()
        os.environ.pop("ZTP_CONFIG_DIR", None)
        sys.modules.pop("app", None)

    def _client(self):
        client = self.webapp.app.test_client()
        with client.session_transaction() as sess:
            sess["authenticated"] = True
            sess["expires_at"] = 9999999999
            sess["csrf_token"] = "test-csrf-token"
        return client

    @patch("app.add_reservation", return_value=True)
    def test_add_reservation_sends_subnet_id(self, mock_add):
        client = self._client()
        response = client.post(
            "/api/dhcp/reservations",
            json={"mac": "00:1c:73:aa:bb:cc", "ip": "10.0.5.50", "hostname": "sw1"},
            headers={"X-CSRF-Token": "test-csrf-token"},
        )
        self.assertEqual(response.status_code, 200)
        mock_add.assert_called_once()
        reservation, service = mock_add.call_args[0]
        self.assertEqual(service, "dhcp4")
        self.assertEqual(reservation["subnet-id"], 1)
        self.assertEqual(reservation["identifier-type"], "hw-address")

    @patch("app.delete_reservation", return_value=True)
    def test_delete_reservation_uses_subnet_id_not_service_string(self, mock_delete):
        self.config_file.write_text(
            "dhcp:\n  enabled: true\n  reservations:\n"
            "  - hw-address: 00:1c:73:aa:bb:cc\n    ip-address: 10.0.5.50\n"
        )
        client = self._client()
        response = client.delete(
            "/api/dhcp/reservations/00%3A1c%3A73%3Aaa%3Abb%3Acc",
            headers={"X-CSRF-Token": "test-csrf-token"},
        )
        self.assertEqual(response.status_code, 200)
        mock_delete.assert_called()
        args, kwargs = mock_delete.call_args
        self.assertEqual(args[1], 1)
        self.assertEqual(kwargs.get("service") or args[2] if len(args) > 2 else "dhcp4", "dhcp4")


if __name__ == "__main__":
    unittest.main()
