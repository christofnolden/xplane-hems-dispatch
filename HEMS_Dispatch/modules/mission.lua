local M = {}

local floor = math.floor
local CANDIDATE_SAMPLE_LIMIT = 24

local UNIT_LABELS = {
    RTW = "Ambulance",
    NEF = "Emergency physician",
    FIRE = "Fire brigade",
    POLICE = "Police",
    CRASHED = "Crashed vehicle",
}

local UNIT_ORDER = { "RTW", "NEF", "FIRE", "POLICE", "CRASHED" }

local CONFIGURABLE_UNITS = {
    RTW = true,
    NEF = true,
    FIRE = true,
    POLICE = true,
}

local function validate_range(name, r)
    if type(r) ~= "table" then return false, name .. " is missing." end
    local minv = tonumber(r.min)
    local maxv = tonumber(r.max)
    if not minv or not maxv or minv < 0 or maxv < minv then
        return false, name .. " has invalid min/max values."
    end
    return true
end

function M.validate_config(cfg)
    if type(cfg.dispatch) ~= "table" then return false, "dispatch is missing." end
    if type(cfg.missions) ~= "table" or #cfg.missions == 0 then return false, "missions is missing or empty." end
    if type(cfg.rescuex) ~= "table" or type(cfg.rescuex.objects) ~= "table" then return false, "rescuex.objects is missing." end

    local min_r = tonumber(cfg.dispatch.min_radius_km)
    local max_r = tonumber(cfg.dispatch.max_radius_km)
    if not min_r or not max_r or min_r < 0 or max_r <= min_r then
        return false, "dispatch.min_radius_km/max_radius_km are invalid."
    end
    if not tonumber(cfg.dispatch.road_search_radius_km) or cfg.dispatch.road_search_radius_km <= 0 then
        return false, "dispatch.road_search_radius_km must be > 0."
    end
    if not tonumber(cfg.dispatch.max_target_attempts) or cfg.dispatch.max_target_attempts < 1 then
        return false, "dispatch.max_target_attempts must be >= 1."
    end
    if not tonumber(cfg.dispatch.candidate_spacing_m) or cfg.dispatch.candidate_spacing_m < 10 then
        return false, "dispatch.candidate_spacing_m must be >= 10 m."
    end
    if cfg.dispatch.scene_path_resolution_m ~= nil then
        local resolution = tonumber(cfg.dispatch.scene_path_resolution_m)
        if not resolution or resolution < 0.5 or resolution > 10.0 then
            return false, "dispatch.scene_path_resolution_m must be between 0.5 and 10 m."
        end
    end

    local probability_sum = 0
    for _, mission in ipairs(cfg.missions) do
        if not mission.id or not mission.name then return false, "Every mission type requires id and name." end
        local p = tonumber(mission.probability or 0) or 0
        if p < 0 then return false, "Mission probability must not be negative." end
        probability_sum = probability_sum + p
        if type(mission.road_groups) ~= "table" or #mission.road_groups == 0 then
            return false, "Mission " .. mission.id .. " has no road_groups."
        end
        if type(mission.units) ~= "table" then
            return false, "Mission " .. mission.id .. " has no units table."
        end

        local has_guaranteed_unit = false
        for unit, range in pairs(mission.units) do
            if not CONFIGURABLE_UNITS[unit] then
                return false, "Mission " .. mission.id .. ": unknown unit type '" .. tostring(unit)
                    .. "'. Allowed types are RTW, NEF, FIRE and POLICE."
            end
            local ok, err = validate_range("units." .. unit, range)
            if not ok then return false, err end
            if (tonumber(range.min) or 0) > 0 then
                has_guaranteed_unit = true
            end
        end
        if not has_guaranteed_unit then
            return false, "Mission " .. mission.id
                .. " must define at least one unit type with min >= 1; additional units may optionally use min = 0."
        end
        if mission.include_crashed_vehicle then
            local crash_pool = cfg.rescuex.objects.CRASHED
            if type(crash_pool) ~= "table" or #crash_pool == 0 then
                return false, "Mission " .. mission.id
                    .. " uses include_crashed_vehicle = true, but rescuex.objects.CRASHED is missing or empty."
            end
        end
    end
    if probability_sum <= 0 then return false, "Sum of mission probabilities is 0." end

    if cfg.moving_map ~= nil then
        if type(cfg.moving_map) ~= "table" then return false, "moving_map must be a table." end
        local mm = cfg.moving_map
        local min_zoom = tonumber(mm.min_zoom or 10)
        local max_zoom = tonumber(mm.max_zoom or 16)
        local default_zoom = tonumber(mm.default_zoom or 14)
        if not min_zoom or not max_zoom or min_zoom < 1 or max_zoom > 19 or min_zoom > max_zoom then
            return false, "moving_map.min_zoom/max_zoom are invalid (1..19)."
        end
        if not default_zoom or default_zoom < min_zoom or default_zoom > max_zoom then
            return false, "moving_map.default_zoom must be within min_zoom/max_zoom."
        end
        local nav_hz = tonumber(mm.nav_update_hz or 10)
        local info_hz = tonumber(mm.info_update_hz or 1)
        if not nav_hz or nav_hz < 1 or nav_hz > 30 then
            return false, "moving_map.nav_update_hz must be between 1 and 30."
        end
        if not info_hz or info_hz < 0.2 or info_hz > 10 then
            return false, "moving_map.info_update_hz must be between 0.2 and 10."
        end
    end

    for _, required in ipairs({ "RTW", "NEF", "FIRE", "POLICE" }) do
        if type(cfg.rescuex.objects[required]) ~= "table" or #cfg.rescuex.objects[required] == 0 then
            return false, "rescuex.objects." .. required .. " is missing or empty."
        end
    end

    return true
