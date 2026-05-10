#!/usr/bin/env python3
import json
import os
import re
import shlex
import subprocess
import tempfile
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BACKEND = ROOT / "webui" / "backend.sh"
STATE_DIR = Path(os.environ.get("MCDOCKER_WEBUI_HOME", Path.home() / ".minecraftdocker-webui"))
SERVER_DIR = STATE_DIR / "servers"
RUN_DIR = STATE_DIR / "run"
SAFE_ID = re.compile(r"^[a-zA-Z0-9_.-]+$")

DEFAULT_SERVER = {
    "id": "survival",
    "name": "Survival",
    "data_dir": "/opt/minecraft/survival",
    "container_name": "mc-survival",
    "memory": "6G",
    "type": "PAPER",
    "version": "LATEST",
    "paper_channel": "default",
    "host_port": "25565",
    "extra_ports": "",
    "docker_image": "itzg/minecraft-server",
    "backup_before_apply": False,
    "start_after_apply": True,
}

HTML = r'''<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Minecraft Docker WebUI</title>
<style>
:root{color-scheme:dark;--bg:#111418;--panel:#1b2027;--line:#323b45;--text:#edf2f4;--muted:#9aa6b2;--accent:#6fcf97;--bad:#eb5757;--button:#26313b}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:14px/1.45 system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}header{height:56px;display:flex;align-items:center;justify-content:space-between;padding:0 18px;border-bottom:1px solid var(--line);background:#151a20}h1{margin:0;font-size:18px}main{display:grid;grid-template-columns:300px minmax(0,1fr);min-height:calc(100vh - 56px)}aside{border-right:1px solid var(--line);padding:14px;background:#14191f}.content{padding:16px}.server{width:100%;display:grid;gap:3px;text-align:left;padding:10px;border:1px solid var(--line);border-radius:8px;color:var(--text);background:var(--panel);margin-bottom:8px;cursor:pointer}.server.active{border-color:var(--accent)}.muted{color:var(--muted)}.status{display:inline-flex;align-items:center;gap:6px;font-size:12px;color:var(--muted)}.dot{width:8px;height:8px;border-radius:99px;background:var(--bad)}.dot.running{background:var(--accent)}form{display:grid;grid-template-columns:repeat(4,minmax(140px,1fr));gap:12px;align-items:end;margin-bottom:16px}label{display:grid;gap:5px;color:var(--muted);font-size:12px}input,select{width:100%;min-height:36px;border:1px solid var(--line);border-radius:6px;background:#101419;color:var(--text);padding:7px 9px;font:inherit}.wide{grid-column:span 2}.checks{display:flex;gap:14px;align-items:center;min-height:36px;color:var(--text)}.checks label{display:flex;flex-direction:row;align-items:center;gap:7px;color:var(--text)}.checks input{width:16px;min-height:16px}.actions{display:flex;flex-wrap:wrap;gap:8px;margin-bottom:14px}button{border:1px solid var(--line);border-radius:7px;min-height:36px;padding:0 12px;background:var(--button);color:var(--text);font:inherit;cursor:pointer}button.primary{background:#24583b;border-color:#347a54}button.warn{background:#5a4920;border-color:#80692c}pre{margin:0;min-height:360px;max-height:65vh;overflow:auto;padding:12px;border:1px solid var(--line);border-radius:8px;background:#0c0f13;color:#dbe7ef;white-space:pre-wrap}.output{display:grid;grid-template-columns:1fr 1fr;gap:12px}@media(max-width:920px){main{grid-template-columns:1fr}aside{border-right:0;border-bottom:1px solid var(--line)}form,.output{grid-template-columns:1fr 1fr}}@media(max-width:560px){form,.output{grid-template-columns:1fr}.wide{grid-column:span 1}}
</style>
</head>
<body>
<header><h1>Minecraft Docker WebUI</h1><button id="newServer">Neu</button></header>
<main><aside><div id="servers"></div></aside><section class="content"><form id="editor"></form><div class="actions"><button class="primary" data-action="apply">Anwenden</button><button data-action="start">Start</button><button data-action="stop">Stop</button><button data-action="restart">Restart</button><button class="warn" data-action="backup">Backup</button><button id="refreshLogs" type="button">Logs laden</button></div><div class="output"><pre id="log"></pre><pre id="result"></pre></div></section></main>
<script>
let servers=[],selected=null;
const fields=[["id","ID"],["name","Name"],["container_name","Container"],["memory","RAM"],["type","Typ"],["version","Version"],["paper_channel","Paper Channel"],["host_port","Host-Port"],["data_dir","Datenverzeichnis","wide"],["extra_ports","Extra Ports","wide"],["docker_image","Docker Image","wide"]];
function el(t,a={},c=[]){const n=document.createElement(t);for(const[k,v]of Object.entries(a)){if(k==="class")n.className=v;else if(k==="text")n.textContent=v;else n.setAttribute(k,v)}for(const x of c)n.append(x);return n}
async function api(path,opt={}){const r=await fetch(path,{headers:{"content-type":"application/json"},...opt});const d=await r.json();if(!r.ok)throw new Error(d.error||"Request failed");return d}
function current(){return servers.find(s=>s.id===selected)||{}}
async function loadServers(){servers=await api("/api/servers");selected=selected||servers[0]?.id;renderServers();renderEditor();if(selected)loadLogs()}
function renderServers(){const box=document.getElementById("servers");box.innerHTML="";for(const s of servers){const st=s.status||{};const b=el("button",{class:"server"+(s.id===selected?" active":"")},[el("strong",{text:s.name||s.id}),el("span",{class:"muted",text:`${s.container_name} :${s.host_port}`}),el("span",{class:"status"},[el("span",{class:"dot"+(st.running?" running":"")}),document.createTextNode(st.state||"unknown")])]);b.onclick=()=>{selected=s.id;renderServers();renderEditor();loadLogs()};box.append(b)}}
function checkbox(name,label,checked){const box=el("input",{type:"checkbox",name});box.checked=!!checked;return el("label",{},[box,document.createTextNode(label)])}
function renderEditor(){const f=document.getElementById("editor"),s=current();f.innerHTML="";for(const[key,label,cls]of fields){const input=el(key==="type"?"select":"input",{name:key,value:s[key]||""});if(key==="type"){for(const opt of ["PAPER","FOLIA","PURPUR","SPIGOT","VANILLA","FABRIC","FORGE","QUILT","BUNGEECORD","VELOCITY"]){const o=el("option",{value:opt,text:opt});if((s[key]||"PAPER")===opt)o.selected=true;input.append(o)}}f.append(el("label",{class:cls||""},[document.createTextNode(label),input]))}f.append(el("div",{class:"checks wide"},[checkbox("backup_before_apply","Backup vorher",s.backup_before_apply),checkbox("start_after_apply","Danach starten",s.start_after_apply??true)]));f.append(el("button",{class:"primary",type:"submit",text:"Speichern"}))}
document.getElementById("editor").onsubmit=async e=>{e.preventDefault();const form=new FormData(e.currentTarget),data={};for(const[key]of fields)data[key]=form.get(key);data.backup_before_apply=form.get("backup_before_apply")==="on";data.start_after_apply=form.get("start_after_apply")==="on";const saved=await api("/api/servers",{method:"POST",body:JSON.stringify(data)});selected=saved.id;await loadServers()};
document.getElementById("newServer").onclick=()=>{const id=`server-${servers.length+1}`;servers.push({id,name:id,container_name:`mc-${id}`,data_dir:`/opt/minecraft/${id}`,memory:"6G",type:"PAPER",version:"LATEST",paper_channel:"default",host_port:"25565",extra_ports:"",docker_image:"itzg/minecraft-server",start_after_apply:true});selected=id;renderServers();renderEditor()};
document.querySelectorAll("[data-action]").forEach(b=>{b.onclick=async()=>{if(!selected)return;const action=b.dataset.action;document.getElementById("result").textContent=`Running ${action}...`;const r=await api(`/api/servers/${selected}/action`,{method:"POST",body:JSON.stringify({action})});document.getElementById("result").textContent=`$ ${action}\nexit ${r.code}\n\n${r.stdout}\n${r.stderr}`;await loadServers()}});
document.getElementById("refreshLogs").onclick=()=>loadLogs();async function loadLogs(){if(!selected)return;const r=await api(`/api/servers/${selected}/logs`);document.getElementById("log").textContent=r.stdout||r.stderr||""}loadServers().catch(e=>document.getElementById("result").textContent=e.message);
</script></body></html>'''

