"""Protocol, durable acceptance and process-isolated host worker tests."""

import json
import multiprocessing
import socket
import struct
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "webui"))
import network_jobs as jobs


def profile():
    return {
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
        "ipv6": {"address": "", "subnet": "", "gateway": ""},
    }


def _process_worker(socket_path, state_dir, stop, release):
    """Forked host server outlives a separate short-lived submitting client."""

    def execute(*_args, **_kwargs):
        if not release.wait(10):
            raise RuntimeError("Test release missing")
        return {"state": "succeeded", "effective_applied": True, "detail": "verified"}

    with (
        patch("network_jobs._peer_allowed", return_value=True),
        patch("network_deploy.execute_host_job", side_effect=execute),
    ):
        jobs.run_worker(socket_path, state_dir, config_manager=object(), stop_event=stop)


def _submit_client(socket_path, output):
    output.put(jobs.NetworkJobClient(socket_path).enqueue_apply(profile()))


class ProtocolTests(unittest.TestCase):
    def test_roundtrip_and_frame_bounds(self):
        request = jobs.build_apply_request(profile())
        self.assertEqual(jobs.decode(jobs.encode(request)), request)
        for frame in (
            b"",
            struct.pack("!I", 0),
            struct.pack("!I", 65537),
            struct.pack("!I", 2) + b"[]",
            jobs.encode(request) + b"x",
        ):
            with self.subTest(frame=frame[:8]), self.assertRaises(ValueError):
                jobs.decode(frame)
        with self.assertRaises(ValueError):
            jobs.encode({"x": "x" * jobs.MAX_MESSAGE_BYTES})

    def test_rejects_command_and_nested_type_injection(self):
        for key, value in (
            ("parent_interface", "eth0\n[Service]\nExecStart=/bin/x"),
            ("podman_network", "--help"),
            ("vlan_id", True),
            ("ipv4", []),
            ("enabled", 1),
            ("macvlan_mode", ["bridge"]),
        ):
            bad = profile()
            bad[key] = value
            self.assertEqual(
                jobs.validate_request(jobs.build_apply_request(bad)),
                (False, "validation"),
            )
        for value in (
            [],
            4,
            {"address": {}},
            {"address": "10.0.5.10", "subnet": "10.0.5.0/24", "exec": "id"},
        ):
            bad = profile()
            bad["ipv4"] = value
            self.assertFalse(jobs.validate_profile(bad))
        for request in (
            {"v": 1, "op": "exec", "cmd": "id"},
            {"v": 1, "op": "restart", "unit": "sshd"},
            {"v": 1, "op": "status", "job_id": "../../etc/passwd"},
            {"v": True, "op": "restart"},
        ):
            self.assertFalse(jobs.validate_request(request)[0])

    def test_client_unavailable_and_invalid_input_are_explicit(self):
        client = jobs.NetworkJobClient("/nonexistent/worker.sock", timeout=0.1)
        self.assertEqual(client.enqueue_restart()["error"], "worker_down")
        self.assertEqual(client.enqueue_apply([])["error"], "validation")

    def test_credentials_fail_closed(self):
        fake = unittest.mock.Mock()
        fake.getsockopt.return_value = struct.pack("3i", 10, 1000, 1000)
        with patch.object(socket, "SO_PEERCRED", 17, create=True):
            self.assertFalse(jobs._peer_allowed(fake))
            fake.getsockopt.return_value = struct.pack("3i", 10, 0, 0)
            self.assertTrue(jobs._peer_allowed(fake))


