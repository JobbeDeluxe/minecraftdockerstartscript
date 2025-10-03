#!/bin/bash
set -euo pipefail

# === Minecraft Docker Update-, Backup- und Restore-Skript ===

# === Konfigurationsdatei für History ===
HISTORY_FILE="${HOME}/.minecraft_script_history"

# ------------------------ History-Helpers ------------------------

save_history() {
    local key="$1"
    local value="$2"
    touch "$HISTORY_FILE"
    grep -v "^${key}=" "$HISTORY_FILE" > "${HISTORY_FILE}.tmp" 2>/dev/null || true
    echo "${key}=${value}" >> "${HISTORY_FILE}.tmp"
    mv "${HISTORY_FILE}.tmp" "$HISTORY_FILE"
}

load_history() {
    local key="$1"
    if [[ -f "$HISTORY_FILE" ]]; then
        grep "^${key}=" "$HISTORY_FILE" | cut -d'=' -f2- | tail -1
    fi
}

read_with_history() {
    local prompt="$1"
    local default="$2"
    local history_key="$3"
    local user_input last_value
    last_value=$(load_history "$history_key" || true)

    if [[ -n "${last_value:-}" && "$last_value" != "$default" ]]; then
        printf "%s [Letzte Eingabe: %s] (Standard: %s): " "$prompt" "$last_value" "$default" >&2
        read -r user_input || true
        [[ -z "${user_input:-}" ]] && user_input="$last_value"
    else
        printf "%s (Standard: %s): " "$prompt" "$default" >&2
        read -r user_input || true
    fi

    [[ -z "${user_input:-}" ]] && user_input="$default"
    if [[ "$user_input" != "$default" ]]; then
        save_history "$history_key" "$user_input"
    fi
    echo "$user_input"
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

# === Pfad abfragen (vor Log-Init) ===
echo "=== Minecraft Server Management Script ===" >&2
DATA_DIR=$(read_with_history "Pfad zum Minecraft-Datenverzeichnis" "/opt/minecraft_server" "DATA_DIR")

# === Initialisierung nach DATA_DIR ===
SERVER_NAME="mc"
BACKUP_DIR="${DATA_DIR}/backups"
PLUGIN_DIR="${DATA_DIR}/plugins"
PLUGIN_CONFIG="${DATA_DIR}/plugins.txt"
DOCKER_IMAGE="itzg/minecraft-server"
LOG_FILE="${DATA_DIR}/update_log.txt"

mkdir -p "$DATA_DIR"

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
    local deps=("docker" "jq" "curl" "wget" "unzip" "sed" "awk")
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
    local api_url="https://api.github.com/repos/${owner_repo}/releases/latest"

    local auth_args=()
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        auth_args=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
    fi

    local resp
    if ! resp=$(curl -sfL -H "Accept: application/vnd.github+json" "${auth_args[@]}" "$api_url"); then
        return 1
    fi

    local url
    url=$(echo "$resp" | jq -r '.assets[]? | select(.name|test("(?i)(spigot|paper).+\\.jar$")) | .browser_download_url' | head -1)
    if [[ -z "${url:-}" || "$url" == "null" ]]; then
        url=$(echo "$resp" | jq -r '.assets[]? | select(.name|test("\\.jar$")) | .browser_download_url' | head -1)
    fi

    [[ -n "${url:-}" && "$url" != "null" ]] && echo "$url"
}

