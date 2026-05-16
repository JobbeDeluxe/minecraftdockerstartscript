# Minecraft Docker WebUI

Version: `v1.0.2`

GitHub: <https://github.com/JobbeDeluxe/minecraftdockerstartscript>

Host-WebUI fuer Minecraft-Server in Docker. Die WebUI speichert Serverprofile als JSON unter
`~/.minecraftdocker-webui/servers`, schreibt daraus temporaere Shell-Config-Dateien und ruft `webui/backend.sh`
nicht-interaktiv auf.

## Start

```bash
cd /pfad/zum/repository
python3 webui/app.py
```

Danach lokal oeffnen:

```text
http://127.0.0.1:8088
```

Der Server bindet absichtlich nur an `127.0.0.1`. Fuer Tests im LAN kann der Host geaendert werden:

```bash
MCDOCKER_WEBUI_HOST=0.0.0.0 MCDOCKER_WEBUI_PORT=8088 python3 webui/app.py
```

## Was aktuell funktioniert

- Serverprofile anlegen und speichern
- Docker-Container per Profil anwenden, starten, stoppen, neu starten
- Backup-Aktionen ueber den Backend-Runner ausloesen
- RCON pro Server aktivieren, Passwort setzen und Host-/Container-Port getrennt konfigurieren
- Offensichtliche Port-Konflikte zwischen Profilen, laufenden Docker-Containern und TCP-Ports anzeigen
- `plugins.txt` im Web bearbeiten und einfache Plugin-Updates ausloesen
- Containerstatus, einfache Docker-Stats und Logs anzeigen
- Spieleranzahl und einfache Spielerliste per RCON `list` anzeigen
- RCON-Schnellbefehle fuer `tp`, `give`, `kick`, `ban` und `pardon`
- BlueMap ueber die WebUI unter `/map/<server-id>/` proxien und einbetten
- Profile deaktivieren, ohne Profil oder Datenordner zu loeschen
- Mehrere Server ueber unterschiedliche Containernamen, Datenverzeichnisse und Ports verwalten

## Deaktivierte Profile

`Deaktivieren` entfernt nur den Docker-Container und setzt das Profil auf `deaktiviert`.
Profil und Datenordner bleiben erhalten. In der WebUI wird das Profil links ausgegraut und mit
Status `deaktiviert` angezeigt.

Deaktivierte Profile geben ihre Ports fuer andere Profile frei. Die Portpruefung ignoriert nur
wirklich deaktivierte Profile; aktive Profile mit gleichem Host-Port blockieren weiterhin. Sobald
du bei einem deaktivierten Profil `Anwenden`, `Start` oder `Restart` erfolgreich ausfuehrst, wird
das Profil automatisch wieder aktiviert.

## Backend-Modus

Die WebUI nutzt diesen nicht-interaktiven Modus:

```bash
webui/backend.sh --config /tmp/server.env --action apply
webui/backend.sh --config /tmp/server.env --action start
webui/backend.sh --config /tmp/server.env --action stop
webui/backend.sh --config /tmp/server.env --action logs
webui/backend.sh --config /tmp/server.env --action plugins
```

Beispiel fuer eine Config:

```bash
DATA_DIR=/opt/minecraft/survival
SERVER_NAME=mc-survival
MEMORY=6G
TYPE=PAPER
VERSION=LATEST
PAPER_CHANNEL=default
HOST_PORT=25565
EXTRA_PORTS=19132:19132/udp,24454:24454/udp,8100:8100/tcp
MAP_URL=
EULA_ACCEPTED=ja
RCON_ENABLED=ja
RCON_PASSWORD=bitte-aendern
RCON_HOST_PORT=25575
RCON_CONTAINER_PORT=25575
DO_BACKUP=nein
DO_START_DOCKER=ja
```

## Plugins

Die WebUI bearbeitet `DATA_DIR/plugins.txt`. Der Update-Button unterstuetzt im Prototyp:

- `modrinth:<slug>`
- GitHub-Repositories mit `.jar` Asset im neuesten Release
- direkte `http(s)` Download-Links
- CoreProtect-Builds aus `https://github.com/PlayPro/CoreProtect` oder `https://github.com/PlayPro/CoreProtect:branch`
- manuell hochgeladene `.jar` Dateien unter `DATA_DIR/plugins/manuell`

Beispiel:

```text
BlueMap modrinth:bluemap
Geyser modrinth:geyser
Geyser-Velocity https://download.geysermc.org/v2/projects/geyser/versions/latest/builds/latest/downloads/velocity
Floodgate https://github.com/GeyserMC/Floodgate
WorldEdit modrinth:worldedit
DiscordSRV modrinth:discordsrv
DiscordSRV https://download.discordsrv.com/v2/DiscordSRV/DiscordSRV/release/download/latest/jar
CoreProtect https://github.com/PlayPro/CoreProtect
CoreProtect build:master
```

Bei `modrinth:<slug>` waehlt die WebUI den Loader passend zum Server-Typ. Velocity bevorzugt `velocity`, Bungee/Waterfall bevorzugen `bungeecord`/`waterfall`, Paper/Purpur/Folia bevorzugen Bukkit-kompatible Loader. Wenn kein passender Loader gefunden wird, wird das Plugin als Fehler gemeldet, statt eine falsche JAR zu installieren.

Zeilen mit `#` am Anfang sind deaktiviert. CoreProtect wird aus dem GitHub-Source-Zip gebaut; dafuer braucht der Host
kein `git`, aber `curl`/`wget` und entweder `mvn` oder Docker, damit der Maven-Container genutzt werden kann.
SpigotMC-/BukkitDev-Projektseiten sind in der Regel keine direkten JAR-Downloads. Die WebUI lehnt heruntergeladene
Dateien ab, wenn sie keine echte JAR/ZIP-Datei sind, und beendet das Plugin-Update dann mit Fehlercode.

## RCON und Ports

Bei mehreren Servern kann der interne RCON-Port meist `25575` bleiben. Der Host-Port muss eindeutig sein:

```text
Survival: 25575:25575
Creative: 25576:25575
Lobby:    25577:25575
```

Fuer Geyser oder VoiceChat die UDP-Ports in `Extra Ports` setzen, z. B. `19132:19132/udp`. Die WebUI warnt bei offensichtlichen Kollisionen, passt Plugin-Konfigurationsdateien aber noch nicht automatisch an.

Fuer BlueMap `BlueMap modrinth:bluemap` in `plugins.txt` setzen und den Web-Port mappen, z. B. `8100:8100/tcp`.
Der Button `BlueMap oeffnen` und `BlueMap einbetten` laufen ueber den WebUI-Proxy unter `/map/<server-id>/`.
Dadurch reicht spaeter ein Reverse Proxy auf die WebUI; der Browser muss den BlueMap-Port nicht direkt erreichen.
`BlueMap URL` ist der optionale Upstream fuer die WebUI, z. B. `http://127.0.0.1:8100/`. Wenn das Feld leer ist,
nutzt die WebUI lokal `127.0.0.1:8100` oder den Host-Port aus einem Mapping wie `8123:8100/tcp`.

## Sicherheit

Die WebUI kann Docker-Container starten und stoppen. Sie sollte nicht ohne Authentifizierung oeffentlich erreichbar
sein. Fuer den ersten Test ist eine Host-Installation mit Zugriff auf Docker am einfachsten.
