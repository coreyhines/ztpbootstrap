#!/usr/bin/env python3
"""
Unit tests for ConfigManager class
Tests thread-safe configuration file management
"""

import fcntl
import os
import stat
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock

# Add webui directory to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../../webui"))

try:
    from config_manager import ConfigManager
except ImportError:
    ConfigManager = None


@unittest.skipIf(ConfigManager is None, "ConfigManager not available")
class TestConfigManager(unittest.TestCase):
    """Test cases for ConfigManager"""

    def setUp(self):
        """Create a temporary config file for testing"""
        self.temp_dir = tempfile.mkdtemp()
        self.config_path = Path(self.temp_dir) / "test_config.yaml"

        # Create initial config
        with open(self.config_path, "w") as f:
            f.write("test_key: test_value\n")

        self.config_manager = ConfigManager(self.config_path)

    def tearDown(self):
        """Clean up temporary files"""
        import shutil

        if os.path.exists(self.temp_dir):
            shutil.rmtree(self.temp_dir)

    def test_read_config(self):
        """Test reading configuration"""
        config = self.config_manager.read_config()
        self.assertIsInstance(config, dict)
        self.assertEqual(config.get("test_key"), "test_value")

    def test_write_config(self):
        """Test writing configuration"""
        new_config = {"new_key": "new_value"}
        self.config_manager.write_config(new_config)

        # Read back and verify
        config = self.config_manager.read_config()
        self.assertEqual(config.get("new_key"), "new_value")

    def test_update_section(self):
        """Test updating a single section"""
        success, error = self.config_manager.update_section("dhcp", {"enabled": True})
        self.assertTrue(success)
        self.assertIsNone(error)

        # Verify update
        config = self.config_manager.read_config()
        self.assertEqual(config.get("dhcp"), {"enabled": True})

    def test_update_section_with_validation(self):
        """Test updating section with validation"""

        def validator(config):
            if "dhcp" in config and config["dhcp"].get("enabled"):
                return True, None
            return False, "DHCP must be enabled"

        # Should succeed
        success, error = self.config_manager.update_section(
            "dhcp", {"enabled": True}, validate=validator
        )
        self.assertTrue(success)

        # Should fail
        success, error = self.config_manager.update_section(
            "dhcp", {"enabled": False}, validate=validator
        )
        self.assertFalse(success)
        self.assertIn("DHCP must be enabled", error)

    def test_backup_creation(self):
        """Test that backups are created"""
        initial_config = {"key1": "value1"}
        self.config_manager.write_config(initial_config)

        # Update config (should create backup)
        new_config = {"key2": "value2"}
        self.config_manager.write_config(new_config)

        # Check that backup exists
        backup_files = list(Path(self.temp_dir).glob("test_config.backup.*"))
        self.assertGreater(len(backup_files), 0, "Backup file should be created")

    def test_backup_cleanup(self):
        """Test that old backups are cleaned up"""
        # Create more backups than max_backups
        config_manager = ConfigManager(self.config_path, max_backups=3)

        for i in range(5):
            config = {f"key{i}": f"value{i}"}
            config_manager.write_config(config)

        # Check that only max_backups are kept
        backup_files = list(Path(self.temp_dir).glob("test_config.backup.*"))
        self.assertLessEqual(len(backup_files), 3, "Should keep at most 3 backups")

    def _mode(self, path):
        return stat.S_IMODE(os.stat(path).st_mode)

    def test_write_is_atomic_replace(self):
        """#17: writes go through a temp file + rename, never truncate in place"""
        old_inode = os.stat(self.config_path).st_ino
        self.config_manager.write_config({"a": 1})
        self.assertNotEqual(os.stat(self.config_path).st_ino, old_inode)
        leftovers = [p.name for p in Path(self.temp_dir).iterdir() if p.name.endswith(".tmp")]
        self.assertEqual(leftovers, [])

    def test_failed_write_leaves_original_intact(self):
        """#17: a crash mid-dump must not leave a truncated config.yaml"""
        with mock.patch("config_manager.yaml.dump", side_effect=RuntimeError("boom")):
            with self.assertRaises(RuntimeError):
                self.config_manager.write_config({"a": 1})
        self.assertEqual(self.config_manager.read_config(), {"test_key": "test_value"})
        leftovers = [p.name for p in Path(self.temp_dir).iterdir() if p.name.endswith(".tmp")]
        self.assertEqual(leftovers, [])

    def test_config_and_backups_are_0600(self):
        """#67: config.yaml, its backups and the lock file are owner-only"""
        os.chmod(self.config_path, 0o644)
        self.config_manager.write_config({"a": 1})
        self.assertEqual(self._mode(self.config_path), 0o600)
        backups = list(Path(self.temp_dir).glob("test_config.backup.*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(self._mode(backups[0]), 0o600)
        self.assertEqual(self._mode(self.config_manager.lock_path), 0o600)

    def test_new_config_file_is_0600(self):
        """#67: a config.yaml created by update() is owner-only"""
        path = Path(self.temp_dir) / "fresh.yaml"
        manager = ConfigManager(path)
        success, error = manager.update_section("auth", {"x": 1})
        self.assertTrue(success, error)
        self.assertEqual(self._mode(path), 0o600)
        self.assertEqual(manager.read_config(), {"auth": {"x": 1}})

    def test_backup_names_unique_within_same_instant(self):
        """#58: same-timestamp writes must not clobber each other's backups"""
        manager = ConfigManager(self.config_path, max_backups=50)
        with mock.patch("time.time_ns", return_value=1_700_000_000_123_456_789):
            for i in range(4):
                manager.write_config({"n": i})
        backups = sorted(p.name for p in Path(self.temp_dir).glob("test_config.backup.*"))
        self.assertEqual(
            backups,
            [
                "test_config.backup.1700000000_123456",
                "test_config.backup.1700000000_123456_1",
                "test_config.backup.1700000000_123456_2",
                "test_config.backup.1700000000_123456_3",
            ],
        )

    def test_rapid_writes_keep_every_backup(self):
        """#58: back-to-back writes each produce their own backup"""
        manager = ConfigManager(self.config_path, max_backups=50)
        for i in range(10):
            manager.write_config({"n": i})
        backups = list(Path(self.temp_dir).glob("test_config.backup.*"))
        self.assertEqual(len(backups), 10)

    def test_update_mutator_in_place(self):
        """update() passes the current config to the mutator and writes it back"""

        def mutate(config):
            config["dhcp"] = {"enabled": True}

        success, error = self.config_manager.update(mutate)
        self.assertTrue(success, error)
        self.assertEqual(
            self.config_manager.read_config(),
            {"test_key": "test_value", "dhcp": {"enabled": True}},
        )

    def test_update_mutator_returning_new_dict(self):
        """update() writes a dict returned by the mutator"""
        success, error = self.config_manager.update(lambda config: {"only": 1})
        self.assertTrue(success, error)
        self.assertEqual(self.config_manager.read_config(), {"only": 1})

    def test_update_mutator_exception_aborts_without_write(self):
        """A mutator that raises aborts the update and nothing is written"""

        def mutate(config):
            config["test_key"] = "changed"
            raise ValueError("bad reservation")

        success, error = self.config_manager.update(mutate)
        self.assertFalse(success)
        self.assertIn("bad reservation", error)
        self.assertEqual(self.config_manager.read_config(), {"test_key": "test_value"})
        self.assertEqual(list(Path(self.temp_dir).glob("test_config.backup.*")), [])

    def test_update_multiple_sections(self):
        """update_multiple_sections still sets every section"""
        success, error = self.config_manager.update_multiple_sections({"a": 1, "b": 2})
        self.assertTrue(success, error)
        self.assertEqual(
            self.config_manager.read_config(), {"test_key": "test_value", "a": 1, "b": 2}
        )

    def test_concurrent_updates_are_not_lost(self):
        """#18: RMW holds the file lock across read and write, across managers"""
        self.config_manager.write_config({"counter": 0})
        # Separate managers have separate thread locks, so only the flock on
        # the sidecar file serializes them, the same as separate processes.
        managers = [ConfigManager(self.config_path, max_backups=2) for _ in range(4)]
        errors = []

        def bump(config):
            config["counter"] = config["counter"] + 1

        def worker(manager):
            for _ in range(15):
                ok, err = manager.update(bump, timeout=30)
                if not ok:
                    errors.append(err)

        threads = [threading.Thread(target=worker, args=(m,)) for m in managers]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.assertEqual(errors, [])
        self.assertEqual(self.config_manager.read_config()["counter"], 60)

    def _hold_file_lock(self):
        fd = os.open(self.config_manager.lock_path, os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
        self.addCleanup(os.close, fd)
        return fd

    def test_read_times_out_when_file_locked(self):
        """#48: timeout is honored when another process holds the lock"""
        self._hold_file_lock()
        with self.assertRaises(TimeoutError):
            self.config_manager.read_config(timeout=0.2)

    def test_write_times_out_when_file_locked(self):
        """#48: write_config raises TimeoutError and leaves the file alone"""
        self._hold_file_lock()
        with self.assertRaises(TimeoutError):
            self.config_manager.write_config({"a": 1}, timeout=0.2)
        with open(self.config_path) as f:
            self.assertEqual(f.read(), "test_key: test_value\n")

    def test_update_section_reports_timeout(self):
        """#48: update_section returns (False, msg) on lock timeout"""
        self._hold_file_lock()
        success, error = self.config_manager.update_section("dhcp", {}, timeout=0.2)
        self.assertFalse(success)
        self.assertIn("Timed out", error)

    def test_timeout_on_thread_lock(self):
        """#48: timeout also bounds the wait for the in-process lock"""
        self.config_manager._lock.acquire()
        try:
            with self.assertRaises(TimeoutError):
                self.config_manager.read_config(timeout=0.1)
        finally:
            self.config_manager._lock.release()

    def test_lock_released_after_timeout_holder_exits(self):
        """Once the other holder releases, the lock is acquired within timeout"""
        fd = os.open(self.config_manager.lock_path, os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
        timer = threading.Timer(0.2, lambda: (fcntl.flock(fd, fcntl.LOCK_UN), os.close(fd)))
        timer.start()
        try:
            self.assertEqual(self.config_manager.read_config(timeout=5)["test_key"], "test_value")
        finally:
            timer.join()


if __name__ == "__main__":
    unittest.main()
