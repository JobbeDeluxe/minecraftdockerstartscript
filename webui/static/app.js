let servers = [];
let selected = null;
let liveTimer = null;
let pluginsDirty = false;
let propertiesDirty = false;
let configDirty = false;
let fileEditorDirty = false;
let fileEditorPath = "";
let selectedDataEntryPath = "";

const serverTypes = ["PAPER", "FOLIA", "PURPUR", "SPIGOT", "VANILLA", "FABRIC", "FORGE", "QUILT", "BUKKIT", "SPONGEVANILLA", "MAGMA", "MOHIST", "NEOFORGE", "LEAF", "PUFFERFISH", "AIRPLANE", "BANNER", "YOUER", "GTNH", "CANYON", "LIMBO", "NANOLIMBO", "CRUCIBLE", "CUSTOM", "BUNGEECORD", "WATERFALL", "VELOCITY"];
const proxyTypes = new Set(["BUNGEECORD", "WATERFALL", "VELOCITY"]);
const fields = [["id", "field.id"], ["name", "field.name"], ["container_name", "field.container"], ["memory", "field.memory"], ["init_memory", "field.initMemory"], ["max_memory", "field.maxMemory"], ["type", "field.type"], ["version", "field.version"], ["paper_channel", "field.paperChannel"], ["host_port", "field.hostPort"], ["data_dir", "field.dataDir", "wide"], ["network_group", "field.networkGroup"], ["network_role", "field.networkRole"], ["network_alias", "field.networkAlias"], ["network_default", "field.networkDefault"], ["extra_ports", "field.extraPorts", "wide"], ["map_url", "field.mapUrl", "wide"], ["backup_root", "field.backupRoot", "wide"], ["docker_image", "field.dockerImage", "wide"], ["rcon_host_port", "field.rconHostPort"], ["rcon_container_port", "field.rconContainerPort"], ["rcon_password", "field.rconPassword", "wide"]];

