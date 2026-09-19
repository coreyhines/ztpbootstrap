"""Regression tests for config.yaml writes in the WebUI (#48, #54, #58, #64)."""

import importlib.util
import os
import stat
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

import yaml

WEBUI = Path(__file__).resolve().parents[2] / "webui"
sys.path.insert(0, str(WEBUI))

FLASK_AVAILABLE = importlib.util.find_spec("flask") is not None

CSRF = "test-csrf-token"

BASE_CONFIG = {
    "auth": {"session_secret": "test-session-key"},
    "dhcp": {
        "enabled": False,
        "ipv4": {
            "subnet": "10.0.5.0/24",
            "range_start": "10.0.5.100",
            "range_end": "10.0.5.200",
            "gateway": "10.0.5.1",
        },
        "reservations": [],
    },
}


@unittest.skipUnless(FLASK_AVAILABLE, "Flask not installed")
class AppTestCase(unittest.TestCase):
    """Loads a private copy of app.py against a temp ZTP_CONFIG_DIR."""

    initial_config = BASE_CONFIG

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.config_dir = Path(self.tmp.name)
        (self.config_dir / "logs").mkdir()
        self.config_file = self.config_dir / "config.yaml"
        self.config_file.write_text(yaml.safe_dump(self.initial_config, sort_keys=False))
        os.chmod(self.config_file, 0o644)
        with patch.dict(os.environ, {"ZTP_CONFIG_DIR": self.tmp.name}):
            spec = importlib.util.spec_from_file_location(
                "config_writes_test_app", WEBUI / "app.py"
            )
            self.webapp = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(self.webapp)
        handler = self.webapp.security_handler
        self.addCleanup(handler.close)
        self.addCleanup(self.webapp.security_logger.removeHandler, handler)
        self.addCleanup(self.webapp.security_logger.removeHandler, self.webapp.console_handler)

    def client(self):
        client = self.webapp.app.test_client()
        with client.session_transaction() as sess:
            sess["authenticated"] = True
            sess["expires_at"] = 9999999999
            sess["csrf_token"] = CSRF
        return client

    def read_config(self):
        return yaml.safe_load(self.config_file.read_text())