class StoreTests(unittest.TestCase):
    def test_durable_state_stale_and_permissions(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = jobs.JobStore(Path(tmp) / "state")
            job = store.create("apply", profile())
            self.assertEqual(job.changed_endpoint["after"], "https://10.0.5.10")
            with self.assertRaises(BlockingIOError):
                store.create("restart", None)
            restored = jobs.JobStore(store.state_dir)
            self.assertEqual(restored.get(job.job_id), job)
            self.assertEqual((store.state_dir / f"{job.job_id}.json").stat().st_mode & 0o777, 0o600)
            self.assertEqual(store.state_dir.stat().st_mode & 0o777, 0o700)
            stale = restored.mark_stale_on_boot()
            self.assertEqual(stale[0].state, "stale")
            self.assertFalse(stale[0].effective_applied)
            self.assertIsNone(restored.active())

    def test_recovery_block_survives_restart_until_explicit_host_reset(self):
        for state in ("stale", "rollback_failed"):
            with self.subTest(state=state), tempfile.TemporaryDirectory() as tmp:
                store = jobs.JobStore(Path(tmp))
                job = store.create("restart", None)
                store.update(job.job_id, state=state, error_code=state)
                reopened = jobs.JobStore(Path(tmp))
                self.assertTrue(reopened.recovery_required())
                self.assertEqual(reopened.recovery_job().job_id, job.job_id)
                with self.assertRaises(BlockingIOError):
                    reopened.create("restart", None)
                # No protocol operation can perform this reset. A host operator
                # removes the marker only after stopping/inspecting the worker.
                (Path(tmp) / ".recovery-required").unlink()
                self.assertIsNotNone(reopened.create("restart", None))

    def test_retention_keeps_active_and_newest_terminal(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = jobs.JobStore(Path(tmp))
            with patch("network_jobs.MAX_RETENTION", 2):
                terminal = []
                for _ in range(4):
                    job = store.create("restart", None)
                    store.update(job.job_id, state="failed", error_code="timeout")
                    terminal.append(job.job_id)
                active = store.create("restart", None)
                store.prune()
            self.assertEqual(
                {job.job_id for job in store.list_recent()},
                set(terminal[-2:] + [active.job_id]),
            )

    def test_corrupt_or_symlinked_record_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = jobs.JobStore(Path(tmp))
            job = store.create("restart", None)
            path = Path(tmp) / f"{job.job_id}.json"
            path.write_text("not json")
            with self.assertRaises(json.JSONDecodeError):
                store.active()
            path.unlink()
            path.symlink_to("/etc/passwd")
            with self.assertRaises(OSError):
                store.get(job.job_id)


class WorkerTests(unittest.TestCase):
    def test_process_survival_busy_and_durable_result(self):
        ctx = multiprocessing.get_context("fork")
        with tempfile.TemporaryDirectory() as tmp:
            socket_path = str(Path(tmp) / "run" / "worker.sock")
            state_dir = Path(tmp) / "state"
            stop, release, output = ctx.Event(), ctx.Event(), ctx.Queue()
            worker = ctx.Process(
                target=_process_worker, args=(socket_path, state_dir, stop, release)
            )
            worker.start()
            try:
                limit = time.monotonic() + 5
                while not Path(socket_path).exists() and time.monotonic() < limit:
                    time.sleep(0.02)
                self.assertTrue(Path(socket_path).exists())
                submitter = ctx.Process(target=_submit_client, args=(socket_path, output))
                submitter.start()
                accepted = output.get(timeout=5)
                submitter.join(timeout=5)
                self.assertEqual(submitter.exitcode, 0)
                self.assertTrue(accepted["ok"])
                job_id = accepted["job"]["job_id"]
                self.assertIsNotNone(jobs.JobStore(state_dir).get(job_id))
                client = jobs.NetworkJobClient(socket_path)
                self.assertEqual(client.enqueue_restart()["error"], "worker_busy")
                self.assertIn(client.status(job_id)["job"]["state"], ("queued", "running"))
                self.assertTrue(worker.is_alive())
                release.set()
                limit = time.monotonic() + 5
                while time.monotonic() < limit:
                    status = client.status(job_id)["job"]
                    if status["state"] == "succeeded":
                        break
                    time.sleep(0.02)
                self.assertEqual(status["state"], "succeeded")
                self.assertTrue(status["effective_applied"])
                self.assertIsNone(client.status("00000000-0000-4000-8000-000000000000")["job"])
            finally:
                release.set()
                stop.set()
                worker.join(timeout=5)
                if worker.is_alive():
                    worker.kill()
                    worker.join()
            self.assertEqual(jobs.JobStore(state_dir).get(job_id).state, "succeeded")

    def test_worker_rejects_new_mutation_after_interrupted_job(self):
        with tempfile.TemporaryDirectory() as tmp:
            socket_path = str(Path(tmp) / "run" / "worker.sock")
            state_dir = Path(tmp) / "state"
            interrupted = jobs.JobStore(state_dir).create("restart", None)
            stop, release = threading.Event(), threading.Event()
            worker = threading.Thread(
                target=_process_worker, args=(socket_path, state_dir, stop, release)
            )
            worker.start()
            try:
                limit = time.monotonic() + 5
                while not Path(socket_path).exists() and time.monotonic() < limit:
                    time.sleep(0.02)
                client = jobs.NetworkJobClient(socket_path)
                rejected = client.enqueue_restart()
                self.assertEqual(rejected["error"], "worker_busy")
                self.assertTrue(rejected["recovery_required"])
                self.assertEqual(rejected["job"]["state"], "stale")
                self.assertEqual(rejected["job"]["job_id"], interrupted.job_id)
                self.assertTrue(client.status()["recovery_required"])
            finally:
                release.set()
                stop.set()
                worker.join(timeout=5)

    def test_second_worker_cannot_mark_live_job_stale(self):
        with tempfile.TemporaryDirectory() as tmp:
            socket_path = str(Path(tmp) / "run" / "worker.sock")
            state_dir = Path(tmp) / "state"
            stop, release = threading.Event(), threading.Event()
            worker = threading.Thread(
                target=_process_worker, args=(socket_path, state_dir, stop, release)
            )
            worker.start()
            try:
                limit = time.monotonic() + 5
                while not Path(socket_path).exists() and time.monotonic() < limit:
                    time.sleep(0.02)
                client = jobs.NetworkJobClient(socket_path)
                job = client.enqueue_restart()["job"]
                with self.assertRaises(BlockingIOError):
                    jobs.run_worker(socket_path, state_dir, config_manager=object())
                self.assertNotEqual(client.status(job["job_id"])["job"]["state"], "stale")
            finally:
                release.set()
                stop.set()
                worker.join(timeout=5)


if __name__ == "__main__":
    unittest.main()
