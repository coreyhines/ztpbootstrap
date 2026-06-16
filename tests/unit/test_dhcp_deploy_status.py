#!/usr/bin/env python3
"""Tests for dhcp_deploy container status — verifies no fail-open behavior."""

import os
import sys
import unittest
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


if __name__ == "__main__":
    unittest.main()
