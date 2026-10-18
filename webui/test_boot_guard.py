import copy
import json
import socket
import sys
import tarfile
import tempfile
import threading
import unittest
import urllib.request
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
from boot_guard import BootFailure, BootGuard, minecraft_ping, varint


def result(ok=True, stdout="", stderr=""):
    return {"ok": ok, "code": 0 if ok else 1, "stdout": stdout, "stderr": stderr}


class GuardTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.data = self.root / "world"
        self.data.mkdir()
        (self.data / "world.dat").write_text("old world")
        (self.data / "paper-old.jar").write_text("old server")
        (self.data / ".paper.env").write_text("VERSION='1.21.4'\nSERVER='/data/paper-old.jar'\n")
        self.config = {"id": "test", "container_name": "mc-test", "data_dir": str(self.data),
                       "backup_root": str(self.root / "backups"), "type": "PAPER", "version": "LATEST",
                       "host_port": "25565", "boot_timeout_seconds": 30, "boot_stability_seconds": 10,
                       "start_after_apply": True, "rcon_password": "secret"}
        self.info = {"Id": "container-1", "Image": "sha256:old-image", "RestartCount": 0,
                     "Config": {"Env": ["TYPE=PAPER", "VERSION=LATEST", "MEMORY=4G", "ENABLE_RCON=true", "RCON_PASSWORD=secret", "RCON_PORT=25575"]},
                     "Mounts": [{"Type": "bind", "Destination": "/data", "Source": str(self.data)}],
                     "HostConfig": {"PortBindings": {"25565/tcp": [{"HostPort": "25565"}]}},
                     "State": {"Running": True, "Status": "running", "StartedAt": "2026-10-15T00:00:00Z", "Health": {"Status": "healthy"}}}
        self.backend_calls = []
        self.docker_calls = []
        self.boot_output = ""
        self.fail_tar = False
        self.fail_extract = False
        self.fail_start = False
        self.fail_rollback = False
        self.clock = 0
        self.app = SimpleNamespace(STATE_DIR=self.root / "state", DEFAULT_SERVER={"rcon_container_port": "25575"},
                                   run_command=self.command, _run_backend_action=self.backend,
                                   write_server=Mock(), server_path=lambda value: self.root / value,
                                   resolve_data_dir_path=lambda raw: Path(raw).resolve(), is_disabled=lambda conf: False)
        self.guard = BootGuard(self.app)
        self.guard.ready = lambda conf, info: bool(info["State"].get("Running") and not info["State"].get("Restarting") and info["State"].get("Health", {}).get("Status") == "healthy")
        self.monotonic = patch("boot_guard.time.monotonic", side_effect=lambda: self.clock)
        self.sleep = patch("boot_guard.time.sleep", side_effect=self.tick)
        self.monotonic.start()
        self.sleep.start()
        self.addCleanup(self.monotonic.stop)
        self.addCleanup(self.sleep.stop)

    def tick(self, seconds):
        self.clock += seconds

    def command(self, args, timeout=60):
        if args[0] == "docker":
            self.docker_calls.append(args)
            if args[1:3] == ["container", "inspect"]:
                return result(stdout=json.dumps([self.info]))
            if args[1] == "stop":
                self.info["State"].update(Running=False, Status="exited", Restarting=False)
            if args[1] == "logs":
                return result(stdout=self.boot_output)
            return result()
        if args[0] == "tar":
            if "-cpf" in args:
                if self.fail_tar:
                    return result(False, stderr="disk full")
                with tarfile.open(args[args.index("-cpf") + 1], "w") as archive:
                    archive.add(args[args.index("-C") + 1], arcname=".", filter=lambda item: None if item.name.startswith("./backups") else item)
            elif "-xpf" in args:
                if self.fail_extract:
                    return result(False, stderr="restore disk full")
                with tarfile.open(args[2]) as archive:
                    archive.extractall(args[4], filter="data")
            else:
                with tarfile.open(args[2]) as archive:
                    archive.getmembers()
            return result()
        raise AssertionError(args)

    def backend(self, config, action):
        self.backend_calls.append((copy.deepcopy(config), action))
        if action == "plugins":
            (self.data / "bad-plugin.jar").write_text("broken plugin")
            return result()
        if action in {"apply", "start", "restart"}:
            rollback = bool(config.get("pinned_server_jar"))
            (self.data / "world.dat").write_text("old world" if rollback else "new world")
            if self.fail_start and not rollback or self.fail_rollback and rollback:
                self.info["State"].update(Running=False, Status="exited", ExitCode=1)
                (self.data / "bad-plugin.jar").write_text("broken plugin")
            else:
                self.info["State"].update(Running=True, Status="running", ExitCode=0)
                self.boot_output = "Server started"
        return result(stdout="backend completed")

    def test_success_waits_for_stability_and_retains_failure_log(self):
        self.guard.capture_failure(self.config, "earlier failure")
        path = self.guard.directory(self.config) / "last-failed-boot.log"
        before = path.read_text()
        outcome = self.guard.run(self.config, "apply")
        self.assertTrue(outcome["ok"])
        self.assertGreaterEqual(self.clock, 10)
        self.assertEqual(self.guard.read(self.config)["state"], "healthy")
        self.assertEqual(path.read_text(), before)
        self.assertIn(["docker", "update", "--restart=on-failure:3", "mc-test"], self.docker_calls)

    def test_failed_start_restores_exact_files_and_image(self):
        self.fail_start = True
        (self.data / "backups").mkdir()
        (self.data / "backups" / "user-backup.txt").write_text("keep")
        outcome = self.guard.run(self.config, "apply")
        self.assertFalse(outcome["ok"])
        self.assertTrue(outcome["rolled_back"])
        self.assertEqual((self.data / "world.dat").read_text(), "old world")
        self.assertFalse((self.data / "bad-plugin.jar").exists())
        self.assertTrue((self.data / "backups" / "user-backup.txt").exists())
        restored = self.backend_calls[-1][0]
        self.assertEqual(restored["version"], "1.21.4")
        self.assertEqual(restored["docker_image"], "sha256:old-image")
        self.assertEqual(restored["memory"], "4G")
        self.assertEqual(restored["pinned_server_jar"], "/data/paper-old.jar")
        self.assertEqual(self.guard.read(self.config)["state"], "rolled_back")
        self.assertTrue(list(self.root.glob("world.failed-*")))

    def test_backup_failure_does_not_apply_changes(self):
        self.fail_tar = True
        outcome = self.guard.run(self.config, "apply")
        self.assertFalse(outcome["ok"])
        self.assertEqual(self.backend_calls, [])
        self.assertEqual((self.data / "world.dat").read_text(), "old world")
        self.assertFalse(self.info["State"]["Running"])

    def test_failed_rollback_stays_stopped_and_keeps_both_errors(self):
        self.fail_start = self.fail_rollback = True
        outcome = self.guard.run(self.config, "restart")
        self.assertFalse(outcome["rolled_back"])
        self.assertEqual(len(self.backend_calls), 2)
        self.assertFalse(self.info["State"]["Running"])
        self.assertEqual(self.guard.read(self.config)["state"], "error")
        content = (self.guard.directory(self.config) / "last-failed-boot.log").read_text()
        self.assertGreaterEqual(content.count("Grund:"), 2)

    def test_extract_failure_preserves_failed_data_and_backup(self):
        self.fail_start = self.fail_extract = True
        outcome = self.guard.run(self.config, "apply")
        self.assertFalse(outcome["rolled_back"])
        self.assertEqual((self.data / "world.dat").read_text(), "new world")
        self.assertTrue(Path(self.guard.read(self.config)["checkpoint"]["archive"]).exists())

    def test_unpinned_platform_restores_data_but_does_not_restart(self):
        self.info["Config"]["Env"][0] = "TYPE=FABRIC"
        self.fail_start = True
        outcome = self.guard.run(self.config, "apply")
        self.assertFalse(outcome["rolled_back"])
        self.assertEqual(len(self.backend_calls), 1)
        self.assertEqual((self.data / "world.dat").read_text(), "old world")
        self.assertFalse(self.info["State"]["Running"])

    def test_pending_plugin_backup_survives_next_request(self):
        self.assertTrue(self.guard.run(self.config, "plugins")["ok"])
        archive = self.guard.read(self.config)["checkpoint"]["archive"]
        self.assertFalse(self.info["State"]["Running"])
        self.fail_start = True
        outcome = self.guard.run(self.config, "restart")
        self.assertTrue(outcome["rolled_back"])
        self.assertEqual(self.guard.read(self.config)["checkpoint"]["archive"], archive)
        self.assertFalse((self.data / "bad-plugin.jar").exists())

    def test_manual_stop_keeps_pending_plugin_checkpoint(self):
        self.guard.run(self.config, "plugins")
        checkpoint = self.guard.read(self.config)["checkpoint"]
        self.guard.run(self.config, "stop")
        self.assertTrue(self.guard.read(self.config)["pending"])
        self.assertEqual(self.guard.read(self.config)["checkpoint"], checkpoint)

    def test_runtime_restart_loop_stops_without_restoring_world(self):
        self.guard.save(self.config, state="healthy")
        self.guard.monitor_once(self.config)
        (self.data / "world.dat").write_text("player progress")
        self.info["RestartCount"] = 3
        self.guard.monitor_once(self.config)
        self.assertFalse(self.info["State"]["Running"])
        self.assertEqual((self.data / "world.dat").read_text(), "player progress")
        self.assertEqual(self.backend_calls, [])

    def test_existing_restart_loop_is_stopped_on_adoption(self):
        self.info["RestartCount"] = 9000
        self.info["State"]["Restarting"] = True
        self.guard.monitor_once(self.config)
        self.assertFalse(self.info["State"]["Running"])

    def test_scheduler_does_not_restart_or_stop_recovered_server(self):
        self.guard.save(self.config, state="rolled_back")
        outcome = self.guard.run(self.config | {"_scheduled": True}, "plugins-restart")
        self.assertFalse(outcome["ok"])
        self.assertTrue(self.info["State"]["Running"])
        self.assertEqual(self.docker_calls, [])

    def test_interrupted_action_stops_without_automatic_old_world_restore(self):
        self.guard.save(self.config, state="checking", pending=True)
        self.guard.monitor_once(self.config)
        self.assertFalse(self.info["State"]["Running"])
        self.assertEqual(self.guard.read(self.config)["state"], "error")
        self.assertFalse(self.guard.read(self.config)["pending"])

    def test_scheduler_cannot_resume_interrupted_update_before_monitor(self):
        self.guard.save(self.config, state="checking", pending=True)
        outcome = self.guard.run(self.config | {"_scheduled": True}, "restart")
        self.assertFalse(outcome["ok"])
        self.assertFalse(self.info["State"]["Running"])
        self.assertEqual(self.backend_calls, [])

    def test_second_action_is_rejected_while_server_busy(self):
        errors = []
        with self.guard.exclusive(self.config):
            def worker():
                try:
                    self.guard.run(self.config, "restart")
                except BootFailure as exc:
                    errors.append(str(exc))
            thread = threading.Thread(target=worker)
            thread.start()
            thread.join()
        self.assertEqual(len(errors), 1)
        self.assertEqual(self.backend_calls, [])

    def test_plugin_failure_detected_even_when_ping_is_healthy(self):
        self.boot_output = "[ERROR] Error occurred while enabling WorldEdit v1\nsecret"
        with self.assertRaisesRegex(BootFailure, "WorldEdit"):
            self.guard.wait_ready(self.config)

    def test_health_timeout(self):
        self.info["State"]["Health"]["Status"] = "starting"
        with self.assertRaisesRegex(BootFailure, "Startzeitlimit"):
            self.guard.wait_ready(self.config)
        self.assertLessEqual(self.clock, 45)

    def test_failure_log_redacts_password(self):
        self.boot_output = "password=secret"
        self.guard.capture_failure(self.config, "failed")
        content = (self.guard.directory(self.config) / "last-failed-boot.log").read_text()
        self.assertNotIn("secret", content)
        self.assertIn("[REDACTED]", content)

    def test_explicit_start_overrides_apply_without_start(self):
        outcome = self.guard.run(self.config | {"start_after_apply": False}, "start")
        self.assertTrue(outcome["ok"])
        self.assertTrue(self.backend_calls[0][0]["start_after_apply"])
        self.assertEqual(self.guard.read(self.config)["state"], "healthy")

    def test_pending_backup_cannot_restore_into_another_directory(self):
        self.guard.run(self.config, "plugins")
        other = self.root / "another-world"
        other.mkdir()
        (other / "keep").write_text("untouched")
        outcome = self.guard.run(self.config | {"data_dir": str(other)}, "restart")
        self.assertFalse(outcome["ok"])
        self.assertEqual((other / "keep").read_text(), "untouched")
        self.assertEqual(len(self.backend_calls), 1)

    def test_scheduler_plugin_restart_is_one_transaction(self):
        outcome = self.guard.run(self.config | {"_scheduled": True}, "plugins-restart")
        self.assertTrue(outcome["ok"])
        self.assertEqual([action for _, action in self.backend_calls], ["plugins", "restart"])
        self.assertEqual(self.guard.read(self.config)["state"], "healthy")

    def test_slow_then_ready_server_gets_full_stability_window(self):
        self.guard.ready = lambda conf, info: self.clock >= 25
        self.guard.wait_ready(self.config)
        self.assertEqual(self.clock, 35)

    def test_runtime_unresponsive_server_stops_without_rollback(self):
        self.guard.save(self.config, state="healthy")
        self.info["State"]["Health"]["Status"] = "unhealthy"
        self.guard.monitor_once(self.config)
        self.clock = 31
        self.guard.monitor_once(self.config)
        self.assertFalse(self.info["State"]["Running"])
        self.assertEqual(self.backend_calls, [])

    def test_restart_observations_expire_after_five_minutes(self):
        self.guard.save(self.config, state="healthy")
        self.guard.monitor_once(self.config)
        self.info["RestartCount"] = 2
        self.guard.monitor_once(self.config)
        self.clock = 301
        self.info["RestartCount"] = 3
        self.guard.monitor_once(self.config)
        self.assertTrue(self.info["State"]["Running"])


