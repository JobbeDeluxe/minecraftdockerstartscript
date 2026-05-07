#!/bin/bash
set -euo pipefail

# === Minecraft Docker Update-, Backup- und Restore-Skript ===

# === Konfigurationsdatei für History ===
HISTORY_FILE="${HOME}/.minecraft_script_history"
HISTORY_LOCK="${HISTORY_FILE}.lock"

ensure_history_storage() {
    local history_dir
    history_dir="$(dirname "$HISTORY_FILE")"
    mkdir -p "$history_dir"
    : > "$HISTORY_LOCK"
}

# ------------------------ History-Helpers ------------------------

save_history() {
    local key="$1"
    local value="$2"
    ensure_history_storage

    local tmp_file
    tmp_file="$(mktemp "${HISTORY_FILE}.XXXXXX")"

    exec {lock_fd}>"$HISTORY_LOCK"
    flock "$lock_fd"

    if [[ -f "$HISTORY_FILE" ]]; then
        grep -v "^${key}=" "$HISTORY_FILE" > "$tmp_file" 2>/dev/null || true
    fi
    printf '%s=%s\n' "$key" "$value" >> "$tmp_file"
    mv "$tmp_file" "$HISTORY_FILE"

    python3 - "$HISTORY_FILE" <<'PY' 2>/dev/null || true
import os
import sys

path = sys.argv[1]
try:
    fd = os.open(path, os.O_RDONLY)
except OSError:
    sys.exit(0)
try:
    os.fsync(fd)
finally:
    os.close(fd)
PY

    flock -u "$lock_fd"
    exec {lock_fd}>&-
}

load_history() {
    local key="$1"
    ensure_history_storage

    exec {lock_fd}<"$HISTORY_LOCK"
    flock -s "$lock_fd"

    if [[ -f "$HISTORY_FILE" ]]; then
        local line
        line=$(grep "^${key}=" "$HISTORY_FILE" | tail -1 2>/dev/null || true)
        if [[ -n "${line:-}" ]]; then
            echo "${line#*=}"
        fi
    fi

    flock -u "$lock_fd"
    exec {lock_fd}<&-
}

read_with_history() {
    local prompt="$1"
    local default="$2"
    local history_key="$3"
    local user_input last_value
    last_value=$(load_history "$history_key" || true)

    if [[ -n "${last_value:-}" ]]; then
        printf "%s [Letzte Eingabe: %s] (Standard: %s): " "$prompt" "$last_value" "$default" >&2
        read -r user_input || true
        if [[ -z "${user_input:-}" ]]; then
            if [[ -n "${last_value:-}" ]]; then
                user_input="$last_value"
            else
                user_input="$default"
            fi
        fi
    else
        printf "%s (Standard: %s): " "$prompt" "$default" >&2
        read -r user_input || true
    fi

    [[ -z "${user_input:-}" ]] && user_input="$default"
    if [[ -n "$history_key" ]]; then
        save_history "$history_key" "$user_input"
    fi
    echo "$user_input"
}

