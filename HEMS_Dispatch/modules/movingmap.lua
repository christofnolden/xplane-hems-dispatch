local M = {}

M.window = nil
M.zoom = 14
M.follow_aircraft = true
-- North-Up by default. Heading-Up rotates the OSM imagery and all world overlays
-- together; screen UI elements (toolbar/status) always remain upright.
M.heading_up = false
M.map_rotation_deg = 0
M.map_rotation_cos = 1
M.map_rotation_sin = 0
M.last_rotation_update = -1000
M.quad_image_mode = nil
M.map_center_lat = nil
M.map_center_lon = nil
M.base_position = nil
M.direct_to_base = false
M.base_route_start = nil
M.hospital_target = nil
M.hospital_route_start = nil
M.mission_route_start = nil
M.nav = {
    valid = false,
    lat = nil,
    lon = nil,
    heading_deg = 0,
    target_lat = nil,
    target_lon = nil,
    target_kind = nil,
    bearing_true_deg = nil,
    distance_km = nil,
    distance_nm = nil,
    groundspeed_kt = nil,
    eta_seconds = nil,
}
M.track_points = {}
M.track_revision = 0
M.last_track_sample = -1000
M.track_render_cache = nil
M.track_file = nil
M.track_segment_pending = false
M.track_persistence_warned = false
M.last_nav_update = -1000
M.last_info_update = -1000
M.last_tile_prepare = -1000
M.last_canvas_width = 0
M.last_canvas_height = 0
M.last_visible_tiles = {}
M.warned_pan_unavailable = false
-- Single in-map dialog state: confirmation, custom mission type selection, or
-- a pending user map click. No mission scene work happens in the draw callback.
M.dialog = nil
M.custom_pick_type = nil
M.custom_mouse_down = nil
M.custom_mouse_moved = false
M.gettime = os.clock

local ok_socket, socket_mod = pcall(require, "socket")
if ok_socket and socket_mod and type(socket_mod.gettime) == "function" then
    M.gettime = socket_mod.gettime
end

local function cfg()
    return (HEMS.config and HEMS.config.moving_map) or {}
end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function monotonic_seconds()
    return M.gettime()
end

local function read_dataref(path, fallback)
    if type(get) == "function" then
        local ok, value = pcall(get, path)
        if ok and tonumber(value) then return tonumber(value) end
    end
    return fallback
end

local function set_follow_aircraft(enabled)
    M.follow_aircraft = enabled and true or false
    if M.follow_aircraft and M.nav.valid then
        M.map_center_lat = M.nav.lat
        M.map_center_lon = M.nav.lon
    end
    M.track_render_cache = nil
end

local function update_nav(force)
    local now = monotonic_seconds()
    local hz = tonumber(cfg().nav_update_hz) or 10
    if hz < 1 then hz = 1 end
    local interval = 1.0 / hz
    if not force and now - M.last_nav_update < interval then return end
    M.last_nav_update = now

    local lat = tonumber(LATITUDE)
    local lon = tonumber(LONGITUDE)
    if not lat or not lon then
        M.nav.valid = false
        return
    end

    M.nav.valid = true
    M.nav.lat = lat
    M.nav.lon = lon
    M.nav.heading_deg = read_dataref("sim/flightmodel/position/psi", tonumber(HEADING) or 0) or 0
    M.nav.groundspeed_kt = (read_dataref("sim/flightmodel/position/groundspeed", 0) or 0) * 1.943844492

    if M.follow_aircraft or not M.map_center_lat or not M.map_center_lon then
        M.map_center_lat = lat
        M.map_center_lon = lon
    end

    local mission = HEMS.active_mission
    local target_lat, target_lon, target_kind
    if mission and not M.mission_route_start then
        -- Keep mission Direct-To geometry fixed from the moment it first becomes
        -- active. This fallback covers unusual state transitions where a mission
        -- exists without having been initialized through set_direct_to_active_mission().
        M.mission_route_start = { lat = lat, lon = lon }
        HEMS.log(string.format(
            "Moving Map: Mission Direct-To start initialized at %.6f/%.6f.",
            lat,
            lon
        ))
    end

    if M.hospital_target then
        target_lat = M.hospital_target.lat
        target_lon = M.hospital_target.lon
        target_kind = "hospital"
    elseif M.direct_to_base and M.base_position then
        target_lat = M.base_position.lat
        target_lon = M.base_position.lon
        target_kind = "base"
    elseif mission then
        target_lat = mission.lat
        target_lon = mission.lon
        target_kind = "mission"
    end

    if target_lat and target_lon then
        M.nav.target_lat = target_lat
        M.nav.target_lon = target_lon
        M.nav.target_kind = target_kind
        M.nav.bearing_true_deg = HEMS.geo.bearing_deg(lat, lon, target_lat, target_lon)
        M.nav.distance_km = HEMS.geo.distance_km(lat, lon, target_lat, target_lon)
        M.nav.distance_nm = M.nav.distance_km / 1.852
    else
        M.nav.target_lat = nil
        M.nav.target_lon = nil
        M.nav.target_kind = nil
        M.nav.bearing_true_deg = nil
        M.nav.distance_km = nil
        M.nav.distance_nm = nil
        M.nav.eta_seconds = nil
    end
end

-- Navigation and the heading prediction use nav_update_hz (10 Hz by default).
-- Heading-Up orientation is sampled separately at 5 Hz by default (0.2 s).
-- This does not change heading prediction or flight-track sampling rates.
local function update_map_rotation(force)
    if not M.heading_up then return end
    local now = monotonic_seconds()
    local hz = tonumber(cfg().heading_up_update_hz) or 5
    if hz ~= hz or hz < 1 then hz = 5 end
    if hz > 20 then hz = 20 end
    local interval = 1.0 / hz
    if not force and now - M.last_rotation_update < interval then return end
    if not M.nav.valid then return end
    M.last_rotation_update = now

    local degrees = (tonumber(M.nav.heading_deg) or 0) % 360
    if degrees ~= degrees then return end
    if math.abs(degrees - M.map_rotation_deg) < 0.001 then return end
    M.map_rotation_deg = degrees
    local radians = math.rad(degrees)
    M.map_rotation_cos = math.cos(radians)
    M.map_rotation_sin = math.sin(radians)
    M.track_render_cache = nil
end

local function set_heading_up(enabled)
    if enabled and type(imgui.DrawList_AddImageQuad) ~= "function" then
        HEMS.status_message = "Heading Up unavailable: rotated images are not supported by this FlyWithLua version."
        HEMS.log("Moving Map: " .. HEMS.status_message)
        return false
    end
    M.heading_up = enabled and true or false
    M.last_rotation_update = -1000
    if M.heading_up then
        update_nav(true)
        update_map_rotation(true)
    else
        M.map_rotation_deg = 0
        M.map_rotation_cos = 1
        M.map_rotation_sin = 0
    end
    M.track_render_cache = nil
    M.last_tile_prepare = -1000
    HEMS.log("Moving Map orientation: " .. (M.heading_up and "Heading Up" or "North Up"))
    return true
end

local function update_info(force)
    local now = monotonic_seconds()
    local hz = tonumber(cfg().info_update_hz) or 1
    if hz < 0.2 then hz = 0.2 end
    local interval = 1.0 / hz
    if not force and now - M.last_info_update < interval then return end
    M.last_info_update = now

    if M.nav.distance_nm and M.nav.groundspeed_kt and M.nav.groundspeed_kt >= 5 then
        M.nav.eta_seconds = M.nav.distance_nm / M.nav.groundspeed_kt * 3600.0
    else
        M.nav.eta_seconds = nil
    end
end

local function write_base_position(position)
    local f, err = io.open(HEMS.paths.base_position, "wb")
    if not f then return false, err end
    f:write(string.format("lat=%.8f\n", position.lat))
    f:write(string.format("lon=%.8f\n", position.lon))
    f:write("saved_at=" .. tostring(position.saved_at or os.date("%Y-%m-%d %H:%M:%S")) .. "\n")
    f:close()
    return true
end

