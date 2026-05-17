#!/usr/bin/env python3
import base64
import io
import json
import os
import re
import shutil
import shlex
import socket
import subprocess
import tempfile
import urllib.parse
import urllib.request
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BACKEND = ROOT / "webui" / "backend.sh"
STATIC_DIR = ROOT / "webui" / "static"
APP_VERSION = "v1.0.10"
STATE_DIR = Path(os.environ.get("MCDOCKER_WEBUI_HOME", Path.home() / ".minecraftdocker-webui"))
SERVER_DIR = STATE_DIR / "servers"
RUN_DIR = STATE_DIR / "run"
INIT_MARKER = STATE_DIR / ".initialized"
SAFE_ID = re.compile(r"^[a-zA-Z0-9_.-]+$")
PORT_RE = re.compile(r"^(\d+):(\d+)(?:/(tcp|udp))?$", re.I)
MEMORY_RE = re.compile(r"^(\d+)\s*([kmg])(?:b)?$", re.I)

DEFAULT_SERVER = {
    "id": "survival",
    "name": "Survival",
    "data_dir": "/opt/minecraft/survival",
    "container_name": "mc-survival",
    "memory": "6G",
    "init_memory": "",
    "max_memory": "",
    "type": "PAPER",
    "version": "LATEST",
    "paper_channel": "default",
    "host_port": "25565",
    "extra_ports": "",
    "map_url": "",
    "docker_image": "itzg/minecraft-server",
    "eula_accepted": False,
    "backup_before_apply": False,
    "start_after_apply": True,
    "disabled": False,
    "rcon_enabled": True,
    "rcon_password": "",
    "rcon_host_port": "25575",
    "rcon_container_port": "25575",
    "backup_root": str(Path.home() / "minecraftdocker-backups"),
}

def ensure_state():
    SERVER_DIR.mkdir(parents=True, exist_ok=True)
    RUN_DIR.mkdir(parents=True, exist_ok=True)
    if INIT_MARKER.exists():
        return
    if any(SERVER_DIR.glob("*.json")):
        INIT_MARKER.write_text("ok\n", encoding="utf-8")
        return
    sample = SERVER_DIR / "survival.json"
    sample.write_text(json.dumps(DEFAULT_SERVER, indent=2) + "\n", encoding="utf-8")
    INIT_MARKER.write_text("ok\n", encoding="utf-8")


def server_path(server_id):
    if not SAFE_ID.match(server_id):
        raise ValueError("invalid server id")
    return SERVER_DIR / f"{server_id}.json"


def read_server(server_id):
    path = server_path(server_id)
    if not path.exists():
        raise FileNotFoundError(server_id)
    data = DEFAULT_SERVER.copy()
    data.update(json.loads(path.read_text(encoding="utf-8")))
    return data


def is_disabled(config):
    value = config.get("disabled", False)
    if isinstance(value, str):
        return value.lower() in {"1", "true", "yes", "ja", "on"}
    return bool(value)


def normalize_memory_value(value):
    value = str(value or "").strip()
    match = MEMORY_RE.match(value)
    if match:
        return f"{match.group(1)}{match.group(2).upper()}"
    return value


def write_server(data):
    server_id = str(data.get("id", "")).strip()
    if not server_id:
        server_id = re.sub(r"[^a-z0-9_.-]+", "-", str(data.get("name", "server")).lower()).strip("-") or "server"
    if not SAFE_ID.match(server_id):
        raise ValueError("server id may only contain letters, numbers, dot, underscore and dash")
    existing = {}
    path = server_path(server_id)
    if path.exists():
        try:
            existing = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            existing = {}
    merged = DEFAULT_SERVER.copy()
    merged.update(existing)
    merged.update(data)
    merged["id"] = server_id
    merged["container_name"] = merged.get("container_name") or f"mc-{server_id}"
    merged["data_dir"] = merged.get("data_dir") or f"/opt/minecraft/{server_id}"
    for key in ("memory", "init_memory", "max_memory"):
        merged[key] = normalize_memory_value(merged.get(key, ""))
    merged["disabled"] = is_disabled(merged)
    warnings = port_warnings(merged)
    server_path(server_id).write_text(json.dumps(merged, indent=2) + "\n", encoding="utf-8")
    merged["warnings"] = warnings
    return merged


def set_server_disabled(server_id, disabled):
    config = read_server(server_id)
    config["disabled"] = bool(disabled)
    return write_server(config)


def remove_container(container_name):
    name = str(container_name or "").strip()
    if not name:
        return ["Kein Containername im Profil gesetzt."]
    result = run_command(["docker", "container", "rm", "-f", name], timeout=60)
    stdout = result.get("stdout", "").strip()
    stderr = result.get("stderr", "").strip()
    if result.get("ok"):
        return [f"Container {name} geloescht."]
    if result.get("code") == 127:
        raise RuntimeError(f"Docker konnte nicht ausgefuehrt werden: {stderr}")
    if "No such container" in stderr or "No such object" in stderr:
        return [f"Container {name} war nicht vorhanden."]
    raise RuntimeError(f"Container {name} konnte nicht geloescht werden: {stderr or stdout}")


