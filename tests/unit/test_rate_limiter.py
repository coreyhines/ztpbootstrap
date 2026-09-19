"""Regression tests for client identity and the single-process serving contract."""

import shlex
import sys
import unittest
from pathlib import Path

from flask import Flask
from werkzeug.middleware.proxy_fix import ProxyFix

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "webui"))

from rate_limiter import RateLimiter

ROOT = Path(__file__).resolve().parents[2]


class TestRateLimiterIdentity(unittest.TestCase):
    def setUp(self):
        self.app = Flask(__name__)
        self.limiter = RateLimiter()

        @self.app.route("/limited")
        @self.limiter.rate_limit(max_calls=1, window=60)
        def limited():
            return {"identity": self.limiter._get_client_identifier()}

    def test_spoofed_forwarded_headers_do_not_change_identity(self):
        for forwarded in (None, "203.0.113.1", "203.0.113.2, 203.0.113.3"):
            with self.subTest(forwarded=forwarded):
                headers = {} if forwarded is None else {"X-Forwarded-For": forwarded}
                with self.app.test_request_context(
                    "/limited", headers=headers, environ_base={"REMOTE_ADDR": "192.0.2.1"}
                ):
                    self.assertEqual(self.limiter._get_client_identifier(), "192.0.2.1:limited")

    def test_rotating_spoofed_headers_cannot_bypass_limit(self):
        client = self.app.test_client()
        self.assertEqual(
            client.get("/limited", headers={"X-Forwarded-For": "203.0.113.1"}).status_code,
            200,
        )
        self.assertEqual(
            client.get("/limited", headers={"X-Forwarded-For": "203.0.113.2"}).status_code,
            429,
        )

    def test_proxyfix_resolved_address_is_used(self):
        self.app.wsgi_app = ProxyFix(self.app.wsgi_app, x_for=1)
        response = self.app.test_client().get(
            "/limited", headers={"X-Forwarded-For": "203.0.113.99, 192.0.2.1"}
        )
        self.assertEqual(response.json["identity"], "192.0.2.1:limited")

    def test_distinct_remote_addresses_have_separate_limits(self):
        client = self.app.test_client()
        for address in ("192.0.2.1", "192.0.2.2"):
            response = client.get("/limited", environ_overrides={"REMOTE_ADDR": address})
            self.assertEqual(response.status_code, 200)


class TestServingConfiguration(unittest.TestCase):
    def test_startup_uses_single_worker_on_loopback(self):
        script = (ROOT / "webui/start-webui.sh").read_text()
        command = next(line for line in script.splitlines() if line.startswith("exec "))
        self.assertEqual(
            shlex.split(command),
            [
                "exec",
                "gunicorn",
                "--bind",
                "127.0.0.1:5000",
                "--workers",
                "1",
                "--threads",
                "8",
                "--timeout",
                "120",
                "app:app",
            ],
        )

    def test_image_installs_pinned_gunicorn_and_healthcheck_uses_loopback(self):
        requirements = (ROOT / "webui/requirements.txt").read_text()
        self.assertRegex(requirements, r"(?m)^gunicorn==\d+\.\d+\.\d+$")
        containerfile = (ROOT / "webui/Containerfile").read_text()
        self.assertIn("pip3 install --no-cache-dir -r requirements.txt", containerfile)
        quadlet = (ROOT / "systemd/ztpbootstrap-webui.container").read_text()
        self.assertIn("http://localhost:5000/api/status", quadlet)


if __name__ == "__main__":
    unittest.main()