class ProtocolTest(unittest.TestCase):
    def test_minecraft_status_response(self):
        server = socket.socket()
        server.bind(("127.0.0.1", 0))
        server.listen(1)
        self.addCleanup(server.close)
        def respond():
            connection, _ = server.accept()
            with connection:
                connection.recv(4096)
                data = json.dumps({"version": {"name": "test"}, "players": {"online": 0}}).encode()
                packet = b"\x00" + varint(len(data)) + data
                connection.sendall(varint(len(packet)) + packet)
        thread = threading.Thread(target=respond)
        thread.start()
        self.assertTrue(minecraft_ping(server.getsockname()[1]))
        thread.join()

    def test_open_non_minecraft_port_is_not_ready(self):
        server = socket.socket()
        server.bind(("127.0.0.1", 0))
        server.listen(1)
        self.addCleanup(server.close)
        def respond():
            connection, _ = server.accept()
            with connection:
                connection.recv(4096)
                connection.sendall(b"HTTP/1.1 200 OK\r\n\r\n")
        thread = threading.Thread(target=respond)
        thread.start()
        self.assertFalse(minecraft_ping(server.getsockname()[1]))
        thread.join()


class AppIntegrationTest(unittest.TestCase):
    def setUp(self):
        import app
        self.app = app
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        for name, value in {"STATE_DIR": root / "state", "SERVER_DIR": root / "state" / "servers",
                            "RUN_DIR": root / "state" / "run", "INIT_MARKER": root / "state" / ".initialized"}.items():
            patcher = patch.object(app, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        app.SERVER_DIR.mkdir(parents=True)
        app.RUN_DIR.mkdir()
        patcher = patch.object(app, "port_warnings", return_value=[])
        patcher.start()
        self.addCleanup(patcher.stop)
        patcher = patch.object(app, "GUARD", BootGuard(app))
        patcher.start()
        self.addCleanup(patcher.stop)
        self.config = app.write_server({"id": "test", "data_dir": str(root / "data")})

    def test_settings_validation_and_pin_release(self):
        self.app.write_server({"id": "test", "pinned_server_jar": "/data/old.jar", "version": "1.21.4"})
        self.app.write_server({"id": "test", "version": "1.21.5"})
        self.assertEqual(self.app.read_server("test")["pinned_server_jar"], "")
        with self.assertRaises(ValueError):
            self.app.write_server({"id": "test", "boot_timeout_seconds": 0})

    def test_existing_profiles_get_boot_defaults_without_losing_custom_values(self):
        path = self.app.server_path("test")
        for values in ({}, {"boot_timeout_seconds": "", "boot_stability_seconds": None},
                       {"boot_timeout_seconds": "  ", "boot_stability_seconds": ""}):
            path.write_text(json.dumps({"id": "test", **values}), encoding="utf-8")
            for config in (self.app.read_server("test"), self.app.list_servers()[0]):
                self.assertEqual(config["boot_timeout_seconds"], 600)
                self.assertEqual(config["boot_stability_seconds"], 120)
        saved = self.app.write_server({"id": "test", "boot_timeout_seconds": "900", "boot_stability_seconds": ""})
        self.assertEqual(saved["boot_timeout_seconds"], 900)
        self.assertEqual(saved["boot_stability_seconds"], 120)

    def test_pending_profile_cannot_be_moved(self):
        self.app.GUARD.save(self.config, pending=True)
        with self.assertRaises(ValueError):
            self.app.write_server({"id": "test", "data_dir": str(Path(self.temp.name) / "other")})
        with patch.object(self.app, "remove_container") as remove:
            with self.assertRaises(ValueError):
                self.app.move_data_dir("test", str(Path(self.temp.name) / "other"))
            remove.assert_not_called()

    def test_delete_local_data_invalidates_pending_checkpoint(self):
        self.app.GUARD.save(self.config, pending=True, checkpoint={"archive": "old.tar"})
        with patch.object(self.app, "remove_container", return_value=[]), patch.object(self.app, "delete_data_dir", return_value=[]):
            self.app.delete_local_data(self.config)
        state = self.app.GUARD.read(self.config)
        self.assertFalse(state["pending"])
        self.assertIsNone(state["checkpoint"])

    def test_boot_log_http_api_and_version(self):
        self.app.GUARD.save(self.config, state="error", reason="Test failure", failure_at="2026-10-15")
        (self.app.GUARD.directory(self.config) / "last-failed-boot.log").write_text("saved failure")
        server = self.app.ThreadingHTTPServer(("127.0.0.1", 0), self.app.Handler)
        thread = threading.Thread(target=server.serve_forever)
        thread.start()
        try:
            base = f"http://127.0.0.1:{server.server_port}"
            with urllib.request.urlopen(base + "/api/servers/test/boot-log") as response:
                payload = json.load(response)
                self.assertEqual(payload["content"], "saved failure")
                self.assertEqual(payload["state"], "error")
                self.assertNotIn("checkpoint", payload)
            with urllib.request.urlopen(base + "/api/version") as response:
                self.assertEqual(json.load(response)["version"], "v1.3.1")
            with urllib.request.urlopen(base + "/static/items.json") as response:
                catalog = json.load(response)
                diamond = next(item for item in catalog["items"] if item["id"] == "minecraft:diamond")
                self.assertEqual(diamond["de"], "Diamant")
                self.assertTrue(diamond["icon"].startswith("data:image/png;base64,"))
        finally:
            server.shutdown()
            thread.join()
            server.server_close()

    def test_error_status_survives_removed_container(self):
        self.app.GUARD.save(self.config, state="error", reason="Failed boot")
        with patch.object(self.app, "run_command", return_value=result(False, stderr="No such container")):
            self.assertEqual(self.app.docker_status(self.config)["state"], "error")

    def test_container_recreation_shows_operation_instead_of_missing(self):
        self.app.GUARD.save(self.config, state="updating", reason="Applying changes")
        with patch.object(self.app, "run_command", return_value=result(False, stderr="No such container")):
            self.assertEqual(self.app.docker_status(self.config)["state"], "updating")


if __name__ == "__main__":
    unittest.main()
