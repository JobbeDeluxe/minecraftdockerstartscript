#!/usr/bin/env python3
import json, os, re, shlex, socket, subprocess, tempfile, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BACKEND = ROOT / "webui" / "backend.sh"
STATE_DIR = Path(os.environ.get("MCDOCKER_WEBUI_HOME", Path.home() / ".minecraftdocker-webui"))
SERVER_DIR = STATE_DIR / "servers"
RUN_DIR = STATE_DIR / "run"
SAFE_ID = re.compile(r"^[a-zA-Z0-9_.-]+$")
PORT_RE = re.compile(r"^(\d+):(\d+)(?:/(tcp|udp))?$", re.I)

DEFAULT_SERVER = {
    "id": "survival", "name": "Survival", "data_dir": "/opt/minecraft/survival",
    "container_name": "mc-survival", "memory": "6G", "init_memory": "", "max_memory": "",
    "type": "PAPER", "version": "LATEST", "paper_channel": "default", "host_port": "25565",
    "extra_ports": "", "docker_image": "itzg/minecraft-server", "eula_accepted": False,
    "backup_before_apply": False, "start_after_apply": True, "rcon_enabled": True,
    "rcon_password": "", "rcon_host_port": "25575", "rcon_container_port": "25575",
}

HTML = r'''<!doctype html><html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Minecraft Docker WebUI</title><style>
:root{color-scheme:dark;--bg:#111418;--panel:#1b2027;--line:#323b45;--text:#edf2f4;--muted:#9aa6b2;--accent:#6fcf97;--warn:#f2c94c;--button:#26313b}*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:14px/1.45 system-ui,sans-serif}header{height:56px;display:flex;align-items:center;justify-content:space-between;padding:0 18px;border-bottom:1px solid var(--line);background:#151a20}h1{margin:0;font-size:18px}main{display:grid;grid-template-columns:300px minmax(0,1fr);min-height:calc(100vh - 56px)}aside{border-right:1px solid var(--line);padding:14px;background:#14191f}.content{padding:16px}.server{width:100%;display:grid;gap:3px;text-align:left;padding:10px;border:1px solid var(--line);border-radius:8px;color:var(--text);background:var(--panel);margin-bottom:8px;cursor:pointer}.server.active{border-color:var(--accent)}.muted{color:var(--muted)}.dot{width:8px;height:8px;border-radius:99px;background:#eb5757;display:inline-block}.dot.running{background:var(--accent)}form{display:grid;grid-template-columns:repeat(4,minmax(140px,1fr));gap:12px;align-items:end;margin-bottom:16px}label{display:grid;gap:5px;color:var(--muted);font-size:12px}input,select,textarea{width:100%;min-height:36px;border:1px solid var(--line);border-radius:6px;background:#101419;color:var(--text);padding:7px 9px;font:inherit}.wide{grid-column:span 2}.full{grid-column:1/-1}.checks{display:flex;gap:14px;align-items:center;min-height:36px;flex-wrap:wrap}.checks label{display:flex;flex-direction:row;align-items:center;gap:7px;color:var(--text)}.checks input{width:16px;min-height:16px}.actions{display:flex;flex-wrap:wrap;gap:8px;margin-bottom:14px}button{border:1px solid var(--line);border-radius:7px;min-height:36px;padding:0 12px;background:var(--button);color:var(--text);font:inherit;cursor:pointer}button.primary{background:#24583b;border-color:#347a54}button.warn{background:#5a4920;border-color:#80692c}.box{border:1px solid var(--line);border-radius:8px;background:var(--panel);padding:12px;margin-bottom:14px}.box h2{font-size:15px;margin:0 0 10px}.warnings{color:var(--warn);white-space:pre-wrap}.output{display:grid;grid-template-columns:1fr 1fr;gap:12px}pre{margin:0;min-height:300px;max-height:55vh;overflow:auto;padding:12px;border:1px solid var(--line);border-radius:8px;background:#0c0f13;color:#dbe7ef;white-space:pre-wrap}textarea{min-height:180px;font-family:ui-monospace,Consolas,monospace}@media(max-width:920px){main{grid-template-columns:1fr}aside{border-right:0;border-bottom:1px solid var(--line)}form,.output{grid-template-columns:1fr 1fr}}@media(max-width:560px){form,.output{grid-template-columns:1fr}.wide{grid-column:span 1}}
</style></head><body><header><h1>Minecraft Docker WebUI</h1><button id="newServer">Neu</button></header><main><aside><div id="servers"></div></aside><section class="content"><form id="editor"></form><div class="box"><h2>Portpruefung</h2><div id="warnings" class="warnings muted">Noch keine Pruefung.</div></div><div class="actions"><button class="primary" data-action="apply">Anwenden</button><button data-action="start">Start</button><button data-action="stop">Stop</button><button data-action="restart">Restart</button><button class="warn" data-action="backup">Backup</button><button id="deleteServer" type="button">Server loeschen</button><button id="refreshLogs" type="button">Logs laden</button><button id="liveLogs" type="button">Live Logs</button></div><div class="box"><h2>RCON Konsole</h2><div class="actions"><input id="rconCommand" placeholder="say Hallo Welt / list / save-all"><button id="sendRcon" type="button">Senden</button></div></div><div class="box"><h2>Plugins.txt</h2><textarea id="plugins" spellcheck="false"></textarea><div class="actions"><button id="savePlugins" type="button">Plugins speichern</button><button id="updatePlugins" class="warn" type="button">Plugins aktualisieren</button></div></div><div class="output"><pre id="log"></pre><pre id="result"></pre></div><div class="box"><h2>Feldhilfe</h2><pre class="muted">Minecraft Host-Port: Java-Port auf dem Host, intern 25565.
Extra Ports: weitere Mappings, z. B. 19132:19132/udp fuer Geyser.
RCON Host-Port: eindeutiger Host-Port je Server, z. B. 25575, 25576.
RCON Container-Port: kann meist 25575 bleiben.
Min/Max RAM: optional; leer lassen, wenn MEMORY reichen soll.
Plugins.txt: Format PluginName Quelle, z. B. Geyser modrinth:geyser.</pre></div><datalist id="versionOptions"></datalist></section></main><script>
let servers=[],selected=null,liveTimer=null;const fields=[["id","ID"],["name","Name"],["container_name","Container"],["memory","RAM (MEMORY)"],["init_memory","Min RAM"],["max_memory","Max RAM"],["type","Typ"],["version","Version"],["paper_channel","Paper Channel"],["host_port","Minecraft Host-Port"],["data_dir","Datenverzeichnis","wide"],["extra_ports","Extra Ports, z. B. 19132:19132/udp","wide"],["docker_image","Docker Image","wide"],["rcon_host_port","RCON Host-Port"],["rcon_container_port","RCON Container-Port"],["rcon_password","RCON Passwort","wide"]];
function el(t,a={},c=[]){const n=document.createElement(t);for(const[k,v]of Object.entries(a)){if(k==="class")n.className=v;else if(k==="text")n.textContent=v;else n.setAttribute(k,v)}for(const x of c)n.append(x);return n}async function api(path,opt={}){const r=await fetch(path,{headers:{"content-type":"application/json"},...opt});const d=await r.json();if(!r.ok)throw new Error(d.error||"Request failed");return d}function current(){return servers.find(s=>s.id===selected)||{}}
async function loadServers(){servers=await api("/api/servers");selected=selected||servers[0]?.id;renderServers();renderEditor();await refreshDetails()}function renderServers(){const box=document.getElementById("servers");box.innerHTML="";for(const s of servers){const st=s.status||{};const b=el("button",{class:"server"+(s.id===selected?" active":"")},[el("strong",{text:s.name||s.id}),el("span",{class:"muted",text:`${s.container_name} :${s.host_port}`}),el("span",{},[el("span",{class:"dot"+(st.running?" running":"")}),document.createTextNode(" "+(st.state||"unknown"))])]);b.onclick=()=>{selected=s.id;renderServers();renderEditor();refreshDetails()};box.append(b)}}
function checkbox(name,label,checked){const box=el("input",{type:"checkbox",name});box.checked=!!checked;return el("label",{},[box,document.createTextNode(label)])}function renderEditor(){const f=document.getElementById("editor"),s=current();f.innerHTML="";for(const[key,label,cls]of fields){const input=el(key==="type"?"select":"input",{name:key,value:s[key]||""});if(key==="version")input.setAttribute("list","versionOptions");if(key==="rcon_password")input.type="password";if(key==="type"){for(const opt of ["PAPER","FOLIA","PURPUR","SPIGOT","VANILLA","FABRIC","FORGE","QUILT","BUNGEECORD","VELOCITY"]){const o=el("option",{value:opt,text:opt});if((s[key]||"PAPER")===opt)o.selected=true;input.append(o)}input.onchange=()=>loadVersions(input.value)}f.append(el("label",{class:cls||""},[document.createTextNode(label),input]))}f.append(el("div",{class:"checks full"},[checkbox("eula_accepted","Minecraft EULA akzeptiert",s.eula_accepted),checkbox("rcon_enabled","RCON aktiv",s.rcon_enabled),checkbox("backup_before_apply","Backup vorher",s.backup_before_apply),checkbox("start_after_apply","Danach starten",s.start_after_apply??true)]));f.append(el("button",{class:"primary",type:"submit",text:"Speichern"}));loadVersions(s.type||"PAPER")}
function formData(){const form=new FormData(document.getElementById("editor")),data={};for(const[key]of fields)data[key]=form.get(key);for(const k of ["eula_accepted","rcon_enabled","backup_before_apply","start_after_apply"])data[k]=form.get(k)==="on";return data}document.getElementById("editor").onsubmit=async e=>{e.preventDefault();try{const saved=await api("/api/servers",{method:"POST",body:JSON.stringify(formData())});selected=saved.id;await loadServers();document.getElementById("result").textContent="Gespeichert."}catch(err){document.getElementById("result").textContent=err.message}};document.getElementById("editor").oninput=async()=>{try{const r=await api("/api/ports/check",{method:"POST",body:JSON.stringify(formData())});showWarnings(r.warnings)}catch{}};
document.getElementById("newServer").onclick=()=>{const id=`server-${servers.length+1}`;servers.push({id,name:id,container_name:`mc-${id}`,data_dir:`/opt/minecraft/${id}`,memory:"6G",type:"PAPER",version:"LATEST",paper_channel:"default",host_port:"25565",rcon_enabled:true,rcon_host_port:String(25575+servers.length),rcon_container_port:"25575",extra_ports:"",docker_image:"itzg/minecraft-server",start_after_apply:true});selected=id;renderServers();renderEditor();refreshDetails()};document.querySelectorAll("[data-action]").forEach(b=>{b.onclick=async()=>{if(!selected)return;const action=b.dataset.action;document.getElementById("result").textContent=`Running ${action}...`;const r=await api(`/api/servers/${selected}/action`,{method:"POST",body:JSON.stringify({action})});document.getElementById("result").textContent=`$ ${action}\nexit ${r.code}\n\n${r.stdout}\n${r.stderr}`;await loadServers()}});document.getElementById("deleteServer").onclick=async()=>{if(!selected||!confirm("Serverprofil wirklich loeschen? Container und Daten bleiben erhalten."))return;await api(`/api/servers/${selected}`,{method:"DELETE"});selected=null;await loadServers()};document.getElementById("refreshLogs").onclick=()=>loadLogs();document.getElementById("liveLogs").onclick=()=>{const b=document.getElementById("liveLogs");if(liveTimer){clearInterval(liveTimer);liveTimer=null;b.textContent="Live Logs";return}loadLogs();liveTimer=setInterval(loadLogs,2000);b.textContent="Live stoppen"};document.getElementById("sendRcon").onclick=async()=>{const command=document.getElementById("rconCommand").value.trim();if(!command)return;const r=await api(`/api/servers/${selected}/rcon`,{method:"POST",body:JSON.stringify({command})});document.getElementById("result").textContent=`$ rcon ${command}\nexit ${r.code}\n\n${r.stdout}\n${r.stderr}`;document.getElementById("rconCommand").value=""};document.getElementById("savePlugins").onclick=async()=>{const text=document.getElementById("plugins").value;const r=await api(`/api/servers/${selected}/plugins`,{method:"POST",body:JSON.stringify({content:text})});document.getElementById("result").textContent=r.message};document.getElementById("updatePlugins").onclick=async()=>{const r=await api(`/api/servers/${selected}/action`,{method:"POST",body:JSON.stringify({action:"plugins"})});document.getElementById("result").textContent=`$ plugins\nexit ${r.code}\n\n${r.stdout}\n${r.stderr}`};async function refreshDetails(){if(!selected)return;await Promise.all([loadLogs(),loadPlugins(),checkPorts()])}async function loadLogs(){const r=await api(`/api/servers/${selected}/logs`);document.getElementById("log").textContent=r.stdout||r.stderr||""}async function loadPlugins(){const r=await api(`/api/servers/${selected}/plugins`);document.getElementById("plugins").value=r.content||""}async function loadVersions(type){const box=document.getElementById("versionOptions");box.innerHTML="";try{const r=await api(`/api/versions?type=${encodeURIComponent(type||"PAPER")}`);for(const v of r.versions){box.append(el("option",{value:v}))}}catch{}}async function checkPorts(){const r=await api(`/api/servers/${selected}/ports`);showWarnings(r.warnings)}function showWarnings(w){document.getElementById("warnings").textContent=w.length?w.join("\n"):"Keine offensichtlichen Port-Konflikte gefunden."}loadServers().catch(e=>document.getElementById("result").textContent=e.message);
</script></body></html>'''