select_with_history() {
    local prompt="$1"
    local history_key="$2"
    shift 2

    local -a raw_options=("$@")

    local -a option_values=()
    local -a option_displays=()

    local opt value display
    for opt in "${raw_options[@]}"; do
        if [[ "$opt" == *":::"* ]]; then
            value="${opt%%:::*}"
            display="${opt#*:::}"
            [[ -z "${display:-}" ]] && display="$value"
        else
            value="$opt"
            display="$opt"
        fi
        option_values+=("$value")
        option_displays+=("$display")
    done

    if ((${#option_values[@]} == 0)); then
        echo "select_with_history benötigt mindestens eine Option." >&2
        return 1
    fi
    if ((${#option_values[@]} > 10)); then
        echo "select_with_history unterstützt maximal 10 Optionen (übergeben: ${#option_values[@]})." >&2
        return 1
    fi

    local raw_last default_index="" default_custom=""
    raw_last=$(load_history "$history_key" || true)

    if [[ "$raw_last" == CUSTOM:* ]]; then
        default_custom="${raw_last#CUSTOM:}"
    elif [[ "$raw_last" == INDEX:* ]]; then
        local idx="${raw_last#INDEX:}"
        if [[ "$idx" =~ ^[0-9]+$ ]]; then
            default_index="$idx"
        fi
    elif [[ "$raw_last" =~ ^[0-9]+$ ]]; then
        default_index="$raw_last"
    elif [[ -n "$raw_last" ]]; then
        for i in "${!option_values[@]}"; do
            if [[ "${option_values[$i]}" == "$raw_last" ]]; then
                default_index=$(( i + 1 ))
                break
            fi
        done
        if [[ -z "$default_index" ]]; then
            default_custom="$raw_last"
        fi
    fi

    if [[ -n "$default_index" ]]; then
        if (( default_index < 1 || default_index > ${#option_values[@]} )); then
            default_index=""
        fi
    fi

    if [[ -z "$default_index" && -z "$default_custom" ]]; then
        default_index=1
    fi

    local choice="" custom_value=""

    while true; do
        printf "%s\n" "$prompt" >&2
        for i in "${!option_values[@]}"; do
            local num=$(( i + 1 ))
            local marker=""
            if [[ -n "$default_index" && "$num" -eq "$default_index" ]]; then
                marker=" [Standard]"
            fi
            printf "  %d) %s%s\n" "$num" "${option_displays[$i]}" "$marker" >&2
        done

        local custom_label="Eigene Eingabe"
        if [[ -n "$default_custom" ]]; then
            custom_label+=" (Letzte Eingabe: $default_custom)"
            custom_label+=" [Standard]"
        fi
        printf "  0) %s\n" "$custom_label" >&2

        local default_desc
        if [[ -n "$default_custom" ]]; then
            default_desc="$default_custom"
        elif [[ -n "$default_index" ]]; then
            default_desc="${option_displays[$((default_index - 1))]}"
        else
            default_desc="${option_displays[0]}"
        fi

        printf "Auswahl (Enter = %s): " "$default_desc" >&2
        read -r choice || choice=""

        if [[ -z "$choice" ]]; then
            if [[ -n "$default_custom" ]]; then
                choice=0
                custom_value="$default_custom"
            elif [[ -n "$default_index" ]]; then
                choice="$default_index"
            else
                choice=1
            fi
        fi

        if [[ "$choice" == 0 ]]; then
            if [[ -z "$custom_value" ]]; then
                printf "Bitte gewünschte Eingabe: " >&2
                read -r custom_value || custom_value=""
            fi
            if [[ -z "$custom_value" ]]; then
                echo "Keine Eingabe erhalten. Bitte erneut versuchen." >&2
                continue
            fi
            save_history "$history_key" "CUSTOM:${custom_value}"
            SELECT_WITH_HISTORY_RESULT="$custom_value"
            echo 0
            return 0
        elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#option_values[@]} )); then
            save_history "$history_key" "INDEX:${choice}"
            SELECT_WITH_HISTORY_RESULT="${option_values[$((choice - 1))]}"
            echo "$choice"
            return 0
        else
            echo "Ungültige Auswahl: $choice" >&2
        fi

        custom_value=""
    done
}

read_yesno_with_history() {
    local prompt="$1"
    local history_key="$2"
    local user_input last_value
    last_value=$(load_history "$history_key" || true)

    if [[ -n "${last_value:-}" ]]; then
        printf "%s [Letzte Eingabe: %s] (ja/nein): " "$prompt" "$last_value" >&2
        read -r user_input || true
        [[ -z "${user_input:-}" ]] && user_input="$last_value"
    else
        printf "%s (ja/nein): " "$prompt" >&2
        read -r user_input || true
    fi

    case "${user_input,,}" in
        j|ja|y|yes) user_input="ja" ;;
        n|nein|no)  user_input="nein" ;;
        *)          user_input="nein" ;;
    esac

    save_history "$history_key" "$user_input"
    echo "$user_input"
}

map_type_to_version_endpoint() {
    local type_upper="${1^^}"
    case "$type_upper" in
        PAPER|FOLIA)
            local slug
            slug="$(echo "$type_upper" | tr '[:upper:]' '[:lower:]')"
            printf '%s\n' "papermc_fill:https://fill.papermc.io/v3/projects/${slug}"
            return 0
            ;;
        PURPUR)
            printf '%s\n' "purpur:https://api.purpurmc.org/v2/purpur"
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

fetch_versions_for_type() {
    local type="$1"
    local mapping
    mapping=$(map_type_to_version_endpoint "$type" || true)
    if [[ -z "${mapping:-}" ]]; then
        return 1
    fi

    local provider="${mapping%%:*}"
    local url="${mapping#*:}"
    local resp
    if ! resp=$(curl -sfL "$url"); then
        return 1
    fi

    local jq_filter
    case "$provider" in
        papermc_fill) jq_filter='.versions | to_entries[] | .value[]?' ;;
        papermc) jq_filter='.versions[]?' ;;
        purpur)  jq_filter='.versions[]?' ;;
        *)       return 1 ;;
    esac

    echo "$resp" | jq -r "$jq_filter" 2>/dev/null | awk 'NF'
}

declare -A PAPER_VERSION_CHANNEL_CACHE=()

get_paper_version_channel_summary() {
    local version="$1"

    if [[ -n "${PAPER_VERSION_CHANNEL_CACHE[$version]+_}" ]]; then
        printf '%s\n' "${PAPER_VERSION_CHANNEL_CACHE[$version]}"
        return 0
    fi

    local url resp
    if [[ "$version" == 26.* ]]; then
        url="https://fill.papermc.io/v3/projects/paper/versions/${version}/builds"
    else
        url="https://api.papermc.io/v2/projects/paper/versions/${version}/builds"
    fi
    if ! resp=$(curl -sfL "$url" 2>/dev/null); then
        return 1
    fi

    local summary
    if [[ "$version" == 26.* ]]; then
        summary=$(echo "$resp" | jq -r '.[].channel' 2>/dev/null | awk 'NF' | sort -u | paste -sd ', ' -)
    else
        summary=$(echo "$resp" | jq -r '.builds[]?.channel' 2>/dev/null | awk 'NF' | sort -u | paste -sd ', ' -)
    fi
    if [[ -z "${summary:-}" ]]; then
        return 1
    fi

    PAPER_VERSION_CHANNEL_CACHE[$version]="$summary"
    printf '%s\n' "$summary"
}

select_version_for_type() {
    local type="$1"
    local history_key="$2"
    local prompt="$3"

    VERSION_CHANNEL_HINT=""
    VERSION_SELECTION_SOURCE="manual"

    local versions_raw
    versions_raw=$(fetch_versions_for_type "$type" || true)

    if [[ -z "${versions_raw:-}" ]]; then
        echo "Es konnten keine Versionen für den Typ ${type} ermittelt werden. Bitte manuell eingeben." >&2
        VERSION=$(read_with_history "$prompt" "LATEST" "$history_key")
        VERSION_SELECTION_SOURCE="manual"
        VERSION_CHANNEL_HINT=""
        return
    fi

    local -a all_versions=()
    while IFS= read -r version; do
        all_versions+=("$version")
    done <<<"$versions_raw"

    if ((${#all_versions[@]} == 0)); then
        VERSION=$(read_with_history "$prompt" "LATEST" "$history_key")
        VERSION_SELECTION_SOURCE="manual"
        VERSION_CHANNEL_HINT=""
        return
    fi

    mapfile -t all_versions < <(printf '%s\n' "${all_versions[@]}" | sort -rV | uniq)

    local -a menu_versions=("LATEST")
    local -a menu_channel_info=("")
    local limit=9
    local count=0
    for v in "${all_versions[@]}"; do
        local entry="$v"
        local channel_summary=""
        if [[ "${type^^}" == "PAPER" ]]; then
            if channel_summary=$(get_paper_version_channel_summary "$v" || true) && [[ -n "${channel_summary:-}" ]]; then
                entry="${v}:::${v} (${channel_summary})"
            fi
        fi

        menu_versions+=("$entry")
        menu_channel_info+=("$channel_summary")
        ((++count))
        if ((count >= limit)); then
            break
        fi
    done

    while true; do
        local selection temp_file
        temp_file="$(mktemp)"
        if ! select_with_history "$prompt" "$history_key" "${menu_versions[@]}" >"$temp_file"; then
            rm -f "$temp_file"
            echo "Version konnte nicht ausgewählt werden." >&2
            exit 1
        fi

        selection="$(<"$temp_file")"
        rm -f "$temp_file"

        local chosen="$SELECT_WITH_HISTORY_RESULT"
        local selection_source="manual"
        local channel_hint=""

        if [[ "$selection" =~ ^[0-9]+$ ]] && (( selection >= 1 && selection <= ${#menu_versions[@]} )); then
            selection_source="menu"
            channel_hint="${menu_channel_info[$((selection - 1))]:-}"
        fi

        if [[ "$chosen" == "LATEST" ]]; then
            save_history "$history_key" "$chosen"
            VERSION="$chosen"
            VERSION_SELECTION_SOURCE="$selection_source"
            VERSION_CHANNEL_HINT="$channel_hint"
            return
        fi

        if [[ -z "${chosen:-}" ]]; then
            echo "Keine Version angegeben. Bitte erneut wählen." >&2
            continue
        fi

        if [[ "${chosen^^}" == "${type^^}" ]]; then
            echo "Die Eingabe entspricht dem Server-Typ '${type}'. Bitte geben Sie eine Versionsnummer wie z. B. 1.21.1 an." >&2
            continue
        fi

        local valid=0
        for v in "${all_versions[@]}"; do
            if [[ "$v" == "$chosen" ]]; then
                valid=1
                break
            fi
        done

        if ((valid)); then
            save_history "$history_key" "$chosen"
            VERSION="$chosen"
            VERSION_SELECTION_SOURCE="$selection_source"
            if [[ "$selection_source" == "menu" ]]; then
                VERSION_CHANNEL_HINT="$channel_hint"
            else
                VERSION_CHANNEL_HINT=""
            fi
            return
        fi

        local confirm_custom
        confirm_custom=$(read_yesno_with_history "Die Auswahl '${chosen}' konnte nicht geprüft werden. Trotzdem verwenden?" "CONFIRM_VERSION_${type^^}")
        if [[ "${confirm_custom,,}" == "ja" ]]; then
            save_history "$history_key" "$chosen"
            VERSION="$chosen"
            VERSION_SELECTION_SOURCE="manual"
            VERSION_CHANNEL_HINT=""
            log "Hinweis: Verwende benutzerdefinierte Version '${chosen}' ohne Validierung."
            return
        fi

        echo "Die Auswahl '${chosen}' ist nicht unter den verfügbaren Versionen. Bitte erneut wählen." >&2
    done
}

select_server_type() {
    local prompt="Welcher Server-Typ (PAPER, SPIGOT, VANILLA, ... )?"
    local history_key="TYPE"
    local -a options=(
        "PAPER"
        "FOLIA"
        "PURPUR"
        "SPIGOT"
        "VANILLA"
        "FABRIC"
        "FORGE"
        "QUILT"
        "BUNGEECORD"
        "VELOCITY"
    )

    if ! select_with_history "$prompt" "$history_key" "${options[@]}" >/dev/null; then
        echo "Server-Typ konnte nicht ausgewählt werden." >&2
        exit 1
    fi

    local chosen="$SELECT_WITH_HISTORY_RESULT"
    if [[ -z "${chosen:-}" ]]; then
        chosen="PAPER"
    fi

    chosen="${chosen^^}"
    save_history "$history_key" "$chosen"
    TYPE="$chosen"
}

prompt_host_port() {
    local history_key="HOST_PORT"
    local default_port="25565"
    local last_value
    while true; do
        last_value=$(load_history "$history_key" || true)

        if [[ -n "${last_value:-}" ]]; then
            printf "Welcher Host-Port soll für den Minecraft-Server verwendet werden? (Standard: %s) [Letzte Eingabe: %s, Enter übernimmt letzte Eingabe]: " "$default_port" "$last_value" >&2
        else
            printf "Welcher Host-Port soll für den Minecraft-Server verwendet werden? (Standard: %s): " "$default_port" >&2
        fi
        local input=""
        read -r input || input=""
        if [[ -z "${input:-}" ]]; then
            if [[ -n "${last_value:-}" ]]; then
                input="$last_value"
            else
                input="$default_port"
            fi
        fi

        if [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= 65535 )); then
            HOST_PORT="$input"
            save_history "$history_key" "$HOST_PORT"
            break
        fi

        echo "Ungültige Portnummer '${input}'. Bitte eine Zahl zwischen 1 und 65535 angeben." >&2
    done
}

prompt_additional_ports() {
    EXTRA_PORT_MAPPINGS=()

    local enable_extra
    enable_extra=$(read_yesno_with_history "Sollen zusätzliche Ports (z. B. 19132:19132/udp) freigegeben werden?" "EXTRA_PORTS_ENABLED")
    if [[ "${enable_extra,,}" != "ja" ]]; then
        return
    fi

    local history_key="EXTRA_PORTS_LIST"
    local last_value
    last_value=$(load_history "$history_key" || true)

    while true; do
        local input=""
        local info_msg="Zusätzliche Ports im Format Host:Container[/Protokoll] (z. B. 19132:19132/udp). Mehrere Einträge durch Kommas oder Leerzeichen trennen. '-' löscht alle zusätzlichen Ports."
        printf "%s\n" "$info_msg" >&2
        if [[ -n "${last_value:-}" ]]; then
            printf "Eingabe (Enter = %s): " "$last_value" >&2
        else
            printf "Eingabe (Enter = keine zusätzlichen Ports): " >&2
        fi
        read -r input || input=""

        if [[ -z "${input:-}" ]]; then
            input="$last_value"
        fi

        if [[ "${input:-}" == "-" ]]; then
            save_history "$history_key" ""
            EXTRA_PORT_MAPPINGS=()
            return
        fi

        local condensed
        condensed="${input//[[:space:],]/}"
        if [[ -z "${condensed:-}" ]]; then
            save_history "$history_key" ""
            EXTRA_PORT_MAPPINGS=()
            return
        fi

        local cleaned
        cleaned=$(echo "$input" | tr ',' ' ')
        local -a tokens=()
        read -ra tokens <<< "$cleaned"

        local -a parsed=()
        local valid=1
        local token
        for token in "${tokens[@]}"; do
            local entry="$token"
            entry="${entry//[$'\t\r\n']/}"
            [[ -z "${entry:-}" ]] && continue

            local proto=""
            if [[ "$entry" =~ /(tcp|udp)$ ]]; then
                proto="/${BASH_REMATCH[1],,}"
                entry="${entry%${BASH_REMATCH[0]}}"
            fi

            if [[ "$entry" != *:* ]]; then
                echo "Ungültiges Port-Mapping '${token}'. Erwartet wird Host:Container[/Protokoll]." >&2
                valid=0
                break
            fi

            local host_port="${entry%%:*}"
            local container_port="${entry#*:}"

            if [[ -z "${host_port:-}" || -z "${container_port:-}" || ! "$host_port" =~ ^[0-9]+$ || ! "$container_port" =~ ^[0-9]+$ ]]; then
                echo "Ungültiges Port-Mapping '${token}'. Host- und Container-Port müssen numerisch sein." >&2
                valid=0
                break
            fi

            if (( host_port < 1 || host_port > 65535 || container_port < 1 || container_port > 65535 )); then
                echo "Ungültige Ports in '${token}'. Erlaubt sind Werte zwischen 1 und 65535." >&2
                valid=0
                break
            fi

            parsed+=("${host_port}:${container_port}${proto}")
        done

        if (( ! valid )); then
            echo "Bitte die Eingaben prüfen und erneut versuchen." >&2
            last_value="$input"
            continue
        fi

        if (( ${#parsed[@]} == 0 )); then
            save_history "$history_key" ""
            EXTRA_PORT_MAPPINGS=()
            return
        fi

        EXTRA_PORT_MAPPINGS=("${parsed[@]}")
        local history_value
        history_value=$(printf '%s,' "${EXTRA_PORT_MAPPINGS[@]}")
        history_value="${history_value%,}"
        save_history "$history_key" "$history_value"
        return
    done
}

init_environment() {
    # === Pfad abfragen (vor Log-Init) ===
    echo "=== Minecraft Server Management Script ===" >&2
    DATA_DIR=$(read_with_history "Pfad zum Minecraft-Datenverzeichnis" "/opt/minecraft_server" "DATA_DIR")

    # === Initialisierung nach DATA_DIR ===
    SERVER_NAME="mc"
    SERVER_NAME=$(read_with_history "Docker Container-Name" "$SERVER_NAME" "SERVER_NAME")
    BACKUP_DIR="${DATA_DIR}/backups"
    PLUGIN_DIR="${DATA_DIR}/plugins"
    PLUGIN_CONFIG="${DATA_DIR}/plugins.txt"
    DOCKER_IMAGE="itzg/minecraft-server"
    LOG_FILE="${DATA_DIR}/update_log.txt"
    HOST_PORT="25565"
    EXTRA_PORT_MAPPINGS=()
    VERSION=""
    VERSION_CHANNEL_HINT=""
    VERSION_SELECTION_SOURCE="manual"

    mkdir -p "$DATA_DIR"
}

# ------------------------ Logging & Traps ------------------------

log() {
    printf "%s - %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" | tee -a "$LOG_FILE"
}

cleanup() {
    log "Script wurde abgebrochen."
    exit 1
}
trap cleanup SIGINT SIGTERM

check_dependencies() {
    local deps=("docker" "jq" "curl" "wget" "unzip" "sed" "awk" "python3")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            log "Fehler: $dep ist nicht installiert."
            exit 1
        fi
    done
}

# ------------------------ Docker Helpers ------------------------

stop_server() {
    log "Stoppe Server..."
    docker stop "$SERVER_NAME" >/dev/null 2>&1 || true
}

start_server() {
    log "Starte Server..."
    docker start "$SERVER_NAME" >/dev/null 2>&1 || {
        log "Fehler: Konnte den Server nicht starten." >&2
        return 1
    }
}

initialize_new_server() {
    log "Initialisiere neuen Server..."
    rm -rf "$DATA_DIR/world" "$DATA_DIR/world_nether" "$DATA_DIR/world_the_end"
    rm -f "$PLUGIN_CONFIG"
    mkdir -p "$PLUGIN_DIR"
    find "$PLUGIN_DIR" -maxdepth 1 -name "*.jar" -delete
    log "Datenverzeichnis geleert für neuen Server."
}

create_backup() {
    stop_server || true
    log "Erstelle Backup..."
    mkdir -p "$BACKUP_DIR"
    local backup_name="backup_$(date +%Y%m%d%H%M)"
    local backup_file="$BACKUP_DIR/$backup_name.tar.gz"
    log "Starte Backup nach $backup_file..."
    local start_time
    start_time=$(date +%s)
    tar --exclude="./backups" -czf "$backup_file" -C "$DATA_DIR" . &
    local pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        sleep 5
        local current_size
        current_size=$(du -sh "$backup_file" 2>/dev/null | awk '{print $1}')
        local elapsed_time=$(( $(date +%s) - start_time ))
        log "Backup läuft: Größe=${current_size:-0}, verstrichene Zeit=${elapsed_time}s"
    done
    if wait "$pid"; then
        local final_size
        final_size=$(du -sh "$backup_file" | awk '{print $1}')
        local total_time=$(( $(date +%s) - start_time ))
        log "Backup erstellt: $backup_file (Größe: $final_size, Dauer: ${total_time}s)"
    else
        log "Fehler beim Erstellen des Backups." >&2
        return 1
    fi
    [[ "${DO_START_DOCKER:-nein}" == "ja" ]] && start_server || true
}

delete_and_backup_plugins() {
    log "Sichere bestehende Plugins nach ${PLUGIN_DIR}/old_version"
    mkdir -p "${PLUGIN_DIR}/old_version"
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    find "$PLUGIN_DIR" -maxdepth 1 -name "*.jar" -exec mv -v {} "${PLUGIN_DIR}/old_version/" \; | tee -a "$LOG_FILE"
    [[ -f "$PLUGIN_CONFIG" ]] && cp -v "$PLUGIN_CONFIG" "${PLUGIN_DIR}/old_version/plugins_$timestamp.txt" | tee -a "$LOG_FILE"
    log "Alte Plugins wurden gesichert."
}

# ------------------------ Download Helpers ------------------------

# ------------------------ Plugin-Konfiguration ------------------------

create_plugin_config_template() {
    cat <<'EOL' > "$PLUGIN_CONFIG"
# Format: <Plugin-Name> <Quelle>
# Quellen-Typen:
#   - GitHub-Repo:          https://github.com/<owner>/<repo>
#   - Spigot-Seite:         https://www.spigotmc.org/resources/<slug>.<ID>/
#   - Modrinth:             modrinth:<slug>   ODER   https://modrinth.com/plugin/<slug>
#     (optional: Kanal festlegen: modrinth:<slug>@beta  bzw. @alpha)
#   - Direkter Link (.jar): https://...
#   - Source-Build:         build[:branch] ODER build:<owner>/<repo>[:branch]

# Beispiele:
# CoreProtect build:PlayPro/CoreProtect:master
# SimpleVoiceChat https://modrinth.com/plugin/simple-voice-chat
# VoiceChatDiscordBridge modrinth:simple-voice-chat-discord-bridge
# DiscordSRV https://www.spigotmc.org/resources/discordsrv.18494/
# GriefPrevention modrinth:griefprevention
# ViaVersion https://github.com/ViaVersion/ViaVersion
# ViaBackwards https://github.com/ViaVersion/ViaBackwards
# Geyser-Spigot https://download.geysermc.org/v2/projects/geyser/versions/latest/builds/latest/downloads/spigot
# floodgate-spigot https://download.geysermc.org/v2/projects/floodgate/versions/latest/builds/latest/downloads/spigot
EOL
}

ensure_plugin_config() {
    if [[ ! -f "$PLUGIN_CONFIG" ]]; then
        log "plugins.txt nicht gefunden – erstelle Vorlage (alles kommentiert)."
        create_plugin_config_template
        log "Vorlage erstellt: $PLUGIN_CONFIG"
    fi
}

parse_plugin_config_entry() {
    local line="$1"
    local active="ja"
    local cleaned="$line"

    if [[ "$cleaned" =~ ^[[:space:]]*# ]]; then
        active="nein"
        cleaned="${cleaned#\#}"
        cleaned="${cleaned#"${cleaned%%[![:space:]]*}"}"
    fi

    cleaned="${cleaned%%#*}"
    cleaned="${cleaned#"${cleaned%%[![:space:]]*}"}"
    cleaned="${cleaned%"${cleaned##*[![:space:]]}"}"
    [[ -z "$cleaned" ]] && return 1

    local source="${cleaned##*[[:space:]]}"
    case "$source" in
        http://*|https://*|modrinth:*|build|build:*) ;;
        *) return 1 ;;
    esac

    local name="${cleaned%[[:space:]]$source}"
    name="${name%"${name##*[![:space:]]}"}"
    [[ -z "$name" ]] && return 1

    printf '%s\t%s\t%s\n' "$active" "$name" "$source"
}

is_valid_plugin_source() {
    local source="$1"
    case "$source" in
        http://*|https://*|modrinth:*|build|build:*) return 0 ;;
        *) return 1 ;;
    esac
}

ensure_file_ends_with_newline() {
    local file="$1"
    [[ -s "$file" ]] || return 0

    local last_byte
    last_byte=$(tail -c 1 "$file" 2>/dev/null || true)
    if [[ "$last_byte" != $'\n' ]]; then
        printf '\n' >> "$file"
    fi
}

append_plugin_config_entry() {
    local plugin_name="$1"
    local plugin_source="$2"

    ensure_file_ends_with_newline "$PLUGIN_CONFIG"
    printf '%s %s\n' "$plugin_name" "$plugin_source" >> "$PLUGIN_CONFIG"
}

load_plugin_config_entries() {
    PLUGIN_ENTRY_LINES=()
    PLUGIN_ENTRY_ACTIVE=()
    PLUGIN_ENTRY_NAMES=()
    PLUGIN_ENTRY_SOURCES=()

    local line parsed active name source line_no=0
    while IFS= read -r line || [[ -n "${line:-}" ]]; do
        ((++line_no))
        if parsed="$(parse_plugin_config_entry "$line")"; then
            IFS=$'\t' read -r active name source <<<"$parsed"
            PLUGIN_ENTRY_LINES+=("$line_no")
            PLUGIN_ENTRY_ACTIVE+=("$active")
            PLUGIN_ENTRY_NAMES+=("$name")
            PLUGIN_ENTRY_SOURCES+=("$source")
        fi
    done < "$PLUGIN_CONFIG"
}

rewrite_plugin_config_line() {
    local target_line="$1"
    local mode="$2"
    local tmp_file
    tmp_file="$(mktemp)"

    local line line_no=0
    while IFS= read -r line || [[ -n "${line:-}" ]]; do
        ((++line_no))
        if (( line_no == target_line )); then
            case "$mode" in
                enable)
                    line="${line#"${line%%[![:space:]]*}"}"
                    line="${line#\#}"
                    line="${line#"${line%%[![:space:]]*}"}"
                    ;;
                disable)
                    if [[ ! "$line" =~ ^[[:space:]]*# ]]; then
                        line="# $line"
                    fi
                    ;;
                delete)
                    continue
                    ;;
            esac
        fi
        printf '%s\n' "$line" >> "$tmp_file"
    done < "$PLUGIN_CONFIG"

    mv "$tmp_file" "$PLUGIN_CONFIG"
}

manage_plugin_config() {
    ensure_plugin_config

    while true; do
        load_plugin_config_entries
        echo "=== Pluginliste verwalten ==="
        if (( ${#PLUGIN_ENTRY_LINES[@]} == 0 )); then
            echo "Keine Plugin-Einträge vorhanden."
        else
            local i status
            for i in "${!PLUGIN_ENTRY_LINES[@]}"; do
                status="aktiv"
                [[ "${PLUGIN_ENTRY_ACTIVE[$i]}" == "nein" ]] && status="deaktiviert"
                printf "  %d) [%s] %s -> %s\n" "$((i + 1))" "$status" "${PLUGIN_ENTRY_NAMES[$i]}" "${PLUGIN_ENTRY_SOURCES[$i]}"
            done
        fi

        echo ""
        echo "1. Plugin aktivieren/deaktivieren"
        echo "2. Plugin hinzufügen"
        echo "3. Plugin löschen"
        echo "4. Fertig"
        read -r -p "Auswahl: " choice

        case "$choice" in
            1)
                if (( ${#PLUGIN_ENTRY_LINES[@]} == 0 )); then
                    echo "Keine Plugin-Einträge zum Umschalten vorhanden."
                    continue
                fi
                local idx arr_idx
                read -r -p "Nummer des Plugins: " idx
                if [[ ! "$idx" =~ ^[0-9]+$ ]] || (( idx < 1 || idx > ${#PLUGIN_ENTRY_LINES[@]} )); then
                    echo "Ungültige Auswahl."
                    continue
                fi
                arr_idx=$((idx - 1))
                if [[ "${PLUGIN_ENTRY_ACTIVE[$arr_idx]}" == "ja" ]]; then
                    rewrite_plugin_config_line "${PLUGIN_ENTRY_LINES[$arr_idx]}" disable
                    echo "${PLUGIN_ENTRY_NAMES[$arr_idx]} deaktiviert."
                else
                    rewrite_plugin_config_line "${PLUGIN_ENTRY_LINES[$arr_idx]}" enable
                    echo "${PLUGIN_ENTRY_NAMES[$arr_idx]} aktiviert."
                fi
                ;;
            2)
                local plugin_name plugin_source
                read -r -p "Plugin-Name: " plugin_name
                read -r -p "Quelle (URL, modrinth:<slug>, build[:branch] oder build:<owner>/<repo>[:branch]): " plugin_source
                if [[ -z "${plugin_name// }" || -z "${plugin_source// }" ]]; then
                    echo "Name und Quelle dürfen nicht leer sein."
                    continue
                fi
                if ! is_valid_plugin_source "$plugin_source"; then
                    echo "Ungültige Quelle. Erlaubt sind http(s)-URLs, modrinth:<slug>, build[:branch] oder build:<owner>/<repo>[:branch]."
                    continue
                fi
                append_plugin_config_entry "$plugin_name" "$plugin_source"
                echo "$plugin_name hinzugefügt und aktiviert."
                ;;
            3)
                if (( ${#PLUGIN_ENTRY_LINES[@]} == 0 )); then
                    echo "Keine Plugin-Einträge zum Löschen vorhanden."
                    continue
                fi
                local idx arr_idx confirm
                read -r -p "Nummer des Plugins: " idx
                if [[ ! "$idx" =~ ^[0-9]+$ ]] || (( idx < 1 || idx > ${#PLUGIN_ENTRY_LINES[@]} )); then
                    echo "Ungültige Auswahl."
                    continue
                fi
                arr_idx=$((idx - 1))
                read -r -p "${PLUGIN_ENTRY_NAMES[$arr_idx]} wirklich löschen? (ja/nein): " confirm
                if [[ "${confirm,,}" =~ ^(ja|j|yes|y)$ ]]; then
                    rewrite_plugin_config_line "${PLUGIN_ENTRY_LINES[$arr_idx]}" delete
                    echo "${PLUGIN_ENTRY_NAMES[$arr_idx]} gelöscht."
                fi
                ;;
            4|"")
                return 0
                ;;
            *)
                echo "Ungültige Auswahl."
                ;;
        esac
    done
}

# Robuste Erkennung von owner/repo aus GitHub-URL (ohne Regex-Fallen)
normalize_github_owner_repo() {
    local url="$1"

    url="${url#http://}"; url="${url#https://}"; url="${url#www.}"
    if [[ "$url" != github.com/* ]]; then
        return 1
    fi

    local path="${url#github.com/}"
    local owner="${path%%/*}"
    local rest="${path#*/}"
    local repo="${rest%%/*}"

    owner="${owner%%\?*}"; owner="${owner%%#*}"
    repo="${repo%%\?*}";  repo="${repo%%#*}"
    repo="${repo%.git}"

    if [[ -n "$owner" && -n "$repo" ]]; then
        echo "${owner}/${repo}"
        return 0
    fi
    return 1
}

# Ermittelt die neueste Release-JAR aus GitHub
github_latest_jar_url() {
    local owner_repo="$1"

    local auth_args=()
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        auth_args=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
    fi

    local resp
    if ! resp=$(curl -sfL -H "Accept: application/vnd.github+json" "${auth_args[@]}" \
        "https://api.github.com/repos/${owner_repo}/releases/latest"); then
        return 1
    fi

    local url
    url=$(echo "$resp" | jq -r '.assets[]? | select(.name|test("(?i)(spigot|paper).+\\.jar$")) | .browser_download_url' | head -1)
    if [[ -z "${url:-}" || "$url" == "null" ]]; then
        url=$(echo "$resp" | jq -r '.assets[]? | select(.name|test("\\.jar$")) | .browser_download_url' | head -1)
    fi

    if [[ -n "${url:-}" && "$url" != "null" ]]; then
        echo "$url"
        return 0
    fi

    # Einige Projekte markieren das neueste Release ohne Assets. Dann suchen wir
    # die jüngsten Releases nach der ersten passenden JAR ab.
    if ! resp=$(curl -sfL -H "Accept: application/vnd.github+json" "${auth_args[@]}" \
        "https://api.github.com/repos/${owner_repo}/releases?per_page=20"); then
        return 1
    fi

    url=$(echo "$resp" | jq -r '.[] | .assets[]? | select(.name|test("(?i)(spigot|paper).+\\.jar$")) | .browser_download_url' | head -1)
    if [[ -z "${url:-}" || "$url" == "null" ]]; then
        url=$(echo "$resp" | jq -r '.[] | .assets[]? | select(.name|test("\\.jar$")) | .browser_download_url' | head -1)
    fi

    [[ -n "${url:-}" && "$url" != "null" ]] && echo "$url"
}

# Allzweck-Download
download_file() {
    local url="$1"
    local out="$2"
    curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 \
        -H "Accept: application/octet-stream,*/*;q=0.8" \
        -A "minecraftdockerstartscript/1.0 (+https://github.com/JobbeDeluxe/minecraftdockerstartscript)" \
        -o "$out" "$url"
}

# ------------------------ Spigot → Spiget (LATEST Download) ------------------------

# Resource-ID aus Spigot-URL ziehen: https://www.spigotmc.org/resources/<slug>.<ID>/
extract_spigot_resource_id() {
  local url="$1"
  url="${url#http://}"; url="${url#https://}"; url="${url#www.}"
  if [[ "$url" =~ ^spigotmc\.org/resources/[^/]*\.([0-9]+)(/.*)?$ ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

# Spiget liefert 302 auf die JAR der neuesten Version – perfekt für Updates
spiget_latest_download_url() {
  local id="$1"
  echo "https://api.spiget.org/v2/resources/${id}/download"
}

# ------------------------ Modrinth (LATEST mit Channel-Fallback) ------------------------

# Modrinth: Slug aus Seiten-URL extrahieren (plugin oder project)
extract_modrinth_slug() {
  local url="$1"
  url="${url#http://}"; url="${url#https://}"; url="${url#www.}"
  if [[ "$url" =~ ^modrinth\.com/(plugin|project|mod)/([A-Za-z0-9._-]+) ]]; then
    echo "${BASH_REMATCH[2]}"
    return 0
  fi
  return 1
}

# usage: modrinth_latest_jar_url <slug> [channels_csv]
# Default-Kanäle: release,beta,alpha (überschreibbar via ENV MODRINTH_CHANNELS)
modrinth_latest_jar_url() {
    local slug="$1"
    local channels_csv="${2:-${MODRINTH_CHANNELS:-release,beta,alpha}}"
    local resp
    resp="$(curl -sfL \
        -H "Accept: application/json" \
        -A "minecraftdockerstartscript/1.0 (+https://github.com/JobbeDeluxe/minecraftdockerstartscript)" \
        "https://api.modrinth.com/v2/project/${slug}/version")" || return 1

    local IFS=','; read -ra chans <<< "$channels_csv"
    for chan in "${chans[@]}"; do
        # bevorzugt Loader: paper/spigot/bukkit/purpur
        local url
        url=$(echo "$resp" | jq -r --arg chan "$chan" '
          .[] | select(.version_type == $chan) |
          select((.loaders // []) | map(. == "paper" or . == "spigot" or . == "bukkit" or . == "purpur") | any) |
          .files[]? | select(.url | test("\\.jar$")) | .url
        ' | head -1)
        # fallback: irgendeine JAR dieses Channels
        if [[ -z "${url:-}" ]]; then
          url=$(echo "$resp" | jq -r --arg chan "$chan" '
            .[] | select(.version_type == $chan) |
            .files[]? | select(.url | test("\\.jar$")) | .url
          ' | head -1)
        fi
        if [[ -n "${url:-}" ]]; then
          echo "$url"
          return 0
        fi
    done
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

# ------------------------ Spezial-Downloads ------------------------

download_coreprotect_release_fallback() {
    local out_path="$1"
    local release_url

    release_url="$(github_latest_jar_url "PlayPro/CoreProtect" || true)"
    if [[ -n "${release_url:-}" && "$release_url" != "null" ]]; then
        log "CoreProtect: Lade offizielle Release-JAR (GitHub API)..."
        if download_file "$release_url" "$out_path"; then
            log "ERFOLG: CoreProtect (Release-Fallback via GitHub)."
            return 0
        fi
        log "FEHLER: CoreProtect-Release via GitHub API konnte nicht geladen werden."
    fi

    local direct_url="https://github.com/PlayPro/CoreProtect/releases/latest/download/CoreProtect.jar"
    log "CoreProtect: Versuche direkten Release-Download..."
    if download_file "$direct_url" "$out_path"; then
        log "ERFOLG: CoreProtect (Release-Fallback Direktlink)."
        return 0
    fi

    log "FEHLER: CoreProtect-Release konnte nicht heruntergeladen werden."
    return 1
}

download_griefprevention_latest() {
    local out_path="$1"

    local murl
    murl="$(modrinth_latest_jar_url "griefprevention" || true)"
    if [[ -n "${murl:-}" && "$murl" != "null" ]]; then
        log "GriefPrevention: Lade aktuelle Version von Modrinth..."
        if download_file "$murl" "$out_path"; then
            log "ERFOLG: GriefPrevention (Modrinth)."
            return 0
        fi
        log "FEHLER: GriefPrevention konnte nicht über Modrinth geladen werden."
    fi

    local gh_url
    gh_url="$(github_latest_jar_url "TechFortress/GriefPrevention" || true)"
    if [[ -n "${gh_url:-}" && "$gh_url" != "null" ]]; then
        log "GriefPrevention: Lade aktuelle Version von GitHub Releases..."
        if download_file "$gh_url" "$out_path"; then
            log "ERFOLG: GriefPrevention (GitHub Releases)."
            return 0
        fi
        log "FEHLER: GriefPrevention konnte nicht über GitHub Releases geladen werden."
    fi

    local direct_url="https://github.com/TechFortress/GriefPrevention/releases/latest/download/GriefPrevention.jar"
    log "GriefPrevention: Versuche direkten Release-Download..."
    if download_file "$direct_url" "$out_path"; then
        log "ERFOLG: GriefPrevention (Direkter Release-Download)."
        return 0
    fi

    log "FEHLER: GriefPrevention konnte nicht heruntergeladen werden."
    return 1
}

# Kopiert JARs aus dem temporären Download-Verzeichnis und kann Plugins auslassen,
# deren alte Version bewusst behalten werden soll.
copy_plugin_jars() {
    local src_dir="$1"
    local dst_dir="$2"
    shift 2

    local -a skip_names=("$@")
    local jar base plugin skip_name skip
    shopt -s nullglob
    for jar in "$src_dir"/*.jar; do
        base="$(basename "$jar")"
        plugin="${base%.jar}"
        skip=0
        for skip_name in "${skip_names[@]}"; do
            if [[ "${plugin,,}" == "${skip_name,,}" ]]; then
                skip=1
                break
            fi
        done
        if (( skip )); then
            log "Behalte alte Version von ${plugin}; neue/fallback JAR wird nicht übernommen."
            continue
        fi
        cp -v "$jar" "$dst_dir/" | tee -a "$LOG_FILE"
    done
    shopt -u nullglob
}

parse_build_directive() {
    local plugin_name="$1"
    local directive="$2"
    local default_repo=""
    local spec repo branch="master"

    if [[ "${plugin_name,,}" == "coreprotect" ]]; then
        default_repo="PlayPro/CoreProtect"
    fi

    if [[ "$directive" == "build" ]]; then
        [[ -n "$default_repo" ]] || return 1
        BUILD_REPO="$default_repo"
        BUILD_BRANCH="$branch"
        return 0
    fi

    [[ "$directive" == build:* ]] || return 1
    spec="${directive#build:}"

    if [[ "$spec" == http://* || "$spec" == https://* ]]; then
        if repo="$(normalize_github_owner_repo "$spec")"; then
            branch="${spec##*:}"
            if [[ "$branch" == "$spec" || "$branch" == http* || "$branch" == */* ]]; then
                branch="master"
            fi
            BUILD_REPO="$repo"
            BUILD_BRANCH="$branch"
            return 0
        fi
        return 1
    fi

    if [[ "$spec" == */* ]]; then
        repo="$spec"
        if [[ "$repo" == *:* ]]; then
            branch="${repo##*:}"
            repo="${repo%:*}"
        fi
        BUILD_REPO="$repo"
        BUILD_BRANCH="${branch:-master}"
        return 0
    fi

    [[ -n "$default_repo" ]] || return 1
    BUILD_REPO="$default_repo"
    BUILD_BRANCH="$spec"
    return 0
}

# ------------------------ Source Build (Maven) ------------------------

patch_coreprotect_source() {
    local plugin_yml="$1"
    local srcdir="$2"

    if grep -q 'branch:[[:space:]]*\${project\.branch}' "$plugin_yml"; then
        sed -i 's/branch:[[:space:]]*\${project\.branch}/branch: developement/' "$plugin_yml"
        log "CoreProtect: plugin.yml angepasst (branch -> developement)."
    else
        if grep -q '^branch:' "$plugin_yml"; then
            sed -i 's/^branch:[[:space:]].*/branch: developement/' "$plugin_yml"
        else
            sed -i '1i branch: developement' "$plugin_yml"
        fi
        log "CoreProtect: plugin.yml (Fallback) – branch: developement gesetzt."
    fi

    local pom_file="$srcdir/pom.xml"
    if [[ -f "$pom_file" ]]; then
        sed -i -E \
            -e 's#<maven\.compiler\.source>[^<]+</maven\.compiler\.source>#<maven.compiler.source>25</maven.compiler.source>#' \
            -e 's#<maven\.compiler\.target>[^<]+</maven\.compiler\.target>#<maven.compiler.target>25</maven.compiler.target>#' \
            -e 's#<source>[0-9]+</source>#<source>25</source>#' \
            -e 's#<target>[0-9]+</target>#<target>25</target>#' \
            "$pom_file"
        log "CoreProtect: Maven Compiler-Level auf Java 25 gesetzt."
    fi
}

find_built_jar() {
    local srcdir="$1"
    local plugin_name="$2"
    local jar

    jar="$(find "$srcdir/target" -maxdepth 1 -type f -name "${plugin_name}-*.jar" ! -name '*sources.jar' ! -name '*javadoc.jar' | head -1)"
    if [[ -z "${jar:-}" ]]; then
        jar="$(find "$srcdir/target" -maxdepth 1 -type f -name '*.jar' ! -name '*sources.jar' ! -name '*javadoc.jar' | head -1)"
    fi
    [[ -n "${jar:-}" ]] && printf '%s\n' "$jar"
}

# build_plugin_from_source <plugin_name> <owner/repo> <branch> <out_jar_path>
build_plugin_from_source() {
    local plugin_name="$1"
    local owner_repo="$2"
    local branch="${3:-master}"
    local out_path="$4"
    COREPROTECT_USED_RELEASE_FALLBACK=0

    local workdir zip srcdir plugin_yml built
    workdir="$(mktemp -d)"
    zip="${workdir}/src.zip"

    log "${plugin_name}: Lade Source (${owner_repo}, Branch: ${branch})..."
    if ! curl -fL -A "Mozilla/5.0" -o "$zip" "https://github.com/${owner_repo}/archive/refs/heads/${branch}.zip"; then
        log "FEHLER: Konnte Source-Archiv für ${owner_repo}:${branch} nicht laden."
        rm -rf "$workdir"
        return 1
    fi

    unzip -q "$zip" -d "$workdir" || { log "FEHLER: Entpacken fehlgeschlagen."; rm -rf "$workdir"; return 1; }

    plugin_yml="$(find "$workdir" -type f -path "*/src/main/resources/plugin.yml" | head -1)"
    if [[ -n "${plugin_yml:-}" ]]; then
        srcdir="$(dirname "$(dirname "$plugin_yml")")"  # .../src/main
        srcdir="$(dirname "$srcdir")"                  # .../src
        srcdir="$(dirname "$srcdir")"                  # Projektwurzel
    else
        srcdir="$(find "$workdir" -type f -name pom.xml -exec dirname {} \; | head -1)"
    fi

    if [[ -z "${srcdir:-}" || ! -f "$srcdir/pom.xml" ]]; then
        log "FEHLER: Maven-Projektwurzel nicht gefunden."
        rm -rf "$workdir"
        return 1
    fi

    if [[ "${plugin_name,,}" == "coreprotect" ]]; then
        if [[ -z "${plugin_yml:-}" ]]; then
            log "FEHLER: CoreProtect plugin.yml nicht gefunden."
            rm -rf "$workdir"
            return 1
        fi
        patch_coreprotect_source "$plugin_yml" "$srcdir"
    fi

    log "${plugin_name}: Baue Plugin (Maven, Tests übersprungen)..."
    local build_log="$workdir/coreprotect_maven.log"
    local build_ok=0
    local maven_opts_append="-Djava.net.preferIPv4Stack=true -Djava.net.preferIPv4Addresses=true"
    local -a coreprotect_maven_args=(-B -q -DskipTests -Dmaven.compiler.source=25 -Dmaven.compiler.target=25 package)
    local coreprotect_maven_image="${COREPROTECT_MAVEN_IMAGE:-maven:3.9-eclipse-temurin-25}"

    if command -v mvn >/dev/null 2>&1; then
        if ( cd "$srcdir" && MAVEN_OPTS="${MAVEN_OPTS:-} ${maven_opts_append}" mvn "${coreprotect_maven_args[@]}" ) &>"$build_log"; then
            build_ok=1
        else
            log "${plugin_name}: Lokaler Maven-Build fehlgeschlagen."
        fi
    fi

    if (( build_ok == 0 )); then
        if command -v docker >/dev/null 2>&1; then
            log "${plugin_name}: Versuche Maven-Build per Docker-Fallback..."
            if docker run --rm -v "$srcdir":/src -w /src \
                -e MAVEN_OPTS="${MAVEN_OPTS:-} ${maven_opts_append}" \
                "$coreprotect_maven_image" mvn "${coreprotect_maven_args[@]}" &>"$build_log"; then
                build_ok=1
            else
                log "${plugin_name}: Docker-Maven-Build fehlgeschlagen."
            fi
        else
            log "${plugin_name}: Docker nicht verfügbar, kann Maven-Fallback nicht nutzen."
        fi
    fi

    if (( build_ok == 0 )); then
        if [[ -s "$build_log" ]]; then
            log "--- Maven-Fehlerausgabe (letzte 20 Zeilen) ---"
            tail -n 20 "$build_log" | while IFS= read -r line; do log "$line"; done
            log "--- Ende Maven-Fehlerausgabe ---"
        fi
        if [[ "${plugin_name,,}" == "coreprotect" ]]; then
            log "CoreProtect: Build fehlgeschlagen – versuche Fallback auf offizielle Releases."
        elif [[ "${owner_repo,,}" == *"coreprotect" ]]; then
            log "${plugin_name}: Build fehlgeschlagen – versuche GitHub-Release-Fallback."
        fi
        if [[ "${plugin_name,,}" == "coreprotect" || "${owner_repo,,}" == *"coreprotect" ]] && download_coreprotect_release_fallback "$out_path"; then
            COREPROTECT_USED_RELEASE_FALLBACK=1
            rm -rf "$workdir"
            return 0
        fi
        rm -rf "$workdir"
        return 1
    fi

    rm -f "$build_log"

    built="$(find_built_jar "$srcdir" "$plugin_name")"
    if [[ -z "${built:-}" ]]; then
        log "FEHLER: ${plugin_name}-JAR nicht gefunden."
        rm -rf "$workdir"
        return 1
    fi

    cp -f "$built" "$out_path"
    log "ERFOLG: ${plugin_name} gebaut -> $(basename "$out_path")"
    rm -rf "$workdir"
    return 0
}

# ------------------------ Plugin-Update (mit Fehler-Menü) ------------------------

update_plugins() {
    log "Aktualisiere Plugins..."
    mkdir -p "$PLUGIN_DIR"

    ensure_plugin_config

    local temp_dir="${PLUGIN_DIR}_temp"
    rm -rf "$temp_dir" && mkdir -p "$temp_dir"

    local -a ok_list=()
    local -a fail_list=()
    local -a fallback_list=()

    while IFS= read -r line || [[ -n "${line:-}" ]]; do
        [[ "$line" =~ ^#.*$ || -z "${line// }" ]] && continue

        local plugin_name plugin_url target build_branch build_repo owner_repo asset_url
        plugin_name=$(echo "$line" | awk '{$NF=""; sub(/[ \t]+$/, ""); print}')
        plugin_url=$(echo "$line" | awk '{print $NF}')
        [[ -z "${plugin_name:-}" || -z "${plugin_url:-}" ]] && continue

        log "Verarbeite: $plugin_name (${plugin_url})"
        target="${temp_dir}/${plugin_name}.jar"

        # Source-Build per Maven
        if parse_build_directive "$plugin_name" "$plugin_url"; then
            build_repo="$BUILD_REPO"
            build_branch="$BUILD_BRANCH"
            COREPROTECT_USED_RELEASE_FALLBACK=0
            if build_plugin_from_source "$plugin_name" "$build_repo" "$build_branch" "$target"; then
                ok_list+=("$plugin_name")
                if (( ${COREPROTECT_USED_RELEASE_FALLBACK:-0} )); then
                    fallback_list+=("$plugin_name")
                fi
            else
                fail_list+=("$plugin_name")
            fi
            continue
        fi

        # --- Modrinth: Schema "modrinth:<slug>" oder "modrinth:<slug>@beta/alpha" ---
        if [[ "$plugin_url" == modrinth:* ]]; then
            local spec="${plugin_url#modrinth:}"
            local slug="${spec%@*}"
            local channels="${spec#*@}"
            [[ "$channels" == "$slug" ]] && channels=""  # kein @ vorhanden
            local murl
            murl="$(modrinth_latest_jar_url "$slug" "${channels}")" || murl=""
            if [[ -n "$murl" ]]; then
                if download_file "$murl" "$target"; then
                    log "ERFOLG: $plugin_name (Modrinth${channels:+ @${channels}})"
                    ok_list+=("$plugin_name")
                else
                    log "FEHLER: Modrinth-Download fehlgeschlagen für $plugin_name"
                    fail_list+=("$plugin_name")
                fi
            else
                log "FEHLER: Keine Modrinth-Version gefunden für $plugin_name ($slug)"
                fail_list+=("$plugin_name")
            fi
            continue
        fi

        # --- Modrinth: Seiten-URL (einfacher) ---
        if [[ "$plugin_url" == *"modrinth.com/plugin/"* || "$plugin_url" == *"modrinth.com/project/"* ]]; then
            local slug
            if slug="$(extract_modrinth_slug "$plugin_url")"; then
                local murl
                murl="$(modrinth_latest_jar_url "$slug")" || murl=""
                if [[ -n "$murl" ]]; then
                    if download_file "$murl" "$target"; then
                        log "ERFOLG: $plugin_name (Modrinth Seite: $slug)"
                        ok_list+=("$plugin_name")
                    else
                        log "FEHLER: Modrinth-Download fehlgeschlagen für $plugin_name (Seite)"
                        fail_list+=("$plugin_name")
                    fi
                else
                    log "FEHLER: Keine passende Modrinth-Version für $plugin_name (Seite: $slug)"
                    fail_list+=("$plugin_name")
                fi
                continue
            fi
        fi

        # --- Spigot-Seite erkannt → über Spiget laden (immer "latest") ---
        if [[ "$plugin_url" == *"spigotmc.org/resources/"* ]]; then
            local rid
            if rid="$(extract_spigot_resource_id "$plugin_url")"; then
                local surl
                surl="$(spiget_latest_download_url "$rid")"
                if download_file "$surl" "$target"; then
                    log "ERFOLG: $plugin_name (Spigot via Spiget, ID $rid)"
                    ok_list+=("$plugin_name")
                else
                    log "FEHLER: Spiget-Download fehlgeschlagen für $plugin_name (ID $rid)"
                    fail_list+=("$plugin_name")
                fi
                continue
            else
                log "WARNUNG: Konnte Resource-ID aus Spigot-URL nicht erkennen: $plugin_url"
                # fällt durch auf die generische Logik
            fi
        fi

        # GitHub Repo?
        if [[ "$plugin_url" == *"github.com"* ]]; then
            if owner_repo="$(normalize_github_owner_repo "$plugin_url")"; then
                log "GitHub erkannt: owner_repo='${owner_repo}'"
                asset_url="$(github_latest_jar_url "$owner_repo" || true)"
                if [[ -n "${asset_url:-}" ]]; then
                    if download_file "$asset_url" "$target"; then
                        log "ERFOLG: $plugin_name (GitHub API)"
                        ok_list+=("$plugin_name")
                    else
                        log "FEHLER: Download via GitHub API fehlgeschlagen für $plugin_name"
                        fail_list+=("$plugin_name")
                    fi
                else
                    log "FEHLER: Keine .jar in neuester Release gefunden für $plugin_name (${owner_repo})"
                    fail_list+=("$plugin_name")
                fi
            else
                log "WARNUNG: owner/repo nicht ermittelbar, versuche direkten Download."
                if download_file "$plugin_url" "$target"; then
                    log "ERFOLG: $plugin_name (direkter GitHub-Link)"
                    ok_list+=("$plugin_name")
                else
                    log "FEHLER: Direkter GitHub-Download fehlgeschlagen für $plugin_name"
                    fail_list+=("$plugin_name")
                fi
            fi

        else
            if [[ "$plugin_url" == *"dev.bukkit.org"* ]]; then
                local fallback_slug fallback_url
                if fallback_slug="$(bukkit_modrinth_slug_fallback "$plugin_name")"; then
                    log "${plugin_name}: DevBukkit blockiert Direktdownloads häufig (403) – versuche Modrinth-Fallback (${fallback_slug})."
                    fallback_url="$(modrinth_latest_jar_url "$fallback_slug")" || fallback_url=""
                    if [[ -n "$fallback_url" ]] && download_file "$fallback_url" "$target"; then
                        log "ERFOLG: $plugin_name (DevBukkit -> Modrinth-Fallback)"
                        ok_list+=("$plugin_name")
                    else
                        log "FEHLER: Modrinth-Fallback fehlgeschlagen für $plugin_name (${fallback_slug})"
                        fail_list+=("$plugin_name")
                    fi
                    continue
                fi
            fi

            if [[ "${plugin_name,,}" == "griefprevention" && "$plugin_url" == *"dev.bukkit.org"* ]]; then
                if download_griefprevention_latest "$target"; then
                    log "GriefPrevention: Fallback-Download erfolgreich."
                    ok_list+=("$plugin_name")
                else
                    log "FEHLER: GriefPrevention konnte auch per Fallback nicht geladen werden."
                    fail_list+=("$plugin_name")
                fi
                continue
            fi

            # Fremdseite (z. B. Geyser/Floodgate) oder direkte Datei
            if download_file "$plugin_url" "$target"; then
                log "ERFOLG: $plugin_name (Direktlink)"
                ok_list+=("$plugin_name")
            else
                log "FEHLER: Download fehlgeschlagen für $plugin_name"
                fail_list+=("$plugin_name")
            fi
        fi
    done < "$PLUGIN_CONFIG"

    # Manuelle Plugins einbeziehen
    if [[ -d "${PLUGIN_DIR}/manuell" ]]; then
        log "Kopiere manuelle Plugins..."
        find "${PLUGIN_DIR}/manuell" -maxdepth 1 -type f -name "*.jar" -exec cp -v -n {} "$temp_dir/" \; | tee -a "$LOG_FILE"
    fi

    # Auswertung & Auswahl bei Fehlern oder Fallbacks
    if (( ${#fail_list[@]} > 0 || ${#fallback_list[@]} > 0 )); then
        echo "---------------------------------------------"
        if (( ${#fail_list[@]} > 0 )); then
            echo "Folgende Plugins konnten NICHT geladen/gebaut werden:"
            for p in "${fail_list[@]}"; do echo "  - $p"; done
        fi
        if (( ${#fallback_list[@]} > 0 )); then
            echo "Folgende Plugins wurden nur per Fallback geladen:"
            for p in "${fallback_list[@]}"; do echo "  - $p"; done
        fi
        echo "---------------------------------------------"
        local choice temp_file
        while true; do
            temp_file="$(mktemp)"
            if ! select_with_history \
                "Wählen Sie, wie fortgefahren werden soll (Enter übernimmt die zuletzt genutzte Option)." \
                "PLUGIN_FAILURE_ACTION" \
                "Abbrechen (keine Änderungen an Plugins)" \
                "Weiter: neue/fallback Plugins übernehmen; fehlgeschlagene weglassen" \
                "Weiter: alte Versionen für fehlgeschlagene/Fallback-Plugins behalten; nur saubere Downloads übernehmen" \
                >"$temp_file"; then
                choice=1
            else
                choice="$(<"$temp_file")"
            fi
            rm -f "$temp_file"

            if [[ "$choice" == 0 ]]; then
                echo "Benutzerdefinierte Eingaben werden in diesem Menü nicht unterstützt (${SELECT_WITH_HISTORY_RESULT:-})." >&2
                save_history "PLUGIN_FAILURE_ACTION" "INDEX:1"
                continue
            fi
            break
        done

        case "$choice" in
            2)
                log "Entferne alte Plugins und setze erfolgreich geladene inklusive Fallbacks..."
                find "$PLUGIN_DIR" -maxdepth 1 -name "*.jar" -delete
                copy_plugin_jars "$temp_dir" "$PLUGIN_DIR"
                log "Plugin-Update abgeschlossen (fehlgeschlagene ausgelassen, Fallbacks übernommen)."
                ;;
            3)
                log "Behalte alte Versionen für fehlgeschlagene/Fallback-Plugins und kopiere nur saubere Downloads drüber..."
                copy_plugin_jars "$temp_dir" "$PLUGIN_DIR" "${fail_list[@]}" "${fallback_list[@]}"
                log "Plugin-Update abgeschlossen (alte Versionen für problematische Plugins behalten)."
                ;;
            *)
                log "Abgebrochen: Es wurden KEINE Änderungen an den Plugins vorgenommen."
                rm -rf "$temp_dir"
                return 2
                ;;
        esac
    else
        log "Alle Plugins erfolgreich geladen/gebaut. Ersetze alte Plugins..."
        find "$PLUGIN_DIR" -maxdepth 1 -name "*.jar" -delete
        copy_plugin_jars "$temp_dir" "$PLUGIN_DIR"
        log "Plugin-Update komplett."
    fi

    rm -rf "$temp_dir"
    return 0
}

# ------------------------ Backup/Restore & Docker Run ------------------------

restore_backup() {
    log "Verfügbare Backups:"
    mapfile -t backups < <(find "$BACKUP_DIR" -type f -name "*.tar.gz" | sort -r)
    for i in "${!backups[@]}"; do
        local bname bdate
        bname=$(basename "${backups[$i]}")
        bdate=$(echo "$bname" | grep -o '[0-9]\{12\}')
        local ts
        ts=$(date -d "${bdate:0:4}-${bdate:4:2}-${bdate:6:2} ${bdate:8:2}:${bdate:10:2}" +%s 2>/dev/null || echo 0)
        local age_days=$(( ( $(date +%s) - ts ) / 86400 ))
        echo "$((i+1)). $bname (${age_days} Tage alt)"
    done
    echo "0. Abbrechen"
    read -r -p "Backup Nummer auswählen: " choice
    (( choice == 0 )) && log "Wiederherstellung abgebrochen." && return
    local index=$((choice - 1))
    [[ -z "${backups[$index]:-}" ]] && log "Ungültige Auswahl." && return
    local backup_file="${backups[$index]}"

    log "Prüfe Backup-Datei (${backup_file})..."
    local total_entries
    if ! total_entries=$(tar -tzf "$backup_file" | wc -l); then
        log "Fehler: Backup-Datei konnte nicht gelesen werden." >&2
        return 1
    fi

    log "Backup-Analyse: ${total_entries} enthaltene Einträge."

    stop_server
    log "Stelle Backup wieder her: ${backup_file}"

    rm -rf "$DATA_DIR/world"* "$PLUGIN_DIR"/*

    local restore_tmpdir fifo count_file
    restore_tmpdir="$(mktemp -d)"
    fifo="${restore_tmpdir}/restore_fifo"
    count_file="${restore_tmpdir}/count"
    mkfifo "$fifo"
    : > "$count_file"

    local start_time
    start_time=$(date +%s)

    (
        local count=0
        while IFS= read -r _; do
            ((++count))
            printf '%s\n' "$count" > "$count_file"
        done < "$fifo"
    ) &
    local counter_pid=$!

    (
        if tar -xzvf "$backup_file" -C "$DATA_DIR" > "$fifo" 2> >(while IFS= read -r err; do log "tar: $err"; done); then
            exit 0
        else
            exit 1
        fi
    ) &
    local tar_pid=$!

    while kill -0 "$tar_pid" 2>/dev/null; do
        sleep 5
        local now elapsed current_count=0 percent="-" eta_msg="unbekannt"
        now=$(date +%s)
        elapsed=$(( now - start_time ))
        if [[ -s "$count_file" ]]; then
            current_count=$(tail -n 1 "$count_file" 2>/dev/null || echo 0)
        fi
        if (( total_entries > 0 && current_count > 0 )); then
            percent=$(( current_count * 100 / total_entries ))
            local remaining eta_secs
            remaining=$(( total_entries - current_count ))
            eta_secs=$(( elapsed * remaining / current_count ))
            local eta_formatted
            eta_formatted=$(date -u -d "@${eta_secs}" '+%H:%M:%S' 2>/dev/null || echo "??:??:??")
            eta_msg="~${eta_formatted}"
        fi
        log "Entpacke Backup... Fortschritt: ${percent}% (${current_count}/${total_entries}), verstrichene Zeit=${elapsed}s, geschätzte Restzeit=${eta_msg}"
    done

    local tar_status=0
    if wait "$tar_pid"; then
        tar_status=0
    else
        tar_status=$?
    fi

    wait "$counter_pid" 2>/dev/null || true
    rm -rf "$restore_tmpdir"

    if (( tar_status != 0 )); then
        log "Fehler beim Entpacken des Backups." >&2
        return 1
    fi

    log "Wiederherstellung abgeschlossen."
}

update_docker() {
    stop_server || true
    log "Entferne alten Docker-Container..."
    docker rm "$SERVER_NAME" >/dev/null 2>&1 || true

    log "Starte neuen Docker-Container..."
    local docker_args=(
        -d
        -p "${HOST_PORT}:25565"
    )

    if (( ${#EXTRA_PORT_MAPPINGS[@]} > 0 )); then
        local mapping
        for mapping in "${EXTRA_PORT_MAPPINGS[@]}"; do
            docker_args+=(-p "$mapping")
        done
    fi

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

    if ! docker run "${docker_args[@]}" "$DOCKER_IMAGE"; then
        log "Fehler: Neuer Docker-Container konnte nicht gestartet werden." >&2
        return 1
    fi
    log "Neuer Docker-Container gestartet."
}

# ------------------------ History-Management ------------------------

manage_history() {
    echo "=== History Management ==="
    echo "1. History anzeigen"
    echo "2. History löschen"
    echo "3. Zurück zum Hauptmenü"
    read -r -p "Wählen Sie eine Option: " choice
    case "$choice" in
        1)
            if [[ -f "$HISTORY_FILE" ]]; then
                echo "Gespeicherte Einstellungen:"
                cat "$HISTORY_FILE"
            else
                echo "Keine History vorhanden."
            fi
            ;;
        2)
            if [[ -f "$HISTORY_FILE" ]]; then
                rm "$HISTORY_FILE"
                echo "History gelöscht."
            else
                echo "Keine History vorhanden."
            fi
            ;;
        3) return ;;
        *) echo "Ungültige Auswahl." ;;
    esac
    read -r -p "Drücken Sie Enter um fortzufahren..." _
    return 0
}

# ------------------------ Main ------------------------

main() {
    shopt -s nocasematch
    if [[ "${1:-}" == "--history" ]]; then manage_history; exit 0; fi

    init_environment
    log "Starte Update-Prozess..."
    check_dependencies

    DO_INIT=$(read_yesno_with_history "Soll ein neuer Server initialisiert werden?" "DO_INIT")
    if [[ "$DO_INIT" == "ja" ]]; then
        echo "ACHTUNG: Dies wird ALLE Daten löschen..." >&2
        read -r -p "Möchten Sie wirklich fortfahren? (ja/nein): " CONFIRM_INIT
        if [[ "${CONFIRM_INIT,,}" =~ ^(ja|j|yes|y)$ ]]; then
            log "Erstelle vor der Initialisierung ein Backup..."
            create_backup || { log "Backup fehlgeschlagen. Abbruch."; exit 1; }
            initialize_new_server
            if [[ "$(read_yesno_with_history "Soll die Pluginliste geändert werden?" "EDIT_PLUGIN_CONFIG")" == "ja" ]]; then
                manage_plugin_config
            fi
        else
            log "Initialisierung abgebrochen."
            exit 0
        fi
    fi

    MEMORY=$(read_with_history "Wieviel RAM (z. B. 6G, 8G)?" "6G" "MEMORY")
    select_server_type

    select_version_for_type "$TYPE" "VERSION" "Welche Minecraft-Version (z. B. LATEST, 1.21.1)?"

    PAPER_CHANNEL_DEFAULT="default"
    if [[ "${TYPE^^}" == "PAPER" ]]; then
        local channel_prompt_needed="ja"
        local auto_channel=""

        if [[ "${VERSION_SELECTION_SOURCE:-manual}" == "menu" && -n "${VERSION_CHANNEL_HINT:-}" ]]; then
            local -a _channel_parts=()
            IFS=',' read -ra _channel_parts <<<"$VERSION_CHANNEL_HINT"
            local -a cleaned_channels=()
            for part in "${_channel_parts[@]}"; do
                local trimmed="$part"
                trimmed="${trimmed#"${trimmed%%[![:space:]]*}"}"
                trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
                if [[ -n "$trimmed" ]]; then
                    cleaned_channels+=("$trimmed")
                fi
            done
            if (( ${#cleaned_channels[@]} == 1 )); then
                auto_channel="${cleaned_channels[0]}"
                channel_prompt_needed="nein"
            fi
        fi

        if [[ "$channel_prompt_needed" == "nein" ]]; then
            PAPER_CHANNEL="$auto_channel"
            save_history "PAPER_CHANNEL" "$PAPER_CHANNEL"
            log "Paper-Channel automatisch auf '${PAPER_CHANNEL}' gesetzt (basierend auf der Versionsauswahl)."
        else
            PAPER_CHANNEL=$(read_with_history "Welcher Paper-Channel (default oder experimental)?" "${PAPER_CHANNEL_DEFAULT}" "PAPER_CHANNEL")
        fi
    else
        PAPER_CHANNEL="$PAPER_CHANNEL_DEFAULT"
    fi

    prompt_host_port
    prompt_additional_ports

    DO_BACKUP=$(read_yesno_with_history "Soll ein Backup erstellt werden?" "DO_BACKUP")
    DO_RESTORE=$(read_yesno_with_history "Soll ein Backup wiederhergestellt werden?" "DO_RESTORE")

    if [[ "$DO_INIT" == "ja" ]]; then
        DO_UPDATE_PLUGINS=$(read_yesno_with_history "Sollen die Plugins für den neuen Server geladen werden?" "DO_UPDATE_PLUGINS")
        DO_DELETE_PLUGINS="nein"
    else
        DO_UPDATE_PLUGINS=$(read_yesno_with_history "Sollen die Plugins aktualisiert werden?" "DO_UPDATE_PLUGINS")
        if [[ "$DO_UPDATE_PLUGINS" == "ja" && "$(read_yesno_with_history "Soll die Pluginliste vor dem Update geändert werden?" "EDIT_PLUGIN_CONFIG")" == "ja" ]]; then
            manage_plugin_config
        fi
        DO_DELETE_PLUGINS=$(read_yesno_with_history "Sollen die aktuellen Plugins gelöscht und gesichert werden?" "DO_DELETE_PLUGINS")
    fi

    DO_START_DOCKER=$(read_yesno_with_history "Soll der Docker-Container gestartet werden?" "DO_START_DOCKER")

    [[ "$DO_BACKUP" == "ja" ]] && create_backup
    [[ "$DO_RESTORE" == "ja" ]] && restore_backup

    if [[ "$DO_UPDATE_PLUGINS" == "ja" ]]; then
        update_plugins
    else
        [[ "$DO_DELETE_PLUGINS" == "ja" ]] && delete_and_backup_plugins
    fi

    if [[ "$DO_START_DOCKER" == "ja" ]]; then
        update_docker
    else
        # Container einmal neu erzeugen (run) und gleich wieder stoppen – bleibt konsistent
        update_docker
        log "Stoppe den Docker-Container sofort wieder..."
        docker stop "$SERVER_NAME" >/dev/null 2>&1 || true
    fi

    log "Update-Prozess abgeschlossen."
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    echo "Minecraft Server Management Script"
    echo "Verwendung: $0 [Option]"
    echo ""
    echo "Optionen:"
    echo "  --history    History-Management öffnen"
    echo "  --help, -h   Diese Hilfe anzeigen"
    echo ""
    echo "Das Script speichert Ihre letzten Eingaben automatisch und"
    echo "schlägt sie beim nächsten Start vor."
    exit 0
fi

main "$@"
