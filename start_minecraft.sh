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

select_with_history() {
    local prompt="$1"
    local history_key="$2"
    shift 2

    local -a options=("$@")
    if ((${#options[@]} == 0)); then
        echo "select_with_history benötigt mindestens eine Option." >&2
        return 1
    fi
    if ((${#options[@]} > 10)); then
        echo "select_with_history unterstützt maximal 10 Optionen (übergeben: ${#options[@]})." >&2
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
        for i in "${!options[@]}"; do
            if [[ "${options[$i]}" == "$raw_last" ]]; then
                default_index=$(( i + 1 ))
                break
            fi
        done
        if [[ -z "$default_index" ]]; then
            default_custom="$raw_last"
        fi
    fi

    if [[ -n "$default_index" ]]; then
        if (( default_index < 1 || default_index > ${#options[@]} )); then
            default_index=""
        fi
    fi

    if [[ -z "$default_index" && -z "$default_custom" ]]; then
        default_index=1
    fi

    local choice="" custom_value=""

    while true; do
        printf "%s\n" "$prompt" >&2
        for i in "${!options[@]}"; do
            local num=$(( i + 1 ))
            local marker=""
            if [[ -n "$default_index" && "$num" -eq "$default_index" ]]; then
                marker=" [Standard]"
            fi
            printf "  %d) %s%s\n" "$num" "${options[$i]}" "$marker" >&2
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
            default_desc="${options[$((default_index - 1))]}"
        else
            default_desc="${options[0]}"
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
        elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
            save_history "$history_key" "INDEX:${choice}"
            SELECT_WITH_HISTORY_RESULT="${options[$((choice - 1))]}"
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
            printf '%s\n' "papermc:https://api.papermc.io/v2/projects/${slug}"
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
        papermc) jq_filter='.versions[]?' ;;
        purpur)  jq_filter='.versions[]?' ;;
        *)       return 1 ;;
    esac

    echo "$resp" | jq -r "$jq_filter" 2>/dev/null | awk 'NF'
}

select_version_for_type() {
    local type="$1"
    local history_key="$2"
    local prompt="$3"

    local versions_raw
    versions_raw=$(fetch_versions_for_type "$type" || true)

    if [[ -z "${versions_raw:-}" ]]; then
        echo "Es konnten keine Versionen für den Typ ${type} ermittelt werden. Bitte manuell eingeben." >&2
        VERSION=$(read_with_history "$prompt" "LATEST" "$history_key")
        return
    fi

    local -a all_versions=()
    while IFS= read -r version; do
        all_versions+=("$version")
    done <<<"$versions_raw"

    if ((${#all_versions[@]} == 0)); then
        VERSION=$(read_with_history "$prompt" "LATEST" "$history_key")
        return
    fi

    mapfile -t all_versions < <(printf '%s\n' "${all_versions[@]}" | sort -rV | uniq)

    local -a menu_versions=("LATEST")
    local limit=9
    local count=0
    for v in "${all_versions[@]}"; do
        menu_versions+=("$v")
        ((count++))
        if ((count >= limit)); then
            break
        fi
    done

    while true; do
        local selection
        selection=$(select_with_history "$prompt" "$history_key" "${menu_versions[@]}") || {
            echo "Version konnte nicht ausgewählt werden." >&2
            exit 1
        }

        local chosen="$SELECT_WITH_HISTORY_RESULT"

        if [[ "$chosen" == "LATEST" ]]; then
            save_history "$history_key" "$chosen"
            VERSION="$chosen"
            return
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
            return
        fi

        echo "Die Auswahl '${chosen}' ist nicht unter den verfügbaren Versionen. Bitte erneut wählen." >&2
    done
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
    local build_log="$workdir/coreprotect_maven.log"
    local build_ok=0
    local maven_opts_append="-Djava.net.preferIPv4Stack=true -Djava.net.preferIPv4Addresses=true"

    if command -v mvn >/dev/null 2>&1; then
        if ( cd "$srcdir" && MAVEN_OPTS="${MAVEN_OPTS:-} ${maven_opts_append}" mvn -B -q -DskipTests package ) &>"$build_log"; then
            build_ok=1
        else
            log "CoreProtect: Lokaler Maven-Build fehlgeschlagen."
        fi
    fi

    if (( build_ok == 0 )); then
        if command -v docker >/dev/null 2>&1; then
            log "CoreProtect: Versuche Maven-Build per Docker-Fallback..."
            if docker run --rm -v "$srcdir":/src -w /src \
                -e MAVEN_OPTS="${MAVEN_OPTS:-} ${maven_opts_append}" \
                maven:3.9-eclipse-temurin-21 mvn -B -q -DskipTests package &>"$build_log"; then
                build_ok=1
            else
                log "CoreProtect: Docker-Maven-Build fehlgeschlagen."
            fi
        else
            log "CoreProtect: Docker nicht verfügbar, kann Maven-Fallback nicht nutzen."
        fi
    fi

    if (( build_ok == 0 )); then
        if [[ -s "$build_log" ]]; then
            log "--- Maven-Fehlerausgabe (letzte 20 Zeilen) ---"
            tail -n 20 "$build_log" | while IFS= read -r line; do log "$line"; done
            log "--- Ende Maven-Fehlerausgabe ---"
        fi
        log "CoreProtect: Build fehlgeschlagen – versuche Fallback auf offizielle Releases."
        if download_coreprotect_release_fallback "$out_path"; then
            rm -rf "$workdir"
            return 0
        fi
        rm -rf "$workdir"
        return 1
    fi

    rm -f "$build_log"

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

    # Auswertung & Auswahl bei Fehlern
    if (( ${#fail_list[@]} > 0 )); then
        echo "---------------------------------------------"
        echo "Folgende Plugins konnten NICHT geladen/gebaut werden:"
        for p in "${fail_list[@]}"; do echo "  - $p"; done
        echo "---------------------------------------------"
        local choice
        while true; do
            choice=$(select_with_history \
                "Wählen Sie, wie fortgefahren werden soll (Enter übernimmt die zuletzt genutzte Option)." \
                "PLUGIN_FAILURE_ACTION" \
                "Abbrechen (keine Änderungen an Plugins)" \
                "Weiter: Server OHNE die fehlgeschlagenen Plugins starten (alte Plugins werden ersetzt)" \
                "Weiter: ALTE Plugins behalten und NUR neue erfolgreiche drüberkopieren") || choice=1

            if [[ "$choice" == 0 ]]; then
                echo "Benutzerdefinierte Eingaben werden in diesem Menü nicht unterstützt (${SELECT_WITH_HISTORY_RESULT:-})." >&2
                save_history "PLUGIN_FAILURE_ACTION" "INDEX:1"
                continue
            fi
            break
        done

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
            ((count++))
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

    MEMORY=$(read_with_history "Wieviel RAM (z. B. 6G, 8G)?" "6G" "MEMORY")
    TYPE=$(read_with_history "Welcher Server-Typ (PAPER, SPIGOT, VANILLA, ... )?" "PAPER" "TYPE")

    select_version_for_type "$TYPE" "VERSION" "Welche Minecraft-Version (z. B. LATEST, 1.21.1)?"

    PAPER_CHANNEL_DEFAULT="default"
    if [[ "${TYPE^^}" == "PAPER" ]]; then
        PAPER_CHANNEL=$(read_with_history "Welcher Paper-Channel (default oder experimental)?" "${PAPER_CHANNEL_DEFAULT}" "PAPER_CHANNEL")
    else
        PAPER_CHANNEL="$PAPER_CHANNEL_DEFAULT"
    fi

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

