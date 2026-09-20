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


class TestHostTransaction(unittest.TestCase):
    """Real config/quadlet persistence with controlled host failures and concurrency."""

    def setUp(self):
        from contextlib import ExitStack

        import network_deploy as deploy
        import yaml
        from config_manager import ConfigManager

        self.deploy = deploy
        self.resources = ExitStack()
        self.addCleanup(self.resources.close)
        self.root = Path(self.resources.enter_context(tempfile.TemporaryDirectory()))
        self.config_path = self.root / "config.yaml"
        self.config = TestNetworkDeploy()._enabled_config()
        self.config["network"]["ztp"]["vlan_id"] = 5
        self.config["auth"] = {"keep": "original"}
        self.config_path.write_text(yaml.safe_dump(self.config))
        self.manager = ConfigManager(self.config_path)
        self.pod_path = self.root / "ztpbootstrap.pod"
        self.pod_path.write_text("[Pod]\nPodName=ztpbootstrap\nNetwork=ztp-net-5\nIP=10.0.5.10\n")
        self.network = {
            "name": "ztp-net-5",
            "driver": "macvlan",
            "parent": "enp7s0.5",
            "mode": "bridge",
            "subnets": [{"subnet": "10.0.5.0/24", "gateway": "10.0.5.1"}],
            "containers": [],
        }
        self.resources.enter_context(patch("network_deploy.POD_FILE", self.pod_path))
        self.resources.enter_context(
            patch("network_deploy.inspect_podman_network", return_value=self.network)
        )
        self.ensure = self.resources.enter_context(
            patch("network_deploy.ensure_podman_network", return_value=(True, None))
        )
        self.stop = self.resources.enter_context(patch("network_deploy.stop_ztp_stack"))
        self.start = self.resources.enter_context(patch("network_deploy.start_ztp_stack"))
        self.kea = self.resources.enter_context(patch("network_deploy._regenerate_kea_configs"))
        self.verify = self.resources.enter_context(patch("network_deploy.verify_effective_stack"))
        self.profile = self.config["network"]["ztp"].copy()
        self.profile["ipv4"] = dict(self.profile["ipv4"], address="10.0.5.20")

    def execute(self):
        import time

        return self.deploy.execute_host_job(
            self.manager,
            "apply",
            self.profile,
            self.root / "snapshot",
            deadline=time.monotonic() + 10,
        )

    def test_restart_uses_host_lifetime_without_rewriting_config(self):
        import time

        before = self.config_path.read_bytes()
        result = self.deploy.execute_host_job(
            self.manager,
            "restart",
            None,
            self.root / "snapshot",
            deadline=time.monotonic() + 10,
        )
        self.assertEqual(result["state"], "succeeded")
        self.assertTrue(result["effective_applied"])
        self.assertEqual(self.config_path.read_bytes(), before)
        self.ensure.assert_not_called()
        self.stop.assert_called_once()
        self.start.assert_called_once()
        self.verify.assert_called_once()

    def test_success_preserves_concurrent_unrelated_edits(self):
        def concurrent_edit(_profile):
            self.manager.update(lambda fresh: fresh["auth"].update(keep="concurrent"))
            self.manager.update(
                lambda fresh: fresh["dhcp"].update(reservations=[{"ip": "10.0.5.99"}])
            )
            return True, None

        self.ensure.side_effect = concurrent_edit
        result = self.execute()
        self.assertEqual(result["state"], "succeeded")
        final = self.manager.read_config()
        self.assertEqual(final["auth"]["keep"], "concurrent")
        self.assertEqual(final["dhcp"]["reservations"][0]["ip"], "10.0.5.99")
        self.assertEqual(final["network"]["ztp"]["status"], "applied")
        self.assertEqual(final["network"]["ztp"]["ipv4"]["address"], "10.0.5.20")
        self.assertTrue((self.root / "snapshot" / "recovery.json").exists())
        self.assertEqual((self.root / "snapshot" / "recovery.json").stat().st_mode & 0o777, 0o600)

    def test_rollback_preserves_concurrent_auth_and_restores_only_network(self):
        original_pod = self.pod_path.read_text()

        self.kea.side_effect = [OSError("disk full"), None]
        self.verify.side_effect = None
        self.start.side_effect = lambda **_kwargs: self.manager.update(
            lambda fresh: fresh["auth"].update(keep="during failure")
        )
        result = self.execute()
        self.assertEqual(result["state"], "failed")
        final = self.manager.read_config()
        self.assertEqual(final["auth"]["keep"], "during failure")
        self.assertEqual(final["network"]["ztp"]["ipv4"]["address"], "10.0.5.10")
        self.assertEqual(self.pod_path.read_text(), original_pod)
        self.assertEqual(self.kea.call_count, 2)
        self.verify.assert_called_once()

    def test_rollback_failure_is_distinct(self):
        self.start.side_effect = RuntimeError("service failed")
        result = self.execute()
        self.assertEqual(result["state"], "rollback_failed")
        self.assertEqual(result["error_code"], "rollback_failed")
        self.assertFalse(result["effective_applied"])

    def test_managed_concurrent_edit_is_never_overwritten(self):
        def concurrent_edit(_profile):
            self.manager.update(
                lambda fresh: fresh["network"]["ztp"]["ipv4"].update(address="10.0.5.77")
            )
            return True, None

        self.ensure.side_effect = concurrent_edit
        result = self.execute()
        self.assertEqual(result["state"], "rollback_failed")
        self.assertEqual(
            self.manager.read_config()["network"]["ztp"]["ipv4"]["address"], "10.0.5.77"
        )

    def test_partial_stop_failure_attempts_recovery(self):
        self.stop.side_effect = [RuntimeError("partial stop"), None]
        result = self.execute()
        self.assertEqual(result["state"], "failed")
        self.assertEqual(self.stop.call_count, 2)
        self.start.assert_called_once()

    def test_timeout_recovery_finishes_before_return(self):
        self.ensure.side_effect = [
            subprocess.TimeoutExpired("podman", 1),
            (True, None),
            (True, None),
        ]
        result = self.execute()
        self.assertEqual(result["state"], "failed")
        self.assertEqual(result["error_code"], "timeout")
        self.start.assert_called_once()
        self.verify.assert_called_once()

    def test_unsafe_quadlet_is_rejected_before_stopping(self):
        self.pod_path.unlink()
        self.pod_path.symlink_to(self.config_path)
        result = self.execute()
        self.assertEqual(result["state"], "failed")
        self.stop.assert_not_called()

    def test_failed_postcheck_never_reports_effective_success(self):
        self.verify.side_effect = [RuntimeError("wrong actual address"), None]
        result = self.execute()
        self.assertEqual(result["state"], "failed")
        self.assertFalse(result["effective_applied"])
        self.assertEqual(
            self.manager.read_config()["network"]["ztp"]["ipv4"]["address"], "10.0.5.10"
        )


