# HEMS Dispatch for X-Plane 12

**Version:** 1.1.3

HEMS Dispatch generates random HEMS missions for X-Plane 12. Mission locations are derived from the installed **SimHeaven X-World Europe road network**, while emergency vehicles are loaded from **RescueX_Lib** and placed along the actual road geometry.

## Features

- **English runtime UI** across the plugin menu, Moving Map, status messages, and mission information window.
- Random HEMS missions within a configurable dispatch radius
- **Custom HEMS missions** at a user-selected Moving Map position, without random mission distance limits
- Medical emergencies and traffic accidents
- Road-based mission placement using SimHeaven X-World Europe
- RescueX emergency vehicles placed along the actual road course
- Terrain, water and slope validation for generated mission scenes
- Configurable combinations of `RTW`, `NEF`, `FIRE` and `POLICE`
- Random crashed vehicles for traffic accidents
- **Integrated OpenStreetMap Moving Map** with a responsive, scrollbar-free layout and selectable **North Up / Heading Up** orientation
- **Persistent flight track** showing the actually flown route across flights/reloads until manually reset, now with reset confirmation
- **Black dashed heading prediction** from the aircraft position, extending approximately two minutes of travel at the current groundspeed
- **Red Direct-To navigation** with a fixed route start for active missions, the saved home base, and selected hospitals
- **Persistent Base Position** with a one-click **Direct to base** function in the Moving Map
- **Hospital Direct-To** with nearby OpenStreetMap hospitals sorted by distance, initially within 50 km and optionally extended to 100 km
- Free map panning, zoom and **Follow Aircraft** mode
- Live bearing, distance, groundspeed and ETA in an in-map status overlay
- Compact mission start/end controls directly in the Moving Map
- **Rolling GPU texture cache** that releases off-screen map tiles automatically; downloaded OSM tiles remain stored on disk
- **Automatic mission preview** centered on the generated scene at zoom level 16 (configurable)
- Bindable X-Plane commands for keyboard, joystick and VR controllers
- Text output of the active mission for VR workflows

## Requirements

- **X-Plane 12**
- **FlyWithLua NG+ for X-Plane 12**  
  https://forums.x-plane.org/files/file/82888-flywithlua-ng-next-generation-plus-edition-for-x-plane-12-win-lin-mac/
- **SimHeaven X-World Europe** (`simHeaven_X-World_Europe-8-network`) **or X-World Pro Europe** (`simHeaven_X-WORLD-Pro_Europe-13-net3-roads`), with the respective road scenery enabled  
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

**Select the SimHeaven road scenery:** Make sure the matching folder is installed directly under `X-Plane 12/Custom Scenery/` and enabled in `Custom Scenery/scenery_packs.ini` (`SCENERY_PACK`, not `SCENERY_PACK_DISABLED`):

- **X-World Europe (standard):** `simHeaven_X-World_Europe-8-network`
- **X-World Pro Europe:** `simHeaven_X-WORLD-Pro_Europe-13-net3-roads`