def ensure_state():
    SERVER_DIR.mkdir(parents=True, exist_ok=True); RUN_DIR.mkdir(parents=True, exist_ok=True)
    sample = SERVER_DIR / "survival.json"
    if not sample.exists(): sample.write_text(json.dumps(DEFAULT_SERVER, indent=2) + "\n", encoding="utf-8")
def server_path(server_id):
    if not SAFE_ID.match(server_id): raise ValueError("invalid server id")
    return SERVER_DIR / f"{server_id}.json"
def read_server(server_id):
    path = server_path(server_id)
    if not path.exists(): raise FileNotFoundError(server_id)
    data = DEFAULT_SERVER.copy(); data.update(json.loads(path.read_text(encoding="utf-8"))); return data
def write_server(data):
    server_id = str(data.get("id", "")).strip()
    if not server_id: server_id = re.sub(r"[^a-z0-9_.-]+", "-", str(data.get("name", "server")).lower()).strip("-") or "server"
    if not SAFE_ID.match(server_id): raise ValueError("server id may only contain letters, numbers, dot, underscore and dash")
    merged = DEFAULT_SERVER.copy(); merged.update(data); merged["id"] = server_id; merged["container_name"] = merged.get("container_name") or f"mc-{server_id}"; merged["data_dir"] = merged.get("data_dir") or f"/opt/minecraft/{server_id}"
    warnings = port_warnings(merged); server_path(server_id).write_text(json.dumps(merged, indent=2) + "\n", encoding="utf-8"); merged["warnings"] = warnings; return merged
