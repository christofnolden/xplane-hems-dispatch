# HEMS Dispatch for X-Plane 12

**Version:** 1.0.13

HEMS Dispatch generates random HEMS missions for X-Plane 12. Mission locations are derived from the installed **SimHeaven X-World Europe road network**, while emergency vehicles are loaded from **RescueX_Lib** and placed along the actual road geometry.

## Features

- **English runtime UI** across the plugin menu, Moving Map, status messages, and mission information window.
- Random HEMS missions within a configurable dispatch radius
- Medical emergencies and traffic accidents
- Road-based mission placement using SimHeaven X-World Europe
- RescueX emergency vehicles placed along the actual road course
- Terrain, water and slope validation for generated mission scenes
- Configurable combinations of `RTW`, `NEF`, `FIRE` and `POLICE`
- Random crashed vehicles for traffic accidents
- **Integrated OpenStreetMap Moving Map** with a responsive, scrollbar-free layout
- **Live flight track** showing the actually flown route
- **Red Direct-To navigation** to the active mission or back to a saved home base
- **Persistent Base Position** with a one-click **Direct to base** function in the Moving Map
- **Hospital Direct-To** with nearby OpenStreetMap hospitals sorted by distance, initially within 50 km and optionally extended to 100 km
- Free map panning, zoom and **Follow Aircraft** mode
- Live bearing, distance, groundspeed and ETA in an in-map status overlay
- Compact mission start/end controls directly in the Moving Map
- Local OSM tile cache for previously viewed map areas
- Bindable X-Plane commands for keyboard, joystick and VR controllers
- Text output of the active mission for VR workflows

## Requirements

- **X-Plane 12**
- **FlyWithLua NG+ for X-Plane 12**  
  https://forums.x-plane.org/files/file/82888-flywithlua-ng-next-generation-plus-edition-for-x-plane-12-win-lin-mac/
- **SimHeaven X-World Europe** with `simHeaven_X-World_Europe-8-network` enabled  
  https://simheaven.com/package/x-world-europe/
- **RescueX_Lib**  
  https://www.rotorsim.de/de/rescuex/5-rescue-x/11-rescuex

HEMS Dispatch does **not** include SimHeaven or RescueX files.

Little Navmap, AviTab or external flight planning are **not required**.

Mission generation itself works offline. Internet access is required for uncached OpenStreetMap tiles and for refreshing the hospital list through the OpenStreetMap Overpass API.

## Installation

Extract the release archive directly into:

```text
X-Plane 12/Resources/plugins/FlyWithLua/Scripts/
```

The resulting structure should contain:

```text
FlyWithLua/
└── Scripts/
    ├── HEMS_Dispatch.lua
    └── HEMS_Dispatch/
        ├── config.lua
        ├── cache/
        ├── output/
        └── modules/
```

Then start X-Plane or use **FlyWithLua > Reload all Lua script files**.

## Usage

HEMS Dispatch is available under:

```text
Plugins > HEMS Dispatch
```

Menu entries:

- **New Mission**
- **End Active Mission**
- **Active Mission Information**
- **Moving Map**
- **Set Base Position**
- **Reload Configuration**

Starting a new mission automatically replaces an already active mission and removes its temporary RescueX objects.

**Set Base Position** stores the helicopter's current latitude/longitude as the home base. The position is saved locally and restored when HEMS Dispatch is loaded again.

The mission information window opens automatically only when a mission is successfully created from the plugin menu and `output.auto_open_info_window` is enabled. Starting or ending a mission from the Moving Map does not open it automatically. Ending a mission from the plugin menu does not open it either.

### X-Plane Commands

```text
hems_dispatch/new_mission
hems_dispatch/end_mission
hems_dispatch/show_info
hems_dispatch/toggle_moving_map
hems_dispatch/set_base_position
hems_dispatch/reload_config
```

These commands can be assigned to keyboard keys, joystick buttons or VR controllers. `hems_dispatch/toggle_moving_map` opens the Moving Map when it is closed and closes it when it is open. `hems_dispatch/set_base_position` stores the helicopter's current position as the home base.

## Moving Map

The integrated Moving Map uses OpenStreetMap tiles and works **North-Up**. The interface is responsive: the map automatically uses the remaining window area when the floating window is resized, without a separate scrolling workspace.

The compact toolbar provides:

- `-` / `+` — zoom out / in
- Navigation icon — center the map on the helicopter and enable **Follow Aircraft**
- Reset icon — clear the recorded flight track
- Home icon — toggle **Direct to base** using the saved Base Position
- Hospital/Cross icon — open the **Hospitals** list and select a hospital Direct-To
- **New Mission** — create a mission directly from the Moving Map
- **End Mission** — remove the active mission

Drag the map with the left mouse button to freely move the map; this automatically disables Follow Aircraft. The helicopter position is shown live and the active mission is marked as the destination.

The **Direct-To line is red (`#ff0000`)**. Normally it points from the helicopter to the active mission location. Pressing the Home icon switches the Direct-To destination to the saved Base Position; pressing it again disables Direct to base and returns navigation to the active mission if one exists. Starting a new mission automatically disables Direct to base.

The Base Position is stored in:

```text
HEMS_Dispatch/output/base_position.dat
```

The **flight track is orange (`#ffa500`)** and records the actually flown route. By default, a new track point is considered every **0.5 seconds** and stored once the aircraft has moved at least **3 meters**. The track continues recording while the Moving Map window is closed and remains available across mission changes until manually reset.

A semi-transparent status overlay is shown directly on the map and displays the current Direct-To destination together with bearing, distance, groundspeed and ETA, for example:

```text
Traffic Accident
BRG 087°T   7.2 NM   GS 118 kt   ETA 03:40
```

Downloaded OSM tiles are cached locally under:

```text
HEMS_Dispatch/cache/osm/
```

If an uncached tile cannot be downloaded, navigation, Direct-To, bearing, distance, ETA and flight tracking continue to work; only the missing map background remains empty.

### Hospitals

Press the Hospital/Cross icon in the Moving Map to open the hospital selection window. HEMS Dispatch queries OpenStreetMap hospital data asynchronously through the Overpass API, so the X-Plane render loop is not blocked by the network request.

The initial list contains hospitals within **50 km** of the current helicopter position and is sorted by distance. Press **Load more (up to 100 km)** to start a separate 100 km query; hospitals beyond 50 km are not requested before this button is used.

Selecting a hospital:

- closes the hospital selection window,
- disables an active Direct to base route,
- activates the red Direct-To line to the selected hospital center, and
- shows the hospital name, bearing, distance, groundspeed and ETA in the Moving Map overlay.

If hospital navigation is active, reopening the Hospitals window shows **Cancel direction to hospital** at the top. Cancelling removes the hospital override and returns navigation to the active mission when one exists. Starting a new mission also clears any active Base/Hospital Direct-To override.

Hospital results are cached locally for a short time under `HEMS_Dispatch/cache/`.

## Mission Generation

Default dispatch radius:

```text
Minimum: 5 km
Maximum: 50 km
```

Default mission types:

- **Medical Emergency — 60%**
  - Local roads
  - Default: `1x RTW`
- **Traffic Accident — 40%**
  - Weighted Primary / Secondary / Local roads
  - Configurable `RTW`, `NEF`, `FIRE` and `POLICE`
  - Optional 1–3 crashed vehicles

Mission candidates are taken from SimHeaven road data. HEMS Dispatch follows the local road geometry when placing vehicles, validates the available road space and checks terrain conditions before creating the scene.

## Configuration

Main configuration file:

```text
HEMS_Dispatch/config.lua
```

Configurable options include:

- Dispatch radius and road search radius
- Mission probabilities
- Road class weights
- Number and type of emergency vehicles
- RescueX object assignments
- Maximum terrain slope
- Moving Map size, zoom and update rates
- Flight-track interval and minimum movement
- OSM tile URL, download settings and texture limit
- Hospital search radii, Overpass endpoint, request timeout and short-lived hospital cache

Configuration changes can be applied without restarting X-Plane using:

```text
Plugins > HEMS Dispatch > Reload Configuration
```

## Logs and Mission Output

HEMS Dispatch log:

```text
HEMS_Dispatch/output/hems_dispatch.log
```

Active mission text file:

```text
HEMS_Dispatch/output/active_mission.txt
```

The text file is useful for VR workflows and is reset when the active mission ends.

## Notes

- Automatic SimHeaven detection expects an enabled `simHeaven_X-World_Europe-8-network` entry.
- Road data is indexed locally and cached per DSF tile.
- Highway road types are recognized but are not used for missions by default.
- The forest layer is not used for mission classification.
- OpenStreetMap is used for the Moving Map background and hospital search; mission generation does not depend on online OSM data.

## Third-Party Content