In `HEMS_Dispatch/config.lua`, set `simheaven.road_scenery_folder` to the **exact name of the installed road scenery folder**. The standard X-World Europe name is the default. Specify only the folder name, not its full path. See **Configuration** below for examples.

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
hems_dispatch/map_zoom_in
hems_dispatch/map_zoom_out
hems_dispatch/set_base_position
hems_dispatch/reload_config
```

These commands can be assigned to keyboard keys, joystick buttons or VR controllers. `hems_dispatch/toggle_moving_map` opens the Moving Map when it is closed and closes it when it is open. `hems_dispatch/map_zoom_in` and `hems_dispatch/map_zoom_out` adjust the zoom by one step while the Moving Map is open, using the same configured limits as the toolbar buttons. `hems_dispatch/set_base_position` stores the helicopter's current position as the home base.

## Moving Map

The integrated Moving Map uses OpenStreetMap tiles and starts in **North Up** mode. Use the compass icon to toggle **Heading Up**: the map tiles and all geographic overlays rotate with the helicopter's heading, keeping the direction of flight at the top of the map. The aircraft symbol remains pointed approximately upwards. Map orientation refreshes at **5 Hz (every 0.2 seconds)** by default (`moving_map.heading_up_update_hz = 5`); the separate heading prediction retains its faster navigation update rate. Switching back immediately restores North Up. This does not change the flight track, Direct-To start positions or navigation calculations.

The interface is responsive: the map automatically uses the remaining window area when the floating window is resized, without a separate scrolling workspace.

The compact toolbar provides:

- `-` / `+` — zoom out / in
- Navigation icon — center the map on the helicopter and enable **Follow Aircraft**
- Compass icon — toggle **North Up / Heading Up** (highlighted when Heading Up is active)
- Reset icon — request confirmation before permanently clearing the recorded flight track
- Home icon — toggle **Direct to base** using the saved Base Position
- Bullseye icon — **Direct to Active mission**; replace the current Direct-To and capture the helicopter's current position as a new fixed mission-route start
- Hospital/Cross icon — open the **Hospitals** list and select a hospital Direct-To
- **New random mission** — generate a random mission; asks for confirmation before replacing an active mission
- **New custom mission** — choose **Medical emergency** or **Traffic accident**, then click the map to pick the mission location; asks for confirmation before replacing an active mission
- **End mission** — end an active mission after confirmation

To create a **custom mission**, press **New custom mission**, select the emergency type, and then click the desired point on the map. A selection banner stays visible until you click a location or press **Cancel selection**. Zoom and pan before picking the location as needed. The plugin searches up to **1 km** around the click (configurable through `dispatch.custom_road_search_radius_km`) for the closest usable SimHeaven road and places the emergency scene there; it does not place vehicles on arbitrary terrain. Custom locations may lie **outside `dispatch.min_radius_km` and `dispatch.max_radius_km`**. If no suitable road/terrain/scene is found, HEMS Dispatch reports the problem without placing emergency vehicles. As with random missions, preparing an uncached SimHeaven road tile may briefly take time. All mission creation still runs in the safe pre-flightloop rather than inside the map renderer. Canceling the choice of mission type or map location leaves an existing mission untouched. The confirmation dialogs for replacing or ending an active mission and resetting the recorded flight track also offer **No** to leave everything unchanged.

Drag the map with the left mouse button to freely move the map in either orientation; this automatically disables Follow Aircraft. The helicopter position is shown live and the active mission is marked as the destination. Heading Up also works while freely panning the map. **After successfully generating a random or custom mission**, the Moving Map centers on the actual emergency scene at zoom level `moving_map.mission_preview_zoom` (default **16**) for landing-zone reconnaissance; **Follow Aircraft** is temporarily disabled. Press the navigation/follow icon whenever you want to return to the helicopter. A rotated map requires the FlyWithLua ImGui `DrawList_AddImageQuad` binding; if unavailable, HEMS Dispatch keeps the safe North Up display.

The **Direct-To line is red (`#ff0000`)**. For Mission, Base and Hospital Direct-To routes, the helicopter position is captured once when the Direct-To is set and becomes the **fixed start point** of that route. The line therefore remains anchored to that position while the helicopter, Moving Map and orange flight track continue to move normally. Bearing, distance, groundspeed and ETA in the status overlay remain live values based on the helicopter's current position.

Press the bullseye icon (**Direct to Active mission**) at any time during an active mission to remove the current Direct-To override, capture the helicopter's current position as a new fixed start point, and draw a new route to the active mission. This can be used after navigating to the Base/Hospital or after a significant course deviation.

Pressing the Home icon switches the Direct-To destination to the saved Base Position and captures the helicopter's current position as the fixed start of that Base route. Pressing it again disables Direct to base and returns navigation to the active mission if one exists. Starting a new mission automatically disables Direct to base and creates a new fixed mission Direct-To from the helicopter position at that time.

The Base Position is stored in:

```text
HEMS_Dispatch/output/base_position.dat
```

