#!/usr/bin/env python3
"""API tests for the async host network job endpoints (#13/#57, bucket H3).

The WebUI never applies network changes or restarts the stack itself: it
submits jobs to the independent host worker and exposes read-only job status.
These tests pin the HTTP contract: 202 durable acceptance (never a completed
apply), 400 validation, 409 busy/recovery, 503 worker-down, plus auth/CSRF.
"""

import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import yaml

WEBUI = Path(__file__).resolve().parents[2] / "webui"
sys.path.insert(0, str(WEBUI))

FLASK_AVAILABLE = importlib.util.find_spec("flask") is not None

CSRF = "test-csrf-token"
JOB_ID = "abcdef01-2222-4333-8444-555555555555"
OTHER_JOB_ID = "99999999-8888-4777-8666-555555555555"

BASE_CONFIG = {
    "auth": {"session_secret": "test-session-key"},
}

APPLY_PAYLOAD = {
    "ztp": {
        "enabled": True,
        "vlan_id": 5,
        "parent_interface": "enp7s0.5",
        "podman_network": "ztp-net-5",
        "macvlan_mode": "bridge",
        "ipv4": {"address": "10.0.5.10", "subnet": "10.0.5.0/24", "gateway": "10.0.5.1"},
        "ipv6": {"address": "", "subnet": "", "gateway": ""},
    }
}


def make_job(state="queued", op="apply", job_id=JOB_ID, **fields):
    job = {
        "job_id": job_id,
        "op": op,
        "state": state,
        "created_at": "2026-09-19T00:00:00+00:00",
        "updated_at": "2026-09-19T00:00:00+00:00",
        "timeout_at": "2026-09-19T00:15:00+00:00",
        "error_code": None,
        "detail": "Accepted; awaiting host execution",
        "changed_endpoint": None,
        "podman_network": "ztp-net-5",
        "effective_applied": False,
    }
    job.update(fields)
    return job


def worker_response(job=None, error=None, **fields):
    return {"v": 1, "ok": error is None, "error": error, "job": job, **fields}


class FakeJobClient:
    """Stand-in for NetworkJobClient; records calls and replays presets."""

    def __init__(self):
        self.enqueue_apply_result = worker_response(make_job())
        self.enqueue_restart_result = worker_response(make_job(op="restart"))
        self.status_result = worker_response(job=None, jobs=[])
        self.calls = []

    def enqueue_apply(self, profile):
        self.calls.append(("enqueue_apply", profile))
        return self.enqueue_apply_result

    def enqueue_restart(self):
        self.calls.append(("enqueue_restart",))
        return self.enqueue_restart_result

    def status(self, job_id=None):
        self.calls.append(("status", job_id))
        return self.status_result