const I18N = {
  de: {
    "button.help": "Hilfe",
    "button.new": "Neu",
    "button.save": "Speichern",
    "button.reloadProfile": "Lokale Version laden",
    "button.loadVersions": "Versionen laden",
    "button.moveData": "Daten verschieben",
    "button.applyNetwork": "Netzwerk anwenden",
    "button.apply": "Anwenden",
    "button.start": "Start",
    "button.stop": "Stop",
    "button.restart": "Restart",
    "button.disable": "Deaktivieren",
    "button.enable": "Aktivieren",
    "button.backup": "Backup",
    "button.deleteData": "Lokale Daten loeschen",
    "button.deleteServer": "Server loeschen",
    "button.refreshLogs": "Logs laden",
    "button.liveLogs": "Live Logs",
    "button.stopLive": "Live stoppen",
    "button.openMap": "BlueMap oeffnen",
    "button.embedMap": "BlueMap einbetten",
    "button.refreshPlayers": "Spieler laden",
    "button.tp": "TP zu Spieler",
    "button.give": "Give",
    "button.kick": "Kick",
    "button.ban": "Ban",
    "button.pardon": "Pardon",
    "button.send": "Senden",
    "button.restore": "Restore",
    "button.importBackup": "Als neuen Server importieren",
    "button.saveProperties": "server.properties speichern",
    "button.reload": "Neu laden",
    "button.savePlugins": "Plugins speichern",
    "button.updatePlugins": "Plugins aktualisieren",
    "button.uploadPlugin": "Manuelles Plugin hochladen",
    "button.deleteManualPlugin": "Manuelles Plugin loeschen",
    "button.refreshInstalledPlugins": "Installierte Plugins laden",
    "button.deleteInstalledPlugin": "Installiertes Plugin loeschen",
    "button.loadFolder": "Ordner laden",
    "button.back": "Zurueck",
    "button.makeFolder": "Ordner erstellen",
    "button.reloadFile": "Inhalt neu laden",
    "button.saveFile": "Datei speichern",
    "button.rename": "Umbenennen",
    "button.delete": "Loeschen",
    "button.select": "Auswahl",
    "button.uploadZip": "ZIP in aktuellen Ordner entpacken",
    "button.close": "Schliessen",
    "section.portCheck": "Portpruefung",
    "section.velocityNetwork": "Velocity-Netzwerk",
    "section.players": "Spieler",
    "section.rcon": "RCON Konsole",
    "section.backups": "Backups",
    "section.properties": "server.properties",
    "section.plugins": "Plugins.txt",
    "section.files": "Dateien",
    "section.folders": "Ordner",
    "field.id": "ID",
    "field.name": "Name",
    "field.container": "Container",
    "field.memory": "RAM (MEMORY)",
    "field.initMemory": "Min RAM",
    "field.maxMemory": "Max RAM",
    "field.type": "Typ",
    "field.version": "Version",
    "field.paperChannel": "Paper Channel",
    "field.hostPort": "Host-Port",
    "field.dataDir": "Datenverzeichnis",
    "field.networkGroup": "Netzwerk-Gruppe",
    "field.networkRole": "Netzwerk-Rolle",
    "field.networkAlias": "Netzwerk-Alias",
    "field.networkDefault": "Default-Ziel",
    "field.extraPorts": "Extra Ports (Komma, Leerzeichen oder neue Zeile)",
    "field.mapUrl": "BlueMap URL",
    "field.backupRoot": "Zentraler Backup-Ordner",
    "field.dockerImage": "Docker Image",
    "field.rconHostPort": "RCON Host-Port",
    "field.rconContainerPort": "RCON Container-Port",
    "field.rconPassword": "RCON Passwort",
    "help.id": "Stabile Profil-ID und Dateiname. Nach dem Anlegen moeglichst nicht mehr aendern.",
    "help.name": "Anzeigename links in der WebUI.",
    "help.container_name": "Docker-Containername, den die WebUI startet, stoppt und fuer Portpruefungen erkennt.",
    "help.data_dir": "Wenn du den Pfad nachtraeglich aenderst, nutze Daten verschieben, damit vorhandene Dateien mit umziehen.",
    "help.network_group": "Gleicher Gruppenname verbindet einen Velocity-Proxy und seine Backend-Server.",
    "help.network_role": "Auto erkennt Velocity als Proxy und normale Server als Backend. Bei Sonderfaellen manuell setzen.",
    "help.network_alias": "Name fuer Velocity-Befehle wie /server lobby. Leer nutzt die Profil-ID.",
    "help.network_default": "Nur beim Velocity-Profil relevant: erster Zielserver fuer neue Spieler, z. B. lobby.",
    "help.type": "Normale Server nutzen itzg/minecraft-server. BungeeCord, Waterfall und Velocity nutzen automatisch itzg/mc-proxy.",
    "help.map_url": "Optionaler interner BlueMap-Upstream fuer die WebUI, z. B. http://127.0.0.1:8100/. Leer lassen ist meist richtig.",
    "help.docker_image": "Leer lassen oder Standardwert nutzen. Bei Proxy-Typen setzt die WebUI automatisch itzg/mc-proxy.",
    "check.eula": "Minecraft EULA akzeptiert",
    "check.rcon": "RCON aktiv",
    "check.backupBefore": "Backup vorher",
    "check.startAfter": "Danach starten",
    "state.disabled": "deaktiviert",
    "state.missing": "missing",
    "state.unknown": "unknown",
    "players.disabled": "Profil deaktiviert",
    "players.unknown": "Spieler unbekannt",
    "dirty.profile": "Profil ungespeichert",
    "dirty.unsaved": "ungespeichert",
    "warnings.initial": "Noch keine Pruefung.",
    "warnings.none": "Keine offensichtlichen Port-Konflikte gefunden.",
    "warning.duplicatePort": "{label}: Port {port}/{proto} ist im selben Profil doppelt belegt ({other}).",
    "warning.profileConflict": "{label}: Port {port}/{proto} kollidiert mit Profil {profiles}.",
    "warning.hostOpen": "{label}: Port {port}/{proto} scheint auf dem Host bereits offen zu sein.",
    "warning.dockerPublished": "{label}: Port {port}/{proto} wird bereits von Docker-Container {containers} publiziert.",
    "warning.ownContainer": "{label}: Port {port}/{proto} wird vom eigenen Container {container} genutzt.",
    "warning.rconPassword": "rcon: RCON ist aktiv, aber es ist noch kein Passwort gesetzt.",
    "warning.eula": "eula: Die Minecraft EULA ist noch nicht akzeptiert; Anwenden wird blockiert.",
    "network.none": "Keine Netzwerk-Gruppe im aktuellen Profil gesetzt.",
    "network.group": "Gruppe: {group}",
    "network.proxy": "Proxy: {proxy}",
    "network.noProxy": "kein Velocity-Proxy gefunden",
    "network.default": "Default: {target}",
    "network.defaultAuto": "(Auto, bevorzugt lobby)",
    "network.backends": "Backends:",
    "network.noBackends": "- keine aktiven Backends gefunden",
    "network.multiProxy": "Warnung: Mehr als ein Proxy in dieser Gruppe. Bitte nur einen Velocity-Proxy als Proxy markieren.",
    "network.confirm": "Velocity-Netzwerk \"{group}\" konfigurieren?\n\nDie WebUI aktualisiert velocity.toml, forwarding.secret, server.properties, Paper-Forwarding und die Docker-Netzwerkdaten der Profile. Danach bitte die Gruppe per Anwenden/Restart neu erstellen.",
    "network.needGroup": "Bitte zuerst eine Netzwerk-Gruppe im Profil eintragen und speichern.",
    "network.running": "Velocity-Netzwerk wird konfiguriert...",
    "network.done": "Velocity-Netzwerk konfiguriert.",
    "prompt.movePhrase": "VERSCHIEBEN",
    "prompt.moveData": "Datenverzeichnis verschieben?\n\nAlt:\n{oldPath}\n\nNeu:\n{target}\n\nDer Docker-Container wird entfernt. Profil und zentrale Backups bleiben erhalten.\n\nZum Bestaetigen bitte exakt eingeben:\n{phrase}",
    "prompt.deleteDataPhrase": "DATEN LOESCHEN",
    "prompt.deleteData": "Lokale Daten fuer dieses Profil wirklich loeschen?\n\nDatenordner:\n{dataDir}\n\nDer Docker-Container und alle Dateien im Datenordner werden geloescht. Profil und zentrale Backups bleiben erhalten.\n\nZum Bestaetigen bitte exakt eingeben:\n{phrase}",
    "prompt.discardProfile": "Ungespeicherte Profil-Aenderungen verwerfen und lokale Version laden?",
    "prompt.deleteServer": "Server \"{name}\" ({id}) wirklich loeschen?\n\nDer Docker-Container und der Datenordner werden ebenfalls geloescht:\n{dataDir}",
    "prompt.discardPlugins": "Ungespeicherte Aenderungen verwerfen?",
    "prompt.updatePluginsUnsaved": "plugins.txt hat ungespeicherte Aenderungen. Jetzt speichern und dann aktualisieren? OK=speichern, Abbrechen=verwerfen.",
    "prompt.restartAfterPlugins": "Plugin-Updates wurden geladen. Restart laedt Plugins neu. Falls du auch Version/RAM/Ports geaendert hast, nutze danach zusaetzlich Anwenden. Jetzt neu starten?",
    "prompt.discardProperties": "Ungespeicherte server.properties-Aenderungen verwerfen?",
    "prompt.deleteManualPlugin": "{name} loeschen?",
    "prompt.deleteInstalledPlugin": "{name} aus DATA_DIR/plugins loeschen? Der laufende Server braucht danach einen Restart.",
    "prompt.discardFile": "Ungespeicherte Datei-Aenderungen verwerfen?",
    "prompt.deleteEntry": "{path} wirklich loeschen? Das kann Welten/Configs entfernen.",
    "prompt.restore": "Backup in diesen Server wiederherstellen? Der Container wird gestoppt.",
    "message.requestFailed": "Request failed",
    "message.noDataDir": "Bitte neues Datenverzeichnis eintragen.",
    "message.dataUnchanged": "Das Datenverzeichnis ist unveraendert.",
    "message.movingData": "Datenverzeichnis wird verschoben...",
    "message.dataMoved": "Datenverzeichnis verschoben.",
    "message.profileReloaded": "Lokale Profilversion geladen. Ungespeicherte Profil-Aenderungen wurden verworfen.",
    "message.saved": "Gespeichert. Start/Restart erstellt den Container neu, wenn RAM, Ports, Version oder Docker-Image nicht mehr zum Profil passen.",
    "message.actionRunning": "{label} laeuft...",
    "message.profileSaved": "Profil gespeichert.\n",
    "message.serverDeleted": "Server {id} geloescht.",
    "message.sent": "Gesendet",
    "message.error": "Fehler",
    "message.lastLogs": "--- letzte Logs ---",
    "message.pluginUpdateRunning": "Plugin-Update laeuft...",
    "message.pluginUpdateFailed": "Einige Plugins konnten nicht aktualisiert werden. Bitte Ausgabe pruefen; Neustart wird nicht automatisch angeboten, damit keine kaputten/alten JARs unbemerkt geladen werden.",
    "message.restartRunning": "Restart laeuft...",
    "message.noBackup": "Bitte erst ein Backup auswaehlen.",
    "message.restoreRunning": "Restore laeuft...\n{file}",
    "message.importNeedId": "Bitte eine neue Server-ID eintragen, z. B. survival-import.",
    "message.importRunning": "Import laeuft...\nBackup: {file}\nNeues Profil: {id}\nDer Restore kann je nach Weltgroesse dauern.",
    "message.importDone": "Import abgeschlossen.",
    "message.playerUnavailable": "Spielerliste nicht verfuegbar: {message}",
    "message.playersUpdated": "Spielerliste aktualisiert.",
    "message.versionsLoaded": "{count} Versionen geladen. Du kannst frei tippen oder rechts aus der Liste waehlen.",
    "message.versionsFailed": "Versionen konnten nicht geladen werden: {message}",
    "message.tpNeedsPlayers": "TP braucht Spieler und Zielspieler.",
    "message.giveNeedsItem": "Give braucht Spieler und Item.",
    "message.selectBackup": "Bitte erst ein Backup auswaehlen.",
    "message.noTextFile": "Keine Textdatei ausgewaehlt.",
    "message.fileLoaded": "Datei geladen: {path}",
    "message.folderNotChanged": "Datei-Browser nicht gewechselt.",
    "message.folderLoaded": "Ordner geladen: {path}",
    "message.selectFolderName": "Bitte Ordnernamen eintragen.",
    "message.selectRename": "Bitte Datei oder Ordner und neuen Namen waehlen.",
    "message.selectZip": "Bitte eine ZIP-Datei auswaehlen.",
    "message.selectZipType": "Bitte eine .zip Datei auswaehlen.",
    "message.zipRunning": "ZIP Upload laeuft: {name}",
    "message.selectedPath": "Ausgewaehlt: {path}",
    "message.notEditable": "Ausgewaehlt: {path}\nDiese Datei ist keine editierbare Text-Konfigdatei.",
    "message.noJars": "Keine .jar im Plugin-Ordner gefunden.",
    "message.installedPlugins": "Installierte Plugins:\n{content}",
    "option.version": "Version waehlen...",
    "option.auto": "Auto",
    "option.proxy": "Proxy",
    "option.backend": "Backend",
    "empty.folders": "Keine Ordner",
    "empty.files": "Keine Dateien",
    "placeholder.playerName": "Spielername manuell",
    "placeholder.targetPlayer": "Zielspieler fuer TP",
    "placeholder.giveItem": "minecraft:diamond",
    "placeholder.importId": "neue-server-id",
    "placeholder.filePath": "Ordnerpfad, leer = DATA_DIR",
    "placeholder.newFolder": "neuer Ordner",
    "placeholder.fileEditorPath": "Keine Textdatei ausgewaehlt",
    "placeholder.fileContent": "Text-Konfigdatei rechts anklicken, z. B. velocity.toml, forwarding.secret, server.properties oder Plugin-Konfigs",
    "placeholder.rename": "neuer Name",
    "placeholder.rcon": "say Hallo Welt / list / save-all",
    "title.blueMap": "BlueMap",
    "help.title": "Hilfe",
    "help.text": `Wichtig
Speichern sichert das WebUI-Profil. Anwenden erstellt den Container immer neu. Start/Restart erstellt ihn automatisch neu, wenn RAM, Version, Ports, Docker-Image, RCON oder Volumes nicht mehr zum Profil passen.
Lokale Version laden verwirft ungespeicherte Profil-Aenderungen und laedt die gespeicherte Profilversion neu.
Das Spigot/WebUI-Icon ist als Header-Icon, Browser-Favicon und App-Icon eingebunden. Die PNG-Dateien liegen im Repository unter docs/assets.
Stop haelt den Container an und loescht ihn danach. Profil und Daten bleiben erhalten; Start oder Anwenden erstellt den Container neu.
Deaktivieren entfernt nur den Docker-Container und markiert das Profil als deaktiviert. Profil und Daten bleiben erhalten, der Host-Port wird frei.
Deaktivierte Profile werden links ausgegraut und als deaktiviert angezeigt. Ihre Ports blockieren andere Profile nicht mehr.
Bei deaktivierten Profilen wird aus dem Button Deaktivieren automatisch Aktivieren. Aktivieren startet keinen Container, sondern nimmt das Profil nur wieder in Status- und Portpruefung auf.
Anwenden, Start oder Restart aktiviert ein deaktiviertes Profil wieder, wenn die Aktion erfolgreich ist.

Sprache
Die Sprachauswahl im Header uebersetzt die WebUI-Oberflaeche zwischen Deutsch und Englisch. Backend- und Shell-Ausgaben bleiben technisch und koennen weiterhin deutsch sein.

Profilfelder
ID: stabile interne Profil-ID und Dateiname. Nach dem Anlegen moeglichst nicht mehr aendern.
Name: Anzeigename in der WebUI.
Container: Docker-Containername, den die WebUI startet/stoppt und fuer Portpruefungen erkennt.
Datenverzeichnis: Host-Ordner, der bei Minecraft-Servern als /data und bei Proxy-Servern als /server gemountet wird. Wenn der Pfad spaeter korrigiert werden soll, neuen Pfad eintragen und Daten verschieben nutzen.
Typ: normale Minecraft-Typen nutzen itzg/minecraft-server. BungeeCord, Waterfall und Velocity nutzen automatisch itzg/mc-proxy.
Docker Image: bei leerem oder Standardwert setzt die WebUI das passende Image automatisch.
Netzwerk-Gruppe: gleicher Gruppenname verbindet einen Velocity-Proxy mit seinen Backend-Servern.
Netzwerk-Rolle: Auto erkennt Velocity als Proxy und normale Java-Server als Backend. Bei Sonderfaellen Proxy oder Backend manuell setzen.
Netzwerk-Alias: Name fuer Velocity-Befehle wie /server lobby. Leer nutzt die Profil-ID.
Default-Ziel: nur beim Velocity-Profil relevant; erster Zielserver fuer neue Spieler, z. B. lobby.

Velocity-Netzwerk
Alle Server derselben Netzwerk-Gruppe werden als Gruppe betrachtet. Es muss genau einen Velocity-Proxy und mindestens einen Backend-Server geben.
Netzwerk anwenden schreibt oder aktualisiert velocity.toml, forwarding.secret, server.properties und bei Paper/Purpur/Folia config/paper-global.yml. Ausserdem bekommen die Profile Docker-Netzwerkdaten, damit die Container sich per Containername im gemeinsamen Docker-Netzwerk erreichen.
Danach die betroffenen Server per Anwenden oder Restart neu erstellen, damit Docker-Netzwerk und Konfigdateien aktiv sind.
Der Assistent setzt das moderne Velocity-Forwarding und deaktiviert online-mode auf den Backend-Servern. Bedrock/Geyser-Chat oder Spezial-Plugin-Konfigs bleiben vorerst manuelle Feineinstellung.

Ports und RCON
Host-Port: oeffentlicher Java-/Proxy-Port auf dem Host. Minecraft nutzt intern 25565. Velocity nutzt den bind-Port aus velocity.toml, sonst 25565. BungeeCord/Waterfall nutzen intern 25577.
Extra Ports: mehrere Ports mit Komma, Leerzeichen oder Zeilenumbruch trennen, z. B. 19132:19132/udp, 24454:24454/udp.
RCON Host-Port: eindeutiger Host-Port je Server, z. B. 25575, 25576.
RCON Container-Port: kann meist 25575 bleiben.
Die Portpruefung ignoriert nur Profile, die wirklich deaktiviert sind. Aktive Profile mit gleichem Host-Port blockieren weiterhin, damit nicht versehentlich zwei Server auf denselben Port starten.

Version und RAM
Memory: allgemeiner RAM-Wert fuer das Docker-Image. Eingaben wie 1GB werden als 1G gespeichert.
Min/Max RAM: optional; leer lassen, wenn MEMORY reichen soll.
Bei Velocity/BungeeCord/Waterfall ist LATEST meist sinnvoller als Minecraft-Versionsnummern.

BlueMap
BlueMap URL: optionaler interner Upstream fuer den WebUI-Proxy, z. B. http://127.0.0.1:8100/.
Leer lassen nutzt lokal 127.0.0.1:8100 oder den Host-Port aus Extra Ports wie 8123:8100/tcp.
BlueMap oeffnen/einbetten laeuft ueber /map/SERVER_ID/ und funktioniert dadurch auch hinter einem Reverse Proxy zur WebUI.

Backups und Dateien
Backups liegen zentral im Backup-Ordner und enthalten den Containernamen im Dateinamen.
Waehrend ein Backup laeuft, zeigt die WebUI den Fortschritt aus dem Aktionslog an, inklusive aktueller Archivgroesse und verstrichener Zeit.
Lokale Daten loeschen entfernt Container und Datenordner, laesst aber Profil und zentrale Backups stehen. Deaktivieren entfernt nur den Container und markiert das Profil als deaktiviert. Server loeschen entfernt Profil, Docker-Container und Datenordner.
Ordner fuer Welten am besten als ZIP hochladen; die WebUI entpackt das ZIP in den aktuellen Ordner.
Im Datei-Browser oeffnet ein Klick auf den Ordnernamen den Ordner. Auswahl markiert einen Ordner fuer Umbenennen oder Loeschen. Zurueck geht eine Ebene nach oben.

Plugins
Eine Zeile in plugins.txt besteht aus Name und Quelle. # deaktiviert eine Zeile.
Bei modrinth:<slug> waehlt die WebUI passend zum Server-Typ den Loader, z. B. velocity fuer Velocity und paper/spigot/bukkit fuer Paper. Wenn kein passender Loader gefunden wird, gibt es eine Fehlermeldung statt einer falschen JAR.

Dateien und Konfigs
Der Datei-Browser zeigt Ordner links und Dateien rechts. Ein Klick auf einen Ordner oeffnet ihn, Zurueck geht eine Ebene hoch.
Text-Konfigdateien wie velocity.toml, forwarding.secret, server.properties, .yml, .json, .conf oder .txt werden heller markiert. Ein Klick auf so eine Datei laedt sie direkt in den Editor darunter; Inhalt neu laden aktualisiert die geoeffnete Datei, Datei speichern schreibt sie zurueck.
Nicht editierbare Dateien wie .jar oder grosse Weltdaten werden nur fuer Umbenennen oder Loeschen ausgewaehlt.`
  },
  en: {
    "button.help": "Help",
    "button.new": "New",
    "button.save": "Save",
    "button.reloadProfile": "Reload saved profile",
    "button.loadVersions": "Load versions",
    "button.moveData": "Move data",
    "button.applyNetwork": "Apply network",
    "button.apply": "Apply",
    "button.start": "Start",
    "button.stop": "Stop",
    "button.restart": "Restart",
    "button.disable": "Disable",
    "button.enable": "Enable",
    "button.backup": "Backup",
    "button.deleteData": "Delete local data",
    "button.deleteServer": "Delete server",
    "button.refreshLogs": "Load logs",
    "button.liveLogs": "Live logs",
    "button.stopLive": "Stop live",
    "button.openMap": "Open BlueMap",
    "button.embedMap": "Embed BlueMap",
    "button.refreshPlayers": "Load players",
    "button.tp": "TP to player",
    "button.give": "Give",
    "button.kick": "Kick",
    "button.ban": "Ban",
    "button.pardon": "Pardon",
    "button.send": "Send",
    "button.restore": "Restore",
    "button.importBackup": "Import as new server",
    "button.saveProperties": "Save server.properties",
    "button.reload": "Reload",
    "button.savePlugins": "Save plugins",
    "button.updatePlugins": "Update plugins",
    "button.uploadPlugin": "Upload manual plugin",
    "button.deleteManualPlugin": "Delete manual plugin",
    "button.refreshInstalledPlugins": "Load installed plugins",
    "button.deleteInstalledPlugin": "Delete installed plugin",
    "button.loadFolder": "Load folder",
    "button.back": "Back",
    "button.makeFolder": "Create folder",
    "button.reloadFile": "Reload content",
    "button.saveFile": "Save file",
    "button.rename": "Rename",
    "button.delete": "Delete",
    "button.select": "Select",
    "button.uploadZip": "Extract ZIP here",
    "button.close": "Close",
    "section.portCheck": "Port check",
    "section.velocityNetwork": "Velocity network",
    "section.players": "Players",
    "section.rcon": "RCON console",
    "section.backups": "Backups",
    "section.properties": "server.properties",
    "section.plugins": "plugins.txt",
    "section.files": "Files",
    "section.folders": "Folders",
    "field.id": "ID",
    "field.name": "Name",
    "field.container": "Container",
    "field.memory": "RAM (MEMORY)",
    "field.initMemory": "Min RAM",
    "field.maxMemory": "Max RAM",
    "field.type": "Type",
    "field.version": "Version",
    "field.paperChannel": "Paper channel",
    "field.hostPort": "Host port",
    "field.dataDir": "Data directory",
    "field.networkGroup": "Network group",
    "field.networkRole": "Network role",
    "field.networkAlias": "Network alias",
    "field.networkDefault": "Default target",
    "field.extraPorts": "Extra ports (comma, space or newline)",
    "field.mapUrl": "BlueMap URL",
    "field.backupRoot": "Central backup folder",
    "field.dockerImage": "Docker image",
    "field.rconHostPort": "RCON host port",
    "field.rconContainerPort": "RCON container port",
    "field.rconPassword": "RCON password",
    "help.id": "Stable internal profile ID and filename. Avoid changing it after creation.",
    "help.name": "Display name in the WebUI sidebar.",
    "help.container_name": "Docker container name used by the WebUI for start, stop and port checks.",
    "help.data_dir": "If you change the path later, use Move data so existing files are moved with it.",
    "help.network_group": "Same group name connects a Velocity proxy with its backend servers.",
    "help.network_role": "Auto detects Velocity as proxy and normal servers as backends. Set manually for special cases.",
    "help.network_alias": "Name for Velocity commands like /server lobby. Empty uses the profile ID.",
    "help.network_default": "Only relevant for Velocity profiles: first target server for new players, e.g. lobby.",
    "help.type": "Normal servers use itzg/minecraft-server. BungeeCord, Waterfall and Velocity automatically use itzg/mc-proxy.",
    "help.map_url": "Optional internal BlueMap upstream for the WebUI, e.g. http://127.0.0.1:8100/. Usually leave empty.",
    "help.docker_image": "Leave empty or use the default. Proxy types automatically use itzg/mc-proxy.",
    "check.eula": "Minecraft EULA accepted",
    "check.rcon": "RCON enabled",
    "check.backupBefore": "Backup first",
    "check.startAfter": "Start afterwards",
    "state.disabled": "disabled",
    "state.missing": "missing",
    "state.unknown": "unknown",
    "players.disabled": "Profile disabled",
    "players.unknown": "Players unknown",
    "dirty.profile": "Profile unsaved",
    "dirty.unsaved": "unsaved",
    "warnings.initial": "No check yet.",
    "warnings.none": "No obvious port conflicts found.",
    "warning.duplicatePort": "{label}: Port {port}/{proto} is used twice in this profile ({other}).",
    "warning.profileConflict": "{label}: Port {port}/{proto} conflicts with profile {profiles}.",
    "warning.hostOpen": "{label}: Port {port}/{proto} already appears to be open on the host.",
    "warning.dockerPublished": "{label}: Port {port}/{proto} is already published by Docker container {containers}.",
    "warning.ownContainer": "{label}: Port {port}/{proto} is used by this profile's own container {container}.",
    "warning.rconPassword": "rcon: RCON is enabled, but no password has been set yet.",
    "warning.eula": "eula: The Minecraft EULA has not been accepted yet; Apply will be blocked.",
    "network.none": "No network group set on the current profile.",
    "network.group": "Group: {group}",
    "network.proxy": "Proxy: {proxy}",
    "network.noProxy": "no Velocity proxy found",
    "network.default": "Default: {target}",
    "network.defaultAuto": "(Auto, prefers lobby)",
    "network.backends": "Backends:",
    "network.noBackends": "- no active backends found",
    "network.multiProxy": "Warning: More than one proxy in this group. Please mark only one Velocity proxy as proxy.",
    "network.confirm": "Configure Velocity network \"{group}\"?\n\nThe WebUI will update velocity.toml, forwarding.secret, server.properties, Paper forwarding and Docker network profile data. Afterwards recreate the group with Apply or Restart.",
    "network.needGroup": "Please enter and save a network group first.",
    "network.running": "Configuring Velocity network...",
    "network.done": "Velocity network configured.",
    "prompt.movePhrase": "MOVE",
    "prompt.moveData": "Move data directory?\n\nOld:\n{oldPath}\n\nNew:\n{target}\n\nThe Docker container will be removed. Profile and central backups stay intact.\n\nTo confirm, type exactly:\n{phrase}",
    "prompt.deleteDataPhrase": "DELETE DATA",
    "prompt.deleteData": "Really delete local data for this profile?\n\nData folder:\n{dataDir}\n\nThe Docker container and all files in the data folder will be deleted. Profile and central backups stay intact.\n\nTo confirm, type exactly:\n{phrase}",
    "prompt.discardProfile": "Discard unsaved profile changes and reload the saved profile?",
    "prompt.deleteServer": "Really delete server \"{name}\" ({id})?\n\nThe Docker container and data folder will also be deleted:\n{dataDir}",
    "prompt.discardPlugins": "Discard unsaved changes?",
    "prompt.updatePluginsUnsaved": "plugins.txt has unsaved changes. Save before updating? OK=saves, Cancel=discards.",
    "prompt.restartAfterPlugins": "Plugin updates have been loaded. Restart loads the new plugins. If you also changed version, RAM or ports, use Apply as well. Restart now?",
    "prompt.discardProperties": "Discard unsaved server.properties changes?",
    "prompt.deleteManualPlugin": "Delete {name}?",
    "prompt.deleteInstalledPlugin": "Delete {name} from DATA_DIR/plugins? The running server needs a restart afterwards.",
    "prompt.discardFile": "Discard unsaved file changes?",
    "prompt.deleteEntry": "Really delete {path}? This may remove worlds or configs.",
    "prompt.restore": "Restore this backup into the server? The container will be stopped.",
    "message.requestFailed": "Request failed",
    "message.noDataDir": "Please enter a new data directory.",
    "message.dataUnchanged": "The data directory is unchanged.",
    "message.movingData": "Moving data directory...",
    "message.dataMoved": "Data directory moved.",
    "message.profileReloaded": "Saved profile version loaded. Unsaved profile changes were discarded.",
    "message.saved": "Saved. Start/Restart recreates the container if RAM, ports, version or Docker image no longer match the profile.",
    "message.actionRunning": "{label} is running...",
    "message.profileSaved": "Profile saved.\n",
    "message.serverDeleted": "Server {id} deleted.",
    "message.sent": "Sent",
    "message.error": "Error",
    "message.lastLogs": "--- latest logs ---",
    "message.pluginUpdateRunning": "Plugin update is running...",
    "message.pluginUpdateFailed": "Some plugins could not be updated. Please check the output. Restart will not be offered automatically so broken or stale JARs do not get loaded unnoticed.",
    "message.restartRunning": "Restart is running...",
    "message.noBackup": "Please select a backup first.",
    "message.restoreRunning": "Restore is running...\n{file}",
    "message.importNeedId": "Please enter a new server ID, e.g. survival-import.",
    "message.importRunning": "Import is running...\nBackup: {file}\nNew profile: {id}\nRestore can take a while depending on world size.",
    "message.importDone": "Import complete.",
    "message.playerUnavailable": "Player list unavailable: {message}",
    "message.playersUpdated": "Player list refreshed.",
    "message.versionsLoaded": "{count} versions loaded. You can type freely or choose from the list on the right.",
    "message.versionsFailed": "Versions could not be loaded: {message}",
    "message.tpNeedsPlayers": "TP needs a player and a target player.",
    "message.giveNeedsItem": "Give needs a player and an item.",
    "message.selectBackup": "Please select a backup first.",
    "message.noTextFile": "No text file selected.",
    "message.fileLoaded": "File loaded: {path}",
    "message.folderNotChanged": "File browser was not changed.",
    "message.folderLoaded": "Folder loaded: {path}",
    "message.selectFolderName": "Please enter a folder name.",
    "message.selectRename": "Please select a file or folder and enter a new name.",
    "message.selectZip": "Please select a ZIP file.",
    "message.selectZipType": "Please select a .zip file.",
    "message.zipRunning": "ZIP upload is running: {name}",
    "message.selectedPath": "Selected: {path}",
    "message.notEditable": "Selected: {path}\nThis file is not an editable text config file.",
    "message.noJars": "No .jar files found in the plugin folder.",
    "message.installedPlugins": "Installed plugins:\n{content}",
    "option.version": "Choose version...",
    "option.auto": "Auto",
    "option.proxy": "Proxy",
    "option.backend": "Backend",
    "empty.folders": "No folders",
    "empty.files": "No files",
    "placeholder.playerName": "Player name manually",
    "placeholder.targetPlayer": "Target player for TP",
    "placeholder.giveItem": "minecraft:diamond",
    "placeholder.importId": "new-server-id",
    "placeholder.filePath": "Folder path, empty = DATA_DIR",
    "placeholder.newFolder": "new folder",
    "placeholder.fileEditorPath": "No text file selected",
    "placeholder.fileContent": "Click a text config file on the right, e.g. velocity.toml, forwarding.secret, server.properties or plugin configs",
    "placeholder.rename": "new name",
    "placeholder.rcon": "say Hello world / list / save-all",
    "title.blueMap": "BlueMap",
    "help.title": "Help",
    "help.text": `Important
Save only stores the WebUI profile. Apply always recreates the container. Start/Restart recreates it automatically when RAM, version, ports, Docker image, RCON or volumes no longer match the profile.
Reload saved profile discards unsaved profile changes and loads the saved profile version again.
The Spigot/WebUI icon is used as header icon, browser favicon and app icon. The PNG files live in docs/assets.
Stop stops the container and removes it afterwards. Profile and data remain; Start or Apply creates the container again.
Disable removes only the Docker container and marks the profile as disabled. Profile and data remain, the host port becomes free.
Disabled profiles are greyed out in the sidebar and shown as disabled. Their ports no longer block other profiles.
For disabled profiles the Disable button automatically becomes Enable. Enable does not start a container; it only includes the profile in status and port checks again.
Apply, Start or Restart enables a disabled profile again when the action succeeds.

Language
The language selector in the header switches the WebUI between German and English. Backend and shell output stay technical and may still be German.

Profile fields
ID: stable internal profile ID and filename. Avoid changing it after creation.
Name: display name in the WebUI.
Container: Docker container name used by the WebUI for start/stop and port checks.
Data directory: host folder mounted as /data for Minecraft servers and /server for proxy servers. If the path needs correction later, enter the new path and use Move data.
Type: normal Minecraft server types use itzg/minecraft-server. BungeeCord, Waterfall and Velocity automatically use itzg/mc-proxy.
Docker image: empty or default values are replaced with the matching image automatically.
Network group: same group name connects a Velocity proxy with its backend servers.
Network role: Auto detects Velocity as proxy and normal Java servers as backends. Set Proxy or Backend manually for special cases.
Network alias: name for Velocity commands like /server lobby. Empty uses the profile ID.
Default target: only relevant for Velocity profiles; first target server for new players, e.g. lobby.

Velocity network
All servers with the same network group are treated as one group. There must be exactly one Velocity proxy and at least one backend server.
Apply network writes or updates velocity.toml, forwarding.secret, server.properties and config/paper-global.yml for Paper/Purpur/Folia. Profiles also get Docker network data so containers can reach each other by container name.
Afterwards recreate affected servers with Apply or Restart so Docker network and config files are active.
The assistant enables modern Velocity forwarding and disables online-mode on backend servers. Bedrock/Geyser chat or special plugin configs remain manual fine tuning for now.

Ports and RCON
Host port: public Java/proxy port on the host. Minecraft uses 25565 internally. Velocity uses the bind port from velocity.toml, otherwise 25565. BungeeCord/Waterfall use 25577 internally.
Extra ports: separate multiple ports with comma, space or newline, e.g. 19132:19132/udp, 24454:24454/udp.
RCON host port: unique host port per server, e.g. 25575, 25576.
RCON container port: usually can stay 25575.
The port check ignores only profiles that are really disabled. Active profiles with the same host port still block each other.

Version and RAM
Memory: general RAM value for the Docker image. Inputs like 1GB are saved as 1G.
Min/Max RAM: optional; leave empty when MEMORY is enough.
For Velocity/BungeeCord/Waterfall, LATEST is usually more useful than Minecraft version numbers.

BlueMap
BlueMap URL: optional internal upstream for the WebUI proxy, e.g. http://127.0.0.1:8100/.
Empty uses local 127.0.0.1:8100 or the host port from a mapping like 8123:8100/tcp.
Open/Embed BlueMap runs through /map/SERVER_ID/ and therefore works behind a reverse proxy to the WebUI.

Backups and files
Backups live in the central backup folder and include the container name in the filename.
While a backup is running, the WebUI shows progress from the action log, including current archive size and elapsed time.
Delete local data removes container and data folder but keeps profile and central backups. Disable removes only the container and marks the profile disabled. Delete server removes profile, Docker container and data folder.
Upload world folders as ZIP files; the WebUI extracts the ZIP into the current folder.
In the file browser, clicking a folder name opens it. Select marks a folder for rename or delete. Back moves one level up.

Plugins
One line in plugins.txt consists of name and source. # disables a line.
For modrinth:<slug>, the WebUI chooses the loader matching the server type, e.g. velocity for Velocity and paper/spigot/bukkit for Paper. If no matching loader is found, the plugin reports an error instead of installing the wrong JAR.

Files and configs
The file browser shows folders on the left and files on the right. Clicking a folder opens it, Back moves one level up.
Text config files such as velocity.toml, forwarding.secret, server.properties, .yml, .json, .conf or .txt are highlighted. Clicking such a file loads it directly into the editor below; Reload content refreshes it, Save file writes it back.
Non-editable files such as .jar files or large world data are only selected for rename or delete.`
  }
};

