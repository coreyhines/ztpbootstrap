#!/usr/bin/env python3
"""Unit tests for G6b P1 fixes: enabled preservation, CSRF on auto-detect."""

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
class TestDhcpConfigPutPreservesEnabled(unittest.TestCase):
    """P1d: config PUT must not change dhcp.enabled (toggle endpoints own that flag)."""

    @classmethod
    def setUpClass(cls):
        cls._tmpdir = tempfile.TemporaryDirectory()
        cls.config_dir = Path(cls._tmpdir.name)
        (cls.config_dir / "logs").mkdir(parents=True)
        cls.config_file = cls.config_dir / "config.yaml"
        cls.config_file.write_text("dhcp:\n  enabled: false\n  ipv4:\n    subnet: 10.0.5.0/24\n")
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

    @patch("app.generate_kea_config", return_value={})
    @patch("app.config_manager")
    def test_put_ignores_client_enabled_and_preserves_existing(
        self, mock_config_manager, _mock_kea
    ):
        mock_config_manager.read_config.return_value = {
            "dhcp": {"enabled": False, "ipv4": {"subnet": "10.0.5.0/24"}}
        }
        mock_config_manager.update_section.return_value = (True, None)

        payload = {
            "dhcp": {
                "enabled": True,
                "ipv4": {"subnet": "10.0.5.0/24", "gateway": "10.0.5.1"},
            }
        }
        response = self._client().put(
            "/api/dhcp/config",
            data=json.dumps(payload),
            content_type="application/json",
            headers={"X-CSRF-Token": "test-csrf-token"},
        )
        self.assertEqual(response.status_code, 200)
        saved = mock_config_manager.update_section.call_args[0][1]
        self.assertFalse(saved["enabled"])
        self.assertEqual(saved["ipv4"]["gateway"], "10.0.5.1")


@unittest.skipUnless(FLASK_AVAILABLE, "Flask not installed")
class TestDhcpAutoDetectCsrf(unittest.TestCase):
    """P1a: auto-detect POST requires CSRF token."""

    @classmethod
    def setUpClass(cls):
        cls._tmpdir = tempfile.TemporaryDirectory()
        cls.config_dir = Path(cls._tmpdir.name)
        (cls.config_dir / "logs").mkdir(parents=True)
        (cls.config_dir / "config.yaml").write_text("dhcp:\n  enabled: false\n")
        os.environ["ZTP_CONFIG_DIR"] = str(cls.config_dir)
        sys.modules.pop("app", None)
        import app as webapp

        cls.webapp = webapp

    @classmethod
    def tearDownClass(cls):
        cls._tmpdir.cleanup()
        os.environ.pop("ZTP_CONFIG_DIR", None)
        sys.modules.pop("app", None)

    def test_auto_detect_rejects_missing_csrf(self):
        client = self.webapp.app.test_client()
        with client.session_transaction() as sess:
            sess["authenticated"] = True
            sess["expires_at"] = 9999999999
            sess["csrf_token"] = "test-csrf-token"

        response = client.post(
            "/api/dhcp/config/auto-detect",
            data=json.dumps({"ipv4_address": "10.0.5.10"}),
            content_type="application/json",
        )
        self.assertEqual(response.status_code, 403)
        data = response.get_json()
        self.assertEqual(data.get("code"), "CSRF_ERROR")

    @patch("app.detect_gateway", return_value={})
    @patch("app.detect_subnet", return_value="10.0.5.0/24")
    @patch("app.calculate_default_range", return_value=("10.0.5.100", "10.0.5.200"))
    def test_auto_detect_accepts_csrf_header(self, *_mocks):
        client = self.webapp.app.test_client()
        with client.session_transaction() as sess:
            sess["authenticated"] = True
            sess["expires_at"] = 9999999999
            sess["csrf_token"] = "test-csrf-token"

        response = client.post(
            "/api/dhcp/config/auto-detect",
            data=json.dumps({"ipv4_address": "10.0.5.10"}),
            content_type="application/json",
            headers={"X-CSRF-Token": "test-csrf-token"},
        )
        self.assertEqual(response.status_code, 200)


if __name__ == "__main__":
    unittest.main()