SimHeaven X-World Europe, RescueX_Lib, FlyWithLua NG+ and OpenStreetMap are separate third-party projects and are not distributed as part of HEMS Dispatch. Their respective licenses and terms apply independently.

---

# HEMS Dispatch für X-Plane 12

**Version:** 1.0.13

HEMS Dispatch erzeugt zufällige HEMS-Einsätze für X-Plane 12. Die Einsatzorte werden aus dem installierten **SimHeaven X-World Europe Straßennetz** abgeleitet. Einsatzfahrzeuge werden aus **RescueX_Lib** geladen und entlang des tatsächlichen Straßenverlaufs platziert.

## Features

- **Englische Programmoberfläche** in Plugin-Menü, Moving Map, Statusmeldungen und Einsatzinformationsfenster.
- Zufällige HEMS-Einsätze innerhalb eines konfigurierbaren Einsatzradius
- Medizinische Notfälle und Verkehrsunfälle
- Straßenbasierte Einsatzplatzierung mit SimHeaven X-World Europe
- RescueX-Einsatzfahrzeuge entlang des tatsächlichen Straßenverlaufs
- Terrain-, Wasser- und Neigungsprüfung für erzeugte Einsatzszenen
- Konfigurierbare Kombinationen aus `RTW`, `NEF`, `FIRE` und `POLICE`
- Zufällige Unfallfahrzeuge bei Verkehrsunfällen
- **Integrierte OpenStreetMap Moving Map** mit responsivem, scrollbar-freiem Layout
- **Live-Flugspur** der tatsächlich geflogenen Strecke
- **Rote Direct-To-Navigation** zur aktiven Einsatzstelle oder zurück zur gespeicherten Heimatbasis
- **Persistente Base Position** mit **Direct to base** über einen Haus-Button in der Moving Map
- **Hospital Direct-To** mit Krankenhäusern aus OpenStreetMap, nach Entfernung sortiert; zunächst 50 km, optional erweiterbar auf 100 km
- Freies Verschieben der Karte, Zoom und **Follow Aircraft**
- Live-Anzeige von Bearing, Distanz, Groundspeed und ETA als Overlay direkt in der Karte
- Kompakte Einsatzsteuerung direkt in der Moving Map
- Lokaler OSM-Tile-Cache für bereits betrachtete Kartenbereiche
- Bindbare X-Plane-Commands für Tastatur, Joystick und VR-Controller
- Textausgabe des aktiven Einsatzes für VR-Workflows

## Voraussetzungen

- **X-Plane 12**
- **FlyWithLua NG+ für X-Plane 12**  
  https://forums.x-plane.org/files/file/82888-flywithlua-ng-next-generation-plus-edition-for-x-plane-12-win-lin-mac/
- **SimHeaven X-World Europe** mit aktiviertem `simHeaven_X-World_Europe-8-network`  
  https://simheaven.com/package/x-world-europe/
- **RescueX_Lib**  
  https://www.rotorsim.de/de/rescuex/5-rescue-x/11-rescuex

HEMS Dispatch enthält **keine** SimHeaven- oder RescueX-Dateien.

Little Navmap, AviTab oder eine externe Flugplanung werden **nicht benötigt**.

Die Einsatzgenerierung funktioniert vollständig offline. Eine Internetverbindung wird für nicht gecachte OpenStreetMap-Kacheln sowie zum Aktualisieren der Krankenhausliste über die OpenStreetMap Overpass API benötigt.

## Installation

Das Release-Archiv direkt nach

```text
X-Plane 12/Resources/plugins/FlyWithLua/Scripts/
```

entpacken.

Danach sollte folgende Struktur vorhanden sein:

```text
FlyWithLua/
└── Scripts/
    ├── HEMS_Dispatch.lua
    └── HEMS_Dispatch/
        ├── config.lua
        ├── cache/
        ├── output/
        └── modules/
```

Anschließend X-Plane starten oder in FlyWithLua **Reload all Lua script files** ausführen.

## Bedienung

HEMS Dispatch ist erreichbar unter:

```text
Plugins > HEMS Dispatch
```

Menüeinträge:

- **New Mission**
- **End Active Mission**
- **Active Mission Information**
- **Moving Map**
- **Set Base Position**
- **Reload Configuration**

Ein neuer Einsatz ersetzt automatisch einen bereits aktiven Einsatz und entfernt dessen temporäre RescueX-Objekte.