function readStoredLanguage() {
  try {
    return window.localStorage?.getItem("mdwLanguage") || null;
  } catch {
    return null;
  }
}
function writeStoredLanguage(value) {
  try {
    window.localStorage?.setItem("mdwLanguage", value);
  } catch {}
}
const storedLang = readStoredLanguage();
let lang = storedLang || ((navigator.language || "").toLowerCase().startsWith("de") ? "de" : "en");
if (!I18N[lang]) lang = "en";

const $ = id => document.getElementById(id);
function t(key, vars = {}) {
  const value = I18N[lang]?.[key] ?? I18N.de[key] ?? key;
  return String(value).replace(/\{(\w+)\}/g, (_, name) => vars[name] ?? "");
}
function el(tag, attrs = {}, children = []) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(attrs)) {
    if (key === "class") node.className = value;
    else if (key === "text") node.textContent = value;
    else node.setAttribute(key, value);
  }
  for (const child of children) node.append(child);
  return node;
}
async function api(path, opt = {}) {
  const response = await fetch(path, { headers: { "content-type": "application/json" }, ...opt });
  const data = await response.json();
  if (!response.ok) throw new Error(data.error || t("message.requestFailed"));
  return data;
}
function setSelectorText(selector, key) {
  const node = document.querySelector(selector);
  if (node) node.textContent = t(key);
}
function setPlaceholder(id, key) {
  const node = $(id);
  if (node) node.placeholder = t(key);
}
function setHeadingWithSpan(spanId, key) {
  const span = $(spanId);
  if (span && span.parentNode && span.parentNode.firstChild) span.parentNode.firstChild.nodeValue = `${t(key)} `;
}
function applyLanguageStatic() {
  document.documentElement.lang = lang;
  if ($("languageSelect")) $("languageSelect").value = lang;
  const targets = [
    ["#helpButton", "button.help"], ["#newServer", "button.new"], ["#applyNetwork", "button.applyNetwork"],
    ["[data-action='apply']", "button.apply"], ["[data-action='start']", "button.start"], ["[data-action='stop']", "button.stop"],
    ["[data-action='restart']", "button.restart"], ["[data-action='backup']", "button.backup"], ["[data-action='delete-data']", "button.deleteData"],
    ["#deleteServer", "button.deleteServer"], ["#refreshLogs", "button.refreshLogs"], ["#liveLogs", liveTimer ? "button.stopLive" : "button.liveLogs"],
    ["#openMap", "button.openMap"], ["#embedMap", "button.embedMap"], ["#refreshPlayers", "button.refreshPlayers"],
    ["[data-rcon-shortcut='tp']", "button.tp"], ["[data-rcon-shortcut='give']", "button.give"], ["[data-rcon-shortcut='kick']", "button.kick"],
    ["[data-rcon-shortcut='ban']", "button.ban"], ["[data-rcon-shortcut='pardon']", "button.pardon"], ["#sendRcon", "button.send"],
    ["#restoreBackup", "button.restore"], ["#importBackup", "button.importBackup"], ["#saveProperties", "button.saveProperties"],
    ["#reloadProperties", "button.reload"], ["#savePlugins", "button.savePlugins"], ["#reloadPlugins", "button.reloadProfile"],
    ["#updatePlugins", "button.updatePlugins"], ["#uploadPlugin", "button.uploadPlugin"], ["#deleteManualPlugin", "button.deleteManualPlugin"],
    ["#refreshInstalledPlugins", "button.refreshInstalledPlugins"], ["#deleteInstalledPlugin", "button.deleteInstalledPlugin"],
    ["#loadFiles", "button.loadFolder"], ["#upFiles", "button.back"], ["#makeFolder", "button.makeFolder"],
    ["#reloadFileContent", "button.reloadFile"], ["#saveFileContent", "button.saveFile"], ["#renameEntry", "button.rename"],
    ["#deleteEntry", "button.delete"], ["#uploadZip", "button.uploadZip"], ["#closeHelp", "button.close"],
    [".content > .box:nth-of-type(1) > h2", "section.portCheck"], [".content > .box:nth-of-type(2) > h2", "section.velocityNetwork"],
    [".content > .box:nth-of-type(4) > h2", "section.rcon"], [".content > .box:nth-of-type(5) > h2", "section.backups"],
    [".file-pane:nth-child(1) h3", "section.folders"], [".file-pane:nth-child(2) h3", "section.files"]
  ];
  for (const [selector, key] of targets) setSelectorText(selector, key);
  setHeadingWithSpan("playerSummary", "section.players");
  setHeadingWithSpan("propertiesDirty", "section.properties");
  setHeadingWithSpan("pluginDirty", "section.plugins");
  setHeadingWithSpan("fileEditorDirty", "section.files");
  setPlaceholder("playerName", "placeholder.playerName");
  setPlaceholder("targetPlayer", "placeholder.targetPlayer");
  setPlaceholder("giveItem", "placeholder.giveItem");
  setPlaceholder("importId", "placeholder.importId");
  setPlaceholder("filePath", "placeholder.filePath");
  setPlaceholder("newFolderName", "placeholder.newFolder");
  setPlaceholder("fileEditorPath", "placeholder.fileEditorPath");
  setPlaceholder("fileContent", "placeholder.fileContent");
  setPlaceholder("renameName", "placeholder.rename");
  setPlaceholder("rconCommand", "placeholder.rcon");
  if ($("helpDialog")) $("helpDialog").querySelector("h2").textContent = t("help.title");
  if ($("helpText")) $("helpText").textContent = t("help.text");
  if ($("mapFrame")) $("mapFrame").title = t("title.blueMap");
  if ($("warnings") && Object.values(I18N).some(dict => $("warnings").textContent === dict["warnings.initial"])) $("warnings").textContent = t("warnings.initial");
  setPluginsDirty(pluginsDirty);
  setPropertiesDirty(propertiesDirty);
  setFileEditorDirty(fileEditorDirty);
  setConfigDirty(configDirty);
  updateProfileToggle();
}
function setLanguage(next) {
  if (!I18N[next]) return;
  lang = next;
  writeStoredLanguage(lang);
  applyLanguageStatic();
  renderServers();
  renderEditor();
  renderNetworkSummary();
  if (selected) checkPorts().catch(() => {});
}
function current() { return servers.find(server => server.id === selected) || {}; }
function currentDisabled() {
  const server = current();
  const status = server.status || {};
  return !!server.disabled || !!status.disabled || status.state === "deaktiviert" || status.state === "disabled";
}
function displayState(state, disabled) {
  if (disabled) return t("state.disabled");
  if (state === "missing") return t("state.missing");
  if (!state) return t("state.unknown");
  return state;
}
function updateProfileToggle() {
  const button = $("profileToggle");
  if (!button) return;
  const disabled = currentDisabled();
  button.disabled = !selected;
  button.dataset.action = disabled ? "enable" : "disable";
  button.textContent = disabled ? t("button.enable") : t("button.disable");
  button.className = disabled ? "primary" : "";
}
async function loadServers() {
  servers = await api("/api/servers");
  if (!servers.some(server => server.id === selected)) selected = servers[0]?.id || null;
  renderServers();
  renderEditor();
  renderNetworkSummary();
  await refreshDetails();
}
function selectServer(serverId) {
  if (serverId === selected) return;
  selected = serverId;
  setConfigDirty(false);
  renderServers();
  renderEditor();
  renderNetworkSummary();
  refreshDetails();
}
function renderServers() {
  const box = $("servers");
  box.innerHTML = "";
  for (const server of servers) {
    const status = server.status || {};
    const players = server.players || {};
    const disabled = !!server.disabled || !!status.disabled || status.state === "deaktiviert" || status.state === "disabled";
    const playerText = disabled ? t("players.disabled") : (players.max ? `${players.online ?? 0}/${players.max} ${t("section.players")}` : (players.online != null ? `${players.online} ${t("section.players")}` : t("players.unknown")));
    const stateText = displayState(status.state, disabled);
    const button = el("button", { class: `server${server.id === selected ? " active" : ""}${disabled ? " disabled" : ""}`, "data-server-id": server.id }, [
      el("strong", { text: server.name || server.id }),
      el("span", { class: "muted", text: `${server.container_name} :${server.host_port}` }),
      el("span", { class: "muted", text: playerText }),
      el("span", { class: "status" }, [el("span", { class: `dot${status.running && !disabled ? " running" : ""}` }), document.createTextNode(stateText)])
    ]);
    button.onclick = () => selectServer(button.getAttribute("data-server-id"));
    box.append(button);
  }
}
function checkbox(name, label, checked) {
  const box = el("input", { type: "checkbox", name });
  box.checked = !!checked;
  return el("label", {}, [box, document.createTextNode(label)]);
}
function fieldLabel(cls, label, key, input, extra = []) {
  const kids = [document.createTextNode(label), ...extra];
  const help = t(`help.${key}`);
  if (help !== `help.${key}`) kids.push(el("span", { class: "field-help", text: help }));
  return el("label", { class: cls || "" }, kids);
}
function renderEditor() {
  const form = $("editor");
  const server = current();
  form.innerHTML = "";
  for (const [key, labelKey, cls] of fields) {
    const label = t(labelKey);
    const input = el((key === "type" || key === "network_role") ? "select" : "input", { name: key, value: server[key] || "" });
    if (key === "version") input.setAttribute("list", "versionOptions");
    if (key === "rcon_password") input.type = "password";
    if (key === "type") {
      for (const option of serverTypes) {
        const node = el("option", { value: option, text: option });
        if ((server[key] || "PAPER") === option) node.selected = true;
        input.append(node);
      }
      input.onchange = () => { applyTypeDefaults(input.value); loadVersions(input.value, true); };
    }
    if (key === "network_role") {
      for (const [value, textKey] of [["", "option.auto"], ["proxy", "option.proxy"], ["backend", "option.backend"]]) {
        const node = el("option", { value, text: t(textKey) });
        if ((server[key] || "") === value) node.selected = true;
        input.append(node);
      }
    }
    if (key === "version") {
      const select = el("select", { id: "versionSelect", "aria-label": t("option.version") });
      const button = el("button", { type: "button", text: t("button.loadVersions") });
      select.onchange = () => { if (select.value) { input.value = select.value; setConfigDirty(true); } };
      button.onclick = () => loadVersions(formData().type || "PAPER", true);
      form.append(fieldLabel(cls, label, key, input, [el("div", { class: "field-row" }, [input, select, button])]));
    } else if (key === "data_dir") {
      const button = el("button", { type: "button", text: t("button.moveData") });
      button.onclick = () => moveDataDir();
      form.append(fieldLabel(cls, label, key, input, [el("div", { class: "field-row" }, [input, button])]));
    } else {
      form.append(fieldLabel(cls, label, key, input, [input]));
    }
  }
  form.append(el("div", { class: "checks full" }, [
    checkbox("eula_accepted", t("check.eula"), server.eula_accepted),
    checkbox("rcon_enabled", t("check.rcon"), server.rcon_enabled),
    checkbox("backup_before_apply", t("check.backupBefore"), server.backup_before_apply),
    checkbox("start_after_apply", t("check.startAfter"), server.start_after_apply ?? true)
  ]));
  const saveButton = el("button", { class: "primary", type: "submit", text: t("button.save") });
  const reloadButton = el("button", { type: "button", text: t("button.reloadProfile") });
  reloadButton.onclick = () => reloadCurrentProfile();
  form.append(el("div", { class: "actions full profile-actions" }, [saveButton, reloadButton]));
  setConfigDirty(configDirty);
  updateProfileToggle();
  loadVersions(server.type || "PAPER");
}
function applyTypeDefaults(type) {
  const image = $("editor").querySelector('[name="docker_image"]');
  const version = $("editor").querySelector('[name="version"]');
  if (!image) return;
  if (proxyTypes.has(String(type).toUpperCase())) {
    if (!image.value || image.value === "itzg/minecraft-server") image.value = "itzg/mc-proxy";
    if (version && !version.value) version.value = "LATEST";
  } else if (!image.value || image.value === "itzg/mc-proxy") {
    image.value = "itzg/minecraft-server";
  }
  setConfigDirty(true);
}
function formData() {
  const form = new FormData($("editor"));
  const data = {};
  for (const [key] of fields) data[key] = form.get(key);
  for (const key of ["eula_accepted", "rcon_enabled", "backup_before_apply", "start_after_apply"]) data[key] = form.get(key) === "on";
  data.disabled = !!current().disabled;
  return data;
}
async function saveCurrentProfile() {
  const saved = await api("/api/servers", { method: "POST", body: JSON.stringify(formData()) });
  selected = saved.id;
  setConfigDirty(false);
  return saved;
}
async function reloadCurrentProfile() {
  if (!selected) return;
  if (configDirty && !confirm(t("prompt.discardProfile"))) return;
  setConfigDirty(false);
  await loadServers();
  showOutput(t("message.profileReloaded"));
}
async function moveDataDir() {
  const data = formData();
  const server = current();
  const oldPath = server.data_dir || "";
  const target = (data.data_dir || "").trim();
  if (!selected) return;
  if (!target) return showOutput(t("message.noDataDir"));
  if (target === oldPath) return showOutput(t("message.dataUnchanged"));
  const phrase = t("prompt.movePhrase");
  const answer = prompt(t("prompt.moveData", { oldPath: oldPath || "(leer)", target, phrase }));
  if (answer !== phrase) return;
  showOutput(t("message.movingData"));
  const result = await api(`/api/servers/${selected}/move-data-dir`, { method: "POST", body: JSON.stringify({ target, profile: data }) });
  selected = result.server?.id || selected;
  setConfigDirty(false);
  await loadServers();
  showOutput([result.message || t("message.dataMoved"), ...(result.details || [])].join("\n"));
}
function cleanNetworkAlias(server) {
  return String((server && server.network_alias) || server?.id || server?.name || "server").trim().toLowerCase().replace(/[^a-z0-9_.-]+/g, "-").replace(/^[-_.]+|[-_.]+$/g, "") || "server";
}
function roleOf(server) {
  const role = String(server?.network_role || "").trim().toLowerCase();
  if (role === "proxy" || role === "backend") return role;
  return String(server?.type || "").toUpperCase() === "VELOCITY" ? "proxy" : "backend";
}
function renderNetworkSummary() {
  const box = $("networkSummary");
  if (!box) return;
  const server = current();
  const group = String(server.network_group || "").trim();
  if (!group) {
    box.textContent = t("network.none");
    return;
  }
  const members = servers.filter(item => String(item.network_group || "").trim() === group && !item.disabled);
  const proxies = members.filter(item => roleOf(item) === "proxy" || String(item.type || "").toUpperCase() === "VELOCITY");
  const proxy = proxies[0];
  const backends = members.filter(item => proxy && item.id !== proxy.id && roleOf(item) === "backend" && !proxyTypes.has(String(item.type || "").toUpperCase()));
  const lines = [
    t("network.group", { group }),
    t("network.proxy", { proxy: proxy ? `${proxy.name || proxy.id} (${proxy.container_name || "-"})` : t("network.noProxy") }),
    t("network.default", { target: proxy?.network_default || t("network.defaultAuto") }),
    t("network.backends")
  ];
  if (backends.length) {
    for (const backend of backends) lines.push(`- ${cleanNetworkAlias(backend)} -> ${backend.container_name || backend.id}:25565`);
  } else {
    lines.push(t("network.noBackends"));
  }
  if (proxies.length > 1) lines.push(t("network.multiProxy"));
  box.textContent = lines.join("\n");
}
async function applyNetwork() {
  try {
    if (configDirty) {
      await saveCurrentProfile();
      await loadServers();
    }
    const server = current();
    const group = String(server.network_group || "").trim();
    if (!selected) return;
    if (!group) return showOutput(t("network.needGroup"));
    if (!confirm(t("network.confirm", { group }))) return;
    showOutput(t("network.running"));
    const result = await api(`/api/servers/${selected}/network/apply`, { method: "POST", body: "{}" });
    await loadServers();
    showOutput([result.message || t("network.done"), ...(result.details || [])].join("\n"));
  } catch (err) {
    showOutput(err.message);
  }
}
$("editor").onsubmit = async event => {
  event.preventDefault();
  try {
    await saveCurrentProfile();
    await loadServers();
    showOutput(t("message.saved"));
  } catch (err) {
    showOutput(err.message);
  }
};
$("editor").oninput = async () => {
  setConfigDirty(true);
  try {
    const result = await api("/api/ports/check", { method: "POST", body: JSON.stringify(formData()) });
    showWarnings(result.warnings);
  } catch {}
};
$("newServer").onclick = () => {
  const id = `server-${servers.length + 1}`;
  servers.push({ id, name: id, container_name: `mc-${id}`, data_dir: `/opt/minecraft/${id}`, memory: "6G", type: "PAPER", version: "LATEST", paper_channel: "default", host_port: "25565", network_group: "", network_role: "", network_alias: "", network_default: "", rcon_enabled: true, rcon_host_port: String(25575 + servers.length), rcon_container_port: "25575", extra_ports: "", docker_image: "itzg/minecraft-server", start_after_apply: true });
  selected = id;
  setConfigDirty(true);
  renderServers();
  renderEditor();
  renderNetworkSummary();
  refreshDetails();
};
$("helpButton").onclick = () => $("helpDialog").showModal();
$("closeHelp").onclick = () => $("helpDialog").close();
$("applyNetwork").onclick = () => applyNetwork();
if ($("languageSelect")) $("languageSelect").onchange = event => setLanguage(event.target.value);