def delete_server(server_id):
    path = server_path(server_id)
    if path.exists(): path.unlink()
def list_servers():
    ensure_state(); out = []
    for path in sorted(SERVER_DIR.glob("*.json")):
        try: data = DEFAULT_SERVER.copy(); data.update(json.loads(path.read_text(encoding="utf-8"))); out.append(data)
        except json.JSONDecodeError: pass
    return out
def run_command(args, timeout=60):
    try: proc = subprocess.run(args, text=True, capture_output=True, timeout=timeout); return {"ok": proc.returncode == 0, "code": proc.returncode, "stdout": proc.stdout, "stderr": proc.stderr}
    except FileNotFoundError as exc: return {"ok": False, "code": 127, "stdout": "", "stderr": str(exc)}
    except subprocess.TimeoutExpired as exc: return {"ok": False, "code": 124, "stdout": exc.stdout or "", "stderr": f"Command timed out after {timeout}s"}
def docker_status(config):
    result = run_command(["docker", "inspect", config.get("container_name", ""), "--format", "{{json .State}}"], timeout=15)
    if not result["ok"]: return {"state": "missing", "running": False}
    try: state = json.loads(result["stdout"])
    except json.JSONDecodeError: return {"state": "unknown", "running": False}
    return {"state": state.get("Status", "unknown"), "running": bool(state.get("Running")), "started_at": state.get("StartedAt")}