def resolve_data_dir_path(raw):
    raw = str(raw or "").strip()
    if not raw:
        raise ValueError("Kein Datenordner im Profil gesetzt.")
    target = Path(raw).expanduser().resolve()
    roots = [STATE_DIR.resolve(), ROOT.resolve()]
    if target.parent == target or len(target.parts) < 3 or any(target == root or target in root.parents or root in target.parents for root in roots):
        raise ValueError(f"Datenordner ist aus Sicherheitsgruenden nicht erlaubt: {target}")
    return target


def delete_data_dir(config):
    raw = str(config.get("data_dir") or "").strip()
    if not raw:
        return ["Kein Datenordner im Profil gesetzt."]
    target = resolve_data_dir_path(raw)
    if not target.exists():
        return [f"Datenordner war nicht vorhanden: {target}"]
    if not target.is_dir():
        raise ValueError(f"Datenpfad ist kein Ordner: {target}")
    shutil.rmtree(target)
    return [f"Datenordner geloescht: {target}"]


def delete_server(server_id):
    INIT_MARKER.parent.mkdir(parents=True, exist_ok=True)
    INIT_MARKER.write_text("ok\n", encoding="utf-8")
    config = read_server(server_id)
    details = []
    details.extend(remove_container(config.get("container_name")))
    details.extend(delete_data_dir(config))
    path = server_path(server_id)
    if path.exists():
        path.unlink()
        details.append(f"Serverprofil {server_id} geloescht.")
    return {"message": f"Server {server_id} geloescht.", "details": details}


def delete_local_data(config):
    details = []
    details.extend(remove_container(config.get("container_name")))
    details.extend(delete_data_dir(config))
    details.append("Profil bleibt erhalten. Start oder Anwenden legt Container und Daten neu an.")
    return {"ok": True, "code": 0, "stdout": "\n".join(details), "stderr": ""}


def move_data_dir(server_id, target_raw, profile_update=None):
    config = read_server(server_id)
    source = resolve_data_dir_path(config.get("data_dir"))
    target = resolve_data_dir_path(target_raw)
    if source == target:
        return {"message": "Datenverzeichnis ist bereits auf diesen Pfad gesetzt.", "details": [], "server": config}
    if source in target.parents:
        raise ValueError("Der neue Datenordner darf nicht innerhalb des alten Datenordners liegen.")
    details = []
    details.extend(remove_container(config.get("container_name")))
    if source.exists():
        if not source.is_dir():
            raise ValueError(f"Alter Datenpfad ist kein Ordner: {source}")
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists():
            if not target.is_dir():
                raise ValueError(f"Zielpfad ist kein Ordner: {target}")
            if any(target.iterdir()):
                raise ValueError(f"Zielordner ist nicht leer: {target}")
            target.rmdir()
        shutil.move(str(source), str(target))
        details.append(f"Datenordner verschoben: {source} -> {target}")
    else:
        target.mkdir(parents=True, exist_ok=True)
        details.append(f"Alter Datenordner war nicht vorhanden; neuer Datenordner erstellt: {target}")
    updated = config.copy()
    if isinstance(profile_update, dict):
        updated.update(profile_update)
    updated["id"] = server_id
    updated["data_dir"] = str(target)
    saved = write_server(updated)
    details.append("Profil wurde auf den neuen Datenordner aktualisiert.")
    return {"message": "Datenverzeichnis verschoben.", "details": details, "server": saved}


def list_servers():
    ensure_state()
    out = []
    for path in sorted(SERVER_DIR.glob("*.json")):
        try:
            data = DEFAULT_SERVER.copy()
            data.update(json.loads(path.read_text(encoding="utf-8")))
            out.append(data)
        except json.JSONDecodeError:
            pass
    return out


def run_command(args, timeout=60):
    try:
        proc = subprocess.run(args, text=True, capture_output=True, timeout=timeout)
        return {"ok": proc.returncode == 0, "code": proc.returncode, "stdout": proc.stdout, "stderr": proc.stderr}
    except FileNotFoundError as exc:
        return {"ok": False, "code": 127, "stdout": "", "stderr": str(exc)}
    except subprocess.TimeoutExpired as exc:
        return {"ok": False, "code": 124, "stdout": exc.stdout or "", "stderr": f"Command timed out after {timeout}s"}


def docker_status(config):
    if is_disabled(config):
        return {"state": "deaktiviert", "running": False, "disabled": True}
    result = run_command(["docker", "container", "inspect", config.get("container_name", ""), "--format", "{{json .State}}"], timeout=15)
    if not result["ok"]:
        return {"state": "missing", "running": False}
    try:
        state = json.loads(result["stdout"])
    except json.JSONDecodeError:
        return {"state": "unknown", "running": False}
    return {"state": state.get("Status", "unknown"), "running": bool(state.get("Running")), "started_at": state.get("StartedAt")}