**Set Base Position** speichert die aktuelle Position des Hubschraubers als Heimatbasis. Die Position wird lokal gespeichert und beim nächsten Laden von HEMS Dispatch wiederhergestellt.

Das Einsatzinformationen-Fenster öffnet automatisch nur nach erfolgreicher Einsatzgenerierung über das Plugin-Menü, sofern `output.auto_open_info_window` aktiviert ist. Beim Starten oder Beenden eines Einsatzes über die Moving Map öffnet es nicht automatisch. Auch beim Beenden eines Einsatzes über das Plugin-Menü öffnet es nicht.

### X-Plane-Commands

```text
hems_dispatch/new_mission
hems_dispatch/end_mission
hems_dispatch/show_info
hems_dispatch/toggle_moving_map
hems_dispatch/set_base_position
hems_dispatch/reload_config
```

Die Commands können auf Tastatur, Joystick oder VR-Controller gelegt werden. `hems_dispatch/toggle_moving_map` öffnet die Moving Map, wenn sie geschlossen ist, und schließt sie wieder, wenn sie geöffnet ist. `hems_dispatch/set_base_position` speichert die aktuelle Hubschrauberposition als Heimatbasis.

## Moving Map

Die integrierte Moving Map verwendet OpenStreetMap-Kacheln und arbeitet **North-Up**. Die Oberfläche ist responsiv: Beim Ändern der Fenstergröße nutzt die Karte automatisch die verbleibende Fläche, ohne einen separaten scrollbaren Arbeitsbereich.

Die kompakte Toolbar bietet:

- `-` / `+` — heraus- / hineinzoomen
- Navigationssymbol — Karte auf den Hubschrauber zentrieren und **Follow Aircraft** aktivieren
- Reset-Symbol — aufgezeichnete Flugspur zurücksetzen
- Haus-Symbol — **Direct to base** zur gespeicherten Base Position ein-/ausschalten
- Krankenhaus-/Kreuz-Symbol — die **Hospitals**-Liste öffnen und ein Krankenhaus als Direct-To-Ziel auswählen
- **New Mission** — direkt aus der Moving Map einen Einsatz erzeugen
- **End Mission** — aktiven Einsatz entfernen

Die Karte lässt sich mit gedrückter linker Maustaste frei verschieben; dadurch wird Follow Aircraft automatisch deaktiviert. Die aktuelle Hubschrauberposition wird live dargestellt und die aktive Einsatzstelle als Ziel markiert.

Die **Direct-To-Linie ist rot (`#ff0000`)**. Normalerweise führt sie von der aktuellen Hubschrauberposition zur aktiven Einsatzstelle. Mit dem Haus-Symbol wird das Ziel auf die gespeicherte Base Position umgeschaltet. Ein erneuter Klick deaktiviert **Direct to base** und schaltet – sofern vorhanden – wieder auf den aktiven Einsatz zurück. Beim Start eines neuen Einsatzes wird Direct to base automatisch deaktiviert.

Die Base Position wird lokal gespeichert unter:

```text
HEMS_Dispatch/output/base_position.dat
```

Die **Flugspur ist orange (`#ffa500`)** und zeigt die tatsächlich geflogene Strecke. Standardmäßig wird alle **0,5 Sekunden** ein möglicher Trackpunkt geprüft und gespeichert, sobald sich der Hubschrauber mindestens **3 Meter** bewegt hat. Das Tracking läuft auch bei geschlossenem Moving-Map-Fenster weiter und bleibt über Einsatzwechsel hinweg erhalten, bis es manuell zurückgesetzt wird.

Ein halbtransparentes Status-Overlay liegt direkt auf der Karte und zeigt das aktuelle Direct-To-Ziel sowie Bearing, Distanz, Groundspeed und ETA, beispielsweise:

```text
Traffic accident
BRG 087°T   7.2 NM   GS 118 kt   ETA 03:40
```

Heruntergeladene OSM-Kacheln werden lokal gespeichert unter:

```text
HEMS_Dispatch/cache/osm/
```

Kann eine noch nicht gecachte Kachel nicht geladen werden, funktionieren Navigation, Direct-To, Bearing, Distanz, ETA und Flugspur weiterhin; lediglich der Kartenhintergrund bleibt an dieser Stelle leer.

### Krankenhäuser

Über das Krankenhaus-/Kreuz-Symbol in der Moving Map öffnet sich die Krankenhausauswahl. HEMS Dispatch fragt Krankenhausdaten aus OpenStreetMap asynchron über die Overpass API ab, sodass der X-Plane-Renderloop nicht durch die Netzwerkanfrage blockiert wird.

