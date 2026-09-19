#!/usr/bin/env python3
"""Tests for dhcp_deploy container status — verifies no fail-open behavior."""

import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../../webui"))


class TestContainerStatusTruthfulness(unittest.TestCase):
    """start_dhcp_container must not return True based solely on file existence."""

    @patch("dhcp_deploy.check_dhcp_container_status")
    @patch("dhcp_deploy.subprocess.run")
    def test_start_returns_false_when_only_file_exists(self, mock_run, mock_status):
        """File existing but ctrl-agent down must NOT return True."""
        # Status: file exists, but container not running, service not active.
        # Called multiple times — first call (pre-start check) shows not running,
        # subsequent calls (polling loop) also show not running.
        mock_status.return_value = {
            "exists": True,
            "service_active": False,
            "container_running": False,
            "service_status": "inactive",
        }
        # All subprocess calls fail (systemctl fails, podman fails)
        mock_run.return_value = MagicMock(returncode=1, stdout="", stderr="failed")

        from dhcp_deploy import start_dhcp_container

        result = start_dhcp_container()

        # CRITICAL: must NOT return True just because file exists
        self.assertFalse(
            result, "start_dhcp_container must not return True when container is not running"
        )

    def test_check_status_does_not_infer_running_from_file_existence(self):
        """check_dhcp_container_status should not set container_running from file existence alone."""
        import socket as _socket_mod

        from dhcp_deploy import check_dhcp_container_status as real_check

        # socket is imported locally inside check_dhcp_container_status, so we patch
        # the real socket.socket constructor via sys.modules to intercept connect_ex.
        mock_sock = MagicMock()
        mock_sock.connect_ex.return_value = 1  # 1 = refused, not connected

        with (
            patch("dhcp_deploy.subprocess.run") as mock_run,
            patch("dhcp_deploy.get_podman_cmd", return_value=["podman"]),
            patch.object(_socket_mod, "socket", return_value=mock_sock),
        ):
            # systemctl returns non-zero (not active)
            mock_run.return_value = MagicMock(returncode=1, stdout="inactive", stderr="")

            status = real_check()

            # container_running must be False (no positive signals)
            self.assertFalse(
                status.get("container_running"),
                "container_running must not be True without positive runtime signals",
            )


class TestExpectedDaemons(unittest.TestCase):
    """#54: expected daemons are derived from the generated config files."""

    def test_expected_from_config_files(self):
        from dhcp_deploy import expected_dhcp_daemons

        with tempfile.TemporaryDirectory() as d:
            # v6-only deployment
            Path(d).mkdir(exist_ok=True)
            (Path(d) / "kea-dhcp6.conf").write_text("{}")
            self.assertEqual(expected_dhcp_daemons(Path(d)), {4: False, 6: True})

            # both families
            (Path(d) / "kea-dhcp4.conf").write_text("{}")
            self.assertEqual(expected_dhcp_daemons(Path(d)), {4: True, 6: True})

        with tempfile.TemporaryDirectory() as empty:
            self.assertEqual(expected_dhcp_daemons(Path(empty)), {4: False, 6: False})

    def test_expected_daemons_running_v6_only(self):
        import dhcp_deploy
        from dhcp_deploy import _expected_daemons_running

        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "kea-dhcp6.conf").write_text("{}")
            with patch.object(dhcp_deploy, "DHCP_CONFIG_DIR", Path(d)):
                # v6-only: ready when only kea-dhcp6 is up
                self.assertTrue(
                    _expected_daemons_running({"dhcp4_running": False, "dhcp6_running": True})
                )
                # missing the expected daemon is not ready
                self.assertFalse(
                    _expected_daemons_running({"dhcp4_running": True, "dhcp6_running": False})
                )

    def test_expected_daemons_running_falls_back_to_dhcp4(self):
        import dhcp_deploy
        from dhcp_deploy import _expected_daemons_running

        # No config files visible: historical behaviour requires kea-dhcp4.
        with tempfile.TemporaryDirectory() as empty:
            with patch.object(dhcp_deploy, "DHCP_CONFIG_DIR", Path(empty)):
                self.assertTrue(
                    _expected_daemons_running({"dhcp4_running": True, "dhcp6_running": False})
                )
                self.assertFalse(
                    _expected_daemons_running({"dhcp4_running": False, "dhcp6_running": True})
                )


class TestV6OnlyReadiness(unittest.TestCase):
    """#54: a v6-only deployment is reported healthy when kea-dhcp6 is up."""

    def _status(self, config_dir, daemons):
        import dhcp_deploy

        # systemctl and podman ps find nothing and the ctrl-agent port probe is
        # skipped, so health comes only from the per-daemon check.
        with (
            patch("dhcp_deploy.subprocess.run", return_value=MagicMock(returncode=1, stdout="")),
            patch("dhcp_deploy.get_podman_cmd", return_value=["podman"]),
            patch("dhcp_deploy._kea_ctrl_agent_host_port", side_effect=OSError("skip")),
            patch("dhcp_deploy._kea_daemons_in_container", return_value=daemons),
            patch.object(dhcp_deploy, "DHCP_CONFIG_DIR", Path(config_dir)),
        ):
            return dhcp_deploy.check_dhcp_container_status()

    def test_v6_only_is_healthy(self):
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "kea-dhcp6.conf").write_text("{}")
            status = self._status(d, {"dhcp4_running": False, "dhcp6_running": True})
        self.assertTrue(status["container_running"])
        self.assertEqual(status["service_status"], "active")

    def test_v6_only_degraded_when_expected_daemon_down(self):
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "kea-dhcp6.conf").write_text("{}")
            status = self._status(d, {"dhcp4_running": True, "dhcp6_running": False})
        self.assertEqual(status["service_status"], "degraded")

    def test_dual_stack_needs_both_daemons(self):
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "kea-dhcp4.conf").write_text("{}")
            (Path(d) / "kea-dhcp6.conf").write_text("{}")
            both = self._status(d, {"dhcp4_running": True, "dhcp6_running": True})
            v4_only = self._status(d, {"dhcp4_running": True, "dhcp6_running": False})
        self.assertEqual(both["service_status"], "active")
        self.assertEqual(v4_only["service_status"], "degraded")


if __name__ == "__main__":
    unittest.main()