The **black dashed heading prediction** starts at the current aircraft position, follows the aircraft's current heading (not necessarily its actual ground track) and has a length corresponding to **120 seconds at the current groundspeed**. It updates with heading, speed and position; unlike a Direct-To route, it is not a stored route. Its thin line remains visible independently of mission selection.

The **flight track is orange (`#ffa500`)** and records the actually flown route. By default, a new track point is considered every **0.5 seconds** and stored once the aircraft has moved at least **3 meters**. The track continues recording while the Moving Map window is closed and is persisted across X-Plane/FlyWithLua reloads and new flights until it is manually reset with the existing track-reset button.

The persisted track is stored in:

```text
HEMS_Dispatch/output/flight_track.dat
```

A new X-Plane/FlyWithLua session starts a new visual track segment, so a new flight is not connected to the previous flight by an artificial straight line.

A semi-transparent status overlay is shown directly on the map and displays the current Direct-To destination together with bearing, distance, groundspeed and ETA, for example:

```text
Traffic Accident
BRG 087°T   7.2 NM   GS 118 kt   ETA 03:40
```

Downloaded OSM tiles are cached locally under:

```text
HEMS_Dispatch/cache/osm/
```

The OSM tile GPU cache now uses a **rolling texture budget** (`moving_map.max_loaded_textures`, default **384**): when the budget is reached, non-visible textures are freed and reloaded from disk as needed. This avoids the previous permanent blank-map state after exploring many areas without requiring a FlyWithLua reload. The disk cache is never deleted by GPU eviction. If an uncached tile cannot be downloaded, navigation, Direct-To, bearing, distance, ETA and flight tracking continue to work; only the missing map background remains empty.

### Hospitals

Press the Hospital/Cross icon in the Moving Map to open the hospital selection window. If no cached dataset exists yet, HEMS Dispatch queries OpenStreetMap hospital data asynchronously through the Overpass API, so the X-Plane render loop is not blocked by the network request.

The initial dataset contains hospitals within **50 km** of the helicopter position at the time it is loaded. Once successfully loaded, the dataset is cached persistently and reused when the Hospitals window is opened again. The displayed distances and sorting are still recalculated continuously from the helicopter's **current position**, but reopening the window does not automatically trigger another Overpass request.

Press **Load more (up to 100 km)** to load/use the separate 100 km dataset. A new 100 km Overpass request is only made when no cached 100 km dataset exists. Use **Reload hospital list** to explicitly refresh the currently displayed 50 km or 100 km dataset from the helicopter's current position.

Selecting a hospital:

- closes the hospital selection window,
- disables an active Direct to base route,
- captures the helicopter position at selection time as the fixed Hospital Direct-To start and activates the red Direct-To line to the selected hospital center, and
- shows the hospital name, bearing, distance, groundspeed and ETA in the Moving Map overlay.

If hospital navigation is active, reopening the Hospitals window shows **Cancel direction to hospital** at the top. Cancelling removes the hospital override and returns navigation to the active mission when one exists. Starting a new mission also clears any active Base/Hospital Direct-To override.

Hospital results are cached persistently under `HEMS_Dispatch/cache/` and are only refreshed explicitly with **Reload hospital list** (or when no matching cache exists yet).

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

- SimHeaven road scenery folder (`simheaven.road_scenery_folder`)
- Dispatch radius and road search radius (plus independent custom map-click road search radius)
- Mission probabilities
- Road class weights
- Number and type of emergency vehicles
- RescueX object assignments
- Maximum terrain slope
- Moving Map size, zoom and update rates
- Flight-track interval and minimum movement
- Heading-prediction duration (default: 120 seconds)
- OSM tile URL, download settings and rolling GPU texture budget
- Automatic mission preview zoom (`moving_map.mission_preview_zoom`)
- Hospital search radii, Overpass endpoint, request timeout and persistent hospital cache behavior

To choose the installed SimHeaven road network, edit `road_scenery_folder` in the existing `simheaven` section of `config.lua`. Use **one** of the following values:

**X-World Europe (default):**

```lua
road_scenery_folder = "simHeaven_X-World_Europe-8-network",
```

**X-World Pro Europe:**