@unittest.skipUnless(FLASK_AVAILABLE, "Flask not installed")
class NetworkJobsApiTestCase(unittest.TestCase):
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
                "network_jobs_api_test_app", WEBUI / "app.py"
            )
            self.webapp = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(self.webapp)
        handler = self.webapp.security_handler
        self.addCleanup(handler.close)
        self.addCleanup(self.webapp.security_logger.removeHandler, handler)
        self.addCleanup(self.webapp.security_logger.removeHandler, self.webapp.console_handler)
        self.client = self.webapp.app.test_client()
        self.fake_client = FakeJobClient()
        self.original_job_client = self.webapp._network_job_client
        client_patcher = patch.object(
            self.webapp, "_network_job_client", return_value=self.fake_client
        )
        client_patcher.start()
        self.addCleanup(client_patcher.stop)

    def authenticate(self):
        with self.client.session_transaction() as session:
            session["authenticated"] = True
            session["csrf_token"] = CSRF

    def csrf_headers(self):
        return {"X-CSRF-Token": CSRF}

    # --- Authentication and CSRF -------------------------------------------

    def test_mutations_require_authentication(self):
        for path in ("/api/network/apply", "/api/network/restart"):
            with self.subTest(path=path):
                response = self.client.post(path, json={})
                self.assertEqual(response.status_code, 401)
                self.assertEqual(response.json["code"], "AUTH_REQUIRED")

    def test_job_status_endpoints_require_authentication(self):
        response = self.client.get("/api/network/jobs")
        self.assertEqual(response.status_code, 401)
        self.assertEqual(response.json["code"], "AUTH_REQUIRED")
        response = self.client.get(f"/api/network/jobs/{JOB_ID}")
        self.assertEqual(response.status_code, 401)
        self.assertEqual(response.json["code"], "AUTH_REQUIRED")

    def test_mutations_require_csrf_token(self):
        self.authenticate()
        for path in ("/api/network/apply", "/api/network/restart"):
            with self.subTest(path=path):
                response = self.client.post(path, json={})
                self.assertEqual(response.status_code, 403)
                self.assertEqual(response.json["code"], "CSRF_ERROR")
                self.assertEqual(self.fake_client.calls, [])

    def test_rejected_requests_reach_no_worker(self):
        """Rejected mutations must make no host changes and no worker calls."""
        response = self.client.post("/api/network/apply", json=APPLY_PAYLOAD)
        self.assertEqual(response.status_code, 401)
        self.authenticate()
        response = self.client.post("/api/network/apply", json=APPLY_PAYLOAD)
        self.assertEqual(response.status_code, 403)
        self.assertEqual(self.fake_client.calls, [])
        self.assertEqual(
            self.config_file.read_text(),
            yaml.safe_dump(BASE_CONFIG, sort_keys=False),
        )

    # --- 202 durable acceptance, never "applied" -----------------------------

    def test_apply_returns_202_queued_not_success(self):
        self.authenticate()
        response = self.client.post(
            "/api/network/apply", json=APPLY_PAYLOAD, headers=self.csrf_headers()
        )
        self.assertEqual(response.status_code, 202)
        data = response.get_json()
        self.assertEqual(data["job_id"], JOB_ID)
        self.assertEqual(data["state"], "queued")
        self.assertEqual(data["job"]["state"], "queued")
        self.assertFalse(data["job"]["effective_applied"])
        # An accepted job is never reported as a completed apply or restart.
        self.assertNotIn("success", data)
        self.assertNotIn("applied", json.dumps(data).lower().replace("effective_applied", ""))
        # The editable profile schema was handed to the host worker client.
        ((name, profile),) = self.fake_client.calls
        self.assertEqual(name, "enqueue_apply")
        self.assertTrue(profile["enabled"])
        self.assertEqual(profile["ipv4"]["address"], "10.0.5.10")
        self.assertEqual(profile["vlan_id"], 5)

    def test_restart_returns_202_queued_not_success(self):
        self.authenticate()
        response = self.client.post("/api/network/restart", json={}, headers=self.csrf_headers())
        self.assertEqual(response.status_code, 202)
        data = response.get_json()
        self.assertEqual(data["job_id"], JOB_ID)
        self.assertEqual(data["state"], "queued")
        self.assertEqual(data["job"]["op"], "restart")
        self.assertNotIn("success", data)
        self.assertEqual(self.fake_client.calls, [("enqueue_restart",)])

    def test_apply_saves_no_config_and_calls_no_legacy_deploy(self):
        """H3: Flask must not save returned/full config or call the legacy
        synchronous apply/restart helpers (#13)."""
        self.authenticate()
        before = self.config_file.read_bytes()
        with (
            patch("network_deploy.apply_ztp_network") as legacy_apply,
            patch("network_deploy.restart_ztp_stack") as legacy_restart,
        ):
            response = self.client.post(
                "/api/network/apply", json=APPLY_PAYLOAD, headers=self.csrf_headers()
            )
            self.assertEqual(response.status_code, 202)
            response = self.client.post(
                "/api/network/restart", json={}, headers=self.csrf_headers()
            )
            self.assertEqual(response.status_code, 202)
            legacy_apply.assert_not_called()
            legacy_restart.assert_not_called()
        self.assertEqual(self.config_file.read_bytes(), before)

    def test_app_module_has_no_legacy_sync_paths(self):
        self.assertFalse(hasattr(self.webapp, "apply_ztp_network"))
        self.assertFalse(hasattr(self.webapp, "restart_ztp_stack"))
        self.assertFalse(hasattr(self.webapp, "_save_full_config"))

    # --- Worker submission failures ------------------------------------------

    def test_worker_down_returns_503(self):
        self.authenticate()
        self.fake_client.enqueue_apply_result = worker_response(error="worker_down")
        response = self.client.post(
            "/api/network/apply", json=APPLY_PAYLOAD, headers=self.csrf_headers()
        )
        self.assertEqual(response.status_code, 503)
        self.assertEqual(response.json["code"], "worker_down")
        self.assertNotIn("success", response.json)

        self.fake_client.enqueue_restart_result = worker_response(error="worker_down")
        response = self.client.post("/api/network/restart", json={}, headers=self.csrf_headers())
        self.assertEqual(response.status_code, 503)
        self.assertEqual(response.json["code"], "worker_down")

    def test_worker_busy_returns_409_with_active_job(self):
        self.authenticate()
        active = make_job(state="running", job_id=OTHER_JOB_ID)
        self.fake_client.enqueue_apply_result = worker_response(
            job=active, error="worker_busy", recovery_required=False
        )
        response = self.client.post(
            "/api/network/apply", json=APPLY_PAYLOAD, headers=self.csrf_headers()
        )
        self.assertEqual(response.status_code, 409)
        data = response.get_json()
        self.assertEqual(data["code"], "worker_busy")
        self.assertEqual(data["job"]["job_id"], OTHER_JOB_ID)
        self.assertEqual(data["job"]["state"], "running")
        self.assertFalse(data["recovery_required"])
        self.assertNotIn("job_id", {k: v for k, v in data.items() if k != "job"})

    def test_recovery_required_returns_409(self):
        self.authenticate()
        blocked = make_job(state="stale", job_id=OTHER_JOB_ID)
        self.fake_client.enqueue_restart_result = worker_response(
            job=blocked, error="worker_busy", recovery_required=True
        )
        response = self.client.post("/api/network/restart", json={}, headers=self.csrf_headers())
        self.assertEqual(response.status_code, 409)
        data = response.get_json()
        self.assertEqual(data["code"], "worker_busy")
        self.assertTrue(data["recovery_required"])
        self.assertEqual(data["job"]["job_id"], OTHER_JOB_ID)

    def test_worker_rejection_returns_400(self):
        self.authenticate()
        self.fake_client.enqueue_apply_result = worker_response(error="validation")
        response = self.client.post(
            "/api/network/apply", json=APPLY_PAYLOAD, headers=self.csrf_headers()
        )
        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.json["code"], "validation")

    def test_apply_validation_error_before_worker(self):
        self.authenticate()
        bad = {"ztp": {"enabled": True, "vlan_id": 99999, "ipv4": {"address": "bogus"}}}
        response = self.client.post("/api/network/apply", json=bad, headers=self.csrf_headers())
        self.assertEqual(response.status_code, 400)
        self.assertIn("errors", response.json)
        self.assertTrue(response.json["errors"])
        self.assertIn("vlan_id", response.json["error"])
        self.assertEqual(self.fake_client.calls, [])

    def test_apply_requires_enabled_profile(self):
        self.authenticate()
        payload = {"ztp": {"enabled": False}}
        response = self.client.post("/api/network/apply", json=payload, headers=self.csrf_headers())
        self.assertEqual(response.status_code, 400)
        self.assertEqual(self.fake_client.calls, [])

    def test_apply_rejects_non_object_body(self):
        self.authenticate()
        response = self.client.post(
            "/api/network/apply",
            data='"just-a-string"',
            content_type="application/json",
            headers=self.csrf_headers(),
        )
        self.assertEqual(response.status_code, 400)
        self.assertEqual(self.fake_client.calls, [])

    def test_network_modules_unavailable_returns_503(self):
        self.authenticate()
        with patch.object(self.webapp, "NetworkJobClient", None):
            for path, payload in (
                ("/api/network/apply", APPLY_PAYLOAD),
                ("/api/network/restart", {}),
            ):
                with self.subTest(path=path):
                    response = self.client.post(path, json=payload, headers=self.csrf_headers())
                    self.assertEqual(response.status_code, 503)
            response = self.client.get("/api/network/jobs")
            self.assertEqual(response.status_code, 503)
            response = self.client.get(f"/api/network/jobs/{JOB_ID}")
            self.assertEqual(response.status_code, 503)

    # --- Read-only job status -------------------------------------------------

    def test_jobs_listing_contract(self):
        self.authenticate()
        jobs = [make_job(state="succeeded", effective_applied=True), make_job()]
        self.fake_client.status_result = worker_response(
            job=None, jobs=jobs, recovery_required=False
        )
        response = self.client.get("/api/network/jobs")
        self.assertEqual(response.status_code, 200)
        data = response.get_json()
        self.assertEqual(data["v"], 1)
        self.assertTrue(data["ok"])
        self.assertIsNone(data["error"])
        self.assertIsNone(data["job"])
        self.assertEqual(len(data["jobs"]), 2)
        self.assertFalse(data["recovery_required"])
        self.assertLessEqual(set(data), {"v", "ok", "error", "job", "jobs", "recovery_required"})
        self.assertEqual(self.fake_client.calls, [("status", None)])

    def test_job_status_returns_pending_state_honestly(self):
        self.authenticate()
        self.fake_client.status_result = worker_response(
            job=make_job(state="running"), recovery_required=False
        )
        response = self.client.get(f"/api/network/jobs/{JOB_ID}")
        self.assertEqual(response.status_code, 200)
        data = response.get_json()
        self.assertEqual(data["job"]["job_id"], JOB_ID)
        self.assertEqual(data["job"]["state"], "running")
        self.assertFalse(data["job"]["effective_applied"])
        # A queued/running job must never be framed as an applied change.
        self.assertNotIn("applied", json.dumps(data).lower().replace("effective_applied", ""))
        self.assertEqual(self.fake_client.calls, [("status", JOB_ID)])

    def test_job_status_unknown_id_returns_404(self):
        self.authenticate()
        self.fake_client.status_result = worker_response(job=None, recovery_required=False)
        response = self.client.get(f"/api/network/jobs/{JOB_ID}")
        self.assertEqual(response.status_code, 404)
        self.assertIsNone(response.get_json()["job"])

    def test_job_status_malformed_id_returns_400_without_worker_call(self):
        self.authenticate()
        for bad_id in (
            "not-a-uuid",
            "../etc/passwd",
            JOB_ID.upper(),
            f"{JOB_ID}x",
        ):
            with self.subTest(bad_id=bad_id):
                response = self.client.get(f"/api/network/jobs/{bad_id}")
                self.assertEqual(response.status_code, 400)
                data = response.get_json()
                self.assertEqual(data["v"], 1)
                self.assertFalse(data["ok"])
                self.assertEqual(data["error"], "bad_request")
                self.assertIsNone(data["job"])
        self.assertEqual(self.fake_client.calls, [])

    def test_job_status_worker_down_returns_503(self):
        self.authenticate()
        self.fake_client.status_result = worker_response(error="worker_down")
        response = self.client.get(f"/api/network/jobs/{JOB_ID}")
        self.assertEqual(response.status_code, 503)
        data = response.get_json()
        self.assertEqual(data["error"], "worker_down")
        self.assertFalse(data["ok"])

    def test_jobs_listing_worker_down_returns_503(self):
        self.authenticate()
        self.fake_client.status_result = worker_response(error="worker_down")
        response = self.client.get("/api/network/jobs")
        self.assertEqual(response.status_code, 503)

    def test_status_payload_carries_no_raw_command_output(self):
        """Job records carry bounded worker details only: no stderr/tracebacks."""
        self.authenticate()
        job = make_job(state="failed", detail="Host operation failed; inspect worker journal")
        self.fake_client.status_result = worker_response(job=job, recovery_required=False)
        response = self.client.get(f"/api/network/jobs/{JOB_ID}")
        self.assertEqual(response.status_code, 200)
        data = response.get_json()
        allowed_job_fields = {
            "job_id",
            "op",
            "state",
            "created_at",
            "updated_at",
            "timeout_at",
            "error_code",
            "detail",
            "changed_endpoint",
            "podman_network",
            "effective_applied",
        }
        self.assertLessEqual(set(data["job"]), allowed_job_fields)

    # --- Socket path configuration --------------------------------------------

    def test_socket_path_defaults_to_contract_and_env_override(self):
        with patch.dict(os.environ, {}, clear=False):
            os.environ.pop("ZTP_NETWORK_WORKER_SOCKET", None)
            default_client = self.original_job_client()  # noqa: SLF001
            self.assertEqual(default_client.socket_path, self.webapp.NETWORK_WORKER_SOCKET_PATH)
        with patch.dict(os.environ, {"ZTP_NETWORK_WORKER_SOCKET": "/tmp/test-worker.sock"}):
            override_client = self.original_job_client()  # noqa: SLF001
            self.assertEqual(override_client.socket_path, "/tmp/test-worker.sock")


if __name__ == "__main__":
    unittest.main()