def parse_ports(config):
    ports = []
    if str(config.get("host_port", "")).isdigit():
        ports.append(("minecraft", int(config["host_port"]), "tcp"))
    if config.get("rcon_enabled") and str(config.get("rcon_host_port", "")).isdigit():
        ports.append(("rcon", int(config["rcon_host_port"]), "tcp"))
    for raw in re.split(r"[\s,]+", str(config.get("extra_ports", "")).strip()):
        if not raw:
            continue
        match = PORT_RE.match(raw)
        if match:
            ports.append(("extra", int(match.group(1)), (match.group(3) or "tcp").lower()))
    return ports


def port_is_open(port, proto):
    if proto == "udp":
        return False
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(0.25)
    try:
        return sock.connect_ex(("127.0.0.1", int(port))) == 0
    finally:
        sock.close()


def docker_published_ports():
    result = run_command(["docker", "ps", "--format", "{{json .}}"], timeout=15)
    used = {}
    if not result["ok"]:
        return used
    for line in result["stdout"].splitlines():
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            row = {"Ports": line, "Names": "unknown"}
        for match in re.finditer(r":(\d+)->\d+/(tcp|udp)", str(row.get("Ports", ""))):
            used.setdefault((int(match.group(1)), match.group(2)), set()).add(row.get("Names", "unknown"))
    return used


def port_warnings(config):
    warnings = []
    profile_ports = {}
    for server in list_servers():
        if server.get("id") == config.get("id"):
            continue
        if is_disabled(server):
            continue
        for label, port, proto in parse_ports(server):
            profile_ports.setdefault((port, proto), []).append(f"{server.get('name') or server.get('id')}:{label}")
    current = parse_ports(config)
    used_by_docker = docker_published_ports()
    own_name = config.get("container_name")
    seen = {}
    for label, port, proto in current:
        key = (port, proto)
        if key in seen:
            warnings.append(f"{label}: Port {port}/{proto} ist im selben Profil doppelt belegt ({seen[key]}).")
        seen[key] = label
        if key in profile_ports:
            warnings.append(f"{label}: Port {port}/{proto} kollidiert mit Profil {', '.join(profile_ports[key])}.")
        docker_names = used_by_docker.get(key, set())
        if port_is_open(port, proto) and own_name not in docker_names:
            warnings.append(f"{label}: Port {port}/{proto} scheint auf dem Host bereits offen zu sein.")
    for label, port, proto in current:
        names = used_by_docker.get((port, proto), set())
        if names and own_name not in names:
            warnings.append(f"{label}: Port {port}/{proto} wird bereits von Docker-Container {', '.join(sorted(names))} publiziert.")
        elif names and own_name in names:
            warnings.append(f"{label}: Port {port}/{proto} wird vom eigenen Container {own_name} genutzt.")
    if config.get("rcon_enabled") and not config.get("rcon_password"):
        warnings.append("rcon: RCON ist aktiv, aber es ist noch kein Passwort gesetzt.")
    if not config.get("eula_accepted"):
        warnings.append("eula: Die Minecraft EULA ist noch nicht akzeptiert; Anwenden wird blockiert.")
    return warnings


def blocking_action_warnings(config):
    blockers = []
    for warning in port_warnings(config):
        if (
            warning.startswith("eula:")
            or "doppelt" in warning
            or "kollidiert mit Profil" in warning
            or "scheint auf dem Host bereits offen" in warning
            or "wird bereits von Docker-Container" in warning
        ):
            blockers.append(warning)
    return blockers


def plugins_path(config):
    return Path(config.get("data_dir", "")) / "plugins.txt"


def manual_plugin_dir(config):
    return Path(config.get("data_dir", "")) / "plugins" / "manuell"


def list_manual_plugins(config):
    path = manual_plugin_dir(config)
    if not path.exists():
        return []
    return sorted(p.name for p in path.glob("*.jar") if p.is_file())


def list_installed_plugins(config):
    path = Path(config.get("data_dir", "")) / "plugins"
    if not path.exists():
        return []
    plugins = []
    for jar in sorted(path.glob("*.jar")):
        if jar.is_file():
            stat = jar.stat()
            plugins.append({"name": jar.name, "path": str(jar), "size": stat.st_size, "mtime": stat.st_mtime})
    return plugins


def delete_installed_plugin(config, name):
    if "/" in name or "\\" in name or not name.endswith(".jar"):
        raise ValueError("Nur .jar-Dateien ohne Pfad sind erlaubt.")
    path = Path(config.get("data_dir", "")) / "plugins" / name
    if path.exists() and path.is_file():
        path.unlink()


