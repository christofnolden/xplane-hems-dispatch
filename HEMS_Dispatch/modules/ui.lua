local M = {}

M.info_window = nil
M.menu = nil
M.menu_parent = nil
M.menu_parent_index = nil

local function append_command(menu, label, command_name)
    local cmd = HEMS.xplm.lib.XPLMFindCommand(command_name)
    if cmd == nil then
        return false, "X-Plane command not found: " .. command_name
    end
    local idx = HEMS.xplm.lib.XPLMAppendMenuItemWithCommand(menu, label, cmd)
    if idx < 0 then return false, "Menu item could not be created: " .. label end
    return true
end

function M.init_menu()
    if M.menu then return true end

    local parent = HEMS.xplm.lib.XPLMFindPluginsMenu()
    if parent == nil then return false, "Plugins menu not found." end

    local parent_index = HEMS.xplm.lib.XPLMAppendMenuItem(parent, "HEMS Dispatch", nil, 0)
    if parent_index < 0 then return false, "HEMS Dispatch menu container could not be created." end

    local menu = HEMS.xplm.lib.XPLMCreateMenu("HEMS Dispatch", parent, parent_index, nil, nil)
    if menu == nil then
        HEMS.xplm.lib.XPLMRemoveMenuItem(parent, parent_index)
        return false, "XPLMCreateMenu() failed."
    end

    local ok, err
    ok, err = append_command(menu, "New mission", "hems_dispatch/new_mission")
    if not ok then HEMS.log("WARNING: " .. tostring(err)) end
    ok, err = append_command(menu, "End active mission", "hems_dispatch/end_mission")
    if not ok then HEMS.log("WARNING: " .. tostring(err)) end
    ok, err = append_command(menu, "Active mission information", "hems_dispatch/show_info")
    if not ok then HEMS.log("WARNING: " .. tostring(err)) end
    ok, err = append_command(menu, "Moving Map", "hems_dispatch/toggle_moving_map")
    if not ok then HEMS.log("WARNING: " .. tostring(err)) end
    ok, err = append_command(menu, "Set Base Position", "hems_dispatch/set_base_position")
    if not ok then HEMS.log("WARNING: " .. tostring(err)) end

    HEMS.xplm.lib.XPLMAppendMenuSeparator(menu)

    ok, err = append_command(menu, "Reload configuration", "hems_dispatch/reload_config")
    if not ok then HEMS.log("WARNING: " .. tostring(err)) end

    M.menu_parent = parent
    M.menu_parent_index = parent_index
    M.menu = menu
    return true
end

local function info_lines()
    local mission = HEMS.active_mission
    if not mission then
        return {
            "No active mission.",
            "",
            HEMS.status_message or "",
            "",
            "Text output:",
            HEMS.paths.active_mission,
        }
    end

    local decimals = (HEMS.config.output and HEMS.config.output.coordinate_decimals) or 5
    local lines = {
        "Mission: " .. mission.name,
        "",
        "Coordinates: " .. HEMS.util.format_coord(mission.lat, mission.lon, decimals),
        string.format("Google Maps: %." .. decimals .. "f, %." .. decimals .. "f", mission.lat, mission.lon),
        string.format("Distance: %.1f km", mission.distance_km),
        string.format("Bearing: %03d°", math.floor(mission.bearing_deg + 0.5) % 360),
        "",
        "Emergency units: " .. HEMS.mission.unit_summary(mission.units),
    }

    if HEMS.config.output and HEMS.config.output.include_debug_details then
        lines[#lines + 1] = ""
        lines[#lines + 1] = string.format("Road: %s / subtype %d / heading %.1f°",
            mission.road_group_name, mission.road_subtype, mission.road_heading)
        lines[#lines + 1] = "Tile: " .. mission.tile_name
    end

    if mission.scene_errors and #mission.scene_errors > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Scene setup notes:"
        for _, e in ipairs(mission.scene_errors) do
            lines[#lines + 1] = "- " .. tostring(e)
        end
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = "Text output:"
    lines[#lines + 1] = HEMS.paths.active_mission
    return lines
end

function M.build_info(wnd, x, y)
    imgui.TextUnformatted("HEMS Dispatch v" .. tostring(HEMS.VERSION))
    imgui.Separator()
    for _, line in ipairs(info_lines()) do
        imgui.TextUnformatted(line)
    end
end

function M.on_info_close(wnd)
    M.info_window = nil
end

-- Keep globally visible callback names for FlyWithLua versions that resolve callbacks by name.
HEMS_DISPATCH_BUILD_INFO = function(wnd, x, y) M.build_info(wnd, x, y) end
HEMS_DISPATCH_INFO_CLOSED = function(wnd) M.on_info_close(wnd) end

function M.show_info()
    if not SUPPORTS_FLOATING_WINDOWS then
        HEMS.log("Information window unavailable: FlyWithLua does not support floating windows.")
        return false
    end

    if M.info_window then
        if float_wnd_bring_to_front then float_wnd_bring_to_front(M.info_window) end
        return true
    end

    M.info_window = float_wnd_create(620, 360, 1, true)
    if not M.info_window then
        HEMS.log("Information window could not be created.")
        return false
    end

    float_wnd_set_title(M.info_window, "HEMS Dispatch - Mission Information")
    float_wnd_set_imgui_builder(M.info_window, "HEMS_DISPATCH_BUILD_INFO")
    float_wnd_set_onclose(M.info_window, "HEMS_DISPATCH_INFO_CLOSED")
    if float_wnd_set_resizing_limits then
        float_wnd_set_resizing_limits(M.info_window, 420, 260, 1000, 800)
    end
    return true
end

function M.shutdown()
    if M.info_window then
        local wnd = M.info_window
        M.info_window = nil
        pcall(function() float_wnd_destroy(wnd) end)
    end

    if M.menu and HEMS.xplm.lib then
        local menu = M.menu
        M.menu = nil
        pcall(function() HEMS.xplm.lib.XPLMDestroyMenu(menu) end)
    end
    if M.menu_parent and M.menu_parent_index and HEMS.xplm.lib then
        local parent = M.menu_parent
        local index = M.menu_parent_index
        pcall(function() HEMS.xplm.lib.XPLMRemoveMenuItem(parent, index) end)
    end
    M.menu_parent = nil
    M.menu_parent_index = nil
end

return M
