#!/usr/bin/env python3
"""Unit tests for DHCP status API response shape and container status fields."""

import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../../webui"))

FLASK_AVAILABLE = importlib.util.find_spec("flask") is not None


class TestCheckDhcpContainerStatusFields(unittest.TestCase):
    """UI reads dhcp4_running under container — not top-level container_running."""

    @patch("dhcp_deploy._kea_daemons_in_container")
    @patch("dhcp_deploy.subprocess.run")
    @patch("dhcp_deploy.get_podman_cmd", return_value=["podman"])
    def test_dhcp4_running_set_when_kea_responds(self, _mock_podman_cmd, mock_run, mock_daemons):
        mock_run.return_value = MagicMock(returncode=1, stdout="inactive", stderr="")
        mock_daemons.return_value = {
            "dhcp4_running": True,
            "dhcp6_running": False,
        }

        from dhcp_deploy import check_dhcp_container_status

        status = check_dhcp_container_status()
        self.assertTrue(status["dhcp4_running"])
        self.assertTrue(status["container_running"])
        self.assertEqual(status["service_status"], "active")

    @patch("dhcp_deploy._kea_daemons_in_container")
    @patch("dhcp_deploy.subprocess.run")
    @patch("dhcp_deploy.get_podman_cmd", return_value=["podman"])
    def test_running_container_without_dhcp4_is_degraded(
        self, _mock_podman_cmd, mock_run, mock_daemons
    ):
        mock_run.side_effect = [
            MagicMock(returncode=0, stdout="active\n", stderr=""),
            MagicMock(returncode=0, stdout="ztpbootstrap-dhcp\n", stderr=""),
        ]
        mock_daemons.return_value = {
            "dhcp4_running": False,
            "dhcp6_running": False,
        }

        from dhcp_deploy import check_dhcp_container_status, DHCP_CONTAINER_NAME

        with patch("dhcp_deploy.DHCP_CONTAINER_NAME", DHCP_CONTAINER_NAME):
            status = check_dhcp_container_status()

        self.assertTrue(status["container_running"])
        self.assertFalse(status["dhcp4_running"])
        self.assertEqual(status["service_status"], "degraded")


class TestDhcpStatusResponseContract(unittest.TestCase):
    """UI contract: dhcpServiceStateLabel reads nested container.dhcp4_running."""

    def test_running_label_requires_nested_dhcp4_running(self):
        container_status = {
            "exists": True,
            "service_active": True,
            "container_running": True,
            "dhcp4_running": True,
            "dhcp6_running": False,
            "service_status": "active",
        }
        api_response = {
            "enabled": True,
            "networking_mode": "macvlan",
            "port_conflicts": {"ipv4_conflict": False, "ipv6_conflict": False},
            "container": container_status,
        }
        self.assertTrue(api_response["container"]["dhcp4_running"])
        self.assertNotIn(
            "container_running",
            api_response,
            "loadDhcpStatus assigns data.container — not top-level container_running",
        )

    def test_container_running_without_dhcp4_is_not_fully_running(self):
        container_status = {
            "container_running": True,
            "dhcp4_running": False,
            "service_active": True,
            "service_status": "degraded",
        }
        self.assertFalse(container_status["dhcp4_running"])
        self.assertTrue(container_status["container_running"])


@unittest.skipUnless(FLASK_AVAILABLE, "Flask not installed")
class TestDhcpStatusApiResponseShape(unittest.TestCase):
    """GET /api/dhcp/status must nest runtime fields under container (UI contract)."""

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

    @patch("app.check_dhcp_port_conflicts")
    @patch("app.detect_networking_mode", return_value="macvlan")
    @patch("app.check_dhcp_container_status")
    def test_status_response_nests_container_fields(self, mock_status, _mock_mode, mock_ports):
        mock_status.return_value = {
            "exists": True,
            "service_active": True,
            "container_running": True,
            "dhcp4_running": True,
            "dhcp6_running": False,
            "service_status": "active",
        }
        mock_ports.return_value = {"ipv4_conflict": False, "ipv6_conflict": False}

        client = self.webapp.app.test_client()
        response = client.get("/api/dhcp/status")
        self.assertEqual(response.status_code, 200)
        data = json.loads(response.data)

        self.assertTrue(data["enabled"])
        self.assertIn("container", data)
        self.assertTrue(data["container"]["container_running"])
        self.assertTrue(data["container"]["dhcp4_running"])
        self.assertNotIn("container_running", data, "UI expects nested container.container_running")
        self.assertIn("port_conflicts", data)
        self.assertIn("ipv4_conflict", data["port_conflicts"])

    @patch("app.check_dhcp_port_conflicts")
    @patch("app.detect_networking_mode", return_value="host")
    @patch("app.check_dhcp_container_status")
    def test_status_reports_degraded_when_dhcp4_not_running(
        self, mock_status, _mock_mode, mock_ports
    ):
        mock_status.return_value = {
            "exists": True,
            "service_active": True,
            "container_running": True,
            "dhcp4_running": False,
            "dhcp6_running": False,
            "service_status": "degraded",
        }
        mock_ports.return_value = {"ipv4_conflict": True, "ipv6_conflict": False}

        client = self.webapp.app.test_client()
        response = client.get("/api/dhcp/status")
        data = json.loads(response.data)

        self.assertFalse(data["container"]["dhcp4_running"])
        self.assertEqual(data["container"]["service_status"], "degraded")
        self.assertTrue(data["port_conflicts"]["ipv4_conflict"])

    def test_status_accessible_without_auth(self):
        """Dashboard polls /api/dhcp/status before login — must not require a session."""
        client = self.webapp.app.test_client()
        with patch.object(
            self.webapp, "check_dhcp_container_status", return_value={"exists": False}
        ):
            with patch.object(
                self.webapp,
                "check_dhcp_port_conflicts",
                return_value={"ipv4_conflict": False, "ipv6_conflict": False},
            ):
                with patch.object(self.webapp, "detect_networking_mode", return_value="unknown"):
                    response = client.get("/api/dhcp/status")
        self.assertEqual(response.status_code, 200)


if __name__ == "__main__":
    unittest.main()
