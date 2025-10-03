# Minecraft Docker Start Script

Dieses Skript automatisiert die Pflege eines Minecraft-Servers, der in einem Docker-Container läuft. Es führt interaktive Abfragen durch, merkt sich vergangene Eingaben und übernimmt Aufgaben wie Updates, Backups, Plugin-Verwaltung sowie das Einspielen von Backups.

## Voraussetzungen

* Linux- oder macOS-Shell mit Bash 4+
* Docker
* curl, jq, wget, unzip, sed, awk, python3
* Optional: `mvn` oder Docker (für den CoreProtect-Quellcode-Build)

## Nutzung

1. Skript ausführbar machen: `chmod +x start_minecraft.sh`
2. Skript starten: `./start_minecraft.sh`
3. Fragen des Assistenten beantworten. Frühere Eingaben werden aus einer History-Datei vorgeschlagen.

Während der Ausführung erzeugt das Skript Protokolle im `update_log.txt` des gewählten Datenverzeichnisses.

## Funktionsumfang

* **Historiengestützte Eingaben** – Eingaben und Auswahllisten speichern die letzte Entscheidung pro Frage und schlagen sie beim nächsten Lauf vor.
* **Server-Typ & Versionen wählen** – Auswahlmenüs für verschiedene Server-Typen (Paper, Folia, Purpur, Spigot usw.). Paper-Versionen zeigen, ob Builds im "default"- oder "experimental"-Kanal verfügbar sind.
* **Docker-Management** – Stoppt den laufenden Container, entfernt ihn und startet ihn mit den gewählten Parametern neu. Unterstützt Paper-spezifische Umgebungsvariablen wie `PAPER_CHANNEL`.
* **Backup & Restore** – Erstellt tar.gz-Backups des Datenverzeichnisses mit Fortschrittsmeldungen und stellt ausgewählte Sicherungen inkl. Fortschrittsanzeige wieder her.
* **Plugin-Verwaltung** – Lädt Plugins basierend auf `plugins.txt` aus verschiedenen Quellen (Modrinth, GitHub, Spigot, direkte Downloads). Erstellt bei Bedarf eine kommentierte Vorlage.
* **CoreProtect-Spezialfall** – Erkennt `build`-Direktiven für CoreProtect, kompiliert das Plugin aus dem Git-Repository (lokal oder in einem Maven-Docker-Container) und patcht `plugin.yml` automatisch. Fällt bei Problemen auf offizielle Release-Downloads zurück.
* **Statusmeldungen** – Ausgabe strukturierter Log-Nachrichten mit Zeitstempel, die gleichzeitig im Terminal und im Logfile landen.

## Wichtige Dateien

* `plugins.txt` – Steuerdatei für die Plugin-Verwaltung. Wird automatisch angelegt, falls sie fehlt.
* `backups/` – Zielverzeichnis für Backup-Archive.
* `update_log.txt` – Logdatei für alle Aktionen des Skripts.
* `~/.minecraft_script_history` – Persistente History, die letzte Antworten für künftige Skriptausführungen speichert.

## Fehlerbehandlung & Sicherheit

* Skript bricht bei fehlenden Pflicht-Abhängigkeiten mit einer Logmeldung ab.
* Download- und Build-Vorgänge besitzen Fallbacks sowie Erfolg-/Fehlermeldungen.
* Temporäre Dateien und Arbeitsverzeichnisse werden nach erfolgreichem oder fehlerhaftem Durchlauf bereinigt.

## Weiterführende Hinweise

* Das Skript setzt die Zustimmung zur Minecraft-EULA (`EULA=TRUE`).
* Port-Mappings (25565 TCP, 19132/24454 UDP) sind im Skript hinterlegt und können bei Bedarf angepasst werden.
* Die History-Datei kann manuell gelöscht werden, wenn alte Eingaben nicht mehr vorgeschlagen werden sollen.