EDITABLE_EXTENSIONS = {".conf", ".cfg", ".json", ".properties", ".secret", ".txt", ".toml", ".yml", ".yaml"}


def plugin_file_roots(config):
    data_dir = Path(config.get("data_dir", "")).resolve()
    return [data_dir, data_dir / "plugins", data_dir / "config"]


def safe_plugin_file(config, relative_path):
    rel = Path(str(relative_path).replace("\\", "/"))
    if rel.is_absolute() or ".." in rel.parts:
        raise ValueError("Ungueltiger Plugin-Dateipfad.")
    if rel.suffix.lower() not in EDITABLE_EXTENSIONS:
        raise ValueError("Nur typische Text-Konfigdateien koennen bearbeitet werden.")
    data_dir = Path(config.get("data_dir", "")).resolve()
    target = (data_dir / rel).resolve()
    plugin_root = (data_dir / "plugins").resolve()
    config_root = (data_dir / "config").resolve()
    if target.parent != data_dir and not any(root in target.parents for root in (plugin_root, config_root)):
        raise ValueError("Plugin-Dateien duerfen nur direkt im Datenordner oder unter plugins/ oder config/ liegen.")
    return target


def list_plugin_files(config):
    data_dir = Path(config.get("data_dir", "")).resolve()
    files = []
    roots = [(data_dir, False), (data_dir / "plugins", True), (data_dir / "config", True)]
    for root, recursive in roots:
        if not root.exists():
            continue
        iterator = root.rglob("*") if recursive else root.glob("*")
        for path in sorted(iterator):
            if not path.is_file() or path.suffix.lower() not in EDITABLE_EXTENSIONS:
                continue
            stat = path.stat()
            if stat.st_size > 1024 * 1024:
                continue
            files.append({"path": path.resolve().relative_to(data_dir).as_posix(), "size": stat.st_size})
    return files[:500]


def read_plugin_file(config, relative_path):
    path = safe_plugin_file(config, relative_path)
    if not path.exists():
        raise FileNotFoundError(str(relative_path))
    if path.stat().st_size > 1024 * 1024:
        raise ValueError("Datei ist groesser als 1 MiB und wird nicht im Browser editiert.")
    return path.read_text(encoding="utf-8", errors="replace")


def write_plugin_file(config, relative_path, content):
    path = safe_plugin_file(config, relative_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(str(content).rstrip() + "\n", encoding="utf-8")


def safe_data_path(config, relative_path=""):
    data_dir = Path(config.get("data_dir", "")).resolve()
    rel = Path(str(relative_path or "").replace("\\", "/"))
    if rel.is_absolute() or ".." in rel.parts:
        raise ValueError("Ungueltiger Dateipfad.")
    target = (data_dir / rel).resolve()
    if target != data_dir and data_dir not in target.parents:
        raise ValueError("Pfad liegt ausserhalb des Datenordners.")
    return data_dir, target


def list_data_files(config, relative_path=""):
    data_dir, target = safe_data_path(config, relative_path)
    if not target.exists():
        return {"cwd": target.relative_to(data_dir).as_posix() if target != data_dir else "", "entries": []}
    if not target.is_dir():
        raise ValueError("Pfad ist kein Ordner.")
    entries = []
    for path in sorted(target.iterdir(), key=lambda p: (not p.is_dir(), p.name.lower())):
        try:
            stat = path.stat()
        except OSError:
            continue
        entries.append({
            "name": path.name,
            "path": path.resolve().relative_to(data_dir).as_posix(),
            "type": "dir" if path.is_dir() else "file",
            "size": stat.st_size,
        })
    return {"cwd": target.relative_to(data_dir).as_posix() if target != data_dir else "", "entries": entries[:500]}


def delete_data_entry(config, relative_path):
    data_dir, target = safe_data_path(config, relative_path)
    if target == data_dir:
        raise ValueError("Der Datenordner selbst kann nicht geloescht werden.")
    if target.is_dir():
        shutil.rmtree(target)
    elif target.exists():
        target.unlink()


def rename_data_entry(config, relative_path, new_name):
    data_dir, target = safe_data_path(config, relative_path)
    if target == data_dir:
        raise ValueError("Der Datenordner selbst kann nicht umbenannt werden.")
    if "/" in new_name or "\\" in new_name or new_name in {"", ".", ".."}:
        raise ValueError("Ungueltiger neuer Name.")
    dest = (target.parent / new_name).resolve()
    if data_dir not in dest.parents:
        raise ValueError("Ziel liegt ausserhalb des Datenordners.")
    target.rename(dest)
    return dest.relative_to(data_dir).as_posix()


def make_data_dir(config, relative_path):
    _, target = safe_data_path(config, relative_path)
    target.mkdir(parents=True, exist_ok=True)


def extract_zip_upload(config, target_dir, name, content_b64):
    if not name.lower().endswith(".zip"):
        raise ValueError("Bitte einen .zip Ordner hochladen.")
    data_dir, target = safe_data_path(config, target_dir)
    target.mkdir(parents=True, exist_ok=True)
    payload = base64.b64decode(content_b64)
    with zipfile.ZipFile(io.BytesIO(payload)) as archive:
        for member in archive.infolist():
            if member.file_size > 1024 * 1024 * 1024:
                raise ValueError("ZIP enthaelt eine zu grosse Datei.")
            dest = (target / member.filename).resolve()
            if dest != data_dir and data_dir not in dest.parents:
                raise ValueError("ZIP enthaelt ungueltige Pfade.")
        archive.extractall(target)


def save_manual_plugin(config, name, content_b64):
    if not name.endswith(".jar") or "/" in name or "\\" in name:
        raise ValueError("Nur .jar-Dateien ohne Pfad sind erlaubt.")
    path = manual_plugin_dir(config)
    path.mkdir(parents=True, exist_ok=True)
    (path / name).write_bytes(base64.b64decode(content_b64))


def delete_manual_plugin(config, name):
    path = manual_plugin_dir(config) / name
    if path.exists() and path.is_file():
        path.unlink()


def backup_root(config):
    return Path(config.get("backup_root") or Path.home() / "minecraftdocker-backups")


def list_backups(config):
    root = backup_root(config)
    if not root.exists():
        return []
    prefixes = {
        re.sub(r"[^A-Za-z0-9_.-]+", "_", str(value)).strip("_")
        for value in (config.get("container_name"), config.get("id"), config.get("name"))
        if value
    }
    archives = [p for p in root.iterdir() if p.is_file() and (p.name.endswith(".tar.gz") or p.name.endswith(".tgz"))]

    def archive_score(path):
        name = path.name
        if any(name.startswith(f"{prefix}_backup_") for prefix in prefixes):
            return 0
        if any(prefix and prefix in name for prefix in prefixes):
            return 1
        return 2

    archives.sort(key=lambda p: (archive_score(p), -p.stat().st_mtime))
    return [{"name": p.name, "path": str(p), "size": p.stat().st_size} for p in archives[:200]]


def default_plugins_text():
    return "# Format: PluginName Quelle\n# Beispiele:\n# Geyser modrinth:geyser\n# Floodgate https://github.com/GeyserMC/Floodgate\n"


def read_plugins(config):
    path = plugins_path(config)
    return default_plugins_text() if not path.exists() else path.read_text(encoding="utf-8", errors="replace")


def write_plugins(config, content):
    path = plugins_path(config)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content.rstrip() + "\n", encoding="utf-8")