end

local function counts_to_lines(counts, include_zero)
    local lines = {}
    for _, unit in ipairs(UNIT_ORDER) do
        local count = counts and counts[unit] or 0
        if count > 0 or include_zero then
            local label = UNIT_LABELS[unit]
            if unit == "CRASHED" and count ~= 1 then
                label = "Crashed vehicles"
            end
            lines[#lines + 1] = string.format("%dx %s", count, label)
        end
    end
    return lines
end

function M.unit_summary(counts)
    local lines = counts_to_lines(counts, false)
    if #lines == 0 then return "None" end
    return table.concat(lines, ", ")
end

local function write_text(path, text)
    local f, err = io.open(path, "w")
    if not f then
        HEMS.log("ERROR: Text output could not be written: " .. tostring(err))
        return false
    end
    f:write(text)
    f:close()
    return true
end

function M.write_idle_output()
    write_text(HEMS.paths.active_mission,
        "HEMS DISPATCH\n"
        .. "========================================\n\n"
        .. "No active mission.\n")
end

function M.write_active_output(mission)
    local decimals = (HEMS.config.output and HEMS.config.output.coordinate_decimals) or 5
    local coord = HEMS.util.format_coord(mission.lat, mission.lon, decimals)
    local unit_lines = counts_to_lines(mission.units, false)

    local lines = {
        "HEMS DISPATCH",
        "========================================",
        "",
        "Mission: " .. mission.name,
        "Coordinates: " .. coord,
        string.format("Google Maps: %." .. decimals .. "f, %." .. decimals .. "f", mission.lat, mission.lon),
        string.format("Dispatch distance: %.1f km", mission.distance_km),
        string.format("Dispatch bearing: %03d°", floor(mission.bearing_deg + 0.5) % 360),
        "",
        "Emergency units:",
    }

    for _, line in ipairs(unit_lines) do lines[#lines + 1] = "- " .. line end

    if HEMS.config.output and HEMS.config.output.include_debug_details then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Technical details:"
        lines[#lines + 1] = string.format("- SimHeaven Road subtype: %d (%s)", mission.road_subtype, mission.road_group_name)
        lines[#lines + 1] = string.format("- Road heading: %.1f°", mission.road_heading)
        lines[#lines + 1] = "- Source tile: " .. mission.tile_name
    end

    if mission.scene_errors and #mission.scene_errors > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Notes:"
        for _, e in ipairs(mission.scene_errors) do lines[#lines + 1] = "- " .. tostring(e) end
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = "========================================"
    lines[#lines + 1] = "Generated: " .. mission.created_at
    lines[#lines + 1] = ""

    write_text(HEMS.paths.active_mission, table.concat(lines, "\n"))
end

local function choose_mission_definition()
    return HEMS.util.weighted_pick(HEMS.config.missions, "probability")
end

local function choose_road_group(mission_def)
    local group = HEMS.util.weighted_pick(mission_def.road_groups, "weight")
    return group and group.id or nil
end

local function build_mission(mission_def, road_group, candidate, tile_name, heli_lat, heli_lon, scene)
    local dist = HEMS.geo.distance_km(heli_lat, heli_lon, candidate.lat, candidate.lon)
    local brg = HEMS.geo.bearing_deg(heli_lat, heli_lon, candidate.lat, candidate.lon)

    return {
        id = mission_def.id,
        name = mission_def.name,
        lat = candidate.lat,
        lon = candidate.lon,
        distance_km = dist,
        bearing_deg = brg,
        road_heading = scene.road_heading,
        road_subtype = candidate.subtype,
        road_group = road_group,
        road_group_name = HEMS.dsf.road_group_name(candidate.subtype),
        tile_name = tile_name,
        units = scene.actual_counts,
        requested_units = scene.requested_counts,
        used_objects = scene.used_objects,
        scene_errors = scene.errors,
        created_at = os.date("%Y-%m-%d %H:%M:%S"),
    }
end

local function try_candidate(mission_def, plan, road_group, cache, tile_name, candidate, heli_lat, heli_lon)
    local exact_distance = HEMS.geo.distance_km(heli_lat, heli_lon, candidate.lat, candidate.lon)
    if exact_distance < HEMS.config.dispatch.min_radius_km
        or exact_distance > HEMS.config.dispatch.max_radius_km then
        return nil, "Candidate was outside the dispatch radius after exact distance validation."
    end

    local terrain, terrain_err = HEMS.xplm.probe_world(
        candidate.lat,
        candidate.lon,
        HEMS.config.dispatch.max_slope_deg
    )
    if not terrain then
        return nil, "Terrain check: " .. tostring(terrain_err)
    end

    local required_extent = HEMS.rescuex.required_path_extent(mission_def, plan)
    local resolution = tonumber(HEMS.config.dispatch.scene_path_resolution_m) or 2.0
    local road_path, path_err = HEMS.dsf.build_road_path(cache, candidate, required_extent, resolution)
    if not road_path then
        return nil, "Road-Path: " .. tostring(path_err)
    end

    local layout, layout_err = HEMS.rescuex.plan_layout(mission_def, plan, candidate, road_path)
    if not layout then
        return nil, "Candidate ungeeignet: " .. tostring(layout_err)
    end

    local available_positive, available_negative = HEMS.dsf.path_availability(road_path, layout.scene_direction)
    HEMS.log(string.format(
        "Road candidate suitable: Chain=%d | Along=%.1f m | Road path forward=%.1f m / backward=%.1f m | SceneDirection=%d",
        candidate.chain_id or 0,
        candidate.along_m or 0.0,
        available_positive,
        available_negative,
        layout.scene_direction
    ))

    local scene, scene_err = HEMS.rescuex.spawn_scene(mission_def, candidate, plan, road_path, layout)
    if not scene then
        return nil, "RescueX scene could not be created: " .. tostring(scene_err)
    end

    local mission = build_mission(
        mission_def,
        road_group,
        candidate,
        tile_name,
        heli_lat,
        heli_lon,
        scene
    )
    return mission
end

function M.new_mission(options)
    options = type(options) == "table" and options or {}
    if HEMS.movingmap and HEMS.movingmap.clear_navigation_override then
        HEMS.movingmap.clear_navigation_override()
    elseif HEMS.movingmap and HEMS.movingmap.clear_direct_to_base then
        HEMS.movingmap.clear_direct_to_base()
    end
    if not HEMS.initialized then
        HEMS.status_message = "HEMS Dispatch is not fully initialized yet. See hems_dispatch.log."
        HEMS.ui.show_info()
        return
    end

    if HEMS.active_mission then
        HEMS.log("New mission requested: active mission will be ended and replaced automatically.")
        M.end_mission(true)
    end

    local heli_lat = tonumber(LATITUDE)
    local heli_lon = tonumber(LONGITUDE)
    if not heli_lat or not heli_lon then
        error("Current helicopter position could not be read.")
    end

    local mission_def = choose_mission_definition()
    if not mission_def then error("No mission type could be selected.") end
    local road_group = choose_road_group(mission_def)
    if not road_group then error("No road class could be selected.") end

    -- Counts are fixed before road selection so candidate suitability is checked
    -- against the actual scene that will be spawned.
    local plan = HEMS.rescuex.plan_scene(mission_def)
    local required_extent = HEMS.rescuex.required_path_extent(mission_def, plan)

    HEMS.status_message = "Searching for a suitable mission location ..."
    HEMS.log(string.format(
        "New mission: Type=%s, RoadGroup=%s, Start=%.6f/%.6f | Planned: %s | Road path up to %.1f m",
        mission_def.id,
        road_group,
        heli_lat,
        heli_lon,
        M.unit_summary(plan.requested_counts),
        required_extent
    ))

    local last_error = nil
    for attempt = 1, HEMS.config.dispatch.max_target_attempts do
        local distance, random_bearing = HEMS.geo.sample_annulus(
            HEMS.config.dispatch.min_radius_km,
            HEMS.config.dispatch.max_radius_km
        )
        local target_lat, target_lon = HEMS.geo.destination(heli_lat, heli_lon, random_bearing, distance)
        local tile_lat = floor(target_lat)
        local tile_lon = floor(target_lon)
        local _, tile_name = HEMS.dsf.source_dsf_path(tile_lat, tile_lon)

        HEMS.log(string.format("Location attempt %d/%d: target distance %.1f km | target %.5f/%.5f, tile %s",
            attempt, HEMS.config.dispatch.max_target_attempts, distance, target_lat, target_lon, tile_name))

        local cache, cache_err = HEMS.dsf.ensure_cache(tile_lat, tile_lon)
        if not cache then
            last_error = cache_err
            HEMS.log("Location attempt rejected: " .. tostring(cache_err))
        else
            local candidates, matches_or_err = HEMS.dsf.select_candidates(
                cache,
                target_lat,
                target_lon,
                heli_lat,
                heli_lon,
                road_group,
                CANDIDATE_SAMPLE_LIMIT
            )

            if not candidates then
                last_error = tostring(matches_or_err)
                HEMS.log("Location attempt rejected: " .. last_error)
            elseif #candidates == 0 then
                last_error = "No suitable road found within the search area."
                HEMS.log(last_error .. " Matches=" .. tostring(matches_or_err or 0))
            else
                HEMS.log(string.format(
                    "%d road candidates within search area; checking up to %d random candidates for scene suitability.",
                    tonumber(matches_or_err) or #candidates,
                    #candidates
                ))

                for candidate_index, candidate in ipairs(candidates) do
                    local mission, candidate_err = try_candidate(
                        mission_def,
                        plan,
                        road_group,
                        cache,
                        tile_name,
                        candidate,
                        heli_lat,
                        heli_lon
                    )

                    if mission then
                        HEMS.active_mission = mission
                        HEMS.status_message = "Mission active."
                        M.write_active_output(mission)

                        HEMS.log(string.format(
                            "Mission generated: %s | %s | %.1f km | BRG %03d | %s",
                            mission.name,
                            HEMS.util.format_coord(mission.lat, mission.lon, 5),
                            mission.distance_km,
                            floor(mission.bearing_deg + 0.5) % 360,
                            M.unit_summary(mission.units)
                        ))

                        if HEMS.config.output.auto_open_info_window and options.show_info_on_success ~= false then
                            HEMS.ui.show_info()
                        end
                        if HEMS.config.moving_map and HEMS.config.moving_map.auto_open_on_new_mission then
                            HEMS.movingmap.show()
                        end
                        return mission
                    end

                    last_error = candidate_err
                    HEMS.log(string.format(
                        "Road candidate %d/%d rejected: %s",
                        candidate_index,
                        #candidates,
                        tostring(candidate_err)
                    ))
                end
            end
        end
    end

    HEMS.status_message = "No suitable mission location found. Last reason: " .. tostring(last_error or "unknown")
    HEMS.log(HEMS.status_message)
    HEMS.ui.show_info()
end

function M.end_mission(silent)
    HEMS.rescuex.destroy_scene()
    HEMS.active_mission = nil
    HEMS.status_message = "Active mission ended and all temporary objects removed."
    M.write_idle_output()
    HEMS.log("Active mission ended.")
    if not silent then
        HEMS.ui.show_info()
    end
end

return M
