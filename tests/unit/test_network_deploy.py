#!/usr/bin/env python3
"""Unit tests for network_deploy quadlet rendering and apply/rollback."""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).parent.parent.parent / "webui"))

from network_deploy import (
    apply_ztp_network,
    get_network_status,
    render_pod_quadlet_content,
    restart_ztp_stack,
    restore_network_backup,
    stop_ztp_stack,
)


class TestNetworkDeploy(unittest.TestCase):
    def _enabled_config(self):
        return {
            "container": {"host_network": False},
            "dhcp": {"enabled": False},
            "network": {
                "ztp": {
                    "enabled": True,
                    "parent_interface": "enp7s0.5",
                    "podman_network": "ztp-net-5",
                    "macvlan_mode": "bridge",
                    "ipv4": {
                        "address": "10.0.5.10",
                        "subnet": "10.0.5.0/24",
                        "gateway": "10.0.5.1",
                    },
                }
            },
        }

    @patch("network_deploy.resolve_ipv6_for_network", side_effect=lambda ipv6, _net: ipv6)
    def test_render_macvlan_quadlet(self, _resolve_ipv6):
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

    @patch("network_deploy.inspect_running_pod", return_value={"running": True})
    @patch(
        "network_deploy.parse_pod_quadlet",
        return_value={"network": "ztp-net-5", "ipv4": "10.0.5.10"},
    )
    @patch(
        "network_deploy.inspect_podman_network",
        return_value={"parent": "enp9s0", "name": "ztp-net-5"},
    )
    def test_get_network_status_no_drift_when_parent_matches(self, _inspect_net, _quadlet, _pod):
        config = {
            "network": {
                "ztp": {
                    "enabled": True,
                    "status": "applied",
                    "parent_interface": "enp9s0",
                    "podman_network": "ztp-net-5",
                    "ipv4": {"address": "10.0.5.10", "subnet": "10.0.5.0/24"},
                }
            }
        }
        status = get_network_status(config)
        self.assertEqual(status["status"], "applied")
        self.assertFalse(status["drift"])
        self.assertEqual(status["drift_items"], [])

    @patch("network_deploy._run_systemctl")
    def test_stop_raises_on_systemctl_failure(self, mock_systemctl):
        mock_systemctl.return_value = subprocess.CompletedProcess([], 1, "", "unit not found")
        with self.assertRaises(RuntimeError) as ctx:
            stop_ztp_stack()
        self.assertIn("ztpbootstrap-dhcp.service", str(ctx.exception))
        self.assertIn("unit not found", str(ctx.exception))

    @patch("network_deploy._run_systemctl")
    def test_stop_skips_units_that_are_not_loaded(self, mock_systemctl):
        # systemctl exits 5 for a unit that is not installed (e.g. no DHCP
        # quadlet); that must not abort a network apply.
        mock_systemctl.side_effect = [
            subprocess.CompletedProcess([], 5, "", "Unit ztpbootstrap-dhcp.service not loaded."),
            subprocess.CompletedProcess([], 0, "", ""),
            subprocess.CompletedProcess([], 0, "", ""),
            subprocess.CompletedProcess([], 0, "", ""),
        ]
        stop_ztp_stack()
        self.assertEqual(mock_systemctl.call_count, 4)

    @patch("network_deploy.stop_ztp_stack")
    @patch("network_deploy._run_systemctl")
    def test_restart_reports_service_start_failure(self, mock_systemctl, _mock_stop):
        mock_systemctl.side_effect = [
            subprocess.CompletedProcess([], 0, "", ""),  # daemon-reload
            subprocess.CompletedProcess([], 1, "", "pod failed"),  # pod start
        ]

        success, error = restart_ztp_stack({})

        self.assertFalse(success)
        self.assertIn("ztpbootstrap-pod.service", error)
        self.assertIn("pod failed", error)

    def test_restore_network_backup_restores_config_and_pod(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            backup = tmp_path / "backup"
            backup.mkdir()
            (backup / "ztpbootstrap.pod").write_text("Network=ztp-net-5\n")
            (backup / "config.yaml").write_text("network:\n  ztp:\n    enabled: true\n")

            pod_dest = tmp_path / "systemd"
            pod_dest.mkdir()
            config_dest = tmp_path / "config"
            config_dest.mkdir()

            with (
                patch("network_deploy.POD_FILE", pod_dest / "ztpbootstrap.pod"),
                patch("network_deploy.CONFIG_PATH", config_dest / "config.yaml"),
            ):
                self.assertTrue(restore_network_backup(backup))
                self.assertEqual((pod_dest / "ztpbootstrap.pod").read_text(), "Network=ztp-net-5\n")
                self.assertIn("enabled: true", (config_dest / "config.yaml").read_text())

    @patch("network_deploy.network_apply_lock")
    @patch("network_deploy.restart_ztp_stack", return_value=(True, None))
    @patch("network_deploy._regenerate_kea_configs")
    @patch("network_deploy.ensure_podman_network", return_value=(True, None))
    @patch("network_deploy.inspect_podman_network", return_value=None)
    @patch("network_deploy.restore_network_backup", return_value=True)
    @patch("network_deploy.stop_ztp_stack")
    @patch("network_deploy.create_network_backup")
    @patch("network_deploy.remove_stale_network", return_value=(True, None))
    @patch("network_deploy.plan_network_changes")
    def test_apply_rollback_restores_network_kea_and_restart(
        self,
        mock_plan,
        _mock_remove,
        mock_backup,
        _mock_stop,
        mock_restore,
        mock_inspect,
        mock_ensure,
        mock_kea,
        mock_restart,
        mock_lock,
    ):
        current = self._enabled_config()
        desired = self._enabled_config()
        desired["network"]["ztp"]["ipv4"]["gateway"] = "10.0.5.254"

        with tempfile.TemporaryDirectory() as tmp:
            backup = Path(tmp) / "backup"
            backup.mkdir()
            (backup / "ztpbootstrap.pod").write_text("[Pod]\nNetwork=ztp-net-5\nIP=10.0.5.10\n")
            (backup / "config.yaml").write_text(
                "container:\n  host_network: false\n"
                "dhcp:\n  enabled: true\n"
                "network:\n  ztp:\n    enabled: true\n"
                "    parent_interface: enp7s0.5\n"
                "    podman_network: ztp-net-5\n"
                "    macvlan_mode: bridge\n"
                "    ipv4:\n"
                "      address: 10.0.5.10\n"
                "      subnet: 10.0.5.0/24\n"
                "      gateway: 10.0.5.1\n"
            )
            mock_backup.return_value = backup
            mock_lock.return_value.__enter__ = MagicMock(return_value=None)
            mock_lock.return_value.__exit__ = MagicMock(return_value=False)
            mock_plan.return_value = {
                "replace_network": False,
                "create_network": False,
                "remove_networks": ["ztp-net-5"],
                "update_quadlet": True,
                "restart_required": True,
            }

            with patch(
                "network_deploy.sync_pod_quadlet",
                side_effect=RuntimeError("quadlet write failed"),
            ):
                success, error, updated = apply_ztp_network(
                    desired, restart=True, current_config=current
                )

        self.assertFalse(success)
        self.assertEqual(error, "quadlet write failed")
        # app.py persists the returned config, so it must be the restored one
        # (old gateway) marked as errored, not the failed candidate.
        self.assertEqual(updated["network"]["ztp"]["ipv4"]["gateway"], "10.0.5.1")
        self.assertEqual(updated["network"]["ztp"]["status"], "error")
        self.assertEqual(updated["network"]["ztp"]["last_error"], "quadlet write failed")
        mock_restore.assert_called_once_with(backup)
        mock_inspect.assert_called()
        restored_profile = mock_ensure.call_args[0][0]
        self.assertEqual(restored_profile["podman_network"], "ztp-net-5")
        self.assertEqual(restored_profile["ipv4"]["gateway"], "10.0.5.1")
        mock_kea.assert_called()
        kea_config = mock_kea.call_args[0][0]
        self.assertTrue((kea_config.get("dhcp") or {}).get("enabled"))
        self.assertEqual(
            kea_config["network"]["ztp"]["ipv4"]["gateway"],
            "10.0.5.1",
        )
        mock_restart.assert_called_once()
        restart_config = mock_restart.call_args[0][0]
        self.assertEqual(restart_config["network"]["ztp"]["ipv4"]["gateway"], "10.0.5.1")


if __name__ == "__main__":
    unittest.main()
