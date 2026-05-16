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
  disable  Remove only the Docker container; keep profile and data
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

normalize_memory_value() {
    local value="${1:-}"
    value="${value//[[:space:]]/}"
    if [[ "$value" =~ ^([0-9]+)([kKmMgG])([bB])?$ ]]; then
        printf "%s%s" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]^^}"
    else
        printf "%s" "$value"
    fi
}

MEMORY="$(normalize_memory_value "$MEMORY")"
INIT_MEMORY="$(normalize_memory_value "$INIT_MEMORY")"
MAX_MEMORY="$(normalize_memory_value "$MAX_MEMORY")"

mkdir -p "$DATA_DIR" "$PLUGIN_DIR" "$BACKUP_DIR"

is_proxy_type() {
    case "${TYPE^^}" in
        BUNGEECORD|WATERFALL|VELOCITY)
            return 0
            ;;
    esac
    return 1
}

container_data_mount() {
    if is_proxy_type; then
        printf "/server"
    else
        printf "/data"
    fi
}

container_game_port() {
    case "${TYPE^^}" in
        BUNGEECORD|WATERFALL)
            printf "25577"
            ;;
        *)
            printf "25565"
            ;;
    esac
}

normalize_image_for_type() {
    if is_proxy_type; then
        if [[ -z "${DOCKER_IMAGE:-}" || "$DOCKER_IMAGE" == "itzg/minecraft-server" ]]; then
            DOCKER_IMAGE="itzg/mc-proxy"
        fi
    elif [[ -z "${DOCKER_IMAGE:-}" || "$DOCKER_IMAGE" == "itzg/mc-proxy" ]]; then
        DOCKER_IMAGE="itzg/minecraft-server"
    fi
}

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

container_exists() {
    docker container inspect "$SERVER_NAME" >/dev/null 2>&1
}

stop_server() {
    if ! container_exists; then
        log "Container ${SERVER_NAME} ist nicht vorhanden; nichts zu stoppen."
        return 0
    fi
    log "Stoppe Server ${SERVER_NAME}..."
    docker container stop "$SERVER_NAME" >/dev/null 2>&1 || true
}

desired_container_config_hash() {
    normalize_image_for_type
    {
        printf "DATA_DIR=%s\n" "$DATA_DIR"
        printf "DOCKER_IMAGE=%s\n" "$DOCKER_IMAGE"
        printf "HOST_PORT=%s\n" "$HOST_PORT"
        printf "EXTRA_PORTS=%s\n" "$EXTRA_PORTS"
        printf "MEMORY=%s\n" "$MEMORY"
        printf "INIT_MEMORY=%s\n" "$INIT_MEMORY"
        printf "MAX_MEMORY=%s\n" "$MAX_MEMORY"
        printf "TYPE=%s\n" "$TYPE"
        printf "VERSION=%s\n" "$VERSION"
        printf "PAPER_CHANNEL=%s\n" "$PAPER_CHANNEL"
        printf "RCON_ENABLED=%s\n" "$RCON_ENABLED"
        printf "RCON_PASSWORD=%s\n" "$RCON_PASSWORD"
        printf "RCON_HOST_PORT=%s\n" "$RCON_HOST_PORT"
        printf "RCON_CONTAINER_PORT=%s\n" "$RCON_CONTAINER_PORT"
    } | sha256sum | awk '{print $1}'
}

current_container_config_hash() {
    local value
    value="$(docker container inspect "$SERVER_NAME" --format '{{ index .Config.Labels "minecraftdocker.webui.config-hash" }}' 2>/dev/null || true)"
    [[ "$value" == "<no value>" ]] && value=""
    printf "%s" "$value"
}

current_container_env() {
    docker container inspect "$SERVER_NAME" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null || true
}

env_has_exact() {
    local env_text="$1"
    local expected="$2"
    printf "%s\n" "$env_text" | grep -Fxq "$expected"
}

env_has_key() {
    local env_text="$1"
    local key="$2"
    printf "%s\n" "$env_text" | grep -Eq "^${key}="
}

require_env_or_recreate() {
    local env_text="$1"
    local expected="$2"
    if ! env_has_exact "$env_text" "$expected"; then
        log "Container ${SERVER_NAME} nutzt noch alte Einstellungen (${expected} fehlt); erstelle ihn neu."
        return 0
    fi
    return 1
}