```lua
road_scenery_folder = "simHeaven_X-WORLD-Pro_Europe-13-net3-roads",
```

Use the actual name of the enabled folder under `Custom Scenery` (ideally copied with its original capitalization); do not enter an absolute path or a trailing slash.

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

- Automatic SimHeaven detection uses the configured `simheaven.road_scenery_folder` and requires a corresponding enabled entry in `Custom Scenery/scenery_packs.ini`.
- Road data is indexed locally and cached per DSF tile.
- Highway road types are recognized but are not used for missions by default.
- The forest layer is not used for mission classification.
- OpenStreetMap is used for the Moving Map background and hospital search; mission generation does not depend on online OSM data.

## Third-Party Content

SimHeaven X-World Europe, RescueX_Lib, FlyWithLua NG+ and OpenStreetMap are separate third-party projects and are not distributed as part of HEMS Dispatch. Their respective licenses and terms apply independently.

---

# HEMS Dispatch für X-Plane 12

**Version:** 1.1.3

HEMS Dispatch erzeugt zufällige HEMS-Einsätze für X-Plane 12. Die Einsatzorte werden aus dem installierten **SimHeaven X-World Europe Straßennetz** abgeleitet. Einsatzfahrzeuge werden aus **RescueX_Lib** geladen und entlang des tatsächlichen Straßenverlaufs platziert.

## Features

- **Englische Programmoberfläche** in Plugin-Menü, Moving Map, Statusmeldungen und Einsatzinformationsfenster.
- Zufällige HEMS-Einsätze innerhalb eines konfigurierbaren Einsatzradius
- **Manuelle Einsätze** an einer in der Moving Map gewählten Position, unabhängig vom Einsatzradius
- Medizinische Notfälle und Verkehrsunfälle
- Straßenbasierte Einsatzplatzierung mit SimHeaven X-World Europe
- RescueX-Einsatzfahrzeuge entlang des tatsächlichen Straßenverlaufs
- Terrain-, Wasser- und Neigungsprüfung für erzeugte Einsatzszenen
- Konfigurierbare Kombinationen aus `RTW`, `NEF`, `FIRE` und `POLICE`
- Zufällige Unfallfahrzeuge bei Verkehrsunfällen
- **Integrierte OpenStreetMap Moving Map** mit responsivem, scrollbar-freiem Layout und umschaltbarer **North Up / Heading Up**-Ausrichtung
- **Persistente Flugspur**, die die tatsächlich geflogene Route über Flüge/Reloads hinweg bis zum manuell bestätigten Zurücksetzen erhält
- **Schwarz gestrichelte Heading-Prognose** ab der aktuellen Hubschrauberposition über rund zwei Minuten Flugstrecke anhand der momentanen Groundspeed
- **Rote Direct-To-Navigation** mit festem Routenstart zur aktiven Einsatzstelle, zur gespeicherten Heimatbasis und zu ausgewählten Krankenhäusern
- **Persistente Base Position** mit **Direct to base** über einen Haus-Button in der Moving Map
- **Hospital Direct-To** mit Krankenhäusern aus OpenStreetMap, nach Entfernung sortiert; zunächst 50 km, optional erweiterbar auf 100 km
- Freies Verschieben der Karte, Zoom und **Follow Aircraft**
- Live-Anzeige von Bearing, Distanz, Groundspeed und ETA als Overlay direkt in der Karte
- Kompakte Einsatzsteuerung direkt in der Moving Map
- **Rollierender GPU-Texturcache** mit automatischer Freigabe nicht sichtbarer Kacheln; OSM-Dateien bleiben lokal gespeichert
- **Automatische Einsatzvorschau** auf der tatsächlichen Einsatzstelle bei Zoomstufe 16 (konfigurierbar)
- Bindbare X-Plane-Commands für Tastatur, Joystick und VR-Controller
- Textausgabe des aktiven Einsatzes für VR-Workflows

## Voraussetzungen

- **X-Plane 12**
- **FlyWithLua NG+ für X-Plane 12**  
  https://forums.x-plane.org/files/file/82888-flywithlua-ng-next-generation-plus-edition-for-x-plane-12-win-lin-mac/
