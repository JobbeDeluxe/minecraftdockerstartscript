# Minecraft Docker WebUI

Eine hostbasierte Weboberflaeche zum Erstellen, Starten, Ueberwachen und Pflegen von Minecraft-Docker-Servern.

Das Projekt ist nicht mehr nur ein Startscript. Der CLI-Modus bleibt erhalten, aber der Hauptfokus ist jetzt eine vollwertige WebUI fuer mehrere Serverprofile, Docker-Steuerung, Logs, RCON, Backups, Plugin-Management, BlueMap, Spieleraktionen und Datei-/Konfig-Verwaltung.

## Screenshots

Dashboard einer laufenden WebUI-Instanz:

![Dashboard](webui/docs/images/webui-dashboard-live.png)

Hilfe-Dialog mit den wichtigsten Bedienhinweisen:

![Hilfe](webui/docs/images/webui-help-live.png)

## Was die WebUI kann

- Mehrere Serverprofile mit eigener ID, eigenem Namen, Container, Datenordner, RAM, Minecraft-Version und Ports
- Minecraft-Server ueber `itzg/minecraft-server`: Paper, Folia, Purpur, Vanilla, Fabric, Forge, Quilt und weitere Image-Typen
- Proxy-Server ueber `itzg/mc-proxy`: Velocity, BungeeCord und Waterfall
- Docker-Aktionen: Anwenden, Start, Stop mit Container-Entfernung, Restart und Backup
- Start erstellt bei neuen Profilen automatisch einen fehlenden Container
- Lokale Daten eines Profils loeschen, ohne Profil oder zentrale Backups zu entfernen
- Datenverzeichnis eines Profils nachtraeglich verschieben und das Profil automatisch anpassen
- Profile deaktivieren, ohne Profil oder Datenordner zu loeschen
- Portpruefung gegen andere Profile und laufende Docker-Container
- Deaktivierte Profile werden ausgegraut, als `deaktiviert` markiert und geben ihre Ports frei
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
- Text-Konfigdateien direkt im Datei-Manager bearbeiten, zum Beispiel unter `plugins/`, `config/` oder im Datenordner
- Editierbare Konfigdateien im Datei-Manager heller markieren und per Klick in den Editor laden
- Velocity-Dateien wie `velocity.toml` und `forwarding.secret` editieren
- Datei-Manager fuer Serverdaten: Ordner per Klick oeffnen, zurueck navigieren, Ordner erstellen, umbenennen und loeschen
- ZIP-Upload zum Importieren oder Austauschen von Welten und Daten
- Zentrale Backups mit Restore in ein bestehendes Profil
- Import aus `.tar.gz`/`.tgz` Backups als neues Serverprofil
- BlueMap oeffnen oder direkt in der WebUI einbetten
- BlueMap-Proxy unter `/map/<server-id>/`, damit spaeter ein Reverse Proxy auf die WebUI reicht

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
v1.0.15
```

Im Header gibt es ausserdem einen direkten Link zur GitHub-Projektseite.

## Icons und Assets

Die WebUI nutzt das Spigot/WebUI-PNG als sichtbares Header-Icon und als Browser-Favicon:

- `docs/assets/minecraft-docker-webui-spigot-icon-96.png`
- `docs/assets/minecraft-docker-webui-icon-128.png`

Die Dateien werden von der WebUI unter `/assets/...` ausgeliefert und koennen auch fuer README,
Release-Notizen oder Desktop-/Homescreen-Verknuepfungen genutzt werden.

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

Bei Proxy-Typen setzt die WebUI automatisch das passende Image, mountet den Datenordner nach `/server` und nutzt die passenden internen Ports. Fuer Velocity liest die WebUI den internen Port aus `velocity.toml` (`bind`) und mappt den Host-Port darauf, zum Beispiel `25565:25577`, wenn Velocity intern auf `25577` lauscht. Fuer Velocity koennen `velocity.toml`, `forwarding.secret` und weitere Textdateien ueber den Datei-/Konfig-Editor bearbeitet werden.

## Velocity-Netzwerk

Profile koennen ueber `Netzwerk-Gruppe` zu einem kleinen Velocity-Verbund zusammengefasst werden.
Ein Velocity-Profil wird als `Proxy` genutzt, Paper/Purpur/Folia oder andere Java-Server als
`Backend`. `Netzwerk-Alias` ist der Name fuer Velocity-Befehle wie `/server lobby`; `Default-Ziel`
auf dem Velocity-Profil bestimmt den ersten Zielserver.

`Netzwerk anwenden` aktualisiert automatisch:

- `velocity.toml` mit `[servers]`, `try`, `player-info-forwarding-mode = "modern"` und `forwarding-secret-file`
- `forwarding.secret` im Velocity-Datenordner
- `server.properties` der Backends mit `online-mode=false` und `enforce-secure-profile=false`
- `config/paper-global.yml` fuer Paper/Purpur/Folia mit aktiviertem Velocity-Forwarding
- Docker-Netzwerkdaten in den Profilen, damit die Container sich untereinander per Containername erreichen

Danach die betroffenen Profile per `Anwenden` oder `Restart` neu erstellen, damit Docker-Netzwerk
und neue Konfigdateien aktiv sind. Geyser/Floodgate oder weitere Plugin-Spezialkonfigurationen
bleiben aktuell noch manuelle Feineinstellung.

## Deaktivierte Profile

`Deaktivieren` entfernt nur den Docker-Container. Profil und Datenordner bleiben erhalten.
Das Profil wird links ausgegraut und mit Status `deaktiviert` angezeigt.

Deaktivierte Profile blockieren die Portpruefung nicht. So kann zum Beispiel ein alter Server
kurz deaktiviert werden, waehrend ein anderes Profil denselben Host-Port testweise nutzt. Aktive
Profile mit gleichem Host-Port blockieren weiterhin, damit nicht versehentlich zwei Container auf
denselben Port starten.

Wenn ein deaktiviertes Profil ausgewaehlt ist, wechselt der Button von `Deaktivieren` zu
`Aktivieren`. `Aktivieren` startet keinen Container, sondern nimmt das Profil nur wieder in Status-
und Portpruefung auf. `Anwenden`, `Start` oder `Restart` aktiviert ein deaktiviertes Profil nach
erfolgreicher Aktion ebenfalls automatisch wieder.

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
Geyser-Velocity https://download.geysermc.org/v2/projects/geyser/versions/latest/builds/latest/downloads/velocity
Floodgate https://github.com/GeyserMC/Floodgate
WorldEdit modrinth:worldedit
DiscordSRV modrinth:discordsrv
CoreProtect https://github.com/PlayPro/CoreProtect
CoreProtect build:master
```