class TestConfigWritesUseConfigManager(AppTestCase):
    def test_add_reservation_writes_0600_with_backup(self):
        self.assertIsNotNone(self.webapp.config_manager)
        with patch.object(self.webapp, "add_reservation", return_value=True):
            response = self.client().post(
                "/api/dhcp/reservations",
                json={"mac": "00:1c:73:aa:bb:cc", "ip": "10.0.5.50"},
                headers={"X-CSRF-Token": CSRF},
            )
        self.assertEqual(response.status_code, 200, response.get_json())

        self.assertEqual(stat.S_IMODE(self.config_file.stat().st_mode), 0o600)
        backups = list(self.config_dir.glob("config.backup.*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(yaml.safe_load(backups[0].read_text())["dhcp"]["reservations"], [])

        reservations = self.read_config()["dhcp"]["reservations"]
        self.assertEqual(
            reservations, [{"hw-address": "00:1c:73:aa:bb:cc", "ip-address": "10.0.5.50"}]
        )

    def test_writes_go_through_config_manager_update(self):
        calls = []
        real_update = self.webapp.config_manager.update

        def spy(*args, **kwargs):
            calls.append(args)
            return real_update(*args, **kwargs)

        with patch.object(self.webapp.config_manager, "update", side_effect=spy):
            with patch.object(self.webapp, "delete_reservation", return_value=True):
                response = self.client().delete(
                    "/api/dhcp/reservations/00%3A1c%3A73%3Aaa%3Abb%3Acc",
                    headers={"X-CSRF-Token": CSRF},
                )
        self.assertEqual(response.status_code, 200, response.get_json())
        self.assertEqual(len(calls), 1)

    def test_config_put_preserves_enabled_and_reservations(self):
        config = self.read_config()
        config["dhcp"]["enabled"] = True
        config["dhcp"]["reservations"] = [
            {"hw-address": "00:1c:73:00:00:01", "ip-address": "10.0.5.51"}
        ]
        self.config_file.write_text(yaml.safe_dump(config, sort_keys=False))

        form = dict(BASE_CONFIG["dhcp"], enabled=False, reservations=[])
        form["ipv4"] = dict(form["ipv4"], gateway="10.0.5.254")
        with (
            patch.object(self.webapp, "generate_kea_config", return_value={}),
            patch.object(self.webapp, "reload_config"),
        ):
            response = self.client().put(
                "/api/dhcp/config", json={"dhcp": form}, headers={"X-CSRF-Token": CSRF}
            )
        self.assertEqual(response.status_code, 200, response.get_json())
        dhcp = self.read_config()["dhcp"]
        self.assertTrue(dhcp["enabled"])
        self.assertEqual(dhcp["ipv4"]["gateway"], "10.0.5.254")
        self.assertEqual(len(dhcp["reservations"]), 1)

    def test_fallback_without_config_manager_is_atomic_and_private(self):
        with patch.object(self.webapp, "config_manager", None):
            ok, err, written = self.webapp._update_config(lambda c: c.update({"extra": 1}))
        self.assertTrue(ok, err)
        self.assertEqual(written["extra"], 1)
        self.assertEqual(self.read_config()["extra"], 1)
        self.assertEqual(stat.S_IMODE(self.config_file.stat().st_mode), 0o600)
        self.assertEqual(list(self.config_dir.glob(".config.yaml.*.tmp")), [])

    def test_failed_mutator_writes_nothing(self):
        before = self.config_file.read_text()

        def boom(_config):
            raise ValueError("nope")

        ok, err, written = self.webapp._update_config(boom)
        self.assertFalse(ok)
        self.assertIn("nope", err)
        self.assertIsNone(written)
        self.assertEqual(self.config_file.read_text(), before)


class TestConcurrentConfigWrites(AppTestCase):
    def test_add_reservation_and_config_save_lose_no_update(self):
        """Parallel reservation adds and DHCP form saves must all land (#48)."""
        n_adds, n_saves = 12, 6
        errors = []
        start = threading.Barrier(n_adds + n_saves)

        # The form holds a stale copy of the dhcp section (no reservations).
        form = dict(BASE_CONFIG["dhcp"], reservations=[])
        form["ipv4"] = dict(form["ipv4"], gateway="10.0.5.254")

        def add(i):
            try:
                client = self.client()
                start.wait()
                response = client.post(
                    "/api/dhcp/reservations",
                    json={"mac": f"00:1c:73:00:00:{i:02x}", "ip": f"10.0.5.{10 + i}"},
                    headers={"X-CSRF-Token": CSRF},
                )
                if response.status_code != 200:
                    errors.append(response.get_json())
            except Exception as e:  # pragma: no cover - reported below
                errors.append(repr(e))

        def save():
            try:
                client = self.client()
                start.wait()
                response = client.put(
                    "/api/dhcp/config", json={"dhcp": form}, headers={"X-CSRF-Token": CSRF}
                )
                if response.status_code != 200:
                    errors.append(response.get_json())
            except Exception as e:  # pragma: no cover - reported below
                errors.append(repr(e))

        threads = [threading.Thread(target=add, args=(i,)) for i in range(n_adds)]
        threads += [threading.Thread(target=save) for _ in range(n_saves)]
        with patch.object(self.webapp, "add_reservation", return_value=True):
            for t in threads:
                t.start()
            for t in threads:
                t.join(timeout=60)

        self.assertEqual(errors, [])
        dhcp = self.read_config()["dhcp"]
        self.assertEqual(dhcp["ipv4"]["gateway"], "10.0.5.254")
        macs = sorted(r["hw-address"] for r in dhcp["reservations"])
        self.assertEqual(macs, sorted(f"00:1c:73:00:00:{i:02x}" for i in range(n_adds)))


class TestKeaConfigFiles(AppTestCase):
    initial_config = {
        "auth": {"session_secret": "test-session-key"},
        "dhcp": {
            "enabled": True,
            "ipv6": {
                "subnet": "fd00:5::/64",
                "range_start": "fd00:5::100",
                "range_end": "fd00:5::200",
            },
        },
    }

    def test_stale_dhcp4_config_removed_on_v6_only_save(self):
        dhcp_dir = self.config_dir / "dhcp"
        dhcp_dir.mkdir()
        stale = dhcp_dir / "kea-dhcp4.conf"
        stale.write_text('{"Dhcp4": {}}')

        kea = {"Dhcp6": {"subnet6": []}, "Control-agent": {"http-port": 8000}}
        with (
            patch.object(self.webapp, "generate_kea_config", return_value=kea),
            patch.object(self.webapp, "reload_config"),
        ):
            response = self.client().put(
                "/api/dhcp/config",
                json={"dhcp": self.initial_config["dhcp"]},
                headers={"X-CSRF-Token": CSRF},
            )
        self.assertEqual(response.status_code, 200, response.get_json())
        self.assertFalse(stale.exists())
        self.assertTrue((dhcp_dir / "kea-dhcp6.conf").exists())
        self.assertTrue((dhcp_dir / "kea-ctrl-agent.conf").exists())

    def test_write_kea_config_files_removes_missing_family_only(self):
        dhcp_dir = self.config_dir / "dhcp"
        dhcp_dir.mkdir()
        (dhcp_dir / "kea-dhcp6.conf").write_text("{}")
        (dhcp_dir / "kea-ctrl-agent.conf").write_text("{}")
        self.webapp._write_kea_config_files({"Dhcp4": {"subnet4": []}})
        self.assertTrue((dhcp_dir / "kea-dhcp4.conf").exists())
        self.assertFalse((dhcp_dir / "kea-dhcp6.conf").exists())
        # The control agent is not tied to one address family; leave it alone.
        self.assertTrue((dhcp_dir / "kea-ctrl-agent.conf").exists())


class TestProcessedLogLines(AppTestCase):
    def test_merge_keeps_newest_in_order(self):
        previous = [f"old-{i}" for i in range(1500)]
        current = [f"old-{i}" for i in range(10)] + [f"new-{i}" for i in range(1000)]
        merged = self.webapp._merge_processed_lines(previous, current, limit=2000)
        self.assertEqual(len(merged), 2000)
        # Newest entries (this scan, in log order) are at the end.
        self.assertEqual(merged[-1000:], [f"new-{i}" for i in range(1000)])
        # Lines seen again move to the newest end rather than being dropped.
        self.assertEqual(merged[-1010:-1000], [f"old-{i}" for i in range(10)])
        # The oldest previously processed lines are the ones trimmed.
        self.assertNotIn("old-509", merged)
        self.assertEqual(merged[0], "old-510")

    def test_parse_log_caps_file_to_newest_lines(self):
        processed_file = self.config_dir / "processed_log_lines.txt"
        old = [f"MARK {i:05d}" for i in range(3000)]
        processed_file.write_text("\n".join(old) + "\n")

        log_file = self.config_dir / "access.log"
        log_lines = [
            f'10.0.5.{i} - - [19/Sep/2099:12:00:{i:02d} +0000] "GET /bootstrap.py HTTP/1.1" '
            f'200 1234 "-" "Arista-ZTP/1.0"'
            for i in range(10)
        ]
        log_file.write_text("\n".join(log_lines) + "\n")

        with patch.object(self.webapp, "NGINX_ACCESS_LOG", log_file):
            self.webapp.parse_nginx_access_log()

        saved = processed_file.read_text().splitlines()
        self.assertEqual(len(saved), 2000)
        self.assertEqual(saved[-10:], log_lines)
        self.assertEqual(saved[:1990], old[-1990:])


class TestBootstrapBackups(AppTestCase):
    def test_backup_is_moved_to_unique_name(self):
        target = self.config_dir / "bootstrap.py"
        names = set()
        for i in range(3):
            target.write_text(f"# v{i}\n")
            os.chmod(target, 0o644)
            backup = self.webapp._move_to_unique_backup(target)
            self.assertFalse(target.exists())
            self.assertEqual(backup.read_text(), f"# v{i}\n")
            self.assertEqual(stat.S_IMODE(backup.stat().st_mode), 0o644)
            names.add(backup.name)
        self.assertEqual(len(names), 3)
        self.assertEqual(len(list(self.config_dir.glob("bootstrap_backup_*.py"))), 3)

    def test_backup_timestamp_parsing(self):
        ts = self.webapp._backup_timestamp
        self.assertEqual(ts("bootstrap_backup_1700000000.py"), 1700000000)
        self.assertEqual(ts("bootstrap_backup_1700000000_123456.py"), 1700000000)
        self.assertEqual(ts("bootstrap_backup_1700000000_123456_2.py"), 1700000000)
        self.assertIsNone(ts("bootstrap_backup_manual.py"))

    def test_backup_list_uses_name_then_mtime(self):
        (self.config_dir / "bootstrap_backup_1700000000_000001.py").write_text("a")
        odd = self.config_dir / "bootstrap_backup_manual.py"
        odd.write_text("b")
        os.utime(odd, (1600000000, 1600000000))
        response = self.client().get("/api/bootstrap-scripts/backups")
        self.assertEqual(response.status_code, 200)
        by_name = {b["name"]: b["timestamp"] for b in response.get_json()["backups"]}
        self.assertEqual(by_name["bootstrap_backup_1700000000_000001.py"], 1700000000)
        self.assertEqual(by_name["bootstrap_backup_manual.py"], 1600000000)


class TestSessionSecretPersistence(AppTestCase):
    initial_config = {"dhcp": {"enabled": False}}

    def test_generated_secret_persisted_via_config_manager(self):
        config = self.read_config()
        self.assertEqual(
            config["auth"]["session_secret"], self.webapp.AUTH_CONFIG["session_secret"]
        )
        self.assertEqual(config["dhcp"], {"enabled": False})
        self.assertEqual(stat.S_IMODE(self.config_file.stat().st_mode), 0o600)


if __name__ == "__main__":
    unittest.main()
