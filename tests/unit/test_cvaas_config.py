#!/usr/bin/env python3
"""Unit tests for CVaaS configuration helpers."""

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

WEBUI_DIR = Path(__file__).resolve().parents[2] / "webui"
if str(WEBUI_DIR) not in sys.path:
    sys.path.insert(0, str(WEBUI_DIR))

spec = importlib.util.spec_from_file_location("cvaas_config", WEBUI_DIR / "cvaas_config.py")
cvaas_config = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(cvaas_config)


class TestValidateEnrollChars(unittest.TestCase):
    def test_rejects_empty(self):
        valid, error, warning = cvaas_config.validate_enroll_chars("")
        self.assertFalse(valid)
        self.assertIn("required", error or "")
        self.assertIsNone(warning)

    def test_accepts_jwt_with_short_warning(self):
        value = "short-but-nonempty"
        valid, error, warning = cvaas_config.validate_enroll_chars(value)
        self.assertTrue(valid)
        self.assertIsNone(error)
        self.assertIn("short", warning or "")

    def test_accepts_typical_jwt_without_warning(self):
        value = "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.test.token.here"
        valid, error, warning = cvaas_config.validate_enroll_chars(value)
        self.assertTrue(valid)
        self.assertIsNone(error)
        self.assertIsNone(warning)


class TestSyncEnrollCharsToBootstrap(unittest.TestCase):
    def test_updates_enroll_chars_line(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            bootstrap = Path(tmpdir) / "bootstrap.py"
            bootstrap.write_text(
                'cvAddr = "www.arista.io"\n' 'enrollChars = "OLD_VALUE"\n' 'cvproxy = ""\n',
                encoding="utf-8",
            )

            ok, error = cvaas_config.sync_enroll_chars_to_bootstrap(
                bootstrap, "eyJhbGciOiJSUzI1NiJ9.new.token"
            )
            self.assertTrue(ok, error)
            content = bootstrap.read_text(encoding="utf-8")
            self.assertIn("enrollChars = ", content)
            self.assertIn("eyJhbGciOiJSUzI1NiJ9.new.token", content)
            self.assertNotIn("OLD_VALUE", content)
            backups = list(Path(tmpdir).glob("bootstrap_backup_*.py"))
            self.assertEqual(len(backups), 1)

    def test_fails_when_line_missing(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            bootstrap = Path(tmpdir) / "bootstrap.py"
            bootstrap.write_text('cvAddr = "www.arista.io"\n', encoding="utf-8")

            ok, error = cvaas_config.sync_enroll_chars_to_bootstrap(bootstrap, "token")
            self.assertFalse(ok)
            self.assertIn("not found", error or "")


if __name__ == "__main__":
    unittest.main()