function M.load_base_position()
    local f = io.open(HEMS.paths.base_position, "rb")
    if not f then
        M.base_position = nil
        M.direct_to_base = false
        M.base_route_start = nil
        return true
    end

    local raw = f:read("*a") or ""
    f:close()
    local values = {}
    for line in raw:gmatch("[^\r\n]+") do
        local key, value = line:match("^([%w_]+)=(.*)$")
        if key then values[key] = value end
    end

    local lat = tonumber(values.lat)
    local lon = tonumber(values.lon)
    if not lat or not lon or lat < -90 or lat > 90 or lon < -180 or lon > 180 then
        M.base_position = nil
        M.direct_to_base = false
        M.base_route_start = nil
        return false, "base_position.dat contains invalid coordinates"
    end

    M.base_position = { lat = lat, lon = lon, saved_at = values.saved_at }
    M.direct_to_base = false
    M.base_route_start = nil
    HEMS.log(string.format("Base position loaded: %.6f/%.6f", lat, lon))
    return true
end

function M.set_base_position()
    local lat = tonumber(LATITUDE)
    local lon = tonumber(LONGITUDE)
    if not lat or not lon or lat < -90 or lat > 90 or lon < -180 or lon > 180 then
        return false, "current helicopter position is unavailable"
    end

    local position = {
        lat = lat,
        lon = lon,
        saved_at = os.date("%Y-%m-%d %H:%M:%S"),
    }
    local ok, err = write_base_position(position)
    if not ok then return false, "could not save base position: " .. tostring(err) end

    M.base_position = position
    HEMS.status_message = string.format("Base position set: %.5f, %.5f", lat, lon)
    HEMS.log(string.format("Base position set: %.6f/%.6f", lat, lon))
    update_nav(true)
    update_info(true)
    return true
end

function M.clear_direct_to_base()
    if not M.direct_to_base and not M.base_route_start then return false end
    M.direct_to_base = false
    M.base_route_start = nil
    update_nav(true)
    update_info(true)
    return true
end

function M.has_hospital_target()
    return M.hospital_target ~= nil
end

function M.set_hospital_target(hospital)
    if type(hospital) ~= "table" then return false, "invalid hospital" end
    local lat = tonumber(hospital.lat)
    local lon = tonumber(hospital.lon)
    if not lat or not lon or lat < -90 or lat > 90 or lon < -180 or lon > 180 then
        return false, "invalid hospital coordinates"
    end

    local start_lat = tonumber(LATITUDE)
    local start_lon = tonumber(LONGITUDE)
    if not start_lat or not start_lon or start_lat < -90 or start_lat > 90 or start_lon < -180 or start_lon > 180 then
        return false, "current helicopter position is unavailable"
    end

    M.direct_to_base = false
    M.base_route_start = nil
    M.hospital_target = {
        lat = lat,
        lon = lon,
        name = tostring(hospital.name or "Hospital"),
        osm_id = hospital.osm_id,
        osm_type = hospital.osm_type,
    }
    M.hospital_route_start = { lat = start_lat, lon = start_lon }
    HEMS.status_message = "Direct to hospital enabled: " .. M.hospital_target.name
    HEMS.log(string.format(
        "Moving Map: Direct to hospital enabled from %.6f/%.6f to %s (%.6f/%.6f).",
        start_lat,
        start_lon,
        M.hospital_target.name,
        lat,
        lon
    ))
    update_nav(true)
    update_info(true)
    return true
end

function M.clear_hospital_target()
    if not M.hospital_target and not M.hospital_route_start then return false end
    local name = M.hospital_target and M.hospital_target.name or nil
    M.hospital_target = nil
    M.hospital_route_start = nil
    HEMS.status_message = "Direct to hospital disabled."
    HEMS.log("Moving Map: Direct to hospital disabled" .. (name and (": " .. tostring(name)) or "") .. ".")
    update_nav(true)
    update_info(true)
    return true
end

function M.clear_mission_route()
    if not M.mission_route_start then return false end
    M.mission_route_start = nil
    update_nav(true)
    update_info(true)
    return true
end

function M.set_direct_to_active_mission(options)
    options = type(options) == "table" and options or {}

    local mission = HEMS.active_mission
    if not mission then
        if options.announce ~= false then
            HEMS.status_message = "No active mission available for Direct-To."
        end
        HEMS.log("Moving Map: Direct to Active mission requested, but no mission is active.")
        return false, "no active mission"
    end

    local lat = tonumber(LATITUDE)
    local lon = tonumber(LONGITUDE)
    if not lat or not lon or lat < -90 or lat > 90 or lon < -180 or lon > 180 then
        if options.announce ~= false then
            HEMS.status_message = "Current helicopter position is unavailable."
        end
        HEMS.log("Moving Map: Direct to Active mission requested, but the helicopter position is unavailable.")
        return false, "current helicopter position is unavailable"
    end

    -- Selecting the mission is an explicit Direct-To action: remove any Base or
    -- Hospital override and replace the previous mission route start with the
    -- helicopter's current position.
    M.direct_to_base = false
    M.base_route_start = nil
    M.hospital_target = nil
    M.hospital_route_start = nil
    M.mission_route_start = { lat = lat, lon = lon }

    if options.announce ~= false then
        HEMS.status_message = "Direct to active mission set."
    end
    HEMS.log(string.format(
        "Moving Map: Direct to Active mission set from %.6f/%.6f to %.6f/%.6f.",
        lat,
        lon,
        tonumber(mission.lat) or 0,
        tonumber(mission.lon) or 0
    ))

    update_nav(true)
    update_info(true)
    return true
end

function M.clear_navigation_override()
    local changed = M.direct_to_base or M.base_route_start ~= nil or M.hospital_target ~= nil or M.hospital_route_start ~= nil
    M.direct_to_base = false
    M.base_route_start = nil
    M.hospital_target = nil
    M.hospital_route_start = nil
    if changed then
        update_nav(true)
        update_info(true)
    end
    return changed
end

function M.toggle_direct_to_base()
    if M.direct_to_base then
        M.direct_to_base = false
        M.base_route_start = nil
        HEMS.status_message = "Direct to base disabled."
        HEMS.log("Moving Map: Direct to base disabled.")
        update_nav(true)
        update_info(true)
        return true
    end

    if not M.base_position then
        HEMS.status_message = "No base position is set. Use Plugins > HEMS Dispatch > Set Base Position first."
        HEMS.log("Moving Map: Direct to base requested, but no base position is set.")
        return false, "base position not set"
    end

    local lat = tonumber(LATITUDE)
    local lon = tonumber(LONGITUDE)
    if not lat or not lon or lat < -90 or lat > 90 or lon < -180 or lon > 180 then
        HEMS.status_message = "Current helicopter position is unavailable."
        HEMS.log("Moving Map: Direct to base requested, but the helicopter position is unavailable.")
        return false, "current helicopter position is unavailable"
    end

    M.hospital_target = nil
    M.hospital_route_start = nil
    M.direct_to_base = true
    M.base_route_start = { lat = lat, lon = lon }
    HEMS.status_message = "Direct to base enabled."
    HEMS.log(string.format(
        "Moving Map: Direct to base enabled from %.6f/%.6f to %.6f/%.6f.",
        lat,
        lon,
        tonumber(M.base_position.lat) or 0,
        tonumber(M.base_position.lon) or 0
    ))
    update_nav(true)
    update_info(true)
    return true
end


local function close_track_file()
    if M.track_file then
        pcall(function() M.track_file:flush() end)
        pcall(function() M.track_file:close() end)
        M.track_file = nil
    end
end

local function append_track_point(point)
    if not HEMS.paths or not HEMS.paths.flight_track then return true end

    if not M.track_file then
        local f, err = io.open(HEMS.paths.flight_track, "ab")
        if not f then
            if not M.track_persistence_warned then
                M.track_persistence_warned = true
                HEMS.log("Moving Map: Flight track could not be persisted: " .. tostring(err))
            end
            return false
        end
        pcall(function() f:setvbuf("line") end)
        M.track_file = f
    end

    local break_flag = point.break_before and 1 or 0
    local ok, err = pcall(function()
        local written, write_err = M.track_file:write(
            string.format("%.8f\t%.8f\t%d\n", point.lat, point.lon, break_flag)
        )
        if not written then error(write_err or "write failed") end
        local flushed, flush_err = M.track_file:flush()
        if not flushed then error(flush_err or "flush failed") end
    end)
    if not ok then
        if not M.track_persistence_warned then
            M.track_persistence_warned = true
            HEMS.log("Moving Map: Flight track could not be persisted: " .. tostring(err))
        end
        close_track_file()
        return false
    end
    return true
end