- **SimHeaven X-World Europe** (`simHeaven_X-World_Europe-8-network`) **oder X-World Pro Europe** (`simHeaven_X-WORLD-Pro_Europe-13-net3-roads`), jeweils mit aktiviertem Straßenszenerie-Ordner  
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

**SimHeaven-Straßenszenerie auswählen:** Der passende Ordner muss direkt unter `X-Plane 12/Custom Scenery/` installiert und in `Custom Scenery/scenery_packs.ini` aktiviert sein (`SCENERY_PACK`, nicht `SCENERY_PACK_DISABLED`):

- **X-World Europe (Standard):** `simHeaven_X-World_Europe-8-network`
- **X-World Pro Europe:** `simHeaven_X-WORLD-Pro_Europe-13-net3-roads`

In `HEMS_Dispatch/config.lua` muss `simheaven.road_scenery_folder` auf den **exakten Namen des installierten Straßenszenerie-Ordners** gesetzt werden. Standardmäßig ist X-World Europe voreingestellt. Nur den Ordnernamen angeben, keinen vollständigen Pfad. Beispiele stehen unter **Konfiguration**.

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
hems_dispatch/map_zoom_in
hems_dispatch/map_zoom_out
hems_dispatch/set_base_position
hems_dispatch/reload_config
```

Die Commands können auf Tastatur, Joystick oder VR-Controller gelegt werden. `hems_dispatch/toggle_moving_map` öffnet die Moving Map, wenn sie geschlossen ist, und schließt sie wieder, wenn sie geöffnet ist. Mit `hems_dispatch/map_zoom_in` und `hems_dispatch/map_zoom_out` wird bei geöffneter Moving Map um jeweils eine Zoomstufe hinein- oder herausgezoomt; dabei gelten dieselben Grenzen wie für die Toolbar-Buttons. `hems_dispatch/set_base_position` speichert die aktuelle Hubschrauberposition als Heimatbasis.

## Moving Map

Die integrierte Moving Map verwendet OpenStreetMap-Kacheln und startet standardmäßig in **North Up**. Über das Kompass-Symbol kann jederzeit auf **Heading Up** umgeschaltet werden: Die Kartenkacheln und sämtliche geografischen Markierungen/Linien drehen sich mit dem Heading des Hubschraubers, sodass die Flugrichtung oben liegt. Das Hubschraubersymbol zeigt dabei ungefähr nach oben. Die Kartenausrichtung wird standardmäßig mit **5 Hz (alle 0,2 Sekunden)** aktualisiert (`moving_map.heading_up_update_hz = 5`); die Heading-Prognose behält ihre schnellere Navigationsaktualisierung. Ein erneuter Klick aktiviert sofort wieder North Up. Flugspur, feste Direct-To-Startpositionen und Navigationsberechnungen bleiben unverändert.

Die Oberfläche ist responsiv: Beim Ändern der Fenstergröße nutzt die Karte automatisch die verbleibende Fläche, ohne einen separaten scrollbaren Arbeitsbereich.

Die kompakte Toolbar bietet:

- `-` / `+` — heraus- / hineinzoomen
- Navigationssymbol — Karte auf den Hubschrauber zentrieren und **Follow Aircraft** aktivieren
- Kompass-Symbol — zwischen **North Up / Heading Up** umschalten (aktiv in Heading Up)
- Reset-Symbol — aufgezeichnete Flugspur erst nach Bestätigungsdialog löschen
- Haus-Symbol — **Direct to base** zur gespeicherten Base Position ein-/ausschalten
- Fadenkreuz-/Zielsymbol — **Direct to Active mission**; die aktuelle Direct-To-Route ersetzen und die aktuelle Heli-Position als neuen festen Startpunkt der Einsatzroute übernehmen
- Krankenhaus-/Kreuz-Symbol — die **Hospitals**-Liste öffnen und ein Krankenhaus als Direct-To-Ziel auswählen
- **New random mission** — zufälligen Einsatz erzeugen; bei aktivem Einsatz mit Bestätigungsdialog
- **New custom mission** — **Medical emergency** oder **Traffic accident** auswählen und anschließend die Position auf der Karte anklicken; bei aktivem Einsatz mit Bestätigungsdialog
- **End mission** — aktiven Einsatz nach Bestätigung beenden

Für einen **manuellen Einsatz** zunächst **New custom mission** wählen, dann den Einsatztyp auswählen und anschließend auf die gewünschte Kartenposition klicken. Bis zum Klick oder **Cancel selection** bleibt eine Einblendung sichtbar. Die Karte kann vorher gezoomt und verschoben werden. Das Plugin sucht im Umkreis von standardmäßig **1 km** (`dispatch.custom_road_search_radius_km`) die nächstgelegene geeignete SimHeaven-Straße; Fahrzeuge werden also nicht blind auf Gelände platziert. Die manuelle Position darf **außerhalb der Werte `dispatch.min_radius_km` und `dispatch.max_radius_km`** liegen. Falls kein geeigneter Straßen-/Terrainstandort gefunden wird, erscheint eine Fehlermeldung statt einer instabilen oder falschen Einsatzstelle. Die eigentliche Erzeugung wird weiterhin sicher außerhalb des ImGui-Zeichen-Callbacks ausgeführt. Wird die Auswahl abgebrochen, bleibt ein bestehender Einsatz bestehen. Auch alle Bestätigungsdialoge zum Ersetzen/Beenden eines Einsatzes oder Löschen der Flugspur lassen sich mit **No** ohne Änderungen schließen.

Die Karte lässt sich in beiden Ausrichtungen mit gedrückter linker Maustaste frei verschieben; dadurch wird Follow Aircraft automatisch deaktiviert. Heading Up funktioniert auch bei freier Kartenverschiebung. Die aktuelle Hubschrauberposition wird live dargestellt und die aktive Einsatzstelle als Ziel markiert. **Nach jeder erfolgreich erzeugten zufälligen oder manuellen Mission** wird die Moving Map auf die tatsächliche Einsatzstelle bei `moving_map.mission_preview_zoom` (standardmäßig **16**) zentriert, damit der Landeplatz vor dem Abflug betrachtet werden kann. **Follow Aircraft** ist dafür vorübergehend deaktiviert; mit dem bisherigen Follow-Button wird die Karte wieder auf den Hubschrauber zentriert. Für gedrehte Kartentexturen wird die ImGui-Funktion `DrawList_AddImageQuad` benötigt; fehlt sie in einer FlyWithLua-Version, bleibt die sichere North-Up-Ansicht aktiv.

Die **Direct-To-Linie ist rot (`#ff0000`)**. Für Mission-, Base- und Hospital-Direct-To wird die Hubschrauberposition beim Setzen der jeweiligen Route einmalig gespeichert und bildet anschließend den **festen Startpunkt** dieser Route. Die Linie bleibt damit an dieser Position verankert, während sich Hubschrauberposition, Moving Map und orange Flugspur weiterhin normal aktualisieren. Bearing, Distanz, Groundspeed und ETA im Status-Overlay bleiben Live-Werte auf Basis der aktuellen Hubschrauberposition.

