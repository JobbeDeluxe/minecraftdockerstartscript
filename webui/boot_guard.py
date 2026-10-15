"""Persistent start supervision and one-shot rollback for WebUI-managed changes."""
import json
import os
import re
import shlex
import shutil
import socket
import struct
import tempfile
import threading
import time
from contextlib import contextmanager
from pathlib import Path


class BootFailure(RuntimeError):
    pass


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, name = tempfile.mkstemp(dir=path.parent, prefix=".state-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def varint(value):
    value &= 0xffffffff
    result = bytearray()
    while True:
        byte = value & 127
        value >>= 7
        result.append(byte | (128 if value else 0))
        if not value:
            return bytes(result)


def minecraft_ping(port):
    """Minecraft status response, not merely an open TCP socket (also works for proxies)."""
    try:
        with socket.create_connection(("127.0.0.1", int(port)), timeout=2) as sock:
            sock.settimeout(2)
            handshake = b"\x00" + varint(-1) + b"\x09localhost" + struct.pack(">H", int(port)) + b"\x01"
            sock.sendall(varint(len(handshake)) + handshake + b"\x01\x00")

            def read_int():
                value = 0
                for shift in range(0, 35, 7):
                    raw = sock.recv(1)
                    if not raw:
                        raise ValueError("closed socket")
                    value |= (raw[0] & 127) << shift
                    if not raw[0] & 128:
                        return value
                raise ValueError("invalid varint")

            size = read_int()
            if not 0 < size <= 1048576 or read_int() != 0:
                return False
            length = read_int()
            if not 0 < length <= size:
                return False
            data = bytearray()
            while len(data) < length:
                part = sock.recv(length - len(data))
                if not part:
                    return False
                data.extend(part)
            response = json.loads(data)
            return isinstance(response.get("version"), dict) and isinstance(response.get("players"), dict)
    except (OSError, ValueError, TypeError):
        return False


class BootGuard:
    def __init__(self, app):
        self.app = app
        self.locks = {}
        self.locks_lock = threading.Lock()
        self.observed = {}

    def directory(self, config):
        # Validate before constructing a path, including internal callers.
        self.app.server_path(config["id"])
        return self.app.STATE_DIR / "boot-guard" / config["id"]

    def read(self, config):
        path = self.directory(config) / "state.json"
        if not path.exists():
            return {}
        return json.loads(path.read_text(encoding="utf-8"))

    def save(self, config, **changes):
        state = self.read(config)
        state.update(changes)
        state["updated_at"] = time.strftime("%Y-%m-%d %H:%M:%S")
        atomic_json(self.directory(config) / "state.json", state)
        return state

    def lock(self, config):
        with self.locks_lock:
            return self.locks.setdefault(config["id"], threading.RLock())

    @contextmanager
    def exclusive(self, config):
        lock = self.lock(config)
        if not lock.acquire(blocking=False):
            raise BootFailure("Fuer diesen Server laeuft bereits eine Aktion oder Startpruefung.")
        try:
            yield
        finally:
            lock.release()

    def log(self, config, text):
        directory = self.directory(config)
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        with (directory / "action.log").open("a", encoding="utf-8") as stream:
            stream.write(time.strftime("%Y-%m-%d %H:%M:%S") + " - " + text + "\n")

    def docker(self, *args, timeout=30):
        return self.app.run_command(["docker", *args], timeout=timeout)

    def require(self, result):
        if not result.get("ok"):
            raise BootFailure(result.get("stderr") or result.get("stdout") or "Aktion fehlgeschlagen")
        return result

    def inspect(self, config):
        result = self.docker("container", "inspect", config["container_name"])
        if not result["ok"]:
            if "No such" in result.get("stderr", ""):
                return None
            raise BootFailure("Docker-Status nicht verfuegbar: " + result.get("stderr", ""))
        return json.loads(result["stdout"])[0]

    def ready(self, config, info):
        state = info.get("State", {})
        if not state.get("Running") or state.get("Restarting"):
            return False
        if state.get("Health", {}).get("Status") == "healthy":
            return True
        return minecraft_ping(config["host_port"])

    def stop(self, config):
        if self.inspect(config):
            self.require(self.docker("update", "--restart=no", config["container_name"]))
            self.require(self.docker("stop", "--time", "60", config["container_name"], timeout=90))
            if self.inspect(config)["State"].get("Running"):
                raise BootFailure("Container konnte nicht sicher gestoppt werden.")

    def capture_failure(self, config, reason, append=False):
        result = self.docker("logs", "--timestamps", "--tail", "4000", config["container_name"])
        state = self.inspect(config)
        text = (f"Zeit: {time.strftime('%Y-%m-%d %H:%M:%S')}\nGrund: {reason}\n"
                f"Server: {config['container_name']} / {config.get('type')} {config.get('version')}\n"
                f"Zustand: {json.dumps((state or {}).get('State', {}), ensure_ascii=False)}\n\n"
                + result.get("stdout", "") + "\n" + result.get("stderr", ""))
        # Do not expose known credentials in the retained log or the API.
        for secret in [config.get("rcon_password", "")]:
            if secret:
                text = text.replace(secret, "[REDACTED]")
        path = self.directory(config) / "last-failed-boot.log"
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        with path.open("a" if append else "w", encoding="utf-8") as stream:
            stream.write("\n" + text)
        self.save(config, state="error", reason=reason, failure_at=time.strftime("%Y-%m-%d %H:%M:%S"))
        self.log(config, reason)

    def previous_profile(self, config, info):
        """Recover applied settings even if Save already overwrote the profile."""
        previous = dict(config)
        env = dict(item.split("=", 1) for item in info["Config"].get("Env", []) if "=" in item)
        mapping = {"MEMORY": "memory", "INIT_MEMORY": "init_memory", "MAX_MEMORY": "max_memory",
                   "TYPE": "type", "VERSION": "version", "PAPER_CHANNEL": "paper_channel",
                   "RCON_PASSWORD": "rcon_password", "RCON_PORT": "rcon_container_port"}
        for key, field in mapping.items():
            previous[field] = env.get(key, self.app.DEFAULT_SERVER.get(field, ""))
        previous["rcon_enabled"] = env.get("ENABLE_RCON", "false").lower() == "true"
        previous["docker_image"] = info["Image"]  # immutable local image ID
        previous["start_after_apply"] = True
        previous["backup_before_apply"] = False
        mounts = [m for m in info.get("Mounts", []) if m.get("Destination") in {"/data", "/server"}]
        if len(mounts) != 1 or mounts[0].get("Type") != "bind":
            raise BootFailure("Ruecksicherung benoetigt genau einen Daten-Bind-Mount.")
        if Path(mounts[0]["Source"]).resolve() != Path(config["data_dir"]).resolve():
            raise BootFailure("Datenordner weicht vom laufenden Container ab. Zuerst Daten verschieben.")
        previous["data_dir"] = mounts[0]["Source"]
        game = str(env.get("SERVER_PORT", "25565"))
        ports = info.get("HostConfig", {}).get("PortBindings", {})
        extra = []
        for destination, bindings in ports.items():
            for binding in bindings or []:
                if binding.get("HostIp") not in {None, "", "0.0.0.0", "::"}:
                    raise BootFailure("Spezielle Host-IP-Portbindungen werden fuer Rollback nicht unterstuetzt.")
                port, protocol = destination.split("/")
                if port == game and protocol == "tcp":
                    previous["host_port"] = binding["HostPort"]
                elif port == str(previous["rcon_container_port"]) and protocol == "tcp":
                    previous["rcon_host_port"] = binding["HostPort"]
                else:
                    extra.append(f"{binding['HostPort']}:{destination}")
        previous["extra_ports"] = " ".join(extra)
        networks = info.get("NetworkSettings", {}).get("Networks", {})
        custom = [name for name in networks if name != "bridge"]
        previous["docker_network"] = custom[0] if len(custom) == 1 else ""
        previous["docker_network_alias"] = ""
        if custom:
            aliases = networks[custom[0]].get("Aliases") or []
            previous["docker_network_alias"] = next((a for a in aliases if a != config["container_name"] and a != info.get("Id", "")[:12]), "")
        previous["pinned_server_jar"] = env.get("PAPER_CUSTOM_JAR", "")
        # Paper/Folia record the resolved version and exact jar after installation.
        metadata = Path(config["data_dir"]) / ".paper.env"
        if previous["type"].upper() in {"PAPER", "FOLIA"} and metadata.is_file():
            values = {}
            for line in metadata.read_text(encoding="utf-8").splitlines():
                match = re.match(r"(?:export\s+)?(VERSION|SERVER)=(.*)$", line.strip())
                if match:
                    tokens = shlex.split(match[2])
                    if len(tokens) == 1:
                        values[match[1]] = tokens[0]
            jar = values.get("SERVER", "")
            relative = jar.removeprefix("/data/")
            local = (Path(config["data_dir"]) / relative).resolve()
            if jar and Path(config["data_dir"]).resolve() in local.parents and local.is_file():
                previous["pinned_server_jar"] = "/data/" + relative
                previous["version"] = values.get("VERSION", previous["version"])
        # Fail closed for platforms where an exact runtime cannot yet be pinned.
        pinned = (bool(previous["pinned_server_jar"]) and previous["type"].upper() in {"PAPER", "FOLIA"}
                  and str(previous["version"]).upper() not in {"", "LATEST", "SNAPSHOT"})
        return previous, pinned

    def snapshot(self, config):
        info = self.inspect(config)
        previous, pinned = self.previous_profile(config, info) if info else (dict(config), False)
        previous.pop("_scheduled", None)
        was_ready = bool(info and self.ready(previous, info))
        self.stop(config)
        data = self.app.resolve_data_dir_path(config["data_dir"])
        data.mkdir(parents=True, exist_ok=True)
        root = Path(config["backup_root"]).expanduser().resolve() / "boot-guard" / config["id"]
        if data == root or data in root.parents or root in data.parents:
            raise BootFailure("Startschutz-Backups muessen ausserhalb des Datenordners liegen.")
        root.mkdir(parents=True, exist_ok=True, mode=0o700)
        folder = Path(tempfile.mkdtemp(prefix="checkpoint-", dir=root))
        archive = folder / "data.tar"
        self.save(config, state="preparing", reason="Konsistentes Startschutz-Backup wird erstellt.")
        self.log(config, f"Startschutz-Backup: {archive}. Server ist gestoppt.")
        try:
            self.require(self.app.run_command(["tar", "--exclude=./backups", "-cpf", str(archive), "-C", str(data), "."], timeout=3600))
            self.require(self.app.run_command(["tar", "-tf", str(archive)], timeout=3600))
        except Exception:
            # A partial archive must not consume the remaining disk on each retry.
            if archive.exists():
                archive.unlink()
            raise
        checkpoint = {"archive": str(archive), "profile": previous, "rollback_allowed": was_ready and pinned}
        atomic_json(folder / "checkpoint.json", checkpoint)
        old = self.read(config).get("checkpoint")
        self.save(config, checkpoint=checkpoint, pending=True)
        # Keep one previous complete checkpoint until its replacement is safely written.
        if old:
            old_folder = Path(old["archive"]).parent
            if old_folder.parent == root and old_folder.name.startswith("checkpoint-") and old_folder != folder:
                try:
                    shutil.rmtree(old_folder)
                except OSError as exc:
                    self.log(config, f"Altes Backup konnte nicht entfernt werden: {exc}")
        return checkpoint

    def wait_ready(self, config):
        timeout = int(config.get("boot_timeout_seconds", 600))
        stable = int(config.get("boot_stability_seconds", 120))
        deadline = time.monotonic() + timeout
        healthy_since = None
        identity = None
        self.save(config, state="checking", reason="Minecraft-Start und Stabilitaet werden geprueft.")
        self.log(config, f"Startpruefung: maximal {timeout}s bis bereit, danach {stable}s stabil.")
        while True:
            info = self.inspect(config)
            state = (info or {}).get("State", {})
            if not info or not state.get("Running") or state.get("Restarting") or state.get("OOMKilled"):
                raise BootFailure(f"Start fehlgeschlagen: {state.get('Status', 'Container fehlt')}, Exit {state.get('ExitCode', '?')}.")
            current = (info.get("Id"), state.get("StartedAt"))
            if identity is not None and identity != current:
                raise BootFailure("Container wurde waehrend der Startpruefung neu gestartet.")
            identity = current
            boot_log = self.docker("logs", "--since", state["StartedAt"], "--tail", "4000", config["container_name"])
            output = boot_log.get("stdout", "") + boot_log.get("stderr", "")
            problem = re.search(r"(?im)^.*(?:Error occurred while enabling|Error occurred while loading|Could not load ['\"].*plugins|Could not load plugin|InvalidPluginException|NoCapablePlatformException|Failed to load data\s*packs|Failed to start the minecraft server).*$", output)
            if problem:
                raise BootFailure("Fehler beim Laden von Server/Plugins: " + problem.group(0)[-500:])
            now = time.monotonic()
            if self.ready(config, info):
                if healthy_since is None:
                    healthy_since = now
                    self.log(config, "Minecraft antwortet; pruefe Stabilitaet.")
                if now - healthy_since >= stable:
                    self.require(self.docker("update", "--restart=on-failure:3", config["container_name"]))
                    self.save(config, state="healthy", reason="Startpruefung erfolgreich.", pending=False)
                    self.observed.pop(config["id"], None)
                    self.log(config, "Startpruefung erfolgreich. Wiederherstellungspunkt bleibt bis zur naechsten Aenderung erhalten.")
                    return
            else:
                healthy_since = None
            if (healthy_since is None and now >= deadline) or now >= deadline + stable:
                raise BootFailure("Startzeitlimit/Stabilitaetspruefung ueberschritten.")
            time.sleep(5)

    def restore(self, config, checkpoint):
        self.stop(config)
        data = self.app.resolve_data_dir_path(config["data_dir"])
        archive = Path(checkpoint["archive"])
        self.log(config, f"Stelle vollstaendigen Datenstand aus {archive} wieder her.")
        stage = Path(tempfile.mkdtemp(prefix=f".{data.name}-restore-", dir=data.parent))
        self.require(self.app.run_command(["tar", "-xpf", str(archive), "-C", str(stage)], timeout=3600))
        # Preserve failed data for diagnosis; never overlay old/new plugin jars.
        failed = data.with_name(data.name + ".failed-" + str(time.time_ns()))
        data.rename(failed)
        try:
            stage.rename(data)
        except Exception:
            failed.rename(data)
            raise
        if (failed / "backups").exists() and not (data / "backups").exists():
            (failed / "backups").rename(data / "backups")
        self.log(config, f"Fehlgeschlagener Datenstand bleibt erhalten: {failed}")
        previous = checkpoint["profile"]
        self.app.write_server(previous)
        if not checkpoint["rollback_allowed"]:
            raise BootFailure("Daten zurueckgesichert. Kein nachweislich gesunder, exakt fixierter Paper/Folia-Startstand: Server bleibt gestoppt.")
        self.require(self.app._run_backend_action(previous, "apply"))
        self.wait_ready(previous)
        self.save(config, state="rolled_back", reason="Aenderung fehlgeschlagen; vorheriger Stand wiederhergestellt und geprueft.", pending=False)
        return previous

    def run(self, config, action):
        if action in {"logs", "status"}:
            return self.app._run_backend_action(config, action)
        with self.exclusive(config):
            if action == "rcon":
                return self.app._run_backend_action(config, action)
            checkpoint = None
            changed = False
            state = self.read(config)
            if state.get("state") in {"preparing", "updating", "checking", "restoring"}:
                # No other owner holds this lock: this is an interrupted operation.
                # Do not reuse an old pending rollback automatically after a WebUI restart.
                self.capture_failure(config, "Vorherige Aktion wurde unterbrochen. Server gestoppt; bitte Wiederherstellungspunkt pruefen und danach manuell starten.")
                self.stop(config)
                self.save(config, pending=False)
                return {"ok": False, "code": 1, "stdout": "", "stderr": "Unterbrochene Aktion erkannt. Manuelle Pruefung erforderlich."}
            if config.get("_scheduled") and state.get("state") in {"error", "rolled_back"} and action not in {"stop", "disable", "backup"}:
                return {"ok": False, "code": 1, "stdout": "", "stderr": "Automatisierung blockiert: letzter Start fehlgeschlagen. Bitte manuell pruefen/starten."}
            try:
                if action in {"stop", "disable", "backup", "restore"}:
                    self.stop(config)
                    # Stop/backup must not discard a pending pre-update checkpoint.
                    pending = bool(state.get("pending")) and action != "restore"
                    self.save(config, state="pending" if pending else "stopped", pending=pending, reason="Server gestoppt; Startpruefung steht aus." if pending else "Manuell gestoppt.")
                    return self.app._run_backend_action(config, action)
                if action not in {"apply", "start", "restart", "plugins", "plugins-restart"}:
                    return self.app._run_backend_action(config, action)
                (self.directory(config)).mkdir(parents=True, exist_ok=True, mode=0o700)
                (self.directory(config) / "action.log").write_text("", encoding="utf-8")
                if state.get("pending"):
                    checkpoint = state.get("checkpoint")
                    if not checkpoint or any(str(checkpoint["profile"].get(key)) != str(config.get(key)) for key in ("data_dir", "container_name")):
                        raise BootFailure("Vorgemerkter Wiederherstellungspunkt gehoert zu einem anderen Datenordner/Container.")
                    self.stop(config)
                else:
                    checkpoint = self.snapshot(config)
                self.save(config, state="updating", reason="Aenderung wird angewendet.")
                changed = True
                effective = config | {"backup_before_apply": False}
                if action in {"start", "restart", "plugins-restart"}:
                    effective["start_after_apply"] = True
                if action in {"plugins", "plugins-restart"}:
                    self.require(self.app._run_backend_action(effective, "plugins"))
                    if action == "plugins":
                        self.save(config, state="pending", reason="Plugins aktualisiert. Server bleibt bis Start/Restart gestoppt.")
                        return {"ok": True, "code": 0, "stdout": "Plugins aktualisiert. Startschutz-Backup gesichert; jetzt Start/Restart zur Pruefung ausfuehren.", "stderr": ""}
                    action = "restart"
                result = self.app._run_backend_action(effective, action)
                self.require(result)
                if not effective.get("start_after_apply", True):
                    self.save(config, state="pending", reason="Angewendet, Start deaktiviert. Wiederherstellungspunkt bleibt vorgemerkt.")
                    return result
                self.wait_ready(effective)
                result["stdout"] += "\nStartpruefung erfolgreich."
                return result
            except Exception as exc:
                reason = str(exc)
                rollback = False
                try:
                    self.capture_failure(config, reason)
                    self.stop(config)
                    if checkpoint and changed:
                        self.save(config, state="restoring", reason="Fehlstart: Ruecksicherung laeuft.", pending=False)
                        self.restore(config, checkpoint)
                        rollback = True
                except Exception as recovery_error:
                    reason += "\nRuecksicherung/Stop: " + str(recovery_error)
                    try:
                        self.capture_failure(config, str(recovery_error), append=True)
                        self.stop(config)
                    except Exception as stop_error:
                        reason += "\nStop fehlgeschlagen: " + str(stop_error)
                    self.save(config, state="error", reason=reason, pending=False)
                else:
                    if not rollback:
                        self.save(config, state="error", reason=reason, pending=False)
                message = "Aenderung fehlgeschlagen; vorheriger Stand wiederhergestellt." if rollback else "Fehler – Eingriff erforderlich."
                return {"ok": False, "code": 1, "stdout": message, "stderr": reason, "message": message, "rolled_back": rollback}

    def monitor_once(self, config):
        with self.exclusive(config):
            saved = self.read(config)
            info = self.inspect(config)
            if not info:
                return
            state = info.get("State", {})
            phase = saved.get("state")
            if phase in {"preparing", "updating", "checking", "restoring"}:
                self.capture_failure(config, "WebUI wurde waehrend einer Aktion unterbrochen. Wiederherstellungspunkt bleibt zur manuellen Pruefung erhalten.")
                self.stop(config)
                self.save(config, pending=False)
                return
            if phase in {"pending", "stopped", "error"} or self.app.is_disabled(config):
                if state.get("Running") or state.get("Restarting"):
                    self.stop(config)
                return
            if not state.get("Running") and not state.get("Restarting"):
                if phase in {"healthy", "rolled_back"} or state.get("ExitCode", 0) != 0:
                    self.capture_failure(config, "Server unerwartet beendet. Kein automatischer Welt-Rollback nach laufendem Betrieb.")
                    self.stop(config)
                return
            now = time.monotonic()
            observation = self.observed.get(config["id"])
            identity = info.get("Id")
            if observation is None or observation["id"] != identity:
                observation = {"id": identity, "count": info.get("RestartCount", 0), "events": [], "unready": now, "ready_since": None}
                self.observed[config["id"]] = observation
                self.require(self.docker("update", "--restart=on-failure:3", config["container_name"]))
                if state.get("Restarting") and info.get("RestartCount", 0) >= 3:
                    observation["events"] = [now] * 3
            count = info.get("RestartCount", 0)
            observation["events"] += [now] * min(3, max(0, count - observation["count"]))
            observation["count"] = count
            observation["events"] = [stamp for stamp in observation["events"] if now - stamp < 300]
            ready = self.ready(config, info)
            if ready:
                observation["unready"] = now
                if observation["ready_since"] is None:
                    observation["ready_since"] = now
                if not phase and now - observation["ready_since"] >= int(config.get("boot_stability_seconds", 120)):
                    self.save(config, state="healthy", reason="Laufender Server vom Startschutz uebernommen.")
            else:
                observation["ready_since"] = None
            reason = None
            if len(observation["events"]) >= 3:
                reason = "Neustartschleife erkannt: mindestens 3 Neustarts in 5 Minuten."
            elif now - observation["unready"] >= int(config.get("boot_timeout_seconds", 600)):
                reason = "Server antwortet nicht innerhalb des Startzeitlimits."
            if reason:
                self.capture_failure(config, reason + " Server wird gestoppt; kein Welt-Rollback nach laufendem Betrieb.")
                self.stop(config)

    def monitor_loop(self):
        while True:
            try:
                servers = self.app.list_servers()
            except Exception as exc:
                print(f"Startschutz: Profile nicht lesbar: {exc}", flush=True)
                time.sleep(5)
                continue
            for config in servers:
                try:
                    self.monitor_once(config)
                except BootFailure:
                    # Busy servers and temporary Docker outages are retried next pass.
                    continue
                except Exception as exc:
                    print(f"Startschutz {config['id']}: {exc}", flush=True)
            time.sleep(5)