Bei `modrinth:<slug>` waehlt die WebUI den Loader passend zum Server-Typ. Ein Velocity-Profil bevorzugt also `velocity`, Paper/Purpur/Folia bevorzugen passende Bukkit-Loader. Wenn Modrinth fuer den gewaehlten Server-Typ keine passende JAR anbietet, bricht das Plugin mit einer klaren Meldung ab, statt still eine falsche Fabric/NeoForge/Bukkit-Datei zu installieren.

Zeilen mit `#` am Anfang sind deaktiviert. Nach Plugin-Updates fragt die WebUI nach einem Restart, damit der Server die neuen JARs laedt. Manuelle Plugins landen unter `DATA_DIR/plugins/manuell`; installierte Plugins aus `DATA_DIR/plugins` koennen angezeigt und entfernt werden.

## Dateien und Konfiguration

Die WebUI buendelt Ordnernavigation, Dateiverwaltung und Text-Editor in einem Datei-Bereich.
Ordner stehen links, Dateien rechts. Ein Klick auf einen Ordner oeffnet ihn, `Zurueck` geht eine
Ebene hoch.

Editierbare Text-Konfigdateien wie `server.properties`, Plugin-Konfigs, `velocity.toml`,
`forwarding.secret`, `.yml`, `.json`, `.conf` oder `.txt` werden heller markiert. Ein Klick auf
so eine Datei laedt sie direkt in den Editor darunter; `Inhalt neu laden` aktualisiert die aktuell
geoeffnete Datei und `Datei speichern` schreibt sie zurueck.

Der ZIP-Upload ist fuer Welt-Importe oder Datenaustausch gedacht. Entpackt wird in den aktuell ausgewaehlten Ordner innerhalb des Server-Datenverzeichnisses.

Wenn das Datenverzeichnis nachtraeglich korrigiert werden muss, kann der neue Pfad im Profil eingetragen und mit `Daten verschieben` uebernommen werden. Die WebUI entfernt dabei den Container, verschiebt den alten Datenordner an den neuen Pfad und aktualisiert das Profil. Nicht editierbare Dateien wie `.jar` oder grosse Weltdaten werden im Datei-Browser nur fuer Umbenennen oder Loeschen ausgewaehlt.

## Backups und Import

Backups werden zentral abgelegt und enthalten den Server-/Containernamen im Dateinamen. Dadurch kann ein alter Server geloescht und spaeter wieder als neues Profil importiert werden.

Waehrend ein Backup laeuft, pollt die WebUI das Aktionslog. Das Backend schreibt alle 5 Sekunden
die aktuelle Archivgroesse und die verstrichene Zeit ins Log, damit grosse Backups nicht wie ein
haengender Vorgang wirken.

Restore stoppt den betroffenen Container, entpackt das Backup in den Datenordner und gibt Statusmeldungen im Ergebnisfenster aus. Import erstellt ein neues Profil und stellt das ausgewaehlte Backup dort wieder her.

## Hilfe im WebUI

Die Hilfe erklaert die wichtigsten Felder direkt im Browser, unter anderem ID, Name, Container, Ports, RCON, Plugins, Backups, BlueMap, Datei-/Konfig-Bearbeitung, das eingebundene Icon und den Unterschied zwischen `Speichern` und `Anwenden`.

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

`v1.0.15` ist als aktueller WebUI-Teststand gedacht. Das Ziel ist eine praktische, hostinstallierte Alternative zu groesseren Panels, ohne die vorhandene Docker-Logik zu verstecken.
