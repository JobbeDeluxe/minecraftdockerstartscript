# Minecraft Docker WebUI

Eine hostbasierte Weboberflaeche zum Erstellen, Starten, Ueberwachen und Pflegen von Minecraft-Docker-Servern.

Das Projekt ist nicht mehr nur ein Startscript. Der CLI-Modus bleibt erhalten, aber der Hauptfokus ist jetzt eine vollwertige WebUI fuer mehrere Serverprofile, Docker-Steuerung, Logs, RCON, Backups, Plugin-Management, BlueMap, Spieleraktionen und Datei-/Konfig-Verwaltung.

![Dashboard](docs/screenshots/dashboard.png)

## Was die WebUI kann

- Mehrere Serverprofile mit eigener ID, eigenem Namen, Container, Datenordner, RAM, Minecraft-Version und Ports
- Minecraft-Server ueber `itzg/minecraft-server`: Paper, Folia, Purpur, Vanilla, Fabric, Forge, Quilt und weitere Image-Typen
- Proxy-Server ueber `itzg/mc-proxy`: Velocity, BungeeCord und Waterfall
- Docker-Aktionen: Anwenden, Start, Stop, Restart und Backup
- Start erstellt bei neuen Profilen automatisch einen fehlenden Container
- Portpruefung gegen andere Profile und laufende Docker-Container
- EULA, RAM, Version, Paper-Channel, RCON, Extra-Ports und Backup-Pfad direkt im Browser setzen
- Versionsfeld mit manueller Eingabe plus Versionsliste/Refresh
- Live-Logs und normales Logfenster
- RCON-Konsole mit direktem Feedback und letzten Logzeilen
- Spielerstatus links in der Serverliste und Spieleruebersicht per RCON `list`
- RCON-Schnellaktionen fuer Teleport, Give, Kick, Ban und Pardon
- `server.properties` Editor
- `plugins.txt` Editor mit ungespeichert-Hinweis, Reload, Test-/Update-Workflow und Restart-Hinweis
- Plugin-Updates aus Modrinth, GitHub Releases, Geyser-Endpunkten, Spigot/Fallbacks und direkten JAR-Links
- CoreProtect-Source-Build ohne lokales `git`, mit Maven lokal oder per Docker-Container
- Manuelle Plugin-JARs hochladen und loeschen
- Installierte Plugins anzeigen und aus dem Plugin-Ordner entfernen
- Plugin-Konfigdateien direkt bearbeiten, zum Beispiel unter `plugins/`, `config/` oder im Datenordner
- Velocity-Dateien wie `velocity.toml` und `forwarding.secret` editieren
- Datei-Manager fuer Serverdaten: Ordner laden, hoch navigieren, Ordner erstellen, umbenennen und loeschen
- ZIP-Upload zum Importieren oder Austauschen von Welten und Daten
- Zentrale Backups mit Restore in ein bestehendes Profil
- Import aus `.tar.gz`/`.tgz` Backups als neues Serverprofil
- BlueMap oeffnen oder direkt in der WebUI einbetten
- BlueMap-Proxy unter `/map/<server-id>/`, damit spaeter ein Reverse Proxy auf die WebUI reicht

![Management](docs/screenshots/management.png)

## Schnellstart

Voraussetzungen:

- Linux-Host mit Bash
- Docker
- Python 3
- `curl` oder `wget`
- Optional: `mvn` oder Docker fuer CoreProtect-Builds

Repository klonen und WebUI starten:

```bash
git clone https://github.com/JobbeDeluxe/minecraftdockerstartscript.git
cd minecraftdockerstartscript
python3 webui/app.py
```

Standardmaessig lauscht die WebUI nur lokal:

```text
http://127.0.0.1:8088
```

Fuer einen LAN-Test:

```bash
MCDOCKER_WEBUI_HOST=0.0.0.0 MCDOCKER_WEBUI_PORT=8088 python3 webui/app.py
```

Wichtig: `Speichern` sichert nur das WebUI-Profil. `Anwenden` erstellt oder aktualisiert den Docker-Container, damit Version, RAM, Ports, Docker-Image, RCON und Volumes wirklich aktiv werden.

## WebUI-Version

Die WebUI zeigt ihre Version oben im Header an. Dieser Release-Kandidat ist:

```text
v1.0.0-rc1
```

Im Header gibt es ausserdem einen direkten Link zur GitHub-Projektseite.

## Server und Docker

Normale Minecraft-Server laufen ueber `itzg/minecraft-server`. Dazu gehoeren unter anderem:

```text
VANILLA, PAPER, FOLIA, PURPUR, SPIGOT, FABRIC, FORGE, QUILT,
BUKKIT, SPONGEVANILLA, MAGMA, MOHIST, NEOFORGE, LEAF, PUFFERFISH
```

Proxy-Server laufen ueber `itzg/mc-proxy`:

```text
VELOCITY, BUNGEECORD, WATERFALL
```

