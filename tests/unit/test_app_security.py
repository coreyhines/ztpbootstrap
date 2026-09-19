"""Regression tests for the WebUI API security boundary."""

import ast
import base64
import hashlib
import hmac
import importlib.util
import io
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import yaml

WEBUI = Path(__file__).resolve().parents[2] / "webui"
sys.path.insert(0, str(WEBUI))


class TestAppSecurity(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.config_file = Path(self.tmp.name) / "config.yaml"
        self.config_file.write_text("auth:\n  session_secret: test-session-key\n")
        with patch.dict(os.environ, {"ZTP_CONFIG_DIR": self.tmp.name}):
            spec = importlib.util.spec_from_file_location("security_test_app", WEBUI / "app.py")
            self.webapp = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(self.webapp)
        handler = self.webapp.security_handler
        self.addCleanup(handler.close)
        self.addCleanup(self.webapp.security_logger.removeHandler, handler)
        self.addCleanup(self.webapp.security_logger.removeHandler, self.webapp.console_handler)
        self.client = self.webapp.app.test_client()

    def authenticate(self, expired=False):
        with self.client.session_transaction() as session:
            session["authenticated"] = True
            session["csrf_token"] = "test-csrf"
            if expired:
                session["expires_at"] = 1

    def test_private_api_routes_require_auth(self):
        for path in (
            "/api/dhcp/leases",
            "/api/logs",
            "/api/device-connections",
            "/api/bootstrap-script/x.py",
            "/api/config",
            "/api/bootstrap-scripts",
            "/api/bootstrap-scripts/backups",
            "/api/auth/logout",
            "/api/future-route",
            "/api/status/extra",
        ):
            for method in ("GET", "POST", "DELETE"):
                with self.subTest(path=path, method=method):
                    response = self.client.open(path, method=method)
                    self.assertEqual(response.status_code, 401)
                    self.assertEqual(response.json["code"], "AUTH_REQUIRED")

    def test_expired_session_is_rejected(self):
        self.authenticate(expired=True)
        self.assertEqual(self.client.get("/api/config").status_code, 401)

    def test_public_endpoints_pass_gate(self):
        for path, method in (
            ("/api/auth/status", "GET"),
            ("/api/auth/login", "POST"),
            ("/api/status", "GET"),
            ("/api/dhcp/status", "GET"),
            ("/", "GET"),
        ):
            with self.subTest(path=path):
                rule = next(
                    rule for rule in self.webapp.app.url_map.iter_rules() if rule.rule == path
                )
                with patch.dict(
                    self.webapp.app.view_functions, {rule.endpoint: lambda: ("public", 200)}
                ):
                    self.assertEqual(self.client.open(path, method=method).status_code, 200)

    def test_config_redacts_both_representations_without_changing_file(self):
        config = {
            "auth": {"session_secret": "secret-value", "admin_password_hash": "hash-value"},
            "cvaas": {"enroll_chars": "enroll-value", "enabled": True},
            "nested": [{"DatabasePassword": "nested-value", "port": 123}],
        }
        original = yaml.safe_dump(config)
        self.config_file.write_text(original)
        self.authenticate()
        response = self.client.get("/api/config")
        self.assertEqual(response.status_code, 200)
        for secret in (
            "session_secret",
            "admin_password_hash",
            "enroll_chars",
            "DatabasePassword",
            "secret-value",
            "hash-value",
            "enroll-value",
            "nested-value",
        ):
            self.assertNotIn(secret, response.get_data(as_text=True))
        self.assertEqual(yaml.safe_load(response.json["raw"]), response.json["parsed"])
        self.assertEqual(response.json["parsed"]["nested"], [{"port": 123}])
        self.assertTrue(response.json["parsed"]["cvaas"]["enabled"])
        self.assertEqual(self.config_file.read_text(), original)

    def test_malformed_config_does_not_expose_raw_secrets(self):
        self.config_file.write_text("auth: [\nsession_secret: secret-value")
        self.authenticate()
        response = self.client.get("/api/config")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json["raw"], "")
        self.assertIsNone(response.json["parsed"])
        self.assertNotIn("secret-value", response.get_data(as_text=True))

    def test_upload_limit(self):
        self.authenticate()
        limit = self.webapp.app.config["MAX_CONTENT_LENGTH"]
        self.assertEqual(limit, 10 * 1024 * 1024)
        response = self.client.post(
            "/api/bootstrap-script/upload",
            data={"file": (io.BytesIO(b"x" * (limit + 1)), "bootstrap_test.py")},
            headers={"X-CSRF-Token": "test-csrf"},
        )
        self.assertEqual(response.status_code, 413)
        self.assertFalse((Path(self.tmp.name) / "bootstrap_test.py").exists())

    def test_existing_csrf_protection_remains(self):
        self.authenticate()
        response = self.client.post("/api/bootstrap-script/upload")
        self.assertEqual(response.status_code, 403)
        response = self.client.post(
            "/api/bootstrap-script/upload", headers={"X-CSRF-Token": "test-csrf"}
        )
        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.json["error"], "No file provided")

    def test_legacy_password_checks_use_constant_time_comparison(self):
        password = "Legacy-password-123!"
        digest = hashlib.pbkdf2_hmac("sha256", password.encode(), b"ztpbootstrap", 100000)
        legacy_hash = "pbkdf2:sha256:" + base64.b64encode(digest).decode()
        for endpoint in ("/api/auth/login", "/api/auth/change-password"):
            for valid in (False, True):
                with self.subTest(endpoint=endpoint, valid=valid):
                    self.config_file.write_text(
                        yaml.safe_dump(
                            {
                                "auth": {
                                    "session_secret": "test-session-key",
                                    "admin_password_hash": legacy_hash,
                                }
                            }
                        )
                    )
                    self.webapp.AUTH_CONFIG["admin_password_hash"] = legacy_hash
                    self.authenticate()
                    candidate = password if valid else "incorrect"
                    with patch.object(
                        self.webapp.hmac, "compare_digest", wraps=hmac.compare_digest
                    ) as compare:
                        response = self.client.post(
                            endpoint,
                            json={
                                "password": candidate,
                                "current_password": candidate,
                                "new_password": "New-password-456!",
                            },
                            headers={"X-CSRF-Token": "test-csrf"},
                        )
                    expected = hashlib.pbkdf2_hmac(
                        "sha256", candidate.encode(), b"ztpbootstrap", 100000
                    )
                    compare.assert_any_call(digest, expected)
                    self.assertEqual(response.status_code, 200 if valid else 401)

    def test_legacy_post_change_verification_uses_constant_time_comparison(self):
        password = "Legacy-password-123!"
        digest = hashlib.pbkdf2_hmac("sha256", password.encode(), b"ztpbootstrap", 100000)
        self.webapp.AUTH_CONFIG["admin_password_hash"] = (
            "pbkdf2:sha256:" + base64.b64encode(digest).decode()
        )
        self.authenticate()
        with (
            patch.object(self.webapp, "generate_password_hash", side_effect=ImportError),
            patch.object(self.webapp, "check_password_hash", side_effect=ImportError),
            patch.object(self.webapp.hmac, "compare_digest", wraps=hmac.compare_digest) as compare,
        ):
            response = self.client.post(
                "/api/auth/change-password",
                json={"current_password": password, "new_password": "New-password-456!"},
                headers={"X-CSRF-Token": "test-csrf"},
            )
        self.assertEqual(response.status_code, 200)
        new_digest = hashlib.pbkdf2_hmac("sha256", b"New-password-456!", b"ztpbootstrap", 100000)
        compare.assert_any_call(new_digest, new_digest)

    def test_development_server_binds_loopback(self):
        tree = ast.parse((WEBUI / "app.py").read_text())
        main = next(
            node
            for node in tree.body
            if isinstance(node, ast.If) and ast.unparse(node.test) == "__name__ == '__main__'"
        )
        call = next(
            node
            for node in ast.walk(main)
            if isinstance(node, ast.Call) and ast.unparse(node.func) == "app.run"
        )
        self.assertEqual(
            next(kw.value.value for kw in call.keywords if kw.arg == "host"), "127.0.0.1"
        )


if __name__ == "__main__":
    unittest.main()