def server_properties_path(config):
    return Path(config.get("data_dir", "")) / "server.properties"


def read_server_properties(config):
    path = server_properties_path(config)
    if not path.exists():
        return "# server.properties wurde noch nicht gefunden.\n# Der Minecraft-Container legt die Datei meist beim ersten Start an.\n"
    return path.read_text(encoding="utf-8", errors="replace")


def write_server_properties(config, content):
    path = server_properties_path(config)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content.rstrip() + "\n", encoding="utf-8")


def read_action_log(config, lines=200):
    path = Path(config.get("data_dir", "")) / "update_log.txt"
    if not path.exists():
        return ""
    content = path.read_text(encoding="utf-8", errors="replace").splitlines()
    return "\n".join(content[-lines:])


def config_env(config):
    return {
        "DATA_DIR": config.get("data_dir", ""),
        "SERVER_NAME": config.get("container_name", ""),
        "MEMORY": config.get("memory", "6G"),
        "INIT_MEMORY": config.get("init_memory", ""),
        "MAX_MEMORY": config.get("max_memory", ""),
        "TYPE": config.get("type", "PAPER"),
        "VERSION": config.get("version", "LATEST"),
        "PAPER_CHANNEL": config.get("paper_channel", "default"),
        "HOST_PORT": config.get("host_port", "25565"),
        "EXTRA_PORTS": config.get("extra_ports", ""),
        "DOCKER_IMAGE": config.get("docker_image", "itzg/minecraft-server"),
        "EULA_ACCEPTED": "ja" if config.get("eula_accepted") else "nein",
        "DO_BACKUP": "ja" if config.get("backup_before_apply") else "nein",
        "DO_START_DOCKER": "ja" if config.get("start_after_apply", True) else "nein",
        "RCON_ENABLED": "ja" if config.get("rcon_enabled") else "nein",
        "RCON_PASSWORD": config.get("rcon_password", ""),
        "RCON_HOST_PORT": config.get("rcon_host_port", "25575"),
        "RCON_CONTAINER_PORT": config.get("rcon_container_port", "25575"),
        "RCON_COMMAND": config.get("rcon_command", ""),
        "BACKUP_ROOT": config.get("backup_root", ""),
        "BACKUP_FILE": config.get("backup_file", ""),
    }


