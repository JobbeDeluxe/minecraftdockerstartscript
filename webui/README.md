# Minecraft Docker WebUI

Kleiner Host-WebUI-Prototyp fuer Minecraft-Server in Docker. Die WebUI speichert Serverprofile als JSON unter `~/.minecraftdocker-webui/servers`, schreibt daraus temporaere Shell-Config-Dateien und ruft `webui/backend.sh` nicht-interaktiv auf.

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
- Containerstatus und Logs anzeigen
- Mehrere Server ueber unterschiedliche Containernamen, Datenverzeichnisse und Ports verwalten

## Backend-Modus

Die WebUI nutzt diesen nicht-interaktiven Modus:

```bash
webui/backend.sh --config /tmp/server.env --action apply
webui/backend.sh --config /tmp/server.env --action start
webui/backend.sh --config /tmp/server.env --action stop
webui/backend.sh --config /tmp/server.env --action logs
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
EXTRA_PORTS=19132:19132/udp,24454:24454/udp
DO_BACKUP=nein
DO_START_DOCKER=ja
```

Plugin-Verwaltung bleibt im ersten Prototyp noch im bestehenden interaktiven Script. Der naechste saubere Schritt ist, diese Logik ebenfalls in kleinere nicht-interaktive Funktionen zu schneiden.

## Sicherheit

Die WebUI kann Docker-Container starten und stoppen. Sie sollte nicht ohne Authentifizierung oeffentlich erreichbar sein. Fuer den ersten Test ist eine Host-Installation mit Zugriff auf Docker am einfachsten.