container_needs_recreate() {
    normalize_image_for_type

    local desired_hash current_hash
    desired_hash="$(desired_container_config_hash)"
    current_hash="$(current_container_config_hash)"
    if [[ -n "$current_hash" && "$current_hash" != "$desired_hash" ]]; then
        log "Container ${SERVER_NAME} passt nicht mehr zum Profil; erstelle ihn neu."
        return 0
    fi

    local current_image
    current_image="$(docker container inspect "$SERVER_NAME" --format '{{.Config.Image}}' 2>/dev/null || true)"
    if [[ -n "$current_image" && "$current_image" != "$DOCKER_IMAGE" ]]; then
        log "Container ${SERVER_NAME} nutzt noch Image ${current_image} statt ${DOCKER_IMAGE}; erstelle ihn neu."
        return 0
    fi

    local env_text
    env_text="$(current_container_env)"
    require_env_or_recreate "$env_text" "MEMORY=$MEMORY" && return 0
    require_env_or_recreate "$env_text" "TYPE=$TYPE" && return 0

    if [[ -n "${INIT_MEMORY:-}" ]]; then
        require_env_or_recreate "$env_text" "INIT_MEMORY=$INIT_MEMORY" && return 0
    elif env_has_key "$env_text" "INIT_MEMORY"; then
        log "Container ${SERVER_NAME} nutzt noch INIT_MEMORY, obwohl das Profil leer ist; erstelle ihn neu."
        return 0
    fi

    if [[ -n "${MAX_MEMORY:-}" ]]; then
        require_env_or_recreate "$env_text" "MAX_MEMORY=$MAX_MEMORY" && return 0
    elif env_has_key "$env_text" "MAX_MEMORY"; then
        log "Container ${SERVER_NAME} nutzt noch MAX_MEMORY, obwohl das Profil leer ist; erstelle ihn neu."
        return 0
    fi

    if is_proxy_type; then
        case "${TYPE^^}" in
            VELOCITY)
                if [[ -n "${VERSION:-}" && "${VERSION^^}" != "LATEST" ]]; then
                    require_env_or_recreate "$env_text" "VELOCITY_VERSION=$VERSION" && return 0
                elif env_has_key "$env_text" "VELOCITY_VERSION"; then
                    log "Container ${SERVER_NAME} nutzt noch eine feste VELOCITY_VERSION; erstelle ihn neu."
                    return 0
                fi
                ;;
            WATERFALL)
                if [[ -n "${VERSION:-}" && "${VERSION^^}" != "LATEST" ]]; then
                    require_env_or_recreate "$env_text" "WATERFALL_VERSION=$VERSION" && return 0
                elif env_has_key "$env_text" "WATERFALL_VERSION"; then
                    log "Container ${SERVER_NAME} nutzt noch eine feste WATERFALL_VERSION; erstelle ihn neu."
                    return 0
                fi
                ;;
        esac
    else
        [[ -n "${VERSION:-}" ]] && require_env_or_recreate "$env_text" "VERSION=$VERSION" && return 0
        if [[ "${TYPE^^}" == "PAPER" && -n "${PAPER_CHANNEL:-}" ]]; then
            require_env_or_recreate "$env_text" "PAPER_CHANNEL=$PAPER_CHANNEL" && return 0
        fi
    fi

    return 1
}