Mit dem Fadenkreuz-/Zielsymbol (**Direct to Active mission**) kann während eines aktiven Einsatzes jederzeit die aktuelle Direct-To-Route ersetzt werden. Dabei werden Base-/Hospital-Overrides deaktiviert, die aktuelle Heli-Position als neuer fester Startpunkt gespeichert und von dort eine neue Route zur aktiven Einsatzstelle gezeichnet. Das eignet sich beispielsweise nach einer größeren Kursabweichung oder nach einer zwischenzeitlichen Navigation zur Base bzw. zu einem Krankenhaus.

Mit dem Haus-Symbol wird das Ziel auf die gespeicherte Base Position umgeschaltet. Dabei wird die aktuelle Heli-Position einmalig als fester Startpunkt der Base-Route gespeichert. Ein erneuter Klick deaktiviert **Direct to base** und schaltet – sofern vorhanden – wieder auf den aktiven Einsatz zurück. Beim Start eines neuen Einsatzes wird Direct to base automatisch deaktiviert und ein neues festes Mission-Direct-To von der zu diesem Zeitpunkt aktuellen Heli-Position erzeugt.

Die Base Position wird lokal gespeichert unter:

```text
HEMS_Dispatch/output/base_position.dat
```

Die **schwarz gestrichelte Heading-Prognose** beginnt an der aktuellen Hubschrauberposition und zeigt in Richtung des aktuellen Headings (nicht zwingend der tatsächlichen Bewegung über Grund). Ihre Länge entspricht **120 Sekunden Flugstrecke mit der momentanen Groundspeed**. Sie folgt der aktuellen Position, dem Heading und der Geschwindigkeit, unabhängig von der gewählten Direct-To-Route.