def ensure_state():
    SERVER_DIR.mkdir(parents=True, exist_ok=True)
    RUN_DIR.mkdir(parents=True, exist_ok=True)
    sample = SERVER_DIR / "survival.json"
    if not sample.exists():
        sample.write_text(json.dumps(DEFAULT_SERVER, indent=2) + "\n", encoding="utf-8")

def server_path(server_id):
    if not SAFE_ID.match(server_id):
        raise ValueError("invalid server id")
    return SERVER_DIR / f"{server_id}.json"

def read_server(server_id):
    path = server_path(server_id)
    if not path.exists():
        raise FileNotFoundError(server_id)
    return json.loads(path.read_text(encoding="utf-8"))

def write_server(data):
    server_id = str(data.get("id", "")).strip()
    if not server_id:
        server_id = re.sub(r"[^a-z0-9_.-]+", "-", str(data.get("name", "server")).lower()).strip("-") or "server"
    if not SAFE_ID.match(server_id):
        raise ValueError("server id may only contain letters, numbers, dot, underscore and dash")
    merged = DEFAULT_SERVER.copy()
    merged.update(data)
    merged["id"] = server_id
    merged["container_name"] = merged.get("container_name") or f"mc-{server_id}"
    merged["data_dir"] = merged.get("data_dir") or f"/opt/minecraft/{server_id}"
    server_path(server_id).write_text(json.dumps(merged, indent=2) + "\n", encoding="utf-8")
    return merged