Bei Proxy-Typen setzt die WebUI automatisch das passende Image, mountet den Datenordner nach `/server` und nutzt die passenden internen Ports. Fuer Velocity koennen `velocity.toml`, `forwarding.secret` und weitere Textdateien ueber den Datei-/Konfig-Editor bearbeitet werden.

## Spieler und RCON

RCON kann pro Server aktiviert werden. Wichtig sind ein eigenes Passwort und ein eigener Host-Port pro Server, zum Beispiel `25575`, `25576`, `25577`.

Die WebUI nutzt RCON fuer:

- Spieleranzahl und Spielerliste
- Freie Konsolenbefehle
- Letzte Logausgabe nach einem Befehl
- Schnellaktionen wie `tp`, `give`, `kick`, `ban` und `pardon`

Die Serverliste zeigt neben Status und Port auch die Spielerzahl an, sofern der Server per RCON antwortet.

## BlueMap

BlueMap kann als Plugin installiert werden, zum Beispiel:

```text
BlueMap modrinth:bluemap
```

Der BlueMap-Port muss im Serverprofil als Extra-Port gemappt werden, zum Beispiel:

```text
8100:8100/tcp
```

Die WebUI kann BlueMap dann oeffnen oder als Frame einbetten. Wenn `BlueMap URL` leer bleibt, nutzt die WebUI den Standardpfad:

```text
/map/<server-id>/
```

Damit kann spaeter ein Reverse Proxy nur auf die WebUI zeigen. Der Browser muss den internen BlueMap-Port dann nicht direkt erreichen.

## Plugins

Die Plugin-Verwaltung liest und schreibt `DATA_DIR/plugins.txt`.

Beispiele:

```text
BlueMap modrinth:bluemap
Geyser-Spigot modrinth:geyser
Floodgate https://github.com/GeyserMC/Floodgate
WorldEdit modrinth:worldedit
DiscordSRV modrinth:discordsrv
CoreProtect https://github.com/PlayPro/CoreProtect
CoreProtect build:master
```

Zeilen mit `#` am Anfang sind deaktiviert. Nach Plugin-Updates fragt die WebUI nach einem Restart, damit der Server die neuen JARs laedt. Manuelle Plugins landen unter `DATA_DIR/plugins/manuell`; installierte Plugins aus `DATA_DIR/plugins` koennen angezeigt und entfernt werden.

## Dateien und Konfiguration

Die WebUI enthaelt zwei Ebenen fuer Dateien:

- Konfig-Editor fuer Textdateien wie `server.properties`, Plugin-Konfigs, `velocity.toml` und `forwarding.secret`
- Datei-Manager fuer Ordner, Welten, Uploads, Umbenennen, Loeschen und ZIP-Import

Der ZIP-Upload ist fuer Welt-Importe oder Datenaustausch gedacht. Entpackt wird in den aktuell ausgewaehlten Ordner innerhalb des Server-Datenverzeichnisses.

## Backups und Import

Backups werden zentral abgelegt und enthalten den Server-/Containernamen im Dateinamen. Dadurch kann ein alter Server geloescht und spaeter wieder als neues Profil importiert werden.

Restore stoppt den betroffenen Container, entpackt das Backup in den Datenordner und gibt Statusmeldungen im Ergebnisfenster aus. Import erstellt ein neues Profil und stellt das ausgewaehlte Backup dort wieder her.

## Hilfe im WebUI

![Hilfe](docs/screenshots/help.png)

Die Hilfe erklaert die wichtigsten Felder direkt im Browser, unter anderem ID, Name, Container, Ports, RCON, Plugins, Backups, BlueMap und den Unterschied zwischen `Speichern` und `Anwenden`.

## CLI-Modus

Das alte interaktive Script ist weiterhin enthalten:

```bash
chmod +x start_minecraft.sh
./start_minecraft.sh
```

Es kann weiterhin fuer klassische Terminal-Workflows genutzt werden. Die WebUI nutzt zusaetzlich `webui/backend.sh`, um Aktionen nicht-interaktiv auszufuehren.

## Sicherheit

Die WebUI kann Docker-Container starten, stoppen, loeschen und Daten im Serverordner veraendern. Sie sollte nicht ungeschuetzt oeffentlich erreichbar sein.

Empfehlung fuer produktive Nutzung:

- WebUI nur hinter Reverse Proxy mit Login veroeffentlichen
- RCON-Passwoerter pro Server eindeutig setzen
- Ports pro Server bewusst trennen
- Vor groesseren Aenderungen Backup erstellen
- Datei- und ZIP-Uploads nur vertrauenswuerdigen Admins erlauben

## Status

`v1.0.0-rc1` ist als erster oeffentlicher Release-Kandidat gedacht. Das Ziel ist eine praktische, hostinstallierte Alternative zu groesseren Panels, ohne die vorhandene Docker-Logik zu verstecken.