function M.load_track()
    close_track_file()
    M.track_points = {}
    M.track_revision = M.track_revision + 1
    M.track_render_cache = nil
    M.last_track_sample = -1000
    M.track_segment_pending = false
    M.track_persistence_warned = false

    if not HEMS.paths or not HEMS.paths.flight_track then return true end
    local f = io.open(HEMS.paths.flight_track, "rb")
    if not f then return true end

    local loaded = 0
    local invalid = 0
    for line in f:lines() do
        line = line:gsub("\r$", "")
        if line ~= "" then
            local lat_text, lon_text, break_text = line:match("^([^\t]+)\t([^\t]+)\t([01])$")
            local lat = tonumber(lat_text)
            local lon = tonumber(lon_text)
            if lat and lon and lat >= -90 and lat <= 90 and lon >= -180 and lon <= 180 then
                M.track_points[#M.track_points + 1] = {
                    lat = lat,
                    lon = lon,
                    break_before = break_text == "1",
                }
                loaded = loaded + 1
            else
                invalid = invalid + 1
            end
        end
    end
    f:close()

    -- A script/X-Plane reload starts a new visual track segment so a new flight
    -- is never connected to the previous flight by an artificial straight line.
    M.track_segment_pending = loaded > 0
    if loaded > 0 then
        HEMS.log(string.format("Moving Map: Loaded %d persisted flight-track points.", loaded))
    end
    if invalid > 0 then
        HEMS.log(string.format("Moving Map: Ignored %d invalid persisted flight-track line(s).", invalid))
    end
    return true
end