def parse_ports(config):
    ports = []
    if str(config.get("host_port", "")).isdigit(): ports.append(("minecraft", int(config["host_port"]), "tcp"))
    if config.get("rcon_enabled") and str(config.get("rcon_host_port", "")).isdigit(): ports.append(("rcon", int(config["rcon_host_port"]), "tcp"))
    for raw in re.split(r"[\s,]+", str(config.get("extra_ports", "")).strip()):
        if not raw: continue
        match = PORT_RE.match(raw)
        if match: ports.append(("extra", int(match.group(1)), (match.group(3) or "tcp").lower()))
    return ports
def port_is_open(port, proto):
    if proto == "udp": return False
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM); sock.settimeout(0.25)
    try: return sock.connect_ex(("127.0.0.1", int(port))) == 0
    finally: sock.close()
def docker_published_ports():
    result = run_command(["docker", "ps", "--format", "{{json .}}"], timeout=15); used = {}
    if not result["ok"]: return used
    for line in result["stdout"].splitlines():
        try: row = json.loads(line)
        except json.JSONDecodeError: row = {"Ports": line, "Names": "unknown"}
        for match in re.finditer(r":(\d+)->\d+/(tcp|udp)", str(row.get("Ports", ""))): used.setdefault((int(match.group(1)), match.group(2)), set()).add(row.get("Names", "unknown"))
    return used