def write_temp_env(config):
    fd, path = tempfile.mkstemp(prefix=f"{config['id']}-", suffix=".env", dir=RUN_DIR)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        for key, value in config_env(config).items():
            handle.write(f"{key}={shlex.quote(str(value))}\n")
    return path


def run_backend_action(config, action):
    if action in {"apply", "start", "restart"}:
        blockers = blocking_action_warnings(config)
        if blockers:
            return {"ok": False, "code": 2, "stdout": "", "stderr": "\n".join(blockers)}
    env_file = write_temp_env(config)
    try:
        return run_command(["bash", str(BACKEND), "--config", env_file, "--action", action], timeout=3600)
    finally:
        try:
            os.unlink(env_file)
        except OSError:
            pass


def run_rcon_command(config, command):
    config = config.copy()
    config["rcon_command"] = command
    return run_backend_action(config, "rcon")


def parse_player_list(result):
    text = f"{result.get('stdout', '')}\n{result.get('stderr', '')}"
    online = None
    max_players = None
    players = []
    match = re.search(r"There are (\d+) of a max of (\d+) players online:?\s*(.*)", text, re.I | re.S)
    if match:
        online = int(match.group(1))
        max_players = int(match.group(2))
        tail = match.group(3).strip()
        tail = re.split(r"[\r\n]", tail, 1)[0].strip()
        players = [name.strip() for name in tail.split(",") if name.strip()]
    return {
        "ok": result.get("ok", False),
        "online": online if online is not None else len(players),
        "max": max_players,
        "players": players,
        "raw": text.strip(),
    }


def map_upstream_base(config):
    raw = str(config.get("map_url") or "").strip()
    if raw:
        return raw.rstrip("/") + "/"
    port = "8100"
    for entry in re.split(r"[\s,]+", str(config.get("extra_ports", ""))):
        match = re.match(r"^(\d+):8100(?:/tcp)?$", entry, re.I)
        if match:
            port = match.group(1)
            break
    return f"http://127.0.0.1:{port}/"


def map_upstream_url(config, rest_path, query):
    base = map_upstream_base(config)
    target = urllib.parse.urljoin(base, rest_path)
    return f"{target}?{query}" if query else target


def fetch_versions(server_type):
    server_type = (server_type or "PAPER").upper()
    if server_type in {"VELOCITY", "BUNGEECORD"}:
        return ["LATEST"]
    if server_type in {"PAPER", "FOLIA"}:
        try:
            import urllib.request
            with urllib.request.urlopen(f"https://fill.papermc.io/v3/projects/{server_type.lower()}", timeout=10) as resp:
                data = json.load(resp)
            versions = []
            for group in data.get("versions", {}).values():
                versions.extend(group)
            unique = []
            for version in versions:
                if version not in unique:
                    unique.append(version)
            return ["LATEST"] + unique[:30]
        except Exception:
            return ["LATEST"]
    if server_type == "PURPUR":
        try:
            import urllib.request
            with urllib.request.urlopen("https://api.purpurmc.org/v2/purpur", timeout=10) as resp:
                data = json.load(resp)
            return ["LATEST"] + sorted(set(data.get("versions", [])), reverse=True)[:20]
        except Exception:
            return ["LATEST"]
    return ["LATEST"]