class TestHostBoundaries(unittest.TestCase):
    def test_host_manager_rejects_symlink_config_lock_and_hardlink(self):
        import os

        from network_deploy import HostConfigManager

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            victim = root / "victim"
            victim.write_text("auth: secret\n")
            path = root / "config.yaml"
            manager = HostConfigManager(path, root / "backups")
            self.addCleanup(manager.close)
            path.symlink_to(victim)
            ok, _ = manager.update(lambda fresh: fresh.update(auth="changed"))
            self.assertFalse(ok)
            self.assertEqual(victim.read_text(), "auth: secret\n")
            path.unlink()
            os.link(victim, path)
            ok, _ = manager.update(lambda fresh: fresh.update(auth="changed"))
            self.assertFalse(ok)
            path.unlink()
            path.write_text("network: {}\n")
            manager.lock_path.unlink()
            manager.lock_path.symlink_to(victim)
            ok, _ = manager.update(lambda fresh: fresh.update(auth="changed"))
            self.assertFalse(ok)
            self.assertEqual(victim.read_text(), "auth: secret\n")

    def test_host_manager_backup_is_outside_container_directory(self):
        from network_deploy import HostConfigManager

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            shared = root / "shared"
            shared.mkdir()
            path = shared / "config.yaml"
            path.write_text("auth: original\n")
            manager = HostConfigManager(path, root / "host" / "backups")
            self.addCleanup(manager.close)
            self.assertTrue(manager.update(lambda fresh: fresh.update(auth="changed"))[0])
            self.assertEqual(manager.read_config()["auth"], "changed")
            self.assertEqual(list(shared.glob("*.backup.*")), [])
            self.assertEqual(len(list((root / "host" / "backups").glob("*.yaml"))), 1)

    def test_kea_errors_propagate_and_directory_symlinks_are_rejected(self):
        from network_deploy import _regenerate_kea_configs

        with patch(
            "dhcp_config.generate_kea_config",
            side_effect=ValueError("invalid Kea config"),
        ):
            with self.assertRaises(ValueError):
                _regenerate_kea_configs({"dhcp": {"enabled": True}})
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            outside = root / "outside"
            outside.mkdir()
            (root / "dhcp").symlink_to(outside, target_is_directory=True)
            with patch("dhcp_config.generate_kea_config", return_value={"Dhcp4": {}}):
                with self.assertRaises(OSError):
                    _regenerate_kea_configs({"dhcp": {"enabled": True}}, root)
            self.assertEqual(list(outside.iterdir()), [])

    def test_subprocess_timeout_reaps_children_before_return(self):
        import time

        from network_deploy import _bounded_run

        with tempfile.TemporaryDirectory() as tmp:
            marker = Path(tmp) / "orphan"
            child = "import time,pathlib; time.sleep(.5); pathlib.Path(%r).write_text('bad')" % str(
                marker
            )
            parent = (
                "import subprocess,sys; p=subprocess.Popen([sys.executable,'-c',%r]); p.wait()"
                % child
            )
            with self.assertRaises(subprocess.TimeoutExpired):
                _bounded_run([sys.executable, "-c", parent], timeout=0.1)
            time.sleep(0.6)
            self.assertFalse(marker.exists())

    def test_systemctl_timeout_cancels_exact_pending_job(self):
        import network_deploy as deploy

        with patch("network_deploy._bounded_run") as run:
            run.side_effect = [
                subprocess.TimeoutExpired("systemctl", 1),
                subprocess.CompletedProcess([], 0, "321\n", ""),
                subprocess.CompletedProcess([], 0, "", ""),
            ]
            with self.assertRaises(subprocess.TimeoutExpired):
                deploy._run_systemctl(["start", "ztpbootstrap-webui.service"], timeout=1)
            self.assertEqual(run.call_args_list[-1].args[0][-2:], ["cancel", "321"])

    def test_postcheck_uses_actual_infra_address(self):
        import json

        import network_deploy as deploy

        config = TestNetworkDeploy()._enabled_config()
        with (
            patch(
                "network_deploy._run_systemctl",
                return_value=subprocess.CompletedProcess([], 0),
            ),
            patch("network_deploy.inspect_running_pod", return_value={"running": True}),
            patch("network_deploy._run_podman") as run,
        ):
            run.side_effect = [
                subprocess.CompletedProcess([], 0, "a" * 64, ""),
                subprocess.CompletedProcess(
                    [],
                    0,
                    json.dumps({"Networks": {"ztp-net-5": {"IPAddress": "10.0.5.99"}}}),
                    "",
                ),
            ]
            with self.assertRaisesRegex(RuntimeError, "address differs"):
                deploy.verify_effective_stack(config)