def port_warnings(config):
    warnings, profile_ports = [], {}
    for server in list_servers():
        if server.get("id") == config.get("id"): continue
        for label, port, proto in parse_ports(server): profile_ports.setdefault((port, proto), []).append(f"{server.get('name') or server.get('id')}:{label}")
    current, used_by_docker, own_name, seen = parse_ports(config), docker_published_ports(), config.get("container_name"), {}
    for label, port, proto in current:
        key = (port, proto)
        if key in seen: warnings.append(f"{label}: Port {port}/{proto} ist im selben Profil doppelt belegt ({seen[key]}).")
        seen[key] = label
        if key in profile_ports: warnings.append(f"{label}: Port {port}/{proto} kollidiert mit Profil {', '.join(profile_ports[key])}.")
        if port_is_open(port, proto) and own_name not in used_by_docker.get(key, set()): warnings.append(f"{label}: Port {port}/{proto} scheint auf dem Host bereits offen zu sein.")
    for label, port, proto in current:
        names = used_by_docker.get((port, proto), set())
        if names and own_name not in names: warnings.append(f"{label}: Port {port}/{proto} wird bereits von Docker-Container {', '.join(sorted(names))} publiziert.")
        elif names and own_name in names: warnings.append(f"{label}: Port {port}/{proto} wird vom eigenen Container {own_name} genutzt.")
    if config.get("rcon_enabled") and not config.get("rcon_password"): warnings.append("rcon: RCON ist aktiv, aber es ist noch kein Passwort gesetzt.")
    if not config.get("eula_accepted"): warnings.append("eula: Die Minecraft EULA ist noch nicht akzeptiert; Anwenden wird blockiert.")
    return warnings