class Handler(BaseHTTPRequestHandler):
    def send_file(self, path, content_type):
        body = path.read_bytes()
        self.send_response(200)
        self.send_header("content-type", content_type)
        self.send_header("cache-control", "no-store, max-age=0")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_json(self, payload, status=200):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("content-type", "application/json; charset=utf-8")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_proxy(self, url):
        request = urllib.request.Request(url, headers={"user-agent": "minecraftdocker-webui"})
        with urllib.request.urlopen(request, timeout=30) as response:
            body = response.read()
            self.send_response(response.status)
            self.send_header("content-type", response.headers.get("content-type", "application/octet-stream"))
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    def read_json(self):
        length = int(self.headers.get("content-length", "0"))
        return json.loads(self.rfile.read(length).decode("utf-8")) if length else {}

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        parts = [part for part in parsed.path.split("/") if part]
        try:
            if parsed.path == "/":
                self.send_file(STATIC_DIR / "index.html", "text/html; charset=utf-8")
            elif parsed.path == "/static/style.css":
                self.send_file(STATIC_DIR / "style.css", "text/css; charset=utf-8")
            elif parsed.path == "/static/app.js":
                self.send_file(STATIC_DIR / "app.js", "text/javascript; charset=utf-8")
            elif parts == ["api", "version"]:
                self.send_json({"version": APP_VERSION})
            elif parts == ["api", "servers"]:
                payload = []
                for server in list_servers():
                    server["status"] = docker_status(server)
                    payload.append(server)
                self.send_json(payload)
            elif len(parts) == 4 and parts[:2] == ["api", "servers"] and parts[3] == "logs":
                self.send_json(run_backend_action(read_server(parts[2]), "logs"))
            elif len(parts) == 4 and parts[:2] == ["api", "servers"] and parts[3] == "plugins":
                self.send_json({"content": read_plugins(read_server(parts[2]))})
            elif len(parts) == 4 and parts[:2] == ["api", "servers"] and parts[3] == "properties":
                self.send_json({"content": read_server_properties(read_server(parts[2]))})
            elif len(parts) == 4 and parts[:2] == ["api", "servers"] and parts[3] == "action-log":
                self.send_json({"content": read_action_log(read_server(parts[2]))})
            elif len(parts) == 4 and parts[:2] == ["api", "servers"] and parts[3] == "ports":
                self.send_json({"warnings": port_warnings(read_server(parts[2]))})
            elif len(parts) == 4 and parts[:2] == ["api", "servers"] and parts[3] == "backups":
                self.send_json({"backups": list_backups(read_server(parts[2]))})
            elif len(parts) == 4 and parts[:2] == ["api", "servers"] and parts[3] == "manual-plugins":
                self.send_json({"plugins": list_manual_plugins(read_server(parts[2]))})
            elif len(parts) == 4 and parts[:2] == ["api", "servers"] and parts[3] == "installed-plugins":
                self.send_json({"plugins": list_installed_plugins(read_server(parts[2]))})
            elif len(parts) == 4 and parts[:2] == ["api", "servers"] and parts[3] == "plugin-files":
                self.send_json({"files": list_plugin_files(read_server(parts[2]))})
            elif len(parts) == 4 and parts[:2] == ["api", "servers"] and parts[3] == "plugin-file":
                query = urllib.parse.parse_qs(parsed.query)
                rel_path = query.get("path", [""])[0]
                self.send_json({"path": rel_path, "content": read_plugin_file(read_server(parts[2]), rel_path)})
            elif len(parts) == 4 and parts[:2] == ["api", "servers"] and parts[3] == "files":
                query = urllib.parse.parse_qs(parsed.query)
                rel_path = query.get("path", [""])[0]
                self.send_json(list_data_files(read_server(parts[2]), rel_path))
            elif len(parts) == 4 and parts[:2] == ["api", "servers"] and parts[3] == "players":
                self.send_json(parse_player_list(run_rcon_command(read_server(parts[2]), "list")))
            elif parts == ["api", "versions"]:
                query = urllib.parse.parse_qs(parsed.query)
                self.send_json({"versions": fetch_versions(query.get("type", ["PAPER"])[0])})
            elif len(parts) >= 2 and parts[0] == "map":
                rest_path = "/".join(urllib.parse.quote(part) for part in parts[2:])
                self.send_proxy(map_upstream_url(read_server(parts[1]), rest_path, parsed.query))
            else:
                self.send_json({"error": "not found"}, 404)
        except Exception as exc:
            self.send_json({"error": str(exc)}, 500)

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        parts = [part for part in parsed.path.split("/") if part]
        try:
            if parts == ["api", "servers"]:
                self.send_json(write_server(self.read_json()))
            elif parts == ["api", "ports", "check"]:
                self.send_json({"warnings": port_warnings(self.read_json())})
            elif len(parts) == 4 and parts[:2] == ["api", "servers"] and parts[3] == "move-data-dir":
                body = self.read_json()
                self.send_json(move_data_dir(parts[2], body.get("target", ""), body.get("profile")))
            elif len(parts) == 4 and parts[:2] == ["api", "servers"] and parts[3] == "plugins":
                write_plugins(read_server(parts[2]), self.read_json().get("content", ""))
                self.send_json({"message": "plugins.txt gespeichert."})
            elif len(parts) == 4 and parts[:2] == ["api", "servers"] and parts[3] == "properties":
                write_server_properties(read_server(parts[2]), self.read_json().get("content", ""))
                self.send_json({"message": "server.properties gespeichert. Einige Einstellungen brauchen einen Restart."})
            elif len(parts) == 4 and parts[:2] == ["api", "servers"] and parts[3] == "action":
                action = self.read_json().get("action", "apply")
                if action not in {"apply", "start", "stop", "restart", "disable", "enable", "backup", "plugins", "delete-data"}:
                    self.send_json({"error": "unsupported action"}, 400)
                    return
                config = read_server(parts[2])
                if action == "enable":
                    set_server_disabled(parts[2], False)
                    self.send_json({
                        "ok": True,
                        "code": 0,
                        "stdout": "Profil wurde aktiviert und wird wieder in Status- und Portpruefung einbezogen.",
                        "stderr": "",
                    })
                    return
                if action == "delete-data":
                    self.send_json(delete_local_data(config))
                    return
                result = run_backend_action(config, action)
                if result.get("ok"):
                    if action == "disable":
                        set_server_disabled(parts[2], True)
                        result["stdout"] = (result.get("stdout", "").rstrip() + "\nProfil wurde deaktiviert. Daten bleiben erhalten.").lstrip()
                    elif action in {"apply", "start", "restart"}:
                        set_server_disabled(parts[2], False)
                self.send_json(result)
            elif len(parts) == 4 and parts[:2] == ["api", "servers"] and parts[3] == "rcon":
                body = self.read_json()
                self.send_json(run_rcon_command(read_server(parts[2]), body.get("command", "")))
            elif len(parts) == 4 and parts[:2] == ["api", "servers"] and parts[3] == "restore":
                body = self.read_json()
                config = read_server(parts[2])
                config["backup_file"] = body.get("file", "")
                self.send_json(run_backend_action(config, "restore"))
            elif len(parts) == 4 and parts[:2] == ["api", "servers"] and parts[3] == "manual-plugins":
                body = self.read_json()
                save_manual_plugin(read_server(parts[2]), body.get("name", ""), body.get("content", ""))
                self.send_json({"message": "Manuelles Plugin hochgeladen."})
            elif len(parts) == 4 and parts[:2] == ["api", "servers"] and parts[3] == "plugin-file":
                body = self.read_json()
                write_plugin_file(read_server(parts[2]), body.get("path", ""), body.get("content", ""))
                self.send_json({"message": "Plugin-Konfig gespeichert. Plugin oder Server muss ggf. neu geladen werden."})
            elif len(parts) == 4 and parts[:2] == ["api", "servers"] and parts[3] == "files":
                body = self.read_json()
                config = read_server(parts[2])
                op = body.get("op", "")
                if op == "rename":
                    new_path = rename_data_entry(config, body.get("path", ""), body.get("name", ""))
                    self.send_json({"message": "Eintrag umbenannt.", "path": new_path})
                elif op == "delete":
                    delete_data_entry(config, body.get("path", ""))
                    self.send_json({"message": "Eintrag geloescht."})
                elif op == "mkdir":
                    make_data_dir(config, body.get("path", ""))
                    self.send_json({"message": "Ordner erstellt."})
                elif op == "upload-zip":
                    extract_zip_upload(config, body.get("target", ""), body.get("name", ""), body.get("content", ""))
                    self.send_json({"message": "ZIP hochgeladen und entpackt."})
                else:
                    self.send_json({"error": "unsupported file operation"}, 400)
            elif parts == ["api", "backups", "import"]:
                body = self.read_json()
                source = Path(body.get("file", ""))
                if not source.exists():
                    self.send_json({"error": "backup not found"}, 404)
                    return
                server_id = body.get("id", "").strip()
                data = DEFAULT_SERVER.copy()
                data.update({
                    "id": server_id,
                    "name": server_id,
                    "container_name": f"mc-{server_id}",
                    "data_dir": f"/opt/minecraft/{server_id}",
                    "host_port": "25566",
                    "rcon_host_port": "25576",
                    "backup_file": str(source),
                    "eula_accepted": True,
                })
                saved = write_server(data)
                result = run_backend_action(saved | {"backup_file": str(source)}, "restore")
                self.send_json({"message": "Backup als neues Serverprofil importiert.", "result": result, "server": saved})
            else:
                self.send_json({"error": "not found"}, 404)
        except Exception as exc:
            self.send_json({"error": str(exc)}, 500)

    def do_DELETE(self):
        parsed = urllib.parse.urlparse(self.path)
        parts = [part for part in parsed.path.split("/") if part]
        try:
            if len(parts) == 3 and parts[:2] == ["api", "servers"]:
                self.send_json(delete_server(parts[2]))
            elif len(parts) == 5 and parts[:2] == ["api", "servers"] and parts[3] == "manual-plugins":
                delete_manual_plugin(read_server(parts[2]), urllib.parse.unquote(parts[4]))
                self.send_json({"message": "Manuelles Plugin geloescht."})
            elif len(parts) == 5 and parts[:2] == ["api", "servers"] and parts[3] == "installed-plugins":
                delete_installed_plugin(read_server(parts[2]), urllib.parse.unquote(parts[4]))
                self.send_json({"message": "Installiertes Plugin geloescht. Restart noetig, falls der Server laeuft."})
            else:
                self.send_json({"error": "not found"}, 404)
        except Exception as exc:
            self.send_json({"error": str(exc)}, 500)

    def log_message(self, fmt, *args):
        print("%s - %s" % (self.address_string(), fmt % args))


def main():
    ensure_state()
    host = os.environ.get("MCDOCKER_WEBUI_HOST", "127.0.0.1")
    port = int(os.environ.get("MCDOCKER_WEBUI_PORT", "8088"))
    print(f"Minecraft Docker WebUI: http://{host}:{port}")
    print(f"State directory: {STATE_DIR}")
    ThreadingHTTPServer((host, port), Handler).serve_forever()


if __name__ == "__main__":
    main()
