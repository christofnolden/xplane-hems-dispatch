# Changelog

All notable changes to HEMS Dispatch are documented in this file.

## 1.0.13 — 2026-10-04

### Fixed
- Fixed an X-Plane crash when pressing the **Hospitals** button in the Moving Map.
- The Hospitals floating window is no longer created directly from the Moving Map ImGui draw callback. Opening it is now queued and performed from the existing pre-flightloop callback, matching the safe deferred-action pattern already used for mission controls.
- Hospital/Overpass loading behavior, 50 km initial search, 100 km **Load more**, caching and Direct-To logic remain unchanged.

## 1.0.12 — 2026-10-04

### Added
- Added a **Hospitals** button to the Moving Map toolbar.
- Added an asynchronous hospital search using OpenStreetMap data through the Overpass API.
- The Hospitals window initially loads hospitals within **50 km** of the current helicopter position and sorts them by distance.
- Added **Load more (up to 100 km)**. The 100 km Overpass request is started only after the button is pressed; there is no background prefetch.
- Selecting a hospital closes the selection window and activates the existing red Direct-To line to the hospital center.
- When hospital navigation is active, the Hospitals window shows **Cancel direction to hospital** as the first action.
- Added a short-lived local hospital cache under `HEMS_Dispatch/cache/` to avoid unnecessary repeated Overpass requests near the same position.

### Changed
- Direct-To targets are now mutually exclusive: selecting a hospital disables Direct to base; selecting Direct to base disables hospital navigation; a new mission clears either override and returns navigation to the new mission.
- The Moving Map status overlay displays the selected hospital name together with bearing, distance, groundspeed and ETA.
- README, configuration and version metadata updated to 1.0.12.

## 1.0.11 — 2026-10-03

### Added
- Added **Set Base Position** to the HEMS Dispatch plugin menu. It stores the helicopter's current latitude/longitude as a persistent home base.
- Added the bindable X-Plane command `hems_dispatch/set_base_position`.
- Added a Home icon to the Moving Map toolbar for **Direct to base** navigation.
- Direct to base draws the existing red Direct-To line from the current helicopter position to the saved Base Position and shows bearing, distance, groundspeed and ETA for the base in the map overlay.
- The saved Base Position is restored across HEMS Dispatch/X-Plane reloads from `HEMS_Dispatch/output/base_position.dat`.

### Changed
- Pressing the Home icon again disables Direct to base and returns Direct-To navigation to the active mission when available.
- Starting a new mission automatically disables Direct to base while keeping the saved Base Position.
- README and version metadata updated to 1.0.11.

## 1.0.10 — 2026-10-03

### Changed
- Replaced the one-way X-Plane command `hems_dispatch/show_moving_map` with `hems_dispatch/toggle_moving_map`.
- The Moving Map can now be opened and closed with the same keyboard, joystick, or VR-controller assignment.
- The **Plugins > HEMS Dispatch > Moving Map** menu entry now uses the same toggle command.
- README and version metadata updated to 1.0.10.

## 1.0.9 — 2026-10-03

### Fixed
- Aligned the Moving Map toolbar panel with the visible map canvas so it no longer extends past the map on the right.

### Changed
- Switched the complete HEMS Dispatch runtime UI to English, including the plugin menu, Moving Map controls and tooltips, mission information window, mission names, status messages, command descriptions, loading/error messages, and generated mission text output.
- Version and OpenStreetMap user agent updated to 1.0.9.

## 1.0.8 — 2026-10-03

### Changed

- Redesigned the Moving Map interface with a more modern, compact toolbar.
- The Moving Map now uses the remaining ImGui content area dynamically when the floating window is resized.
- Removed the previous fixed internal map minimum size that could force scrollbars in smaller window sizes.
- Navigation controls use compact icon buttons; mission controls are visually separated and color-coded.
- Bearing, distance, groundspeed and ETA were moved from the separate line below the map into a semi-transparent status overlay directly on the map.
- OpenStreetMap attribution is displayed as a compact badge in the upper-right corner of the map.
- The minimum floating-window size was reduced to `440 x 320` boxels while retaining a responsive layout.
- Version updated to 1.0.8.

### Notes

- Mission generation, deferred mission actions, OSM downloading, Direct-To navigation, map panning, Follow Aircraft and flight-track sampling remain functionally unchanged.