def plugins_path(config): return Path(config.get("data_dir", "")) / "plugins.txt"
def default_plugins_text(): return "# Format: PluginName Quelle\n# Beispiele:\n# Geyser modrinth:geyser\n# Floodgate https://github.com/GeyserMC/Floodgate\n"
def read_plugins(config):
    path = plugins_path(config); return default_plugins_text() if not path.exists() else path.read_text(encoding="utf-8", errors="replace")
def write_plugins(config, content):
    path = plugins_path(config); path.parent.mkdir(parents=True, exist_ok=True); path.write_text(content.rstrip() + "\n", encoding="utf-8")
def config_env(config):
    return {"DATA_DIR": config.get("data_dir", ""), "SERVER_NAME": config.get("container_name", ""), "MEMORY": config.get("memory", "6G"), "INIT_MEMORY": config.get("init_memory", ""), "MAX_MEMORY": config.get("max_memory", ""), "TYPE": config.get("type", "PAPER"), "VERSION": config.get("version", "LATEST"), "PAPER_CHANNEL": config.get("paper_channel", "default"), "HOST_PORT": config.get("host_port", "25565"), "EXTRA_PORTS": config.get("extra_ports", ""), "DOCKER_IMAGE": config.get("docker_image", "itzg/minecraft-server"), "EULA_ACCEPTED": "ja" if config.get("eula_accepted") else "nein", "DO_BACKUP": "ja" if config.get("backup_before_apply") else "nein", "DO_START_DOCKER": "ja" if config.get("start_after_apply", True) else "nein", "RCON_ENABLED": "ja" if config.get("rcon_enabled") else "nein", "RCON_PASSWORD": config.get("rcon_password", ""), "RCON_HOST_PORT": config.get("rcon_host_port", "25575"), "RCON_CONTAINER_PORT": config.get("rcon_container_port", "25575"), "RCON_COMMAND": config.get("rcon_command", "")}
def write_temp_env(config):
    fd, path = tempfile.mkstemp(prefix=f"{config['id']}-", suffix=".env", dir=RUN_DIR)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        for key, value in config_env(config).items(): handle.write(f"{key}={shlex.quote(str(value))}\n")
    return path
def run_backend_action(config, action):
    if action == "apply":
        blockers = [w for w in port_warnings(config) if w.startswith("eula:") or "kollidiert" in w or "doppelt" in w]
        if blockers: return {"ok": False, "code": 2, "stdout": "", "stderr": "\n".join(blockers)}
    env_file = write_temp_env(config)
    try: return run_command(["bash", str(BACKEND), "--config", env_file, "--action", action], timeout=3600)
    finally:
        try: os.unlink(env_file)
        except OSError: pass
def fetch_versions(server_type):
    server_type = (server_type or "PAPER").upper()
    if server_type in {"PAPER", "FOLIA"}:
        try:
            import urllib.request
            with urllib.request.urlopen(f"https://fill.papermc.io/v3/projects/{server_type.lower()}", timeout=10) as resp: data = json.load(resp)
            versions = []
            for group in data.get("versions", {}).values(): versions.extend(group)
            return ["LATEST"] + sorted(set(versions), reverse=True)[:20]
        except Exception: return ["LATEST"]
    if server_type == "PURPUR":
        try:
            import urllib.request
            with urllib.request.urlopen("https://api.purpurmc.org/v2/purpur", timeout=10) as resp: data = json.load(resp)
            return ["LATEST"] + sorted(set(data.get("versions", [])), reverse=True)[:20]
        except Exception: return ["LATEST"]
    return ["LATEST", "1.21.10", "1.21.9", "1.21.8", "1.21.7", "1.21.6", "1.21.5", "1.21.4"]