Die **Flugspur ist orange (`#ffa500`)** und zeigt die tatsächlich geflogene Strecke. Standardmäßig wird alle **0,5 Sekunden** ein möglicher Trackpunkt geprüft und gespeichert, sobald sich der Hubschrauber mindestens **3 Meter** bewegt hat. Das Tracking läuft auch bei geschlossenem Moving-Map-Fenster weiter und wird über X-Plane-/FlyWithLua-Reloads sowie neue Flüge hinweg gespeichert, bis es über den vorhandenen Track-Reset-Button manuell zurückgesetzt wird.

Die persistente Flugspur wird gespeichert unter:

```text
HEMS_Dispatch/output/flight_track.dat
```

Eine neue X-Plane-/FlyWithLua-Sitzung beginnt einen neuen sichtbaren Trackabschnitt, damit ein neuer Flug nicht durch eine künstliche gerade Linie mit dem Ende des vorherigen Flugs verbunden wird.

Ein halbtransparentes Status-Overlay liegt direkt auf der Karte und zeigt das aktuelle Direct-To-Ziel sowie Bearing, Distanz, Groundspeed und ETA, beispielsweise:

```text
Traffic accident
BRG 087°T   7.2 NM   GS 118 kt   ETA 03:40
```

Heruntergeladene OSM-Kacheln werden lokal gespeichert unter:

```text
HEMS_Dispatch/cache/osm/
```

Die GPU-Kacheln verwenden ein **rollierendes Texturbudget** (`moving_map.max_loaded_textures`, Standard **384**): Bei Bedarf werden nicht sichtbare Texturen freigegeben und beim erneuten Aufruf aus dem lokalen Disk-Cache geladen. Dadurch blockiert das Limit nicht mehr dauerhaft neue Kartenbereiche. Die bereits gespeicherten OSM-PNG-Dateien bleiben erhalten. Kann eine noch nicht gecachte Kachel nicht geladen werden, funktionieren Navigation, Direct-To, Bearing, Distanz, ETA und Flugspur weiterhin; lediglich der Kartenhintergrund bleibt an dieser Stelle leer.

### Krankenhäuser

Über das Krankenhaus-/Kreuz-Symbol in der Moving Map öffnet sich die Krankenhausauswahl. Ist noch kein passender Cache vorhanden, fragt HEMS Dispatch Krankenhausdaten aus OpenStreetMap asynchron über die Overpass API ab, sodass der X-Plane-Renderloop nicht durch die Netzwerkanfrage blockiert wird.

Der erste Datensatz enthält Krankenhäuser im Umkreis von **50 km** um die Heli-Position zum Zeitpunkt des Ladens. Nach einem erfolgreichen Abruf wird dieser Datensatz persistent gecacht und beim erneuten Öffnen der Hospitals-Liste wiederverwendet. Die angezeigten Entfernungen und die Sortierung werden weiterhin anhand der **aktuellen Heli-Position** neu berechnet; allein das Öffnen des Fensters startet aber keine neue Overpass-Abfrage mehr.

Mit **Load more (up to 100 km)** wird der separate 100-km-Datensatz geladen bzw. aus dem Cache verwendet. Eine neue 100-km-Abfrage erfolgt nur, wenn noch kein entsprechender Cache vorhanden ist. Über **Reload hospital list** kann der aktuell angezeigte 50-km- oder 100-km-Datensatz bewusst von der aktuellen Heli-Position aus neu über Overpass geladen werden.

