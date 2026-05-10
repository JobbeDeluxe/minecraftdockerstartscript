#!/bin/bash
set -euo pipefail

CONFIG_FILE=""
ACTION="apply"
LOG_LINES="200"

usage() {
    cat <<'EOF'
Minecraft Docker WebUI backend
Usage: webui/backend.sh --config server.env --action apply

Actions:
  apply    Recreate the configured Docker container from the config
  start    Start the existing Docker container
  stop     Stop the Docker container
  restart  Stop and start the Docker container
  backup   Stop the container and create a tar.gz backup
  restore  Restore BACKUP_FILE into DATA_DIR after stopping the container
  plugins  Update plugins listed in DATA_DIR/plugins.txt
  rcon     Send RCON_COMMAND through docker exec rcon-cli
  status   Print a compact Docker status line
  logs     Print recent Docker logs
EOF
}

while (($# > 0)); do
    case "$1" in
        --config) CONFIG_FILE="${2:-}"; shift 2 ;;
        --action) ACTION="${2:-apply}"; shift 2 ;;
        --log-lines) LOG_LINES="${2:-200}"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [[ -z "${CONFIG_FILE:-}" || ! -f "$CONFIG_FILE" ]]; then
    echo "Config file not found: ${CONFIG_FILE:-<empty>}" >&2
    exit 2
fi

set -a
# shellcheck disable=SC1090
source "$CONFIG_FILE"
set +a

DATA_DIR="${DATA_DIR:-/opt/minecraft_server}"
SERVER_NAME="${SERVER_NAME:-mc}"
BACKUP_DIR="${BACKUP_DIR:-${DATA_DIR}/backups}"
PLUGIN_DIR="${PLUGIN_DIR:-${DATA_DIR}/plugins}"
PLUGIN_CONFIG="${PLUGIN_CONFIG:-${DATA_DIR}/plugins.txt}"
DOCKER_IMAGE="${DOCKER_IMAGE:-itzg/minecraft-server}"
LOG_FILE="${LOG_FILE:-${DATA_DIR}/update_log.txt}"
HOST_PORT="${HOST_PORT:-25565}"
MEMORY="${MEMORY:-6G}"
INIT_MEMORY="${INIT_MEMORY:-}"
MAX_MEMORY="${MAX_MEMORY:-}"
TYPE="${TYPE:-PAPER}"
VERSION="${VERSION:-LATEST}"
PAPER_CHANNEL="${PAPER_CHANNEL:-default}"
DO_BACKUP="${DO_BACKUP:-nein}"
DO_START_DOCKER="${DO_START_DOCKER:-ja}"
EXTRA_PORTS="${EXTRA_PORTS:-}"
EULA_ACCEPTED="${EULA_ACCEPTED:-nein}"
RCON_ENABLED="${RCON_ENABLED:-nein}"
RCON_PASSWORD="${RCON_PASSWORD:-}"
RCON_HOST_PORT="${RCON_HOST_PORT:-25575}"
RCON_CONTAINER_PORT="${RCON_CONTAINER_PORT:-25575}"
RCON_COMMAND="${RCON_COMMAND:-}"
BACKUP_ROOT="${BACKUP_ROOT:-${HOME}/minecraftdocker-backups}"
BACKUP_FILE="${BACKUP_FILE:-}"

mkdir -p "$DATA_DIR" "$PLUGIN_DIR" "$BACKUP_DIR"

log() {
    printf "%s - %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" | tee -a "$LOG_FILE"
}

need_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        log "Fehler: $1 ist nicht installiert."
        exit 1
    fi
}

need_docker() {
    need_cmd docker
}

stop_server() {
    log "Stoppe Server ${SERVER_NAME}..."
    docker stop "$SERVER_NAME" >/dev/null 2>&1 || true
}

start_server() {
    log "Starte Server ${SERVER_NAME}..."
    docker start "$SERVER_NAME"
}

create_backup() {
    stop_server
    mkdir -p "$BACKUP_ROOT"
    local safe_name
    safe_name="$(printf '%s' "$SERVER_NAME" | tr -c 'A-Za-z0-9_.-' '_')"
    local backup_file="${BACKUP_ROOT}/${safe_name}_backup_$(date +%Y%m%d%H%M).tar.gz"
    log "Erstelle Backup: ${backup_file}"
    tar --exclude="./backups" -czf "$backup_file" -C "$DATA_DIR" .
    log "Backup abgeschlossen: ${backup_file}"
}