def list_servers():
    ensure_state()
    out = []
    for path in sorted(SERVER_DIR.glob("*.json")):
        try:
            out.append(json.loads(path.read_text(encoding="utf-8")))
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
    name = config.get("container_name", "")
    result = run_command(["docker", "inspect", name, "--format", "{{json .State}}"], timeout=15)
    if not result["ok"]:
        return {"state": "missing", "running": False}
    try:
        state = json.loads(result["stdout"])
    except json.JSONDecodeError:
        return {"state": "unknown", "running": False}
    return {"state": state.get("Status", "unknown"), "running": bool(state.get("Running")), "started_at": state.get("StartedAt")}

def config_env(config):
    return {
        "DATA_DIR": config.get("data_dir", ""),
        "SERVER_NAME": config.get("container_name", ""),
        "MEMORY": config.get("memory", "6G"),
        "TYPE": config.get("type", "PAPER"),
        "VERSION": config.get("version", "LATEST"),
        "PAPER_CHANNEL": config.get("paper_channel", "default"),
        "HOST_PORT": config.get("host_port", "25565"),
        "EXTRA_PORTS": config.get("extra_ports", ""),
        "DOCKER_IMAGE": config.get("docker_image", "itzg/minecraft-server"),
        "DO_BACKUP": "ja" if config.get("backup_before_apply") else "nein",
        "DO_START_DOCKER": "ja" if config.get("start_after_apply", True) else "nein",
    }

def write_temp_env(config):
    fd, path = tempfile.mkstemp(prefix=f"{config['id']}-", suffix=".env", dir=RUN_DIR)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        for key, value in config_env(config).items():
            handle.write(f"{key}={shlex.quote(str(value))}\n")
    return path

def run_backend_action(config, action):
    env_file = write_temp_env(config)
    try:
        return run_command(["bash", str(BACKEND), "--config", env_file, "--action", action], timeout=3600)
    finally:
        try:
            os.unlink(env_file)
        except OSError:
            pass

class Handler(BaseHTTPRequestHandler):
    def send_json(self, payload, status=200):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("content-type", "application/json; charset=utf-8")
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
                body = HTML.encode("utf-8")
                self.send_response(200)
                self.send_header("content-type", "text/html; charset=utf-8")
                self.send_header("content-length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            elif parts == ["api", "servers"]:
                payload = []
                for server in list_servers():
                    server["status"] = docker_status(server)
                    payload.append(server)
                self.send_json(payload)
            elif len(parts) == 4 and parts[:2] == ["api", "servers"] and parts[3] == "logs":
                self.send_json(run_backend_action(read_server(parts[2]), "logs"))
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
            elif len(parts) == 4 and parts[:2] == ["api", "servers"] and parts[3] == "action":
                action = self.read_json().get("action", "apply")
                if action not in {"apply", "start", "stop", "restart", "backup"}:
                    self.send_json({"error": "unsupported action"}, 400)
                    return
                self.send_json(run_backend_action(read_server(parts[2]), action))
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