local function sample_track(force)
    if not HEMS.initialized then return end

    local now = monotonic_seconds()
    local interval = tonumber(cfg().track_interval_seconds) or 0.5
    if interval < 0.1 then interval = 0.1 end
    if not force and now - M.last_track_sample < interval then return end
    M.last_track_sample = now

    local lat = tonumber(LATITUDE)
    local lon = tonumber(LONGITUDE)
    if not lat or not lon then return end

    local last = M.track_points[#M.track_points]
    local break_before = M.track_segment_pending and #M.track_points > 0 or false
    if last then
        local min_distance_m = tonumber(cfg().track_min_distance_m) or 3.0
        if min_distance_m < 0 then min_distance_m = 0 end
        local distance_m = HEMS.geo.distance_km(last.lat, last.lon, lat, lon) * 1000.0
        if distance_m < min_distance_m then return end

        -- A multi-kilometre position jump between two samples indicates a new
        -- flight/teleport rather than real helicopter movement. Keep the stored
        -- history, but start a separate visual segment instead of drawing a long
        -- artificial connector across the map.
        if distance_m > 2000.0 then
            break_before = #M.track_points > 0
        end
    end

    local point = {
        lat = lat,
        lon = lon,
        break_before = break_before,
    }
    M.track_segment_pending = false
    M.track_points[#M.track_points + 1] = point
    M.track_revision = M.track_revision + 1
    M.track_render_cache = nil
    append_track_point(point)
end

function M.background_update()
    sample_track(false)
end

function M.reset_track()
    close_track_file()
    if HEMS.paths and HEMS.paths.flight_track then
        local track_path = HEMS.paths.flight_track
        local existing = io.open(track_path, "rb")
        if existing then
            existing:close()
            local removed, err = os.remove(track_path)
            if not removed then
                -- Some Windows file-system setups disallow removing a file but
                -- permit truncating it. Never claim the history was removed if
                -- both operations fail: otherwise it would reappear on reload.
                local truncated, truncate_err = io.open(track_path, "wb")
                if truncated then
                    truncated:close()
                else
                    local message = "Moving Map: Persisted flight track could not be reset: "
                        .. tostring(err or truncate_err)
                    HEMS.log(message)
                    HEMS.status_message = message
                    return false
                end
            end
        end
    end
    M.track_points = {}
    M.track_revision = M.track_revision + 1
    M.last_track_sample = -1000
    M.track_render_cache = nil
    M.track_segment_pending = false
    M.track_persistence_warned = false
    sample_track(true)
    HEMS.log("Moving Map: Persisted flight track reset.")
end

local function format_eta(seconds)
    if not seconds or seconds < 0 then return "--:--" end
    local total = math.floor(seconds + 0.5)
    local hours = math.floor(total / 3600)
    local minutes = math.floor((total % 3600) / 60)
    local secs = total % 60
    if hours > 0 then
        return string.format("%d:%02d:%02d", hours, minutes, secs)
    end
    return string.format("%02d:%02d", minutes, secs)
end

-- Rotates screen/world offsets clockwise in world coordinates by -heading:
-- when the aircraft heads east (090), east is at the top of the map.
local function rotate_map_offset(dx, dy)
    if M.map_rotation_deg == 0 then return dx, dy end
    return dx * M.map_rotation_cos + dy * M.map_rotation_sin,
           -dx * M.map_rotation_sin + dy * M.map_rotation_cos
end

local function map_point(lat, lon, center_world_x, center_world_y, zoom, canvas_x, canvas_y, width, height)
    local wx, wy = HEMS.osm.latlon_to_world_px(lat, lon, zoom)
    local dx = wx - center_world_x
    local world_width = HEMS.osm.TILE_SIZE * (2 ^ zoom)
    if dx > world_width * 0.5 then dx = dx - world_width end
    if dx < -world_width * 0.5 then dx = dx + world_width end
    local rx, ry = rotate_map_offset(dx, wy - center_world_y)
    return canvas_x + width * 0.5 + rx, canvas_y + height * 0.5 + ry
end

local function point_in_rect(x, y, left, top, right, bottom)
    return x >= left and x <= right and y >= top and y <= bottom
end

-- Liang-Barsky clipping. Returns the visible part of the segment and preserves
-- the aircraft -> target direction, which matters for the target edge marker.
local function clip_line_to_rect(x0, y0, x1, y1, left, top, right, bottom)
    local dx = x1 - x0
    local dy = y1 - y0
    local t0 = 0.0
    local t1 = 1.0

    local function clip(p, q)
        if math.abs(p) < 1e-9 then return q >= 0 end
        local r = q / p
        if p < 0 then
            if r > t1 then return false end
            if r > t0 then t0 = r end
        else
            if r < t0 then return false end
            if r < t1 then t1 = r end
        end
        return true
    end

    if not clip(-dx, x0 - left) then return nil end
    if not clip(dx, right - x0) then return nil end
    if not clip(-dy, y0 - top) then return nil end
    if not clip(dy, bottom - y0) then return nil end

    return x0 + t0 * dx, y0 + t0 * dy, x0 + t1 * dx, y0 + t1 * dy
end

local function draw_aircraft(cx, cy, heading_deg)
    local a = math.rad(heading_deg or 0)
    local ca = math.cos(a)
    local sa = math.sin(a)

    local function rotate(px, py)
        -- Shape coordinates use +Y down; heading 0 points north/up.
        return cx + px * ca + py * sa, cy + px * sa - py * ca
    end

    local x1, y1 = rotate(0, 13)
    local x2, y2 = rotate(-8, -8)
    local x3, y3 = rotate(0, -4)
    local x4, y4 = rotate(8, -8)

    imgui.DrawList_AddTriangleFilled(x1, y1, x2, y2, x4, y4, 0xFF33CCFF)
    imgui.DrawList_AddLine(x2, y2, x3, y3, 0xFF202020, 2.0)
    imgui.DrawList_AddLine(x3, y3, x4, y4, 0xFF202020, 2.0)
    imgui.DrawList_AddCircle(cx, cy, 14, 0xCCFFFFFF, 24, 1.5)
end

local function draw_target(x, y)
    -- #ff0000 in Dear ImGui's AABBGGRR color layout.
    local color = 0xFF0000FF
    imgui.DrawList_AddCircleFilled(x, y, 8, color)
    imgui.DrawList_AddLine(x - 11, y, x + 11, y, 0xFFFFFFFF, 2.0)
    imgui.DrawList_AddLine(x, y - 11, x, y + 11, 0xFFFFFFFF, 2.0)
end

-- FlyWithLua renders OSM tiles with imgui.Image in North-Up. Heading-Up
-- needs ImDrawList::AddImageQuad, which rotates the actual tile textures (not
-- just the flight-path overlays). Support alternative binding signatures and
-- fall back safely to North-Up if the host cannot render quads.
local function draw_rotated_tile(texture, x, y, size, canvas_cx, canvas_cy)
    local function corner(px, py)
        local rx, ry = rotate_map_offset(px - canvas_cx, py - canvas_cy)
        return canvas_cx + rx, canvas_cy + ry
    end
    local ax, ay = corner(x, y)
    local bx, by = corner(x + size, y)
    local cx, cy = corner(x + size, y + size)
    local dx, dy = corner(x, y + size)
    local quad = imgui.DrawList_AddImageQuad

    local function call_quad(mode)
        if mode == 1 then
            return quad(texture, ax, ay, bx, by, cx, cy, dx, dy)
        elseif mode == 2 then
            return quad(texture, ax, ay, bx, by, cx, cy, dx, dy,
                0, 0, 1, 0, 1, 1, 0, 1)
        else
            return quad(texture, ax, ay, bx, by, cx, cy, dx, dy,
                0, 0, 1, 0, 1, 1, 0, 1, 0xFFFFFFFF)
        end
    end

    if M.quad_image_mode then
        return pcall(call_quad, M.quad_image_mode)
    end
    -- Probe once on the first tile; then render directly on subsequent frames.
    for _, mode in ipairs({ 1, 2, 3 }) do
        local ok = pcall(call_quad, mode)
        if ok then
            M.quad_image_mode = mode
            return true
        end
    end
    return false, "ImGui DrawList_AddImageQuad signature is unsupported"
end

local function draw_tiles(canvas_x, canvas_y, width, height, tiles, coverage_size)
    if not imgui.SetCursorScreenPos or not imgui.Image then return false end
    local any = false
    local rotated = M.heading_up and M.map_rotation_deg ~= 0
    local shift_x = coverage_size and (width - coverage_size) * 0.5 or 0
    local shift_y = coverage_size and (height - coverage_size) * 0.5 or 0
    local center_x, center_y = canvas_x + width * 0.5, canvas_y + height * 0.5
    for _, tile in ipairs(tiles or {}) do
        local texture = HEMS.osm.texture_for(tile.z, tile.x, tile.y)
        if texture then
            local x, y = canvas_x + shift_x + tile.screen_x, canvas_y + shift_y + tile.screen_y
            if rotated then
                local ok, err = draw_rotated_tile(texture, x, y, HEMS.osm.TILE_SIZE, center_x, center_y)
                if not ok then
                    -- Failure must never propagate into the FlyWithLua draw loop.
                    HEMS.status_message = "Heading Up unavailable: " .. tostring(err)
                    HEMS.log("Moving Map: " .. HEMS.status_message)
                    set_heading_up(false)
                    -- Continue with the original reliable North-Up tile renderer.
                    rotated = false
                end
            end
            if not rotated then
                imgui.SetCursorScreenPos(x, y)
                imgui.Image(texture, HEMS.osm.TILE_SIZE, HEMS.osm.TILE_SIZE)
            end
            any = true
        end
    end
    return any
end

local function current_map_center()
    if M.map_center_lat and M.map_center_lon then
        return M.map_center_lat, M.map_center_lon
    end
    if M.nav.valid then return M.nav.lat, M.nav.lon end
    return nil, nil
end

local function prepare_map(width, height)
    if not M.nav.valid then return {}, 0, 0 end
    local center_lat, center_lon = current_map_center()
    if not center_lat or not center_lon then return {}, 0, 0 end

    -- A diagonal-size square covers the entire canvas at every heading and
    -- prevents uncovered map corners during turns. Tiles remain standard 256px
    -- images, only their screen quads are rotated.
    local coverage = M.heading_up and math.ceil(math.sqrt(width * width + height * height)) or nil
    local coverage_width, coverage_height = coverage or width, coverage or height
    local tiles, center_x, center_y = HEMS.osm.visible_tiles(
        center_lat, center_lon, M.zoom, coverage_width, coverage_height)
    M.last_visible_tiles = tiles
    HEMS.osm.set_visible_tiles(tiles)

    local now = monotonic_seconds()
    local interval = tonumber(cfg().tile_prepare_interval_seconds) or 0.5
    if now - M.last_tile_prepare >= interval
        or coverage_width ~= M.last_canvas_width
        or coverage_height ~= M.last_canvas_height then
        M.last_tile_prepare = now
        M.last_canvas_width = coverage_width
        M.last_canvas_height = coverage_height
        HEMS.osm.prepare_tiles(tiles)
    end
    return tiles, center_x, center_y, coverage
end

local function unpack_vec2(a, b)
    if type(a) == "table" then
        return tonumber(a[1] or a.x) or 0, tonumber(a[2] or a.y) or 0
    end
    return tonumber(a) or 0, tonumber(b) or 0
end


local function content_region_avail()
    if imgui.GetContentRegionAvail then
        local a, b = imgui.GetContentRegionAvail()
        local w, h = unpack_vec2(a, b)
        if w > 0 and h > 0 then
            return w, h
        end
    end

    -- FlyWithLua 2.8.14 exposes the cursor/window helpers used by its own demo.
    -- This fallback keeps the layout responsive even if GetContentRegionAvail is
    -- unavailable in a particular ImGui binding.
    local cursor_x = imgui.GetCursorPosX and imgui.GetCursorPosX() or 8
    local cursor_y = imgui.GetCursorPosY and imgui.GetCursorPosY() or 8
    local width = (imgui.GetWindowWidth and imgui.GetWindowWidth() or 620) - cursor_x - 8
    local height = (imgui.GetWindowHeight and imgui.GetWindowHeight() or 620) - cursor_y - 8
    return math.max(1, width), math.max(1, height)
end

local function push_button_colors(base, hovered, active)
    if not (imgui.PushStyleColor and imgui.constant and imgui.constant.Col) then return 0 end
    local col = imgui.constant.Col
    if not (col.Button and col.ButtonHovered and col.ButtonActive) then return 0 end
    imgui.PushStyleColor(col.Button, base)
    imgui.PushStyleColor(col.ButtonHovered, hovered)
    imgui.PushStyleColor(col.ButtonActive, active)
    return 3
end

local function pop_style_colors(count)
    if not imgui.PopStyleColor then return end
    for _ = 1, count or 0 do imgui.PopStyleColor() end
end

local function push_hidden_scrollbar_colors()
    if not (imgui.PushStyleColor and imgui.constant and imgui.constant.Col) then return 0 end
    local col = imgui.constant.Col
    local names = { "ScrollbarBg", "ScrollbarGrab", "ScrollbarGrabHovered", "ScrollbarGrabActive" }
    local count = 0
    for _, name in ipairs(names) do
        if col[name] then
            imgui.PushStyleColor(col[name], 0x00000000)
            count = count + 1
        end
    end
    return count
end

local function tooltip(text)
    if imgui.IsItemHovered and imgui.IsItemHovered() and imgui.BeginTooltip then
        imgui.BeginTooltip()
        imgui.TextUnformatted(text)
        imgui.EndTooltip()
    end
end

local function draw_icon_button(id, icon, tooltip_text, active_state)
    local size = 28
    local bx, by = imgui.GetCursorScreenPos()

    local base = active_state and 0xFF5B8F16 or 0xFF312C28
    local hovered = active_state and 0xFF67A51D or 0xFF443C35
    local pressed_color = active_state and 0xFF4B7812 or 0xFF544A41
    local pushed = push_button_colors(base, hovered, pressed_color)
    local pressed = imgui.Button("##hems_toolbar_" .. id, size, size)
    pop_style_colors(pushed)

    local cx = bx + size * 0.5
    local cy = by + size * 0.5
    local color = 0xFFFFFFFF

    if icon == "minus" then
        imgui.DrawList_AddLine(cx - 6, cy, cx + 6, cy, color, 2.0)
    elseif icon == "plus" then
        imgui.DrawList_AddLine(cx - 6, cy, cx + 6, cy, color, 2.0)
        imgui.DrawList_AddLine(cx, cy - 6, cx, cy + 6, color, 2.0)
    elseif icon == "follow" then
        imgui.DrawList_AddTriangleFilled(cx + 6, cy - 7, cx + 2, cy + 7, cx - 7, cy + 2, color)
        imgui.DrawList_AddLine(cx + 1, cy + 2, cx - 5, cy + 7, color, 1.5)
    elseif icon == "orientation" then
        -- Small compass glyph: active/green when map rotation is enabled.
        imgui.DrawList_AddCircle(cx, cy, 9, color, 20, 1.3)
        imgui.DrawList_AddTriangleFilled(cx, cy - 7, cx - 4, cy + 4, cx + 4, cy + 4, color)
        imgui.DrawList_AddLine(cx, cy + 4, cx, cy + 7, color, 1.5)
    elseif icon == "reset" then
        imgui.DrawList_AddCircle(cx, cy, 7, color, 20, 1.8)
        imgui.DrawList_AddTriangleFilled(cx + 5, cy - 7, cx + 10, cy - 6, cx + 7, cy - 2, color)
        -- Mask a small part of the circle to make the reset-arrow opening visible.
        imgui.DrawList_AddLine(cx + 4, cy - 7, cx + 8, cy - 4, base, 3.0)
    elseif icon == "home" then
        imgui.DrawList_AddTriangleFilled(cx, cy - 8, cx - 9, cy, cx + 9, cy, color)
        imgui.DrawList_AddRectFilled(cx - 7, cy - 1, cx + 7, cy + 8, color, 1)
        imgui.DrawList_AddRectFilled(cx - 2, cy + 3, cx + 2, cy + 8, base, 0)
    elseif icon == "mission_target" then
        -- Bullseye/crosshair: explicit Direct-To to the active mission.
        imgui.DrawList_AddCircle(cx, cy, 7, color, 20, 1.8)
        imgui.DrawList_AddCircle(cx, cy, 2.5, color, 16, 1.6)
        imgui.DrawList_AddLine(cx - 10, cy, cx - 6, cy, color, 1.5)
        imgui.DrawList_AddLine(cx + 6, cy, cx + 10, cy, color, 1.5)
        imgui.DrawList_AddLine(cx, cy - 10, cx, cy - 6, color, 1.5)
        imgui.DrawList_AddLine(cx, cy + 6, cx, cy + 10, color, 1.5)
    elseif icon == "hospital" then
        imgui.DrawList_AddRect(cx - 9, cy - 9, cx + 9, cy + 9, color, 2)
        imgui.DrawList_AddRectFilled(cx - 2, cy - 7, cx + 2, cy + 7, color, 1)
        imgui.DrawList_AddRectFilled(cx - 7, cy - 2, cx + 7, cy + 2, color, 1)
    end

    tooltip(tooltip_text)
    return pressed
end

local function draw_text_button(label, width, role)
    local base, hovered, active
    if role == "primary" then
        base, hovered, active = 0xFFD27619, 0xFFE88926, 0xFFB96515
    elseif role == "danger" then
        base, hovered, active = 0xFF34347A, 0xFF414195, 0xFF2A2A65
    else
        base, hovered, active = 0xFF312C28, 0xFF443C35, 0xFF544A41
    end
    local pushed = push_button_colors(base, hovered, active)
    local pressed = imgui.Button(label, width, 28)
    pop_style_colors(pushed)
    return pressed
end

local function draw_status_overlay(canvas_x, canvas_y, width, height)
    local mission = HEMS.active_mission
    local title
    local details

    if M.nav.target_kind == "hospital" and M.hospital_target and M.nav.bearing_true_deg and M.nav.distance_nm then
        title = M.hospital_target.name or "Hospital"
        details = string.format(
            "BRG %03d°T   %.1f NM   GS %.0f kt   ETA %s",
            math.floor(M.nav.bearing_true_deg + 0.5) % 360,
            M.nav.distance_nm,
            M.nav.groundspeed_kt or 0,
            format_eta(M.nav.eta_seconds)
        )
    elseif M.nav.target_kind == "base" and M.nav.bearing_true_deg and M.nav.distance_nm then
        title = "Base"
        details = string.format(
            "BRG %03d°T   %.1f NM   GS %.0f kt   ETA %s",
            math.floor(M.nav.bearing_true_deg + 0.5) % 360,
            M.nav.distance_nm,
            M.nav.groundspeed_kt or 0,
            format_eta(M.nav.eta_seconds)
        )
    elseif mission and M.nav.bearing_true_deg and M.nav.distance_nm then
        title = mission.name
        details = string.format(
            "BRG %03d°T   %.1f NM   GS %.0f kt   ETA %s",
            math.floor(M.nav.bearing_true_deg + 0.5) % 360,
            M.nav.distance_nm,
            M.nav.groundspeed_kt or 0,
            format_eta(M.nav.eta_seconds)
        )
    else
        title = "No active mission"
        details = M.follow_aircraft and "Follow Aircraft active" or "Free map view"
    end

    local title_w = imgui.CalcTextSize(title)
    local details_w = imgui.CalcTextSize(details)
    local overlay_w = math.min(math.max(title_w, details_w) + 24, math.max(120, width - 16))
    local overlay_h = 48
    local ox = canvas_x + 8
    local oy = canvas_y + height - overlay_h - 8

    imgui.DrawList_AddRectFilled(ox, oy, ox + overlay_w, oy + overlay_h, 0xD8181B1F, 6)
    imgui.DrawList_AddRect(ox, oy, ox + overlay_w, oy + overlay_h, 0x663C424A, 6)

    imgui.SetCursorScreenPos(ox + 10, oy + 7)
    imgui.TextUnformatted(title)
    imgui.SetCursorScreenPos(ox + 10, oy + 26)
    imgui.TextUnformatted(details)
end

local function request_map_action(action, options)
    local ok, err = HEMS.request_action(action, options or { show_info_on_success = false })
    if not ok then
        HEMS.status_message = "Moving Map action could not be queued: " .. tostring(err)
        HEMS.log(HEMS.status_message)
    end
    return ok
end

local function start_custom_type_dialog()
    M.custom_pick_type = nil
    M.custom_mouse_down = nil
    M.custom_mouse_moved = false
    M.dialog = { kind = "type" }
end

local function toolbar_action(action)
    if action == "reset_track" then
        M.dialog = { kind = "confirm", action = action }
    elseif action == "custom" then
        if HEMS.active_mission then
            M.dialog = { kind = "confirm", action = action }
        else
            start_custom_type_dialog()
        end
    elseif action == "random" or action == "end" then
        if HEMS.active_mission then
            M.dialog = { kind = "confirm", action = action }
        elseif action == "random" then
            M.dialog = nil
            M.custom_pick_type = nil
            request_map_action("new_mission", { show_info_on_success = false })
        end
    end
end

local function confirm_dialog_action(action)
    M.dialog = nil
    if action == "reset_track" then
        M.reset_track()
    elseif action == "random" then
        M.custom_pick_type = nil
        request_map_action("new_mission", { show_info_on_success = false })
    elseif action == "end" then
        M.custom_pick_type = nil
        request_map_action("end_mission", { show_info_on_success = false })
    elseif action == "custom" then
        start_custom_type_dialog()
    end
end

local function draw_map_dialog(canvas_x, canvas_y, width, height)
    local dialog = M.dialog
    if not dialog then return end
    local panel_w = math.min(400, math.max(260, width - 24))
    local panel_h = dialog.kind == "type" and 185 or 162
    local px = canvas_x + (width - panel_w) * 0.5
    local py = canvas_y + math.max(8, (height - panel_h) * 0.5)
    imgui.DrawList_AddRectFilled(canvas_x, canvas_y, canvas_x + width, canvas_y + height, 0xB915181D, 0)
    imgui.DrawList_AddRectFilled(px, py, px + panel_w, py + panel_h, 0xFF252A31, 7)
    imgui.DrawList_AddRect(px, py, px + panel_w, py + panel_h, 0xFF515A64, 7)

    if dialog.kind == "type" then
        imgui.SetCursorScreenPos(px + 18, py + 13)
        imgui.TextUnformatted("New custom mission")
        imgui.SetCursorScreenPos(px + 18, py + 36)
        imgui.TextUnformatted("Select the type of emergency:")
        imgui.SetCursorScreenPos(px + 18, py + 63)
        if draw_text_button("Medical emergency##hems_custom_medical", panel_w - 36, "primary") then
            M.dialog = nil
            M.custom_pick_type = "medical"
            M.custom_mouse_down = nil
        end
        imgui.SetCursorScreenPos(px + 18, py + 97)
        if draw_text_button("Traffic accident##hems_custom_accident", panel_w - 36, "primary") then
            M.dialog = nil
            M.custom_pick_type = "traffic_accident"
            M.custom_mouse_down = nil
        end
        imgui.SetCursorScreenPos(px + 18, py + 144)
        if draw_text_button("Cancel##hems_type_cancel", panel_w - 36, "normal") then
            M.dialog = nil
        end
    else
        local messages = {
            reset_track = { "Reset flight track?", "Do you really want to delete the", "entire recorded flight track?" },
            ["end"] = { "End active mission?", "Do you really want to end the", "current mission?" },
            random = { "Replace active mission?", "End the current mission and", "generate a new random mission?" },
            custom = { "Replace active mission?", "End the current mission and", "create a new custom mission?" },
        }
        local lines = messages[dialog.action] or { "Please confirm", "Continue with this action?", "" }
        imgui.SetCursorScreenPos(px + 18, py + 18)
        imgui.TextUnformatted(lines[1])
        imgui.SetCursorScreenPos(px + 18, py + 52)
        imgui.TextUnformatted(lines[2])
        imgui.SetCursorScreenPos(px + 18, py + 72)
        imgui.TextUnformatted(lines[3])
        local bw = (panel_w - 48) * 0.5
        imgui.SetCursorScreenPos(px + 18, py + 115)
        if draw_text_button("Yes##hems_confirm_yes", bw, "danger") then
            confirm_dialog_action(dialog.action)
        end
        imgui.SameLine()
        if draw_text_button("No##hems_confirm_no", bw, "normal") then
            M.dialog = nil
        end
    end
end

-- Shared zoom handling for toolbar buttons and bindable X-Plane commands.
-- Keyboard/joystick zoom only affects an already open Moving Map.
local function adjust_zoom(delta)
    if not M.window then return false end
    M.zoom = clamp(M.zoom + delta, tonumber(cfg().min_zoom) or 10, tonumber(cfg().max_zoom) or 16)
    M.track_render_cache = nil
    M.last_tile_prepare = -1000
    return true
end

function M.zoom_in()
    return adjust_zoom(1)
end

function M.zoom_out()
    return adjust_zoom(-1)
end

local function draw_toolbar()
    local available_w = select(1, content_region_avail())
    local x, y = imgui.GetCursorScreenPos()
    local two_rows = available_w < 725
    local toolbar_h = two_rows and 68 or 38
    -- FlyWithLua's child canvas keeps a small internal right-side inset even
    -- when its scrollbars are visually hidden. Match that visible canvas width
    -- so the toolbar panel ends exactly at the map edge.
    local toolbar_right_inset = 15
    local panel_w = math.max(1, available_w - toolbar_right_inset)

    imgui.DrawList_AddRectFilled(x, y, x + panel_w, y + toolbar_h, 0xE81A1D21, 6)
    imgui.DrawList_AddRect(x, y, x + panel_w, y + toolbar_h, 0x553C424A, 6)

    imgui.SetCursorScreenPos(x + 6, y + 5)
    if draw_icon_button("zoom_out", "minus", "Zoom out", false) then
        M.zoom_out()
    end
    imgui.SameLine()
    if draw_icon_button("zoom_in", "plus", "Zoom in", false) then
        M.zoom_in()
    end
    imgui.SameLine()
    if draw_icon_button(
        "follow", "follow",
        M.follow_aircraft and "Follow Aircraft: active" or "Center on aircraft and enable Follow",
        M.follow_aircraft
    ) then
        set_follow_aircraft(true)
        M.last_tile_prepare = -1000
    end
    imgui.SameLine()
    local orientation_tooltip = M.heading_up
        and "Heading Up: active (click for North Up)"
        or "North Up: active (click for Heading Up)"
    if draw_icon_button("orientation", "orientation", orientation_tooltip, M.heading_up) then
        set_heading_up(not M.heading_up)
    end
    imgui.SameLine()
    if draw_icon_button("track_reset", "reset", "Reset flight track", false) then
        toolbar_action("reset_track")
    end
    imgui.SameLine()
    local base_tooltip
    if M.base_position then
        base_tooltip = M.direct_to_base and "Direct to base: active (click to disable)" or "Direct to base"
    else
        base_tooltip = "Direct to base - base position not set"
    end
    if draw_icon_button("direct_base", "home", base_tooltip, M.direct_to_base) then
        M.toggle_direct_to_base()
    end
    imgui.SameLine()
    local mission_direct_active = HEMS.active_mission ~= nil
        and not M.direct_to_base
        and M.hospital_target == nil
        and M.mission_route_start ~= nil
    local mission_tooltip = HEMS.active_mission
        and "Direct to Active mission"
        or "Direct to Active mission - no active mission"
    if draw_icon_button("direct_mission", "mission_target", mission_tooltip, mission_direct_active) then
        M.set_direct_to_active_mission()
    end
    imgui.SameLine()
    local hospital_active = M.hospital_target ~= nil
    local hospital_tooltip = hospital_active and "Hospitals - hospital direction active" or "Hospitals"
    if draw_icon_button("hospitals", "hospital", hospital_tooltip, hospital_active) then
        if HEMS.hospitals then
            -- Never create another FlyWithLua floating window from this ImGui
            -- draw callback. Queue the request for the safe pre-flightloop.
            local ok, err = HEMS.hospitals.request_show()
            if not ok and err then
                HEMS.status_message = "Hospital list could not be opened: " .. tostring(err)
                HEMS.log("Hospitals: " .. HEMS.status_message)
            end
        end
    end

    if two_rows then
        imgui.SetCursorScreenPos(x + 6, y + 37)
    else
        imgui.SameLine()
        imgui.TextUnformatted("|")
        imgui.SameLine()
    end

    if draw_text_button("New random mission", 136, "primary") then
        toolbar_action("random")
    end
    imgui.SameLine()
    if draw_text_button("New custom mission", 142, "primary") then
        toolbar_action("custom")
    end
    imgui.SameLine()
    if draw_text_button("End mission", 100, "danger") then
        toolbar_action("end")
    end

    -- Explicitly advance to the end of the toolbar panel. This prevents hidden
    -- widget extents from forcing the root FlyWithLua ImGui window to scroll.
    imgui.SetCursorScreenPos(x, y + toolbar_h + 4)
end

local function handle_map_pan()
    if M.dialog then return end
    if not imgui.IsWindowHovered or not imgui.IsMouseDragging or not imgui.GetMouseDragDelta then
        if not M.warned_pan_unavailable then
            M.warned_pan_unavailable = true
            HEMS.log("Moving Map: This FlyWithLua ImGui version does not provide the mouse functions required for map panning.")
        end
        return
    end

    if not imgui.IsWindowHovered() or not imgui.IsMouseDragging(0) then return end

    local d1, d2 = imgui.GetMouseDragDelta(0)
    local dx, dy = unpack_vec2(d1, d2)
    if math.abs(dx) < 0.01 and math.abs(dy) < 0.01 then return end
    if M.custom_pick_type then M.custom_mouse_moved = true end

    local center_lat, center_lon = current_map_center()
    if not center_lat or not center_lon then return end

    -- Convert cursor drag from rotated screen space back to North-Up world
    -- coordinates before updating the center. This also preserves free panning
    -- while Heading-Up is active.
    local world_dx = dx * M.map_rotation_cos - dy * M.map_rotation_sin
    local world_dy = dx * M.map_rotation_sin + dy * M.map_rotation_cos
    local center_x, center_y = HEMS.osm.latlon_to_world_px(center_lat, center_lon, M.zoom)
    center_x = center_x - world_dx
    center_y = center_y - world_dy
    M.map_center_lat, M.map_center_lon = HEMS.osm.world_px_to_latlon(center_x, center_y, M.zoom)
    M.follow_aircraft = false
    M.track_render_cache = nil

    if imgui.ResetMouseDragDelta then
        imgui.ResetMouseDragDelta(0)
    end
end

local function build_track_render_cache(center_world_x, center_world_y, canvas_x, canvas_y, width, height)
    local cache = M.track_render_cache
    if cache
        and cache.revision == M.track_revision
        and cache.zoom == M.zoom
        and cache.rotation_deg == M.map_rotation_deg
        and cache.center_world_x == center_world_x
        and cache.center_world_y == center_world_y
        and cache.canvas_x == canvas_x
        and cache.canvas_y == canvas_y
        and cache.width == width
        and cache.height == height then
        return cache.segments
    end

    local segments = {}
    local left, top = canvas_x, canvas_y
    local right, bottom = canvas_x + width, canvas_y + height
    local previous_x, previous_y = nil, nil

    for _, point in ipairs(M.track_points) do
        local x, y = map_point(
            point.lat, point.lon,
            center_world_x, center_world_y, M.zoom,
            canvas_x, canvas_y, width, height
        )
        if previous_x and not point.break_before then
            local x0, y0, x1, y1 = clip_line_to_rect(
                previous_x, previous_y, x, y,
                left, top, right, bottom
            )
            if x0 then
                segments[#segments + 1] = { x0, y0, x1, y1 }
            end
        end
        previous_x, previous_y = x, y
    end

    M.track_render_cache = {
        revision = M.track_revision,
        zoom = M.zoom,
        rotation_deg = M.map_rotation_deg,
        center_world_x = center_world_x,
        center_world_y = center_world_y,
        canvas_x = canvas_x,
        canvas_y = canvas_y,
        width = width,
        height = height,
        segments = segments,
    }
    return segments
end

local function draw_track(center_world_x, center_world_y, canvas_x, canvas_y, width, height)
    if #M.track_points < 2 then return end
    local segments = build_track_render_cache(center_world_x, center_world_y, canvas_x, canvas_y, width, height)
    -- #ffa500 in Dear ImGui's AABBGGRR color layout.
    local track_color = 0xFF00A5FF
    for _, segment in ipairs(segments) do
        imgui.DrawList_AddLine(segment[1], segment[2], segment[3], segment[4], track_color, 2.5)
    end
end

-- A two-minute heading extension, measured from the current aircraft position.
-- This is a heading projection (not ground track or wind-corrected routing).
-- Map projection and clipping are shared with the existing navigation lines.
local function heading_prediction_endpoint(lat, lon, heading_deg, groundspeed_kt)
    local speed = tonumber(groundspeed_kt)
    local heading = tonumber(heading_deg)
    if not lat or not lon or not speed or not heading or speed ~= speed or heading ~= heading or speed <= 0 then
        return nil
    end

    local seconds = tonumber(cfg().heading_prediction_seconds) or 120
    if seconds <= 0 then return nil end
    -- kt = nautical miles/hour; convert the travel distance to kilometres.
    local distance_km = speed * (seconds / 3600.0) * 1.852
    return HEMS.geo.destination(lat, lon, heading % 360, distance_km)
end

local function draw_heading_prediction(center_world_x, center_world_y, canvas_x, canvas_y, width, height)
    if not M.nav.valid then return end
    local endpoint_lat, endpoint_lon = heading_prediction_endpoint(
        M.nav.lat, M.nav.lon, M.nav.heading_deg, M.nav.groundspeed_kt
    )
    if not endpoint_lat then return end

    local sx, sy = map_point(
        M.nav.lat, M.nav.lon, center_world_x, center_world_y, M.zoom,
        canvas_x, canvas_y, width, height
    )
    local ex, ey = map_point(
        endpoint_lat, endpoint_lon, center_world_x, center_world_y, M.zoom,
        canvas_x, canvas_y, width, height
    )
    local x0, y0, x1, y1 = clip_line_to_rect(
        sx, sy, ex, ey,
        canvas_x + 5, canvas_y + 5,
        canvas_x + width - 5, canvas_y + height - 5
    )
    if not x0 then return end

    local dx, dy = x1 - x0, y1 - y0
    local length = math.sqrt(dx * dx + dy * dy)
    if length < 1 then return end

    local ux, uy = dx / length, dy / length
    local dash, gap = 9.0, 7.0
    local color, thickness = 0xFF000000, 1.5 -- black, thinner than track (2.5) / Direct-To (3)
    local pos = 0
    while pos < length do
        local finish = math.min(length, pos + dash)
        imgui.DrawList_AddLine(
            x0 + ux * pos, y0 + uy * pos,
            x0 + ux * finish, y0 + uy * finish,
            color, thickness
        )
        pos = pos + dash + gap
    end
end

-- Mouse-to-geographic conversion reverses the Heading-Up rotation before
-- using the same OSM Web Mercator transform as normal map rendering.
local function map_click_to_latlon(mouse_x, mouse_y, center_world_x, center_world_y,
                                    canvas_x, canvas_y, width, height)
    local screen_dx = mouse_x - (canvas_x + width * 0.5)
    local screen_dy = mouse_y - (canvas_y + height * 0.5)
    local dx = screen_dx * M.map_rotation_cos - screen_dy * M.map_rotation_sin
    local dy = screen_dx * M.map_rotation_sin + screen_dy * M.map_rotation_cos
    local lat, lon = HEMS.osm.world_px_to_latlon(center_world_x + dx, center_world_y + dy, M.zoom)
    if lon then lon = ((lon + 180) % 360) - 180 end
    return lat, lon
end

local function handle_custom_map_click(canvas_x, canvas_y, width, height, center_world_x, center_world_y)
    if not M.custom_pick_type or M.dialog then return end
    if not (imgui.IsMouseClicked and imgui.IsMouseReleased and imgui.GetMousePos) then
        M.custom_pick_type = nil
        HEMS.status_message = "Custom mission selection requires FlyWithLua mouse click/release support."
        HEMS.log("Moving Map: " .. HEMS.status_message)
        return
    end
    local mx, my = unpack_vec2(imgui.GetMousePos())
    local inside = point_in_rect(mx, my, canvas_x, canvas_y, canvas_x + width, canvas_y + height)
    -- Do not treat clicks on the selection banner, attribution, or mission
    -- status badge as map positions.
    local inside_prompt = point_in_rect(mx, my, canvas_x + 8, canvas_y + 8,
        canvas_x + math.min(width - 8, 408), canvas_y + 83)
    local inside_status = my >= canvas_y + height - 64
    local inside_attribution = my < canvas_y + 32 and mx > canvas_x + width - 230
    if imgui.IsMouseClicked(0) then
        M.custom_mouse_down = (inside and not inside_prompt and not inside_status and not inside_attribution
            and imgui.IsWindowHovered and imgui.IsWindowHovered()) and { x = mx, y = my } or nil
        M.custom_mouse_moved = false
    end
    if imgui.IsMouseReleased(0) then
        local press = M.custom_mouse_down
        M.custom_mouse_down = nil
        if press and inside and not inside_prompt and not inside_status and not inside_attribution
            and not M.custom_mouse_moved
            and math.abs(mx - press.x) <= 5 and math.abs(my - press.y) <= 5 then
            local lat, lon = map_click_to_latlon(mx, my, center_world_x, center_world_y,
                canvas_x, canvas_y, width, height)
            if lat and lon and lat == lat and lon == lon then
                local mission_id = M.custom_pick_type
                if request_map_action("custom_mission", {
                    mission_id = mission_id, lat = lat, lon = lon, show_info_on_success = false
                }) then
                    M.custom_pick_type = nil
                    HEMS.log(string.format("Custom mission map click: %s at %.6f/%.6f.", mission_id, lat, lon))
                end
            end
        end
        M.custom_mouse_moved = false
    end
end

local function draw_custom_map_prompt(canvas_x, canvas_y, width)
    if not M.custom_pick_type then return end
    local bw = math.min(width - 16, 400)
    local x, y = canvas_x + 8, canvas_y + 8
    imgui.DrawList_AddRectFilled(x, y, x + bw, y + 75, 0xE51B232C, 6)
    imgui.DrawList_AddRect(x, y, x + bw, y + 75, 0xFF697584, 6)
    imgui.SetCursorScreenPos(x + 9, y + 7)
    imgui.TextUnformatted("Click on the map to set the position")
    imgui.SetCursorScreenPos(x + 9, y + 25)
    imgui.TextUnformatted(M.custom_pick_type == "traffic_accident"
        and "for your custom traffic accident." or "for your custom medical emergency.")
    imgui.SetCursorScreenPos(x + 9, y + 47)
    if draw_text_button("Cancel selection##hems_cancel_pick", 148, "normal") then
        M.custom_pick_type = nil
        M.custom_mouse_down = nil
        M.custom_mouse_moved = false
    end
end

local function draw_map_canvas(width, height)
    local hidden_scrollbars = push_hidden_scrollbar_colors()
    imgui.BeginChild("##hems_moving_map_canvas", width, height)

    -- Edge tiles are full 256 px image widgets and may extend beyond the child
    -- content bounds. Keep the child fixed at the map origin and make any
    -- implementation-level scrollbars invisible; panning belongs to the map.
    if imgui.SetScrollX then imgui.SetScrollX(0) end
    if imgui.SetScrollY then imgui.SetScrollY(0) end

    local canvas_x, canvas_y = imgui.GetCursorScreenPos()
    local right = canvas_x + width
    local bottom = canvas_y + height

    -- Mouse panning is handled before map geometry is calculated so the visual map
    -- follows the cursor immediately in the same frame.
    handle_map_pan()

    imgui.DrawList_AddRectFilled(canvas_x, canvas_y, right, bottom, 0xFF24272B, 0)

    if not M.nav.valid then
        imgui.SetCursorScreenPos(canvas_x + 12, canvas_y + 12)
        imgui.TextUnformatted("Aircraft position unavailable.")
        -- Even without valid navigation data, keep confirmations and the
        -- custom-type dialog accessible (e.g. ending an active mission).
        draw_map_dialog(canvas_x, canvas_y, width, height)
        imgui.EndChild()
        pop_style_colors(hidden_scrollbars)
        return
    end

    local tiles, center_world_x, center_world_y, coverage = prepare_map(width, height)
    handle_custom_map_click(canvas_x, canvas_y, width, height, center_world_x, center_world_y)
    local map_drawn = draw_tiles(canvas_x, canvas_y, width, height, tiles, coverage)

    if not map_drawn then
        imgui.SetCursorScreenPos(canvas_x + 12, canvas_y + 12)
        if HEMS.osm.pending_count() > 0 then
            imgui.TextUnformatted("Loading OSM map ...")
        else
            imgui.TextUnformatted("No OSM tiles available in cache. Navigation remains active.")
        end
    end

    draw_track(center_world_x, center_world_y, canvas_x, canvas_y, width, height)
    draw_heading_prediction(center_world_x, center_world_y, canvas_x, canvas_y, width, height)

    local aircraft_x, aircraft_y = map_point(
        M.nav.lat, M.nav.lon,
        center_world_x, center_world_y, M.zoom,
        canvas_x, canvas_y, width, height
    )

    if M.nav.target_lat and M.nav.target_lon then
        local target_x, target_y = map_point(
            M.nav.target_lat, M.nav.target_lon,
            center_world_x, center_world_y, M.zoom,
            canvas_x, canvas_y, width, height
        )

        -- Every Direct-To route uses the helicopter position captured at the
        -- moment that route was set. The aircraft symbol and live navigation
        -- values continue to update independently from this fixed geometry.
        local route_start = nil
        if M.nav.target_kind == "mission" then
            route_start = M.mission_route_start
        elseif M.nav.target_kind == "base" then
            route_start = M.base_route_start
        elseif M.nav.target_kind == "hospital" then
            route_start = M.hospital_route_start
        end

        local route_start_x, route_start_y = aircraft_x, aircraft_y
        if route_start then
            route_start_x, route_start_y = map_point(
                route_start.lat, route_start.lon,
                center_world_x, center_world_y, M.zoom,
                canvas_x, canvas_y, width, height
            )
        end

        local line_x0, line_y0, line_x1, line_y1 = clip_line_to_rect(
            route_start_x, route_start_y, target_x, target_y,
            canvas_x + 5, canvas_y + 5, right - 5, bottom - 5
        )
        if line_x0 then
            -- Direct-To: #ff0000.
            imgui.DrawList_AddLine(line_x0, line_y0, line_x1, line_y1, 0xFF0000FF, 3.0)
        end

        if point_in_rect(target_x, target_y, canvas_x, canvas_y, right, bottom) then
            draw_target(target_x, target_y)
        elseif line_x1 then
            draw_target(line_x1, line_y1)
        end
    end

    if point_in_rect(aircraft_x, aircraft_y, canvas_x - 16, canvas_y - 16, right + 16, bottom + 16) then
        -- In Heading-Up the map rotates beneath the helicopter: its displayed
        -- heading is therefore close to straight up rather than turning twice.
        draw_aircraft(aircraft_x, aircraft_y, (M.nav.heading_deg - M.map_rotation_deg) % 360)
    end

    -- Subtle frame around the map canvas.
    imgui.DrawList_AddRect(canvas_x, canvas_y, right, bottom, 0x88474C54, 0)

    -- Attribution becomes a small top-right badge so it never competes with the
    -- navigation/status overlay at the bottom of the map.
    local attribution = "© OpenStreetMap contributors"
    local attribution_w = imgui.CalcTextSize(attribution)
    local attr_x = math.max(canvas_x + 6, right - attribution_w - 14)
    local attr_y = canvas_y + 7
    imgui.DrawList_AddRectFilled(attr_x - 5, attr_y - 3, right - 6, attr_y + 17, 0xB0181B1F, 4)
    imgui.SetCursorScreenPos(attr_x, attr_y)
    imgui.TextUnformatted(attribution)

    draw_status_overlay(canvas_x, canvas_y, width, height)
    draw_custom_map_prompt(canvas_x, canvas_y, width)
    draw_map_dialog(canvas_x, canvas_y, width, height)

    imgui.EndChild()
    pop_style_colors(hidden_scrollbars)
end

function M.build_window(wnd, x, y)
    update_nav(false)
    update_map_rotation(false)
    update_info(false)

    local min_zoom = tonumber(cfg().min_zoom) or 10
    local max_zoom = tonumber(cfg().max_zoom) or 16
    M.zoom = clamp(M.zoom, min_zoom, max_zoom)

    draw_toolbar()

    -- The map consumes exactly the remaining ImGui content region. No fixed
    -- internal map minimum is used, so resizing the floating window scales the
    -- map instead of creating root-window scrollbars.
    local available_w, available_h = content_region_avail()
    local width = math.max(1, math.floor(available_w) - 2)
    local height = math.max(1, math.floor(available_h) - 2)
    draw_map_canvas(width, height)
end

-- Center a completed random/custom mission for landing-site reconnaissance.
-- Never called for a failed mission. The pilot can restore Follow Aircraft with
-- the existing toolbar button. All Direct-To routes and aircraft data stay live.
function M.focus_on_mission(mission)
    local lat = mission and tonumber(mission.lat)
    local lon = mission and tonumber(mission.lon)
    if not lat or not lon or lat ~= lat or lon ~= lon then return false end
    M.follow_aircraft = false
    M.map_center_lat, M.map_center_lon = lat, lon
    M.zoom = clamp(tonumber(cfg().mission_preview_zoom) or 16,
        tonumber(cfg().min_zoom) or 10, tonumber(cfg().max_zoom) or 16)
    M.track_render_cache = nil
    M.last_tile_prepare = -1000
    HEMS.log(string.format("Moving Map: Centered on mission %.6f/%.6f at zoom %d.", lat, lon, M.zoom))
    return true
end

function M.on_close(wnd)
    M.window = nil
    M.dialog = nil
    M.custom_pick_type = nil
    M.custom_mouse_down = nil
end

HEMS_DISPATCH_BUILD_MOVING_MAP = function(wnd, x, y) M.build_window(wnd, x, y) end
HEMS_DISPATCH_MOVING_MAP_CLOSED = function(wnd) M.on_close(wnd) end

function M.show()
    if not SUPPORTS_FLOATING_WINDOWS then
        HEMS.log("Moving Map unavailable: FlyWithLua does not support floating windows.")
        return false
    end

    if M.window then
        if float_wnd_bring_to_front then float_wnd_bring_to_front(M.window) end
        return true
    end

    local ok_osm, osm_err = HEMS.osm.init()
    if not ok_osm then
        HEMS.log("Moving Map: OSM cache could not be initialized: " .. tostring(osm_err))
    end

    local width = tonumber(cfg().window_width) or 620
    local height = tonumber(cfg().window_height) or 620
    M.window = float_wnd_create(width, height, 1, true)
    if not M.window then
        HEMS.log("Moving Map window could not be created.")
        return false
    end

    M.zoom = clamp(tonumber(cfg().default_zoom) or 14, tonumber(cfg().min_zoom) or 10, tonumber(cfg().max_zoom) or 16)
    set_follow_aircraft(true)
    update_nav(true)
    update_info(true)
    sample_track(false)

    float_wnd_set_title(M.window, "HEMS Dispatch - Moving Map")
    float_wnd_set_imgui_builder(M.window, "HEMS_DISPATCH_BUILD_MOVING_MAP")
    float_wnd_set_onclose(M.window, "HEMS_DISPATCH_MOVING_MAP_CLOSED")
    if float_wnd_set_resizing_limits then
        float_wnd_set_resizing_limits(M.window, 440, 320, 1400, 1200)
    end
    return true
end

function M.hide()
    if not M.window then return true end
    local wnd = M.window
    local ok, err = pcall(function() float_wnd_destroy(wnd) end)
    if not ok then
        HEMS.log("Moving Map window could not be closed: " .. tostring(err))
        return false, err
    end
    M.window = nil
    M.dialog = nil
    M.custom_pick_type = nil
    M.custom_mouse_down = nil
    return true
end

function M.toggle()
    if M.window then
        return M.hide()
    end
    return M.show()
end

function M.shutdown()
    close_track_file()
    M.hide()
end

return M