start_server() {
    if ! container_exists; then
        log "Container ${SERVER_NAME} wurde noch nicht gefunden; erstelle ihn mit Anwenden."
        apply_container
        return
    fi
    if container_needs_recreate; then
        apply_container
        return
    fi
    log "Starte Server ${SERVER_NAME}..."
    docker container start "$SERVER_NAME"
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
    normalize_image_for_type
    if ! is_proxy_type && [[ "$EULA_ACCEPTED" != "ja" ]]; then
        log "Fehler: Minecraft EULA wurde in diesem Profil noch nicht akzeptiert."
        exit 2
    fi
    [[ "$DO_BACKUP" == "ja" ]] && create_backup
    sync_manual_plugins

    stop_server
    log "Entferne alten Docker-Container ${SERVER_NAME}..."
    if container_exists; then
        docker container rm -f "$SERVER_NAME" >/dev/null 2>&1 || true
    else
        log "Kein alter Docker-Container ${SERVER_NAME} vorhanden."
    fi

    local mount_path game_port
    mount_path="$(container_data_mount)"
    game_port="$(container_game_port)"

    local config_hash
    config_hash="$(desired_container_config_hash)"

    local docker_args=(-d -p "${HOST_PORT}:${game_port}")

    local cleaned_ports="${EXTRA_PORTS//,/ }"
    local mapping
    for mapping in $cleaned_ports; do
        [[ -n "${mapping:-}" ]] && docker_args+=(-p "$mapping")
    done

    docker_args+=(
        -v "${DATA_DIR}:${mount_path}"
        --name "$SERVER_NAME"
        --label "minecraftdocker.webui.config-hash=$config_hash"
        -e TZ=Europe/Berlin
        -e MEMORY="$MEMORY"
        -e TYPE="$TYPE"
        --restart always
    )

    if ! is_proxy_type; then
        docker_args+=(-e EULA=TRUE)
    fi

    [[ -n "${INIT_MEMORY:-}" ]] && docker_args+=(-e "INIT_MEMORY=$INIT_MEMORY")
    [[ -n "${MAX_MEMORY:-}" ]] && docker_args+=(-e "MAX_MEMORY=$MAX_MEMORY")
    if is_proxy_type; then
        case "${TYPE^^}" in
            VELOCITY)
                [[ -n "${VERSION:-}" && "${VERSION^^}" != "LATEST" ]] && docker_args+=(-e "VELOCITY_VERSION=$VERSION")
                ;;
            WATERFALL)
                [[ -n "${VERSION:-}" && "${VERSION^^}" != "LATEST" ]] && docker_args+=(-e "WATERFALL_VERSION=$VERSION")
                ;;
        esac
    else
        [[ -n "${VERSION:-}" ]] && docker_args+=(-e "VERSION=$VERSION")
    fi
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

    log "RAM-Konfiguration: MEMORY=${MEMORY:-<leer>}, INIT_MEMORY=${INIT_MEMORY:-<leer>}, MAX_MEMORY=${MAX_MEMORY:-<leer>}"
    log "Starte Docker-Container ${SERVER_NAME} mit ${DOCKER_IMAGE} (${TYPE^^}, ${HOST_PORT}:${game_port}, ${DATA_DIR}:${mount_path})..."
    docker run "${docker_args[@]}" "$DOCKER_IMAGE"

    if [[ "$DO_START_DOCKER" != "ja" ]]; then
        log "Stoppe den Docker-Container sofort wieder..."
        docker container stop "$SERVER_NAME" >/dev/null 2>&1 || true
    fi
}

print_status() {
    if container_exists; then
        docker container inspect "$SERVER_NAME" --format '{{.Name}} {{.State.Status}} {{.State.Running}} {{.NetworkSettings.IPAddress}}'
    else
        printf "%s missing false\n" "$SERVER_NAME"
    fi
}

print_logs() {
    if container_exists; then
        docker container logs --tail "$LOG_LINES" "$SERVER_NAME"
    else
        printf "Container %s wurde noch nicht erstellt. Nutze Anwenden oder Start.\n" "$SERVER_NAME"
    fi
}

disable_server() {
    if ! container_exists; then
        log "Container ${SERVER_NAME} ist nicht vorhanden; Profil und Daten bleiben erhalten."
        return 0
    fi
    log "Deaktiviere Server ${SERVER_NAME}: entferne nur den Docker-Container."
    docker container rm -f "$SERVER_NAME"
    log "Server ${SERVER_NAME} deaktiviert. Profil und Daten bleiben erhalten."
}