class Handler(BaseHTTPRequestHandler):
    def send_json(self, payload, status=200):
        body = json.dumps(payload).encode("utf-8"); self.send_response(status); self.send_header("content-type", "application/json; charset=utf-8"); self.send_header("content-length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def read_json(self):
        length = int(self.headers.get("content-length", "0")); return json.loads(self.rfile.read(length).decode("utf-8")) if length else {}
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path); parts = [p for p in parsed.path.split("/") if p]
        try:
            if parsed.path == "/":
                body = HTML.encode("utf-8"); self.send_response(200); self.send_header("content-type", "text/html; charset=utf-8"); self.send_header("content-length", str(len(body))); self.end_headers(); self.wfile.write(body)
            elif parts == ["api", "servers"]:
                payload = []
                for s in list_servers(): s["status"] = docker_status(s); payload.append(s)
                self.send_json(payload)
            elif len(parts) == 4 and parts[:2] == ["api", "servers"] and parts[3] == "logs": self.send_json(run_backend_action(read_server(parts[2]), "logs"))
            elif len(parts) == 4 and parts[:2] == ["api", "servers"] and parts[3] == "plugins": self.send_json({"content": read_plugins(read_server(parts[2]))})
            elif len(parts) == 4 and parts[:2] == ["api", "servers"] and parts[3] == "ports": self.send_json({"warnings": port_warnings(read_server(parts[2]))})
            elif parts == ["api", "versions"]: self.send_json({"versions": fetch_versions(urllib.parse.parse_qs(parsed.query).get("type", ["PAPER"])[0])})
            else: self.send_json({"error": "not found"}, 404)
        except Exception as exc: self.send_json({"error": str(exc)}, 500)
    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path); parts = [p for p in parsed.path.split("/") if p]
        try:
            if parts == ["api", "servers"]: self.send_json(write_server(self.read_json()))
            elif parts == ["api", "ports", "check"]: self.send_json({"warnings": port_warnings(self.read_json())})
            elif len(parts) == 4 and parts[:2] == ["api", "servers"] and parts[3] == "plugins": write_plugins(read_server(parts[2]), self.read_json().get("content", "")); self.send_json({"message": "plugins.txt gespeichert."})
            elif len(parts) == 4 and parts[:2] == ["api", "servers"] and parts[3] == "action":
                action = self.read_json().get("action", "apply")
                if action not in {"apply", "start", "stop", "restart", "backup", "plugins"}: self.send_json({"error": "unsupported action"}, 400); return
                self.send_json(run_backend_action(read_server(parts[2]), action))
            elif len(parts) == 4 and parts[:2] == ["api", "servers"] and parts[3] == "rcon":
                body = self.read_json(); config = read_server(parts[2]); config["rcon_command"] = body.get("command", ""); self.send_json(run_backend_action(config, "rcon"))
            else: self.send_json({"error": "not found"}, 404)
        except Exception as exc: self.send_json({"error": str(exc)}, 500)
    def do_DELETE(self):
        parsed = urllib.parse.urlparse(self.path); parts = [p for p in parsed.path.split("/") if p]
        try:
            if len(parts) == 3 and parts[:2] == ["api", "servers"]: delete_server(parts[2]); self.send_json({"message": "Serverprofil geloescht."})
            else: self.send_json({"error": "not found"}, 404)
        except Exception as exc: self.send_json({"error": str(exc)}, 500)
    def log_message(self, fmt, *args): print("%s - %s" % (self.address_string(), fmt % args))

def main():
    ensure_state(); host = os.environ.get("MCDOCKER_WEBUI_HOST", "127.0.0.1"); port = int(os.environ.get("MCDOCKER_WEBUI_PORT", "8088")); print(f"Minecraft Docker WebUI: http://{host}:{port}"); print(f"State directory: {STATE_DIR}"); ThreadingHTTPServer((host, port), Handler).serve_forever()
if __name__ == "__main__": main()
