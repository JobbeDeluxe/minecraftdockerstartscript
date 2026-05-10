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
  status   Print a compact Docker status line
  logs     Print recent Docker logs
EOF
}

while (($# > 0)); do
    case "$1" in
        --config)
            CONFIG_FILE="${2:-}"
            shift 2
            ;;
        --action)
            ACTION="${2:-apply}"
            shift 2
            ;;
        --log-lines)
            LOG_LINES="${2:-200}"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ -z "${CONFIG_FILE:-}" || ! -f "$CONFIG_FILE" ]]; then
    echo "Config file not found: ${CONFIG_FILE:-<empty>}" >&2
    exit 2
fi

set -a
# The WebUI writes this local env file with shell-quoted values.
# shellcheck disable=SC1090
source "$CONFIG_FILE"
set +a

DATA_DIR="${DATA_DIR:-/opt/minecraft_server}"
SERVER_NAME="${SERVER_NAME:-mc}"
BACKUP_DIR="${BACKUP_DIR:-${DATA_DIR}/backups}"
PLUGIN_DIR="${PLUGIN_DIR:-${DATA_DIR}/plugins}"
DOCKER_IMAGE="${DOCKER_IMAGE:-itzg/minecraft-server}"
LOG_FILE="${LOG_FILE:-${DATA_DIR}/update_log.txt}"
HOST_PORT="${HOST_PORT:-25565}"
MEMORY="${MEMORY:-6G}"
TYPE="${TYPE:-PAPER}"
VERSION="${VERSION:-LATEST}"
PAPER_CHANNEL="${PAPER_CHANNEL:-default}"
DO_BACKUP="${DO_BACKUP:-nein}"
DO_START_DOCKER="${DO_START_DOCKER:-ja}"
EXTRA_PORTS="${EXTRA_PORTS:-}"

mkdir -p "$DATA_DIR" "$PLUGIN_DIR" "$BACKUP_DIR"

log() {
    printf "%s - %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" | tee -a "$LOG_FILE"
}

need_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        log "Fehler: docker ist nicht installiert."
        exit 1
    fi
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
    local backup_file="${BACKUP_DIR}/backup_$(date +%Y%m%d%H%M).tar.gz"
    log "Erstelle Backup: ${backup_file}"
    tar --exclude="./backups" -czf "$backup_file" -C "$DATA_DIR" .
    log "Backup abgeschlossen: ${backup_file}"
}

apply_container() {
    [[ "$DO_BACKUP" == "ja" ]] && create_backup

    stop_server
    log "Entferne alten Docker-Container ${SERVER_NAME}..."
    docker rm "$SERVER_NAME" >/dev/null 2>&1 || true

    local docker_args=(
        -d
        -p "${HOST_PORT}:25565"
    )

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

    [[ -n "${VERSION:-}" ]] && docker_args+=(-e "VERSION=$VERSION")
    if [[ "${TYPE^^}" == "PAPER" && -n "${PAPER_CHANNEL:-}" ]]; then
        docker_args+=(-e "PAPER_CHANNEL=$PAPER_CHANNEL")
    fi

    log "Starte Docker-Container ${SERVER_NAME}..."
    docker run "${docker_args[@]}" "$DOCKER_IMAGE"

    if [[ "$DO_START_DOCKER" != "ja" ]]; then
        log "Stoppe den Docker-Container sofort wieder..."
        docker stop "$SERVER_NAME" >/dev/null 2>&1 || true
    fi
}

need_docker

case "${ACTION,,}" in
    apply)
        apply_container
        ;;
    start)
        start_server
        ;;
    stop)
        stop_server
        ;;
    restart)
        stop_server
        start_server
        ;;
    backup)
        create_backup
        ;;
    status)
        docker inspect "$SERVER_NAME" --format '{{.Name}} {{.State.Status}} {{.State.Running}} {{.NetworkSettings.IPAddress}}'
        ;;
    logs)
        docker logs --tail "$LOG_LINES" "$SERVER_NAME"
        ;;
    *)
        echo "Unknown action: $ACTION" >&2
        exit 2
        ;;
esac