download_file() {
    local url="$1"
    local target="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 \
            -H "Accept: application/octet-stream,*/*;q=0.8" \
            -A "minecraftdockerstartscript/1.0 (+https://github.com/JobbeDeluxe/minecraftdockerstartscript)" \
            -o "$target" "$url"
    else
        need_cmd wget
        wget -q --user-agent="minecraftdockerstartscript/1.0 (+https://github.com/JobbeDeluxe/minecraftdockerstartscript)" -O "$target" "$url"
    fi
}

is_jar_file() {
    local file="$1"
    [[ -s "$file" ]] || return 1
    python3 - "$file" <<'PY'
import sys
from pathlib import Path
data = Path(sys.argv[1]).read_bytes()[:4]
raise SystemExit(0 if data.startswith(b"PK\x03\x04") else 1)
PY
}

download_plugin_jar() {
    local url="$1"
    local target="$2"
    rm -f "$target"
    if ! download_file "$url" "$target"; then
        return 1
    fi
    if ! is_jar_file "$target"; then
        rm -f "$target"
        return 2
    fi
}

github_latest_jar_url() {
    local repo="$1"
    need_cmd python3
    python3 - "$repo" <<'PY'
import json, sys, urllib.request
repo = sys.argv[1].strip()
repo = repo.removeprefix("https://github.com/").removeprefix("http://github.com/").strip("/")
repo = repo.removesuffix(".git")
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
    local channels="${2:-release,beta,alpha}"
    local server_type="${3:-${TYPE:-PAPER}}"
    local mc_version="${4:-${VERSION:-LATEST}}"
    need_cmd python3
    python3 - "$slug" "$channels" "$server_type" "$mc_version" <<'PY'
import json, sys, urllib.parse, urllib.request
slug = sys.argv[1]
channels = [c.strip() for c in sys.argv[2].split(",") if c.strip()]
server_type = sys.argv[3].strip().upper()
mc_version = sys.argv[4].strip()

loader_map = {
    "PAPER": ["paper", "spigot", "bukkit"],
    "FOLIA": ["folia", "paper", "spigot", "bukkit"],
    "PURPUR": ["purpur", "paper", "spigot", "bukkit"],
    "SPIGOT": ["spigot", "bukkit"],
    "BUKKIT": ["bukkit"],
    "VELOCITY": ["velocity"],
    "BUNGEECORD": ["bungeecord", "waterfall"],
    "WATERFALL": ["waterfall", "bungeecord"],
    "FABRIC": ["fabric"],
    "QUILT": ["quilt", "fabric"],
    "FORGE": ["forge"],
    "NEOFORGE": ["neoforge"],
}
preferred_loaders = loader_map.get(server_type, [server_type.lower()])
allow_loader_fallback = server_type in {"PAPER", "FOLIA", "PURPUR", "SPIGOT", "BUKKIT"}
url = "https://api.modrinth.com/v2/project/%s/version" % urllib.parse.quote(slug)
req = urllib.request.Request(url, headers={"User-Agent": "minecraftdocker-webui"})
with urllib.request.urlopen(req, timeout=20) as resp:
    versions = json.load(resp)

def jar_files(version):
    return [
        file for file in version.get("files", [])
        if file.get("filename", "").lower().endswith(".jar")
        and "sources" not in file.get("filename", "").lower()
        and "javadoc" not in file.get("filename", "").lower()
    ]

def choose_file(version):
    primary = version.get("files", [])
    for file in primary:
        if file.get("primary") and file in jar_files(version):
            return file
    files = jar_files(version)
    return files[0] if files else None

def version_matches_mc(version):
    if not mc_version or mc_version.upper() == "LATEST":
        return True
    return mc_version in set(version.get("game_versions") or [])

for channel in channels:
    channel_versions = [v for v in versions if v.get("version_type") == channel]
    if not channel_versions:
        continue

    mc_versions = [v for v in channel_versions if version_matches_mc(v)]
    search_sets = [("mit passender Minecraft-Version", mc_versions)]
    if mc_version and mc_version.upper() != "LATEST" and not mc_versions:
        print(
            f"Warnung: Modrinth {slug}: keine {channel}-Version fuer Minecraft {mc_version}; pruefe neueste passende Loader-Version.",
            file=sys.stderr,
        )
    if mc_version and mc_version.upper() != "LATEST":
        search_sets.append(("ohne Minecraft-Versionsfilter", channel_versions))

    for scope_label, candidates in search_sets:
        for loader in preferred_loaders:
            for version in candidates:
                loaders = set(version.get("loaders") or [])
                if loader not in loaders:
                    continue
                file = choose_file(version)
                if file:
                    print(
                        f"Modrinth {slug}: waehle {version.get('version_number')} fuer Loader {loader} ({scope_label}): {file.get('filename')}",
                        file=sys.stderr,
                    )
                    print(file["url"])
                    raise SystemExit

    if allow_loader_fallback:
        for version in channel_versions:
            file = choose_file(version)
            if file:
                print(
                    f"Warnung: Modrinth {slug}: kein bevorzugter Loader {preferred_loaders} gefunden; nutze Fallback {version.get('loaders')} {file.get('filename')}.",
                    file=sys.stderr,
                )
                print(file["url"])
                raise SystemExit

print(f"Fehler: Modrinth {slug}: keine JAR fuer Server-Typ {server_type} mit Loader {preferred_loaders} gefunden.", file=sys.stderr)
raise SystemExit(1)
PY
}

extract_spigot_resource_id() {
    local url="$1"
    url="${url#http://}"
    url="${url#https://}"
    url="${url#www.}"
    if [[ "$url" =~ ^spigotmc\.org/resources/[^/]*\.([0-9]+)(/.*)?$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

spiget_latest_download_url() {
    local id="$1"
    echo "https://api.spiget.org/v2/resources/${id}/download"
}

extract_modrinth_slug() {
    local url="$1"
    url="${url#http://}"
    url="${url#https://}"
    url="${url#www.}"
    if [[ "$url" =~ ^modrinth\.com/(plugin|project|mod)/([A-Za-z0-9._-]+) ]]; then
        echo "${BASH_REMATCH[2]}"
        return 0
    fi
    return 1
}

bukkit_modrinth_slug_fallback() {
    local plugin_name="$1"
    case "${plugin_name,,}" in
        worldedit|world-edit)
            echo "worldedit"
            return 0
            ;;
    esac
    return 1
}

download_griefprevention_latest() {
    local target="$1"
    local url
    url="$(modrinth_latest_jar_url "griefprevention" || true)"
    if [[ -n "${url:-}" ]] && download_plugin_jar "$url" "$target"; then
        log "GriefPrevention: Fallback ueber Modrinth erfolgreich."
        return 0
    fi
    url="$(github_latest_jar_url "TechFortress/GriefPrevention" || true)"
    if [[ -n "${url:-}" ]] && download_plugin_jar "$url" "$target"; then
        log "GriefPrevention: Fallback ueber GitHub Releases erfolgreich."
        return 0
    fi
    download_plugin_jar "https://github.com/TechFortress/GriefPrevention/releases/latest/download/GriefPrevention.jar" "$target"
}

install_plugin_jar() {
    local name="$1"
    local source="$2"
    local target="${PLUGIN_DIR}/${name}.jar"
    cp -f "$source" "$target"
    local size
    size="$(wc -c < "$target" 2>/dev/null || printf '?')"
    log "Plugin ${name}: gespeichert nach ${target} (${size} Bytes)."
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

    local line name source url target failed updated skipped spec slug channels rid fallback_slug
    failed=0
    updated=0
    skipped=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%$'\r'}"
        [[ -z "${line//[[:space:]]/}" || "$line" =~ ^[[:space:]]*# ]] && continue
        name="$(awk '{print $1}' <<<"$line")"
        source="$(awk '{print $NF}' <<<"$line")"
        [[ -z "$name" || -z "$source" ]] && continue
        target="${tmp_dir}/${name}.jar"
        url=""

        log "Plugin ${name}: ermittle Download aus ${source}"
        if [[ "${name,,}" == "coreprotect" && "$source" == build:* ]]; then
            source="https://github.com/PlayPro/CoreProtect:${source#build:}"
            log "Plugin ${name}: nutze CoreProtect-Source-Build ${source}"
        fi
        if [[ "${name,,}" == "coreprotect" && "$source" == https://github.com/* ]]; then
            if build_coreprotect "$source" "$target"; then
                install_plugin_jar "$name" "$target"
                updated=$((updated + 1))
                log "Plugin ${name}: aus Source gebaut und aktualisiert."
            else
                failed=$((failed + 1))
                log "Plugin ${name}: Build fehlgeschlagen."
            fi
            continue
        elif [[ "$source" == modrinth:* ]]; then
            spec="${source#modrinth:}"
            slug="${spec%@*}"
            channels="${spec#*@}"
            [[ "$channels" == "$slug" ]] && channels=""
            url="$(modrinth_latest_jar_url "$slug" "$channels" "$TYPE" "$VERSION" || true)"
        elif [[ "$source" == *"modrinth.com/plugin/"* || "$source" == *"modrinth.com/project/"* || "$source" == *"modrinth.com/mod/"* ]]; then
            if slug="$(extract_modrinth_slug "$source")"; then
                url="$(modrinth_latest_jar_url "$slug" "" "$TYPE" "$VERSION" || true)"
            fi
        elif [[ "$source" == *"spigotmc.org/resources/"* ]]; then
            if rid="$(extract_spigot_resource_id "$source")"; then
                url="$(spiget_latest_download_url "$rid")"
            fi
        elif [[ "$source" == *"dev.bukkit.org"* ]]; then
            if fallback_slug="$(bukkit_modrinth_slug_fallback "$name")"; then
                log "Plugin ${name}: DevBukkit blockiert oft Direktdownloads, versuche Modrinth-Fallback (${fallback_slug})."
                url="$(modrinth_latest_jar_url "$fallback_slug" "" "$TYPE" "$VERSION" || true)"
            elif [[ "${name,,}" == "griefprevention" ]]; then
                if download_griefprevention_latest "$target"; then
                    install_plugin_jar "$name" "$target"
                    updated=$((updated + 1))
                    log "Plugin ${name}: per Fallback aktualisiert."
                else
                    failed=$((failed + 1))
                    log "Plugin ${name}: Fallback-Download fehlgeschlagen."
                fi
                continue
            else
                url="$source"
            fi
        elif [[ "$source" == https://github.com/* ]]; then
            url="$(github_latest_jar_url "$source" || true)"
        elif [[ "$source" == http://* || "$source" == https://* ]]; then
            url="$source"
        fi

        if [[ -z "$url" ]]; then
            failed=$((failed + 1))
            log "Plugin ${name}: keine unterstuetzte Download-URL gefunden."
            continue
        fi
        if download_plugin_jar "$url" "$target"; then
            install_plugin_jar "$name" "$target"
            updated=$((updated + 1))
            log "Plugin ${name}: aktualisiert."
        else
            failed=$((failed + 1))
            log "Plugin ${name}: Download fehlgeschlagen oder Ergebnis war keine JAR-Datei."
        fi
    done < "$PLUGIN_CONFIG"
    log "Plugin-Update abgeschlossen: ${updated} aktualisiert, ${failed} fehlgeschlagen, ${skipped} uebersprungen."
    if (( failed > 0 )); then
        return 1
    fi
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
    local owner_repo
    if [[ "$source" =~ ^(https://github.com/[^:]+):(.+)$ ]]; then
        repo="${BASH_REMATCH[1]}"
        branch="${BASH_REMATCH[2]}"
    fi
    owner_repo="${repo#https://github.com/}"
    owner_repo="${owner_repo%.git}"
    owner_repo="${owner_repo%/}"

    local workdir zip srcdir plugin_yml
    workdir="$(mktemp -d)"
    zip="${workdir}/src.zip"

    log "CoreProtect: lade Source-Archiv ${owner_repo} (${branch})"
    if ! download_file "https://github.com/${owner_repo}/archive/refs/heads/${branch}.zip" "$zip"; then
        log "CoreProtect: Source-Archiv konnte nicht geladen werden, versuche Release-Fallback."
        rm -rf "$workdir"
        download_coreprotect_release_fallback "$target"
        return $?
    fi

    if command -v unzip >/dev/null 2>&1; then
        if ! unzip -q "$zip" -d "$workdir"; then
            log "CoreProtect: Entpacken fehlgeschlagen, versuche Release-Fallback."
            rm -rf "$workdir"
            download_coreprotect_release_fallback "$target"
            return $?
        fi
    else
        need_cmd python3
        if ! python3 - "$zip" "$workdir" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as zf:
    zf.extractall(sys.argv[2])
PY
        then
            log "CoreProtect: Entpacken fehlgeschlagen, versuche Release-Fallback."
            rm -rf "$workdir"
            download_coreprotect_release_fallback "$target"
            return $?
        fi
    fi

    plugin_yml="$(find "$workdir" -type f -path "*/src/main/resources/plugin.yml" | head -n 1)"
    if [[ -n "${plugin_yml:-}" ]]; then
        srcdir="$(cd "$(dirname "$plugin_yml")/../../.." && pwd)"
        patch_coreprotect_source "$plugin_yml" "$srcdir"
    else
        srcdir="$(find "$workdir" -mindepth 1 -maxdepth 2 -type f -name pom.xml -printf '%h\n' | head -n 1)"
    fi

    if [[ -z "${srcdir:-}" || ! -f "$srcdir/pom.xml" ]]; then
        log "CoreProtect: Maven-Projektwurzel nicht gefunden, versuche Release-Fallback."
        rm -rf "$workdir"
        download_coreprotect_release_fallback "$target"
        return $?
    fi

    log "CoreProtect: baue Plugin mit Maven."
    local build_ok=0
    if command -v mvn >/dev/null 2>&1; then
        if (cd "$srcdir" && MAVEN_OPTS="${MAVEN_OPTS:-} -Djava.net.preferIPv4Stack=true -Djava.net.preferIPv4Addresses=true" mvn -B -q -DskipTests -Dmaven.compiler.source=25 -Dmaven.compiler.target=25 package); then
            build_ok=1
        else
            log "CoreProtect: lokaler Maven-Build fehlgeschlagen."
        fi
    else
        if docker run --rm -v "$srcdir":/src -w /src -e MAVEN_OPTS="${MAVEN_OPTS:-} -Djava.net.preferIPv4Stack=true -Djava.net.preferIPv4Addresses=true" maven:3.9-eclipse-temurin-25 mvn -B -q -DskipTests -Dmaven.compiler.source=25 -Dmaven.compiler.target=25 package; then
            build_ok=1
        else
            log "CoreProtect: Docker-Maven-Build fehlgeschlagen."
        fi
    fi
    if [[ "$build_ok" != "1" ]]; then
        log "CoreProtect: Build fehlgeschlagen, versuche Release-Fallback."
        rm -rf "$workdir"
        download_coreprotect_release_fallback "$target"
        return $?
    fi
    local jar
    jar="$(find "$srcdir" -type f -path "*/target/*.jar" ! -name "*sources*" ! -name "*javadoc*" | head -n 1)"
    if [[ -z "$jar" ]]; then
        log "CoreProtect: Build hat keine JAR erzeugt, versuche Release-Fallback."
        rm -rf "$workdir"
        download_coreprotect_release_fallback "$target"
        return $?
    fi
    cp "$jar" "$target"
    rm -rf "$workdir"
}

patch_coreprotect_source() {
    local plugin_yml="$1"
    local srcdir="$2"
    if grep -q 'branch:[[:space:]]*\${project\.branch}' "$plugin_yml"; then
        sed -i 's/branch:[[:space:]]*\${project\.branch}/branch: developement/' "$plugin_yml"
        log "CoreProtect: plugin.yml angepasst."
    fi
    if [[ -f "$srcdir/pom.xml" ]]; then
        sed -i -E \
            -e 's#<maven\.compiler\.source>[^<]+</maven\.compiler\.source>#<maven.compiler.source>25</maven.compiler.source>#' \
            -e 's#<maven\.compiler\.target>[^<]+</maven\.compiler\.target>#<maven.compiler.target>25</maven.compiler.target>#' \
            -e 's#<source>[0-9]+</source>#<source>25</source>#' \
            -e 's#<target>[0-9]+</target>#<target>25</target>#' \
            "$srcdir/pom.xml"
    fi
}

download_coreprotect_release_fallback() {
    local target="$1"
    local url
    url="$(github_latest_jar_url "https://github.com/PlayPro/CoreProtect" || true)"
    if [[ -n "${url:-}" ]]; then
        log "CoreProtect: lade offizielle Release-JAR."
        download_plugin_jar "$url" "$target" && return 0
    fi
    log "CoreProtect: versuche direkten Release-Download."
    download_plugin_jar "https://github.com/PlayPro/CoreProtect/releases/latest/download/CoreProtect.jar" "$target"
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
    disable) disable_server ;;
    backup) create_backup ;;
    restore) restore_backup ;;
    plugins) update_plugins ;;
    rcon) send_rcon_command ;;
    status) print_status ;;
    logs) print_logs ;;
    *) echo "Unknown action: $ACTION" >&2; exit 2 ;;
esac