const liveActionLogActions = new Set(["apply", "backup", "start", "restart"]);
const actionLabelKeys = { apply: "button.apply", start: "button.start", stop: "button.stop", restart: "button.restart", disable: "button.disable", enable: "button.enable", backup: "button.backup", "delete-data": "button.deleteData" };
function actionLabel(action) { return t(actionLabelKeys[action] || action); }
async function runProfileAction(action) {
  let note = "";
  let poll = null;
  try {
    if (action === "delete-data") {
      const data = formData();
      const phrase = t("prompt.deleteDataPhrase");
      const answer = prompt(t("prompt.deleteData", { dataDir: data.data_dir || "(leer)", phrase }));
      if (answer !== phrase) return;
    }
    if (configDirty) {
      await saveCurrentProfile();
      note = t("message.profileSaved");
    }
    const serverId = selected;
    const label = actionLabel(action);
    showOutput(`${note}${t("message.actionRunning", { label })}`);
    const refreshLog = async () => {
      try {
        const log = await api(`/api/servers/${serverId}/action-log`);
        if (log.content) showOutput(`${note}${t("message.actionRunning", { label })}\n\n${log.content}`);
      } catch {}
    };
    if (liveActionLogActions.has(action)) {
      await refreshLog();
      poll = setInterval(refreshLog, 1000);
    }
    const result = await api(`/api/servers/${serverId}/action`, { method: "POST", body: JSON.stringify({ action }) });
    if (poll) {
      clearInterval(poll);
      poll = null;
    }
    showOutput(`${note}$ ${action}\nexit ${result.code}\n\n${result.stdout}\n${result.stderr}`);
    await loadServers();
  } catch (err) {
    if (poll) clearInterval(poll);
    showOutput(err.message);
  }
}
document.querySelectorAll("[data-action]").forEach(button => {
  button.onclick = async () => {
    if (!selected) return;
    await runProfileAction(button.dataset.action);
  };
});
$("deleteServer").onclick = async () => {
  const target = selected;
  const server = servers.find(item => item.id === target);
  if (!target || !server) return;
  if (!confirm(t("prompt.deleteServer", { name: server.name || target, id: target, dataDir: server.data_dir || "kein Datenordner" }))) return;
  const result = await api(`/api/servers/${encodeURIComponent(target)}`, { method: "DELETE" });
  servers = servers.filter(item => item.id !== target);
  selected = servers[0]?.id || null;
  await loadServers();
  $("result").textContent = [result.message || t("message.serverDeleted", { id: target }), ...(result.details || [])].join("\n");
};
$("refreshLogs").onclick = () => loadLogs();
$("liveLogs").onclick = () => {
  const button = $("liveLogs");
  if (liveTimer) {
    clearInterval(liveTimer);
    liveTimer = null;
    button.textContent = t("button.liveLogs");
    return;
  }
  loadLogs();
  liveTimer = setInterval(loadLogs, 2000);
  button.textContent = t("button.stopLive");
};
$("openMap").onclick = () => {
  const url = mapUrl(current());
  window.open(url, "_blank", "noopener");
};
$("embedMap").onclick = () => {
  const frame = $("mapFrame");
  frame.src = mapUrl(current());
  frame.hidden = false;
};
$("refreshPlayers").onclick = () => loadPlayers(true);
document.querySelectorAll("[data-rcon-shortcut]").forEach(button => {
  button.onclick = () => sendShortcut(button.dataset.rconShortcut);
});
$("sendRcon").onclick = async () => {
  const command = $("rconCommand").value.trim();
  if (!command) return;
  const result = await api(`/api/servers/${selected}/rcon`, { method: "POST", body: JSON.stringify({ command }) });
  const logs = await api(`/api/servers/${selected}/logs`);
  const tail = (logs.stdout || "").split("\n").slice(-10).join("\n");
  $("result").textContent = `${result.ok ? t("message.sent") : t("message.error")}: ${command}\nexit ${result.code}\n\n${result.stdout}\n${result.stderr}\n\n${t("message.lastLogs")}\n${tail}`;
  $("rconCommand").value = "";
};
$("plugins").oninput = () => setPluginsDirty(true);
if ($("serverProperties")) $("serverProperties").oninput = () => setPropertiesDirty(true);
function setPluginsDirty(value) {
  pluginsDirty = value;
  $("pluginDirty").textContent = value ? t("dirty.unsaved") : "";
  $("savePlugins").className = value ? "primary" : "";
}
function setPropertiesDirty(value) {
  propertiesDirty = value;
  $("propertiesDirty").textContent = value ? t("dirty.unsaved") : "";
  $("saveProperties").className = value ? "primary" : "";
}
function setConfigDirty(value) {
  configDirty = value;
  if ($("configDirty")) $("configDirty").textContent = value ? t("dirty.profile") : "";
  const button = $("editor").querySelector("button[type=submit]");
  if (button) button.className = value ? "primary warn" : "primary";
}
function showOutput(text) {
  $("result").textContent = text;
  $("result").scrollTop = $("result").scrollHeight;
}
function waitPaint() { return new Promise(resolve => setTimeout(resolve, 80)); }
$("savePlugins").onclick = async () => savePlugins();
async function savePlugins() {
  const text = $("plugins").value;
  const result = await api(`/api/servers/${selected}/plugins`, { method: "POST", body: JSON.stringify({ content: text }) });
  setPluginsDirty(false);
  showOutput(result.message);
}
$("reloadPlugins").onclick = async () => {
  if (!pluginsDirty || confirm(t("prompt.discardPlugins"))) await loadPlugins();
};
$("updatePlugins").onclick = async () => {
  if (pluginsDirty) {
    const save = confirm(t("prompt.updatePluginsUnsaved"));
    if (save) await savePlugins();
    else await loadPlugins();
  }
  showOutput(t("message.pluginUpdateRunning"));
  const poll = setInterval(async () => {
    try {
      const log = await api(`/api/servers/${selected}/action-log`);
      if (log.content) showOutput(`${t("message.pluginUpdateRunning")}\n\n${log.content}`);
    } catch {}
  }, 1000);
  let result;
  try {
    result = await api(`/api/servers/${selected}/action`, { method: "POST", body: JSON.stringify({ action: "plugins" }) });
  } finally {
    clearInterval(poll);
  }
  showOutput(`$ plugins\nexit ${result.code}\n\n${result.stdout}\n${result.stderr}`);
  await loadManualPlugins();
  await loadInstalledPlugins();
  await waitPaint();
  if (result.ok && confirm(t("prompt.restartAfterPlugins"))) {
    showOutput(`${$("result").textContent}\n\n${t("message.restartRunning")}`);
    const restart = await api(`/api/servers/${selected}/action`, { method: "POST", body: JSON.stringify({ action: "restart" }) });
    showOutput(`${$("result").textContent}\n\n$ restart\nexit ${restart.code}\n\n${restart.stdout}\n${restart.stderr}`);
    await loadServers();
  } else if (!result.ok) {
    showOutput(`${$("result").textContent}\n\n${t("message.pluginUpdateFailed")}`);
  }
};
$("saveProperties").onclick = async () => saveProperties();
async function saveProperties() {
  const text = $("serverProperties").value;
  const result = await api(`/api/servers/${selected}/properties`, { method: "POST", body: JSON.stringify({ content: text }) });
  setPropertiesDirty(false);
  showOutput(result.message);
}
$("reloadProperties").onclick = async () => {
  if (!propertiesDirty || confirm(t("prompt.discardProperties"))) await loadProperties();
};
$("uploadPlugin").onclick = async () => {
  const file = $("manualPluginFile").files[0];
  if (!file) return;
  const data = await file.arrayBuffer();
  let binary = "";
  new Uint8Array(data).forEach(byte => binary += String.fromCharCode(byte));
  const result = await api(`/api/servers/${selected}/manual-plugins`, { method: "POST", body: JSON.stringify({ name: file.name, content: btoa(binary) }) });
  $("result").textContent = result.message;
  await loadManualPlugins();
};
$("deleteManualPlugin").onclick = async () => {
  const name = $("manualPlugins").value;
  if (!name || !confirm(t("prompt.deleteManualPlugin", { name }))) return;
  const result = await api(`/api/servers/${selected}/manual-plugins/${encodeURIComponent(name)}`, { method: "DELETE" });
  $("result").textContent = result.message;
  await loadManualPlugins();
};
$("refreshInstalledPlugins").onclick = () => loadInstalledPlugins(true);
$("deleteInstalledPlugin").onclick = async () => {
  const name = $("installedPluginSelect").value;
  if (!name || !confirm(t("prompt.deleteInstalledPlugin", { name }))) return;
  const result = await api(`/api/servers/${selected}/installed-plugins/${encodeURIComponent(name)}`, { method: "DELETE" });
  $("result").textContent = result.message;
  await loadInstalledPlugins(true);
};
$("loadFiles").onclick = () => loadFiles(true);
$("upFiles").onclick = () => goUpFiles();
$("fileContent").oninput = () => setFileEditorDirty(true);
$("reloadFileContent").onclick = () => loadFileContent();
$("saveFileContent").onclick = () => saveFileContent();
$("makeFolder").onclick = () => makeFolder();
$("renameEntry").onclick = () => renameEntry();
$("deleteEntry").onclick = () => deleteEntry();
$("uploadZip").onclick = () => uploadZip();
$("restoreBackup").onclick = async () => {
  const file = $("backups").value;
  if (!file) return showOutput(t("message.selectBackup"));
  if (!confirm(t("prompt.restore"))) return;
  showOutput(t("message.restoreRunning", { file }));
  const result = await api(`/api/servers/${selected}/restore`, { method: "POST", body: JSON.stringify({ file }) });
  showOutput(`$ restore\nexit ${result.code}\n\n${result.stdout}\n${result.stderr}`);
};
$("importBackup").onclick = async () => {
  const file = $("backups").value;
  const id = $("importId").value.trim();
  if (!file) return showOutput(t("message.noBackup"));
  if (!id) return showOutput(t("message.importNeedId"));
  showOutput(t("message.importRunning", { file, id }));
  const result = await api("/api/backups/import", { method: "POST", body: JSON.stringify({ file, id }) });
  const details = result.result ? `\n\n$ restore\nexit ${result.result.code}\n\n${result.result.stdout}\n${result.result.stderr}` : "";
  showOutput(`${result.message || t("message.importDone")}${details}`);
  selected = id;
  setConfigDirty(false);
  await loadServers();
};
async function refreshDetails() {
  if (!selected) return;
  await Promise.all([loadLogs(), loadPlugins(), loadProperties(), loadManualPlugins(), loadInstalledPlugins(), loadFiles(), loadBackups(), loadPlayers(), checkPorts()]);
}
async function loadLogs() {
  const result = await api(`/api/servers/${selected}/logs`);
  $("log").textContent = result.stdout || result.stderr || "";
}
async function loadPlugins() {
  const result = await api(`/api/servers/${selected}/plugins`);
  $("plugins").value = result.content || "";
  setPluginsDirty(false);
}
async function loadProperties() {
  const result = await api(`/api/servers/${selected}/properties`);
  $("serverProperties").value = result.content || "";
  setPropertiesDirty(false);
}
async function loadManualPlugins() {
  const result = await api(`/api/servers/${selected}/manual-plugins`);
  const box = $("manualPlugins");
  box.innerHTML = "";
  for (const name of result.plugins) box.append(el("option", { value: name, text: name }));
}
async function loadInstalledPlugins(showResult = false) {
  const result = await api(`/api/servers/${selected}/installed-plugins`);
  const select = $("installedPluginSelect");
  select.innerHTML = "";
  for (const plugin of result.plugins || []) select.append(el("option", { value: plugin.name, text: plugin.name }));
  const text = (result.plugins || []).map(plugin => `${plugin.name} (${Math.round((plugin.size || 0) / 1024)} KiB)`).join("\n");
  $("installedPlugins").textContent = text || t("message.noJars");
  if (showResult) showOutput(t("message.installedPlugins", { content: $("installedPlugins").textContent }));
}
function setFileEditorDirty(value) {
  fileEditorDirty = value;
  $("fileEditorDirty").textContent = value ? t("dirty.unsaved") : "";
  $("saveFileContent").className = value ? "primary" : "";
}
function setFileEditorPath(path) {
  fileEditorPath = path || "";
  $("fileEditorPath").value = fileEditorPath;
}
function discardFileEditorChanges() {
  if (fileEditorDirty && !confirm(t("prompt.discardFile"))) return false;
  if (fileEditorDirty) {
    $("fileContent").value = "";
    setFileEditorPath("");
    setFileEditorDirty(false);
  }
  return true;
}
function refreshFileSelectionMarks() {
  document.querySelectorAll(".file-pick.selected,.file-entry.selected").forEach(button => button.classList.remove("selected"));
  document.querySelectorAll("[data-path]").forEach(button => {
    if (button.dataset.path === selectedDataEntryPath) button.classList.add("selected");
  });
}
async function loadFileContent(path = null) {
  const target = path || fileEditorPath;
  if (!target) return showOutput(t("message.noTextFile"));
  if (fileEditorDirty && !confirm(t("prompt.discardFile"))) {
    refreshFileSelectionMarks();
    return false;
  }
  const result = await api(`/api/servers/${selected}/file-content?path=${encodeURIComponent(target)}`);
  $("fileContent").value = result.content || "";
  setFileEditorPath(result.path || target);
  setFileEditorDirty(false);
  selectedDataEntryPath = fileEditorPath;
  refreshFileSelectionMarks();
  showOutput(t("message.fileLoaded", { path: fileEditorPath }));
  return true;
}
async function saveFileContent() {
  if (!fileEditorPath) return showOutput(t("message.noTextFile"));
  const result = await api(`/api/servers/${selected}/file-content`, { method: "POST", body: JSON.stringify({ path: fileEditorPath, content: $("fileContent").value }) });
  setFileEditorDirty(false);
  showOutput(result.message);
}
function fileSize(size) { return `${Math.round((size || 0) / 1024)} KiB`; }
function selectDataEntry(path) {
  selectedDataEntryPath = path || "";
  refreshFileSelectionMarks();
}
function selectedDataEntry() { return selectedDataEntryPath; }
async function openFolder(path) {
  if (!discardFileEditorChanges()) return showOutput(t("message.folderNotChanged"));
  $("filePath").value = path || "";
  await loadFiles(true);
}
async function loadFiles(showResult = false, pathOverride = null) {
  const path = pathOverride ?? $("filePath").value.trim();
  const result = await api(`/api/servers/${selected}/files?path=${encodeURIComponent(path)}`);
  const folderBox = $("fileFolders");
  const fileBox = $("fileEntries");
  selectedDataEntryPath = "";
  $("filePath").value = result.cwd || "";
  folderBox.innerHTML = "";
  fileBox.innerHTML = "";
  const entries = result.entries || [];
  const folders = entries.filter(entry => entry.type === "dir");
  const files = entries.filter(entry => entry.type === "file");
  for (const folder of folders) {
    const open = el("button", { type: "button", class: "file-open", text: folder.name });
    const pick = el("button", { type: "button", class: "file-pick", text: t("button.select") || "Auswahl" });
    open.onclick = () => openFolder(folder.path);
    pick.dataset.path = folder.path;
    pick.onclick = () => { selectDataEntry(folder.path); showOutput(t("message.selectedPath", { path: folder.path })); };
    folderBox.append(el("div", { class: "file-row" }, [open, pick]));
  }
  if (!folders.length) folderBox.append(el("div", { class: "muted file-empty", text: t("empty.folders") }));
  for (const file of files) {
    const button = el("button", { type: "button", class: `file-open file-entry${file.editable ? " config-file" : ""}`, text: `${file.name} (${fileSize(file.size)})` });
    button.dataset.path = file.path;
    button.onclick = async () => {
      selectDataEntry(file.path);
      if (file.editable) await loadFileContent(file.path);
      else showOutput(t("message.notEditable", { path: file.path }));
    };
    fileBox.append(button);
  }
  if (!files.length) fileBox.append(el("div", { class: "muted file-empty", text: t("empty.files") }));
  if (showResult) showOutput(t("message.folderLoaded", { path: result.cwd || "DATA_DIR" }));
}
function goUpFiles() {
  if (!discardFileEditorChanges()) return showOutput(t("message.folderNotChanged"));
  const path = $("filePath").value.trim().split("/").filter(Boolean);
  path.pop();
  $("filePath").value = path.join("/");
  loadFiles(true);
}
async function makeFolder() {
  const base = $("filePath").value.trim();
  const name = $("newFolderName").value.trim();
  if (!name) return showOutput(t("message.selectFolderName"));
  const path = [base, name].filter(Boolean).join("/");
  const result = await api(`/api/servers/${selected}/files`, { method: "POST", body: JSON.stringify({ op: "mkdir", path }) });
  showOutput(result.message);
  $("newFolderName").value = "";
  await loadFiles();
}
async function renameEntry() {
  const path = selectedDataEntry();
  const name = $("renameName").value.trim();
  if (!path || !name) return showOutput(t("message.selectRename"));
  const result = await api(`/api/servers/${selected}/files`, { method: "POST", body: JSON.stringify({ op: "rename", path, name }) });
  if (path === fileEditorPath) setFileEditorPath(result.path);
  showOutput(result.message);
  $("renameName").value = "";
  await loadFiles();
}
async function deleteEntry() {
  const path = selectedDataEntry();
  if (!path || !confirm(t("prompt.deleteEntry", { path }))) return;
  const result = await api(`/api/servers/${selected}/files`, { method: "POST", body: JSON.stringify({ op: "delete", path }) });
  if (path === fileEditorPath) {
    $("fileContent").value = "";
    setFileEditorPath("");
    setFileEditorDirty(false);
  }
  showOutput(result.message);
  await loadFiles();
}
async function uploadZip() {
  const file = $("zipUpload").files[0];
  if (!file) return showOutput(t("message.selectZip"));
  if (!file.name.toLowerCase().endsWith(".zip")) return showOutput(t("message.selectZipType"));
  const data = await file.arrayBuffer();
  let binary = "";
  new Uint8Array(data).forEach(byte => binary += String.fromCharCode(byte));
  showOutput(t("message.zipRunning", { name: file.name }));
  const result = await api(`/api/servers/${selected}/files`, { method: "POST", body: JSON.stringify({ op: "upload-zip", target: $("filePath").value.trim(), name: file.name, content: btoa(binary) }) });
  showOutput(result.message);
  $("zipUpload").value = "";
  await loadFiles();
}
async function loadBackups() {
  const result = await api(`/api/servers/${selected}/backups`);
  const box = $("backups");
  box.innerHTML = "";
  for (const backup of result.backups) box.append(el("option", { value: backup.path, text: backup.name }));
}
async function loadPlayers(showResult = false) {
  try {
    const result = await api(`/api/servers/${selected}/players`);
    const server = current();
    server.players = result;
    renderServers();
    const box = $("players");
    box.innerHTML = "";
    for (const name of result.players || []) box.append(el("option", { value: name, text: name }));
    $("playerSummary").textContent = result.max ? `${result.online}/${result.max} online` : `${result.online ?? 0} online`;
    if (showResult) $("result").textContent = result.raw || t("message.playersUpdated");
  } catch (err) {
    $("playerSummary").textContent = t("message.playerUnavailable", { message: err.message });
  }
}
async function loadVersions(type, showResult = false) {
  const box = $("versionOptions");
  const select = $("versionSelect");
  box.innerHTML = "";
  if (select) select.innerHTML = "";
  try {
    const result = await api(`/api/versions?type=${encodeURIComponent(type || "PAPER")}`);
    if (select) select.append(el("option", { value: "", text: t("option.version") }));
    for (const version of result.versions) {
      box.append(el("option", { value: version }));
      if (select) select.append(el("option", { value: version, text: version }));
    }
    if (showResult) showOutput(t("message.versionsLoaded", { count: result.versions.length }));
  } catch (err) {
    if (showResult) showOutput(t("message.versionsFailed", { message: err.message }));
  }
}
function selectedPlayer() { return $("players").value.trim() || $("playerName").value.trim(); }
async function sendShortcut(kind) {
  const player = selectedPlayer();
  const target = $("targetPlayer").value.trim();
  const item = $("giveItem").value.trim();
  const amount = $("giveAmount").value.trim() || "1";
  let command = "";
  if (kind === "tp") {
    if (!player || !target) return $("result").textContent = t("message.tpNeedsPlayers");
    command = `tp ${player} ${target}`;
  }
  if (kind === "give") {
    if (!player || !item) return $("result").textContent = t("message.giveNeedsItem");
    command = `give ${player} ${item} ${amount}`;
  }
  if (kind === "kick") {
    if (!player || !confirm(`${player} ${t("button.kick").toLowerCase()}?`)) return;
    command = `kick ${player}`;
  }
  if (kind === "ban") {
    if (!player || !confirm(`${player} ${t("button.ban").toLowerCase()}?`)) return;
    command = `ban ${player}`;
  }
  if (kind === "pardon") {
    if (!player) return;
    command = `pardon ${player}`;
  }
  if (!command) return;
  const result = await api(`/api/servers/${selected}/rcon`, { method: "POST", body: JSON.stringify({ command }) });
  $("result").textContent = `${result.ok ? t("message.sent") : t("message.error")}: ${command}\nexit ${result.code}\n\n${result.stdout}\n${result.stderr}`;
  await loadPlayers();
}
function mapUrl(server) { return `/map/${encodeURIComponent(server.id || selected)}/`; }
async function checkPorts() {
  const result = await api(`/api/servers/${selected}/ports`);
  showWarnings(result.warnings);
}
function translateWarning(warning) {
  if (lang === "de") return warning;
  let match = warning.match(/^([^:]+): Port (\d+)\/(tcp|udp) ist im selben Profil doppelt belegt \((.+)\)\.$/);
  if (match) return t("warning.duplicatePort", { label: match[1], port: match[2], proto: match[3], other: match[4] });
  match = warning.match(/^([^:]+): Port (\d+)\/(tcp|udp) kollidiert mit Profil (.+)\.$/);
  if (match) return t("warning.profileConflict", { label: match[1], port: match[2], proto: match[3], profiles: match[4] });
  match = warning.match(/^([^:]+): Port (\d+)\/(tcp|udp) scheint auf dem Host bereits offen zu sein\.$/);
  if (match) return t("warning.hostOpen", { label: match[1], port: match[2], proto: match[3] });
  match = warning.match(/^([^:]+): Port (\d+)\/(tcp|udp) wird bereits von Docker-Container (.+) publiziert\.$/);
  if (match) return t("warning.dockerPublished", { label: match[1], port: match[2], proto: match[3], containers: match[4] });
  match = warning.match(/^([^:]+): Port (\d+)\/(tcp|udp) wird vom eigenen Container (.+) genutzt\.$/);
  if (match) return t("warning.ownContainer", { label: match[1], port: match[2], proto: match[3], container: match[4] });
  if (warning === I18N.de["warning.rconPassword"]) return t("warning.rconPassword");
  if (warning === I18N.de["warning.eula"]) return t("warning.eula");
  return warning;
}
function showWarnings(warnings) {
  $("warnings").textContent = warnings.length ? warnings.map(translateWarning).join("\n") : t("warnings.none");
}

applyLanguageStatic();
loadServers().catch(error => $("result").textContent = error.message);