Die erste Liste enthält Krankenhäuser im Umkreis von **50 km** um die aktuelle Heli-Position und ist nach Entfernung sortiert. Erst mit **Load more (up to 100 km)** wird eine separate Abfrage bis **100 km** gestartet; Krankenhäuser außerhalb von 50 km werden vorher nicht abgefragt.

Die Auswahl eines Krankenhauses:

- schließt das Krankenhausfenster automatisch,
- deaktiviert eine aktive Direct-to-base-Route,
- aktiviert die rote Direct-To-Linie zur Mitte des ausgewählten Krankenhauses und
- zeigt Krankenhausname, Bearing, Entfernung, Groundspeed und ETA im Moving-Map-Overlay.

Ist bereits eine Krankenhausnavigation aktiv, steht beim erneuten Öffnen der Hospitals-Liste **Cancel direction to hospital** ganz oben. Das Abbrechen entfernt das Krankenhaus-Ziel und wechselt zu einer aktiven Einsatzroute zurück, sofern ein Einsatz vorhanden ist. Auch ein neuer Einsatz entfernt automatisch eine aktive Base-/Hospital-Direct-To-Übersteuerung.

Krankenhausergebnisse werden für kurze Zeit lokal unter `HEMS_Dispatch/cache/` zwischengespeichert.

## Einsatzgenerierung

Standard-Einsatzradius:

```text
Minimum: 5 km
Maximum: 50 km
```

Standard-Einsatztypen:

- **Medizinischer Notfall — 60 %**
  - Local Roads
  - Standard: `1x RTW`
- **Verkehrsunfall — 40 %**
  - gewichtete Primary / Secondary / Local Roads
  - konfigurierbare `RTW`, `NEF`, `FIRE` und `POLICE`
  - optional 1–3 Unfallfahrzeuge

Die Einsatzkandidaten stammen aus den SimHeaven-Straßendaten. HEMS Dispatch folgt bei der Fahrzeugplatzierung dem lokalen Straßenverlauf, prüft den verfügbaren Straßenraum und validiert die Terrainbedingungen vor dem Aufbau der Szene.

## Konfiguration

Zentrale Konfigurationsdatei:

```text
HEMS_Dispatch/config.lua
```

Konfigurierbar sind unter anderem:

- Einsatzradius und Straßensuchradius
- Einsatzwahrscheinlichkeiten
- Gewichtung der Straßenklassen
- Anzahl und Typ der Einsatzfahrzeuge
- RescueX-Objektzuordnung
- maximale Geländeneigung
- Größe, Zoom und Update-Raten der Moving Map
- Intervall und Mindestbewegung der Flugspur
- OSM-Tile-URL, Download-Einstellungen und Texture-Limit
- Krankenhaus-Suchradien, Overpass-Endpunkt, Request-Timeout und kurzzeitiger Krankenhaus-Cache

Änderungen können ohne X-Plane-Neustart übernommen werden über:

```text
Plugins > HEMS Dispatch > Reload Configuration
```

## Logs und Einsatzdatei

HEMS-Dispatch-Log:

```text
HEMS_Dispatch/output/hems_dispatch.log
```

Textdatei des aktiven Einsatzes:

```text
HEMS_Dispatch/output/active_mission.txt
```

Die Textdatei eignet sich insbesondere für VR-Workflows und wird beim Beenden des aktiven Einsatzes zurückgesetzt.

## Hinweise

- Die automatische SimHeaven-Erkennung erwartet einen aktivierten Eintrag `simHeaven_X-World_Europe-8-network`.
- Straßendaten werden lokal indiziert und pro DSF-Tile gecacht.
- Autobahn-Subtypes werden erkannt, standardmäßig aber nicht für Einsätze verwendet.
- Der Forest-Layer wird nicht zur Einsatzklassifizierung ausgewertet.
- OpenStreetMap wird für den Kartenhintergrund der Moving Map und die Krankenhaussuche verwendet; die Einsatzgenerierung ist nicht von Online-OSM-Daten abhängig.

## Drittanbieter-Inhalte

SimHeaven X-World Europe, RescueX_Lib, FlyWithLua NG+ und OpenStreetMap sind eigenständige Drittanbieter-Projekte und werden nicht als Bestandteil von HEMS Dispatch ausgeliefert. Die jeweiligen Lizenz- und Nutzungsbedingungen gelten unabhängig davon.