Die Auswahl eines Krankenhauses:

- schließt das Krankenhausfenster automatisch,
- deaktiviert eine aktive Direct-to-base-Route,
- speichert die aktuelle Heli-Position beim Auswählen als festen Startpunkt der Hospital-Route, aktiviert die rote Direct-To-Linie zur Mitte des ausgewählten Krankenhauses und
- zeigt Krankenhausname, Bearing, Entfernung, Groundspeed und ETA im Moving-Map-Overlay.

Ist bereits eine Krankenhausnavigation aktiv, steht beim erneuten Öffnen der Hospitals-Liste **Cancel direction to hospital** ganz oben. Das Abbrechen entfernt das Krankenhaus-Ziel und wechselt zu einer aktiven Einsatzroute zurück, sofern ein Einsatz vorhanden ist. Auch ein neuer Einsatz entfernt automatisch eine aktive Base-/Hospital-Direct-To-Übersteuerung.

Krankenhausergebnisse werden persistent unter `HEMS_Dispatch/cache/` gespeichert und nur über **Reload hospital list** (oder bei fehlendem passenden Cache) erneut über Overpass geladen.

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

- SimHeaven-Straßenszenerie-Ordner (`simheaven.road_scenery_folder`)
- Einsatzradius und Straßensuchradius (einschließlich eigenem Radius für manuelle Kartenpositionen)
- Einsatzwahrscheinlichkeiten
- Gewichtung der Straßenklassen
- Anzahl und Typ der Einsatzfahrzeuge
- RescueX-Objektzuordnung
- maximale Geländeneigung
- Größe, Zoom und Update-Raten der Moving Map
- Intervall und Mindestbewegung der Flugspur
- Dauer der Heading-Prognose (Standard: 120 Sekunden)
- OSM-Tile-URL, Download-Einstellungen und rollierendes GPU-Texturbudget
- Zoom der automatischen Einsatzvorschau (`moving_map.mission_preview_zoom`)
- Krankenhaus-Suchradien, Overpass-Endpunkt, Request-Timeout und persistentes Krankenhaus-Caching

Für das installierte SimHeaven-Straßennetz den Wert `road_scenery_folder` im vorhandenen Abschnitt `simheaven` der `config.lua` ändern. **Nur einen** der folgenden Werte verwenden:

**X-World Europe (Standard):**

```lua
road_scenery_folder = "simHeaven_X-World_Europe-8-network",
```

**X-World Pro Europe:**

```lua
road_scenery_folder = "simHeaven_X-WORLD-Pro_Europe-13-net3-roads",
```

Den tatsächlichen Namen des aktivierten Ordners unter `Custom Scenery` verwenden (am besten mit originaler Groß-/Kleinschreibung übernehmen). Keinen absoluten Pfad und keinen abschließenden Schrägstrich eintragen.

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

- Die automatische SimHeaven-Erkennung verwendet `simheaven.road_scenery_folder` und benötigt einen entsprechenden aktivierten Eintrag in `Custom Scenery/scenery_packs.ini`.
- Straßendaten werden lokal indiziert und pro DSF-Tile gecacht.
- Autobahn-Subtypes werden erkannt, standardmäßig aber nicht für Einsätze verwendet.
- Der Forest-Layer wird nicht zur Einsatzklassifizierung ausgewertet.
- OpenStreetMap wird für den Kartenhintergrund der Moving Map und die Krankenhaussuche verwendet; die Einsatzgenerierung ist nicht von Online-OSM-Daten abhängig.

## Drittanbieter-Inhalte

SimHeaven X-World Europe, RescueX_Lib, FlyWithLua NG+ und OpenStreetMap sind eigenständige Drittanbieter-Projekte und werden nicht als Bestandteil von HEMS Dispatch ausgeliefert. Die jeweiligen Lizenz- und Nutzungsbedingungen gelten unabhängig davon.