restore_backup() {
    if [[ -z "$BACKUP_FILE" || ! -f "$BACKUP_FILE" ]]; then
        echo "BACKUP_FILE nicht gefunden: ${BACKUP_FILE:-<empty>}" >&2
        exit 2
    fi
    stop_server
    mkdir -p "$DATA_DIR"
    log "Stelle Backup wieder her: ${BACKUP_FILE}"
    tar -xzf "$BACKUP_FILE" -C "$DATA_DIR"
    log "Restore abgeschlossen: ${BACKUP_FILE}"
}

apply_container() {
    if [[ "$EULA_ACCEPTED" != "ja" ]]; then
        log "Fehler: Minecraft EULA wurde in diesem Profil noch nicht akzeptiert."
        exit 2
    fi
    [[ "$DO_BACKUP" == "ja" ]] && create_backup
    sync_manual_plugins

    stop_server
    log "Entferne alten Docker-Container ${SERVER_NAME}..."
    docker rm "$SERVER_NAME" >/dev/null 2>&1 || true

    local docker_args=(-d -p "${HOST_PORT}:25565")

    local cleaned_ports="${EXTRA_PORTS//,/ }"
    local mapping
    for mapping in $cleaned_ports; do
        [[ -n "${mapping:-}" ]] && docker_args+=(-p "$mapping")
    done

    docker_args+=(
        -v "${DATA_DIR}:/data"
        --name "$SERVER_NAME"
        -e TZ=Europe/Berlin
        -e EULA=TRUE
        -e MEMORY="$MEMORY"
        -e TYPE="$TYPE"
        --restart always
    )

    [[ -n "${INIT_MEMORY:-}" ]] && docker_args+=(-e "INIT_MEMORY=$INIT_MEMORY")
    [[ -n "${MAX_MEMORY:-}" ]] && docker_args+=(-e "MAX_MEMORY=$MAX_MEMORY")
    [[ -n "${VERSION:-}" ]] && docker_args+=(-e "VERSION=$VERSION")
    if [[ "${TYPE^^}" == "PAPER" && -n "${PAPER_CHANNEL:-}" ]]; then
        docker_args+=(-e "PAPER_CHANNEL=$PAPER_CHANNEL")
    fi

    if [[ "$RCON_ENABLED" == "ja" ]]; then
        if [[ -z "$RCON_PASSWORD" ]]; then
            log "Fehler: RCON ist aktiv, aber RCON_PASSWORD ist leer."
            exit 2
        fi
        docker_args+=(
            -p "${RCON_HOST_PORT}:${RCON_CONTAINER_PORT}"
            -e ENABLE_RCON=true
            -e "RCON_PASSWORD=$RCON_PASSWORD"
            -e "RCON_PORT=$RCON_CONTAINER_PORT"
        )
    fi

    log "Starte Docker-Container ${SERVER_NAME}..."
    docker run "${docker_args[@]}" "$DOCKER_IMAGE"

    if [[ "$DO_START_DOCKER" != "ja" ]]; then
        log "Stoppe den Docker-Container sofort wieder..."
        docker stop "$SERVER_NAME" >/dev/null 2>&1 || true
    fi
}

download_file() {
    local url="$1"
    local target="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fL "$url" -o "$target"
    else
        need_cmd wget
        wget -O "$target" "$url"
    fi
}

github_latest_jar_url() {
    local repo="$1"
    need_cmd python3
    python3 - "$repo" <<'PY'
import json, sys, urllib.request
repo = sys.argv[1].strip().removeprefix("https://github.com/").strip("/")
url = f"https://api.github.com/repos/{repo}/releases/latest"
req = urllib.request.Request(url, headers={"User-Agent": "minecraftdocker-webui"})
with urllib.request.urlopen(req, timeout=20) as resp:
    data = json.load(resp)
for asset in data.get("assets", []):
    name = asset.get("name", "").lower()
    if name.endswith(".jar") and "sources" not in name and "javadoc" not in name:
        print(asset["browser_download_url"])
        break
PY
}

modrinth_latest_jar_url() {
    local slug="${1#modrinth:}"
    need_cmd python3
    python3 - "$slug" <<'PY'
import json, sys, urllib.parse, urllib.request
slug = sys.argv[1]
url = "https://api.modrinth.com/v2/project/%s/version?loaders=[%%22paper%%22,%%22spigot%%22,%%22bukkit%%22]&featured=false" % urllib.parse.quote(slug)
req = urllib.request.Request(url, headers={"User-Agent": "minecraftdocker-webui"})
with urllib.request.urlopen(req, timeout=20) as resp:
    versions = json.load(resp)
for version in versions:
    for file in version.get("files", []):
        if file.get("filename", "").lower().endswith(".jar"):
            print(file["url"])
            raise SystemExit
PY
}