## 1.0.7 — 2026-10-03

### Changed

- **End Active Mission** no longer opens the **HEMS Dispatch - Mission Information** window after a successful mission end.
- This applies both to **Plugins > HEMS Dispatch > End Active Mission** and to the corresponding Moving Map button.
- The automatic mission information window is now limited to a successful **New Mission** action started from the plugin menu, depending on `output.auto_open_info_window`.
- Version updated to 1.0.7.

### Notes

- Errors while ending a mission may still open the mission information window so that error messages remain visible.
- Moving Map, OSM, tracking, panning, Follow Aircraft, Direct-To, Road/DSF cache and mission generation remain functionally unchanged.

## 1.0.6 — 2026-10-03

### Changed

- **End Active Mission** from the Moving Map no longer opens the **HEMS Dispatch - Mission Information** window after a successful mission end.
- **End Active Mission** from the plugin menu retained its previous behavior in this version.
- The existing deferred-action context now also passes UI options for mission termination through the safe pre-flightloop execution path.
- Version updated to 1.0.6.

### Notes

- Errors while ending a mission may still open the mission information window so that error messages remain visible.
- OSM, panning, Follow Aircraft, Direct-To, flight tracking, Road/DSF cache and mission generation remain functionally unchanged.

## 1.0.5 — 2026-10-03

### Changed

- **New Mission** from the Moving Map no longer automatically opens the **HEMS Dispatch - Mission Information** window after successful mission generation.
- **New Mission** from the plugin menu retains the previous behavior and continues to open the mission information window according to `output.auto_open_info_window`.
- The deferred-action context can pass options to mission generation without changing the safe pre-flightloop execution introduced in v1.0.4.
- The Center / Follow Aircraft button now uses the normal ImGui button height and matches the other toolbar buttons.
- The navigation icon in the Follow button was adjusted to the smaller standard button height.
- Version updated to 1.0.5.

### Notes

- Mission-generation errors may still open the mission information window so that error messages remain visible.
- The Road/DSF cache and the known short 1–3 second pause when a tile is indexed for the first time were intentionally left unchanged.
- OSM, panning, Follow Aircraft, Direct-To and flight tracking remain functionally unchanged.

## 1.0.4 — 2026-10-03

### Fixed

- Fixed X-Plane crashes when triggering **New Mission** or **End Active Mission** directly from the Moving Map.
- Moving Map mission buttons no longer execute mission or RescueX logic inside the ImGui/draw callback.
- Added a deferred-action queue for Moving Map mission actions, processed in the FlyWithLua pre-flightloop of the following frame.
- Creation, positioning and destruction of XPLM instances now takes place outside the drawing callback.
- Repeated rapid clicks are blocked while a mission action is already pending.

### Changed

- Version updated to 1.0.4.
- README expanded with the safe deferred-execution path used by the Moving Map mission buttons.

### Notes

- Existing plugin-menu commands remain unchanged and continue to be processed directly.
- The short pause while initially reading an uncached SimHeaven DSF tile is unrelated to this crash fix.

## 1.0.3 — 2026-10-03

### Added

- Free Moving Map panning via mouse drag.
- Follow Aircraft mode with a dedicated navigation-icon button; manual panning automatically disables Follow, while the button recenters the map on the aircraft and enables Follow again.
- Orange (`#ffa500`) flight track showing the actually flown route.
- Configurable track sampling with defaults of **0.5 seconds** and **3 meters minimum movement**.
- Background tracking through a throttled FlyWithLua callback so the flight track continues while the Moving Map window is temporarily closed.
- **Reset Track** button for manually clearing the recorded route.
- **New Mission** and **End Mission** buttons directly inside the Moving Map while keeping the existing plugin-menu entries.
- Inverse Web Mercator conversion for geographically stable map panning across zoom levels.

### Changed

- Direct-To line changed from orange to red (`#ff0000`).
- Removed the numeric zoom-level display from the toolbar to make room for the additional controls.
- Direct-To geometry now supports freely panned map views and is clipped correctly at the visible map edge when the aircraft or target is outside the viewport.
- Track rendering is clipped to the visible map area and cached for unchanged map views.
- Minimum Moving Map width increased to 520 px so the complete toolbar remains usable.
- README expanded with panning, Follow Aircraft, flight tracking, track reset and mission controls from the Moving Map.
- Version updated to 1.0.3.