# Allzweck-Download
download_file() {
    local url="$1"
    local out="$2"
    curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 -A "Mozilla/5.0" -o "$out" "$url"
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
  if [[ "$url" =~ ^modrinth\.com/(plugin|project)/([A-Za-z0-9._-]+) ]]; then
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
    resp="$(curl -sfL "https://api.modrinth.com/v2/project/${slug}/version")" || return 1

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

# ------------------------ CoreProtect Build (master + plugin.yml Patch) ------------------------

# build_coreprotect_from_source <branch> <out_jar_path>
build_coreprotect_from_source() {
    local branch="${1:-master}"
    local out_path="$2"

    local workdir zip srcdir plugin_yml built
    workdir="$(mktemp -d)"
    zip="${workdir}/src.zip"

    log "CoreProtect: Lade Source (Branch: ${branch})..."
    if ! curl -fL -A "Mozilla/5.0" -o "$zip" "https://github.com/PlayPro/CoreProtect/archive/refs/heads/${branch}.zip"; then
        log "FEHLER: Konnte Source-Archiv für Branch '${branch}' nicht laden."
        rm -rf "$workdir"
        return 1
    fi

    unzip -q "$zip" -d "$workdir" || { log "FEHLER: Entpacken fehlgeschlagen."; rm -rf "$workdir"; return 1; }

    plugin_yml="$(find "$workdir" -type f -path "*/src/main/resources/plugin.yml" | head -1)"
    if [[ -z "${plugin_yml:-}" ]]; then
        log "FEHLER: plugin.yml nicht gefunden."
        rm -rf "$workdir"
        return 1
    fi

    # Patch: ${project.branch} -> developement
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

    # Projektwurzel bestimmen
    srcdir="$(dirname "$(dirname "$plugin_yml")")"  # .../src/main
    srcdir="$(dirname "$srcdir")"                  # .../src
    srcdir="$(dirname "$srcdir")"                  # Projektwurzel

    log "CoreProtect: Baue Plugin (Maven, Tests übersprungen)..."
    if command -v mvn >/dev/null 2>&1; then
        ( cd "$srcdir" && mvn -q -DskipTests package )
    else
        docker run --rm -v "$srcdir":/src -w /src maven:3.9-eclipse-temurin-21 mvn -q -DskipTests package
    fi

    built="$(find "$srcdir/target" -maxdepth 1 -type f -name 'CoreProtect-*.jar' | head -1)"
    if [[ -z "${built:-}" ]]; then
        log "FEHLER: CoreProtect-JAR nicht gefunden."
        rm -rf "$workdir"
        return 1
    fi

    cp -f "$built" "$out_path"
    log "ERFOLG: CoreProtect gebaut -> $(basename "$out_path")"
    rm -rf "$workdir"
    return 0
}

# parse_build_directive "build" / "build:master" / "build:<branch>"
parse_build_directive() {
    local url="$1"
    local branch="master"
    if [[ "$url" == build ]]; then
        echo "$branch"; return 0
    fi
    if [[ "$url" == build:* ]]; then
        echo "${url#build:}"; return 0
    fi
    return 1
}

# ------------------------ Plugin-Update (mit Fehler-Menü) ------------------------

update_plugins() {
    log "Aktualisiere Plugins..."
    mkdir -p "$PLUGIN_DIR"

    if [[ ! -f "$PLUGIN_CONFIG" ]]; then
        log "plugins.txt nicht gefunden – erstelle Vorlage (alles kommentiert)."
        cat <<'EOL' > "$PLUGIN_CONFIG"
# Format: <Plugin-Name> <Quelle>
# Quellen-Typen:
#   - GitHub-Repo:          https://github.com/<owner>/<repo>
#   - Spigot-Seite:         https://www.spigotmc.org/resources/<slug>.<ID>/
#   - Modrinth:             modrinth:<slug>   ODER   https://modrinth.com/plugin/<slug>
#     (optional: Kanal festlegen: modrinth:<slug>@beta  bzw. @alpha)
#   - Direkter Link (.jar): https://...
#   - CoreProtect Build:    build[:branch]  (z.B. build:master)

# Beispiele:
# CoreProtect build:master
# SimpleVoiceChat https://modrinth.com/plugin/simple-voice-chat
# VoiceChatDiscordBridge modrinth:simple-voice-chat-discord-bridge
# DiscordSRV https://www.spigotmc.org/resources/discordsrv.18494/
# GriefPrevention modrinth:griefprevention
# ViaVersion https://github.com/ViaVersion/ViaVersion
# ViaBackwards https://github.com/ViaVersion/ViaBackwards
# Geyser-Spigot https://download.geysermc.org/v2/projects/geyser/versions/latest/builds/latest/downloads/spigot
# floodgate-spigot https://download.geysermc.org/v2/projects/floodgate/versions/latest/builds/latest/downloads/spigot
EOL
        log "Vorlage erstellt: $PLUGIN_CONFIG"
    fi

    local temp_dir="${PLUGIN_DIR}_temp"
    rm -rf "$temp_dir" && mkdir -p "$temp_dir"

    local -a ok_list=()
    local -a fail_list=()

    while IFS= read -r line || [[ -n "${line:-}" ]]; do
        [[ "$line" =~ ^#.*$ || -z "${line// }" ]] && continue

        local plugin_name plugin_url target build_branch owner_repo asset_url
        plugin_name=$(echo "$line" | awk '{$NF=""; sub(/[ \t]+$/, ""); print}')
        plugin_url=$(echo "$line" | awk '{print $NF}')
        [[ -z "${plugin_name:-}" || -z "${plugin_url:-}" ]] && continue

        log "Verarbeite: $plugin_name (${plugin_url})"
        target="${temp_dir}/${plugin_name}.jar"

        # CoreProtect: aus Source bauen
        if [[ "${plugin_name,,}" == "coreprotect" ]] && build_branch="$(parse_build_directive "$plugin_url")"; then
            if build_coreprotect_from_source "$build_branch" "$target"; then
                ok_list+=("$plugin_name")
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

    # Auswertung & Auswahl bei Fehlern
    if (( ${#fail_list[@]} > 0 )); then
        echo "---------------------------------------------"
        echo "Folgende Plugins konnten NICHT geladen/gebaut werden:"
        for p in "${fail_list[@]}"; do echo "  - $p"; done
        echo "---------------------------------------------"
        echo "Wählen Sie, wie fortgefahren werden soll:"
        echo "  1) Abbrechen (keine Änderungen an Plugins)"
        echo "  2) Weiter: Server OHNE die fehlgeschlagenen Plugins starten (alte Plugins werden ersetzt)"
        echo "  3) Weiter: ALTE Plugins behalten und NUR neue erfolgreiche drüberkopieren"
        read -r -p "Ihre Wahl [1/2/3]: " choice

        case "$choice" in
            2)
                log "Entferne alte Plugins und setze NUR erfolgreich geladene..."
                find "$PLUGIN_DIR" -maxdepth 1 -name "*.jar" -delete
                find "$temp_dir" -maxdepth 1 -type f -name "*.jar" -exec cp -v {} "$PLUGIN_DIR/" \; | tee -a "$LOG_FILE"
                log "Plugin-Update abgeschlossen (ohne fehlgeschlagene)."
                ;;
            3)
                log "Behalte alte Plugins und kopiere NUR erfolgreich geladene drüber..."
                find "$temp_dir" -maxdepth 1 -type f -name "*.jar" -exec cp -v {} "$PLUGIN_DIR/" \; | tee -a "$LOG_FILE"
                log "Plugin-Update abgeschlossen (Overlay)."
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
        if compgen -G "${temp_dir}/*.jar" > /dev/null; then
            cp -v "$temp_dir"/*.jar "$PLUGIN_DIR/" | tee -a "$LOG_FILE"
        fi
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
    stop_server
    log "Stelle Backup wieder her: ${backups[$index]}"
    rm -rf "$DATA_DIR/world"* "$PLUGIN_DIR"/*
    tar -xzf "${backups[$index]}" -C "$DATA_DIR"
    log "Wiederherstellung abgeschlossen."
}

update_docker() {
    stop_server || true
    log "Entferne alten Docker-Container..."
    docker rm "$SERVER_NAME" >/dev/null 2>&1 || true

    log "Starte neuen Docker-Container..."
    local docker_args=(
        -d
        -p 25565:25565
        -p 19132:19132/udp
        -p 24454:24454/udp   # Simple Voice Chat UDP-Port
        -v "${DATA_DIR}:/data"
        --name "$SERVER_NAME"
        -e TZ=Europe/Berlin
        -e EULA=TRUE
        -e MEMORY="$MEMORY"
        -e TYPE="$TYPE"
        --restart always
    )
    [[ -n "${VERSION:-}" ]] && docker_args+=(-e "VERSION=$VERSION")

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
    log "Starte Update-Prozess..."
    check_dependencies

    if [[ "${1:-}" == "--history" ]]; then manage_history; exit 0; fi

    DO_INIT=$(read_yesno_with_history "Soll ein neuer Server initialisiert werden?" "DO_INIT")
    if [[ "$DO_INIT" == "ja" ]]; then
        echo "ACHTUNG: Dies wird ALLE Daten löschen..." >&2
        read -r -p "Möchten Sie wirklich fortfahren? (ja/nein): " CONFIRM_INIT
        if [[ "${CONFIRM_INIT,,}" =~ ^(ja|j|yes|y)$ ]]; then
            log "Erstelle vor der Initialisierung ein Backup..."
            create_backup || { log "Backup fehlgeschlagen. Abbruch."; exit 1; }
            initialize_new_server
        else
            log "Initialisierung abgebrochen."
            exit 0
        fi
    fi

    VERSION=$(read_with_history "Welche Minecraft-Version (z. B. LATEST, 1.21.1)?" "LATEST" "VERSION")
    MEMORY=$(read_with_history "Wieviel RAM (z. B. 6G, 8G)?" "6G" "MEMORY")
    TYPE=$(read_with_history "Welcher Server-Typ (PAPER, SPIGOT, VANILLA, ... )?" "PAPER" "TYPE")

    DO_BACKUP=$(read_yesno_with_history "Soll ein Backup erstellt werden?" "DO_BACKUP")
    DO_RESTORE=$(read_yesno_with_history "Soll ein Backup wiederhergestellt werden?" "DO_RESTORE")

    if [[ "$DO_INIT" == "ja" ]]; then
        DO_UPDATE_PLUGINS="nein"
        DO_DELETE_PLUGINS="nein"
    else
        DO_UPDATE_PLUGINS=$(read_yesno_with_history "Sollen die Plugins aktualisiert werden?" "DO_UPDATE_PLUGINS")
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