update_plugins() {
    mkdir -p "$PLUGIN_DIR"
    sync_manual_plugins
    if [[ ! -f "$PLUGIN_CONFIG" ]]; then
        log "Keine plugins.txt gefunden: $PLUGIN_CONFIG"
        return 0
    fi
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "$tmp_dir"' RETURN

    local line name source url target
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%$'\r'}"
        [[ -z "${line//[[:space:]]/}" || "$line" =~ ^[[:space:]]*# ]] && continue
        name="$(awk '{print $1}' <<<"$line")"
        source="$(awk '{print $NF}' <<<"$line")"
        [[ -z "$name" || -z "$source" ]] && continue
        target="${tmp_dir}/${name}.jar"
        url=""

        log "Plugin ${name}: ermittle Download aus ${source}"
        if [[ "${name,,}" == "coreprotect" && "$source" == https://github.com/* ]]; then
            if build_coreprotect "$source" "$target"; then
                cp "$target" "$PLUGIN_DIR/"
                log "Plugin ${name}: aus Source gebaut und aktualisiert."
            else
                log "Plugin ${name}: Build fehlgeschlagen."
            fi
            continue
        elif [[ "$source" == modrinth:* ]]; then
            url="$(modrinth_latest_jar_url "$source" || true)"
        elif [[ "$source" == https://github.com/* ]]; then
            url="$(github_latest_jar_url "$source" || true)"
        elif [[ "$source" == http://* || "$source" == https://* ]]; then
            url="$source"
        fi

        if [[ -z "$url" ]]; then
            log "Plugin ${name}: keine unterstuetzte Download-URL gefunden."
            continue
        fi
        if download_file "$url" "$target"; then
            cp "$target" "$PLUGIN_DIR/"
            log "Plugin ${name}: aktualisiert."
        else
            log "Plugin ${name}: Download fehlgeschlagen."
        fi
    done < "$PLUGIN_CONFIG"
}

sync_manual_plugins() {
    if [[ -d "${PLUGIN_DIR}/manuell" ]]; then
        find "${PLUGIN_DIR}/manuell" -maxdepth 1 -type f -name "*.jar" -exec cp -f {} "$PLUGIN_DIR/" \;
        log "Manuelle Plugins synchronisiert."
    fi
}

build_coreprotect() {
    local source="$1"
    local target="$2"
    local repo="$source"
    local branch="master"
    if [[ "$source" =~ ^(https://github.com/[^:]+):(.+)$ ]]; then
        repo="${BASH_REMATCH[1]}"
        branch="${BASH_REMATCH[2]}"
    fi
    local srcdir
    srcdir="$(mktemp -d)"
    need_cmd git
    log "CoreProtect: clone ${repo} (${branch})"
    if ! git clone --depth 1 --branch "$branch" "$repo" "$srcdir" >/dev/null 2>&1; then
        rm -rf "$srcdir"
        return 1
    fi
    if command -v mvn >/dev/null 2>&1; then
        (cd "$srcdir" && mvn -q -DskipTests package)
    else
        docker run --rm -v "$srcdir":/src -w /src maven:3-eclipse-temurin-21 mvn -q -DskipTests package
    fi
    local jar
    jar="$(find "$srcdir" -type f -path "*/target/*.jar" ! -name "*sources*" ! -name "*javadoc*" | head -n 1)"
    if [[ -z "$jar" ]]; then
        rm -rf "$srcdir"
        return 1
    fi
    cp "$jar" "$target"
    rm -rf "$srcdir"
}

send_rcon_command() {
    if [[ -z "$RCON_COMMAND" ]]; then
        echo "RCON_COMMAND ist leer." >&2
        exit 2
    fi
    log "Sende RCON-Befehl: ${RCON_COMMAND}"
    docker exec "$SERVER_NAME" rcon-cli "$RCON_COMMAND"
}

need_docker

case "${ACTION,,}" in
    apply) apply_container ;;
    start) start_server ;;
    stop) stop_server ;;
    restart) stop_server; start_server ;;
    backup) create_backup ;;
    restore) restore_backup ;;
    plugins) update_plugins ;;
    rcon) send_rcon_command ;;
    status) docker inspect "$SERVER_NAME" --format '{{.Name}} {{.State.Status}} {{.State.Running}} {{.NetworkSettings.IPAddress}}' ;;
    logs) docker logs --tail "$LOG_LINES" "$SERVER_NAME" ;;
    *) echo "Unknown action: $ACTION" >&2; exit 2 ;;
esac