### Compatibility

- Existing missions, RescueX configuration and X-Plane commands remain compatible.
- The plugin menu remains available in parallel with the Moving Map controls.
- `track_interval_seconds` and `track_min_distance_m` are optional Moving Map configuration values; defaults are 0.5 seconds and 3 meters.

## 1.0.2 — 2026-10-03

### Added

- Integrated, movable and resizable OpenStreetMap Moving Map as a FlyWithLua ImGui window.
- New **Moving Map** menu entry and bindable X-Plane command `hems_dispatch/show_moving_map`.
- North-Up map with live aircraft position and heading-dependent aircraft symbol.
- Permanent Direct-To line from the current position to the active mission location, including target-direction indication at the map edge when the target is outside the viewport.
- Live display of true bearing, distance in NM, groundspeed and ETA.
- `+` / `-` zoom with configurable limits; default zoom 14, range 10–16.
- Web Mercator / slippy-map calculations for OSM tiles.
- Local OSM tile cache under `HEMS_Dispatch/cache/osm/`.
- Asynchronous tile downloads via `curl` to avoid blocking the X-Plane render path with network requests.
- Offline fallback: navigation and Direct-To remain active even when map tiles are unavailable.
- Configurable GPU texture limit for long FlyWithLua sessions.

### Changed

- Version updated to 1.0.2.
- The Moving Map opens automatically after successful mission generation by default.
- Navigation calculations were decoupled from rendering: navigation defaults to 10 Hz, ETA/text to 1 Hz and tile management to 0.5 seconds; the ImGui window only draws already calculated values each frame.
- README expanded with Moving Map usage, OSM cache, offline behavior, performance concept and configuration parameters.

### Compatibility

- Existing mission, SimHeaven and RescueX configuration remains compatible.
- `moving_map` is a new configuration block; older configurations without it continue to work with internal defaults.
- Online tile downloads require `curl` (`curl.exe` on Windows, `curl` on macOS/Linux); mission generation itself remains fully independent of internet access.

## 1.0.1 — 2026-10-03

### Added

- HRI-v2 cache with road-chain topology and junction connections.
- Assignment of each mission candidate to a specific road chain and position inside that chain.
- Local road path for mission-scene placement with a default resolution of 2 meters.
- Validation of available continuous road length before a scene is created.
- Adaptive one-sided vehicle placement for missions without crashed vehicles when sufficient road space is available only on one side of the incident.
- Candidate selection from multiple random hits within one location attempt so unsuitable road sections can be rejected without immediately selecting a new target area.

### Changed

- Emergency vehicles are now positioned longitudinally along the actual SimHeaven road geometry instead of along a single tangent at the incident point.
- Local vehicle heading is calculated separately for each position along the road path.
- Junctions remain valid mission locations; a geometrically continuous connected road chain is preferred when traversing an intersection.
- Traffic accidents validate the required road space based on the actual randomized number of emergency and crashed vehicles.
- Medical missions no longer require symmetrical road length on both sides of the incident.
- Mission planning determines vehicle counts before candidate validation so location suitability matches the scene that will actually be created.
- HRI format increased from version 1 to version 2; older `.hri` files are automatically rebuilt.
- README was cleaned up for public distribution and technical version history moved into this changelog.

### Compatibility

- Existing mission and RescueX configuration remains compatible.
- `dispatch.scene_path_resolution_m` is optional; the default is `2.0` m when omitted.
- No changes to registered X-Plane commands or plugin-menu entries.

## 1.0.0 — 2026-10-02

### Added

- First stable release of HEMS Dispatch for X-Plane 12.
- SimHeaven-based mission candidates from `8-network`.
- Medical emergencies and traffic accidents with weighted mission selection.
- RescueX instancing for RTW, NEF, fire brigade, police and crashed vehicles.
- Freely configurable emergency-unit combinations per mission type.
- 1–3 random crashed vehicles for traffic accidents.
- Terrain validation including water and slope filtering.
- Pitch/roll alignment to the terrain normal.
- Uniformly distributed dispatch target distance between the configured minimum and maximum radius.
- Automatic replacement of the active mission through **New Mission**.
- Text output of the active mission for VR workflows.
