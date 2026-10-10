-- HEMS Dispatch for X-Plane 12 / FlyWithLua NG+
-- Version 1.0.17
--
-- Install this file and the HEMS_Dispatch directory directly into:
--   X-Plane 12/Resources/plugins/FlyWithLua/Scripts/

HEMS = HEMS or {}
HEMS.VERSION = "1.0.17"
HEMS.NAME = "HEMS Dispatch"
HEMS.active_mission = nil
HEMS.status_message = "Initializing HEMS Dispatch ..."
HEMS.initialized = false
HEMS.shutting_down = false
HEMS.pending_action = nil

local sep = DIRECTORY_SEPARATOR or "/"
HEMS.paths = {
    root = SCRIPT_DIRECTORY .. "HEMS_Dispatch" .. sep,
}
HEMS.paths.modules = HEMS.paths.root .. "modules" .. sep
HEMS.paths.cache = HEMS.paths.root .. "cache" .. sep
HEMS.paths.output = HEMS.paths.root .. "output" .. sep
HEMS.paths.config = HEMS.paths.root .. "config.lua"
HEMS.paths.log = HEMS.paths.output .. "hems_dispatch.log"
HEMS.paths.active_mission = HEMS.paths.output .. "active_mission.txt"
HEMS.paths.base_position = HEMS.paths.output .. "base_position.dat"
HEMS.paths.flight_track = HEMS.paths.output .. "flight_track.dat"

local function raw_log(message)
    local line = string.format("[%s] %s", os.date("%Y-%m-%d %H:%M:%S"), tostring(message))
    if logMsg then
        logMsg("HEMS Dispatch: " .. tostring(message))
    end
    local f = io.open(HEMS.paths.log, "a")
    if f then
        f:write(line, "\n")
        f:close()
    end
end

HEMS.log = raw_log

local function load_module(name)
    local path = HEMS.paths.modules .. name .. ".lua"
    local ok, module_or_error = pcall(dofile, path)
    if not ok then
        error("HEMS Dispatch: Module could not be loaded: " .. path .. "\n" .. tostring(module_or_error))
    end
    return module_or_error
end

HEMS.util = load_module("util")
HEMS.geo = load_module("geo")
HEMS.xplm = load_module("xplm")
HEMS.dsf = load_module("dsf")
HEMS.rescuex = load_module("rescuex")
HEMS.osm = load_module("osm")
HEMS.movingmap = load_module("movingmap")
HEMS.hospitals = load_module("hospitals")
HEMS.mission = load_module("mission")
HEMS.ui = load_module("ui")

function HEMS.load_config()
    local ok, cfg_or_error = pcall(dofile, HEMS.paths.config)
    if not ok then
        HEMS.log("ERROR loading configuration: " .. tostring(cfg_or_error))
        return false, tostring(cfg_or_error)
    end
    if type(cfg_or_error) ~= "table" then
        local msg = "config.lua must return a table."
        HEMS.log("ERROR: " .. msg)
        return false, msg
    end

    local valid, validation_error = HEMS.mission.validate_config(cfg_or_error)
    if not valid then
        HEMS.log("ERROR in config.lua: " .. tostring(validation_error))
        return false, tostring(validation_error)
    end

    HEMS.config = cfg_or_error
    HEMS.log("Configuration loaded.")
    return true
end

function HEMS.command_new_mission(options)
    options = type(options) == "table" and options or {}
    local ok, err = pcall(HEMS.mission.new_mission, options)
    if not ok then
        HEMS.status_message = "Mission generation failed: " .. tostring(err)
        HEMS.log("ERROR new_mission: " .. tostring(err))
        HEMS.ui.show_info()
    end
end

function HEMS.command_end_mission(options)
    options = type(options) == "table" and options or {}
    -- Ending a mission never opens the mission-info window on success.
    -- Errors are still surfaced below via HEMS.ui.show_info().
    local silent = options.show_info_on_success ~= true
    local ok, err = pcall(HEMS.mission.end_mission, silent)
    if not ok then
        HEMS.status_message = "Failed to end mission: " .. tostring(err)
        HEMS.log("ERROR end_mission: " .. tostring(err))
        HEMS.ui.show_info()
    end
end


function HEMS.request_action(action, options)
    if action ~= "new_mission" and action ~= "end_mission" then
        return false, "Unknown action: " .. tostring(action)
    end
    if HEMS.pending_action ~= nil then
        local pending_name = type(HEMS.pending_action) == "table" and HEMS.pending_action.action or HEMS.pending_action
        return false, "Action already queued: " .. tostring(pending_name)
    end
    HEMS.pending_action = {
        action = action,
        options = type(options) == "table" and options or {},
    }
    return true
end

function HEMS.process_pending_action()
    if not HEMS.initialized or HEMS.shutting_down then return end

    local pending = HEMS.pending_action
    if pending == nil then return end
    HEMS.pending_action = nil

    local action = pending
    local options = {}
    if type(pending) == "table" then
        action = pending.action
        options = type(pending.options) == "table" and pending.options or {}
    end

    if action == "new_mission" then
        HEMS.command_new_mission(options)
    elseif action == "end_mission" then
        HEMS.command_end_mission(options)
    end
end

function HEMS.command_show_info()
    HEMS.ui.show_info()
end

function HEMS.command_toggle_moving_map()
    local ok, result, err = pcall(HEMS.movingmap.toggle)
    if not ok then
        HEMS.status_message = "Moving Map could not be toggled: " .. tostring(result)
        HEMS.log("ERROR toggle_moving_map: " .. tostring(result))
        HEMS.ui.show_info()
    elseif result == false then
        HEMS.status_message = "Moving Map could not be toggled: " .. tostring(err or "unknown error")
        HEMS.log("ERROR toggle_moving_map: " .. tostring(err or "unknown error"))
        HEMS.ui.show_info()
    end
end

function HEMS.command_set_base_position()
    local ok, result, err = pcall(HEMS.movingmap.set_base_position)
    if not ok then
        HEMS.status_message = "Base position could not be set: " .. tostring(result)
        HEMS.log("ERROR set_base_position: " .. tostring(result))
        HEMS.ui.show_info()
    elseif result == false then
        HEMS.status_message = "Base position could not be set: " .. tostring(err or "unknown error")
        HEMS.log("ERROR set_base_position: " .. tostring(err or "unknown error"))
        HEMS.ui.show_info()
    end
end

function HEMS.command_reload_config()
    local ok, err = HEMS.load_config()
    if ok then
        HEMS.status_message = "Configuration reloaded successfully."
    else
        HEMS.status_message = "Configuration could not be loaded: " .. tostring(err)
    end
    HEMS.ui.show_info()
end

function HEMS.shutdown()
    if HEMS.shutting_down then return end
    HEMS.shutting_down = true
    HEMS.pending_action = nil
    HEMS.log("Shutdown / reload: cleaning up HEMS Dispatch.")

    pcall(function() HEMS.rescuex.shutdown() end)
    pcall(function() HEMS.hospitals.shutdown() end)
    pcall(function() HEMS.movingmap.shutdown() end)
    pcall(function() HEMS.osm.shutdown() end)
    pcall(function() HEMS.ui.shutdown() end)
    pcall(function() HEMS.xplm.shutdown() end)

    HEMS.initialized = false
end

local function bootstrap()
    HEMS.log("------------------------------------------------------------")
    HEMS.log("HEMS Dispatch v" .. HEMS.VERSION .. " starting.")
    HEMS.log("FlyWithLua: " .. tostring(PLUGIN_VERSION or PLUGIN_VERSION_NO or "unknown"))

    math.randomseed(os.time() + math.floor(((LATITUDE or 0) + 90) * 10000) + math.floor(((LONGITUDE or 0) + 180) * 1000))
    math.random(); math.random(); math.random()

    local ok_cfg, cfg_err = HEMS.load_config()
    if not ok_cfg then
        HEMS.status_message = "Configuration error: " .. tostring(cfg_err)
        return
    end

    local ok_xplm, xplm_err = HEMS.xplm.init()
    if not ok_xplm then
        HEMS.status_message = "XPLM/FFI could not be initialized: " .. tostring(xplm_err)
        HEMS.log(HEMS.status_message)
        return
    end

    local simheaven_root, detect_err = HEMS.dsf.detect_simheaven_root(SYSTEM_DIRECTORY)
    if not simheaven_root then
        HEMS.status_message = "SimHeaven X-World Europe 8-network not found: " .. tostring(detect_err)
        HEMS.log(HEMS.status_message)
        return
    end
    HEMS.paths.simheaven = simheaven_root
    HEMS.log("SimHeaven 8-network: " .. simheaven_root)

    -- Commands are created by FlyWithLua so they can also be bound to joystick/keyboard.
    create_command("hems_dispatch/new_mission", "HEMS Dispatch - New mission", "HEMS.command_new_mission()", "", "")
    create_command("hems_dispatch/end_mission", "HEMS Dispatch - End active mission", "HEMS.command_end_mission()", "", "")
    create_command("hems_dispatch/show_info", "HEMS Dispatch - Show active mission information", "HEMS.command_show_info()", "", "")
    create_command("hems_dispatch/toggle_moving_map", "HEMS Dispatch - Toggle Moving Map", "HEMS.command_toggle_moving_map()", "", "")
    create_command("hems_dispatch/set_base_position", "HEMS Dispatch - Set Base Position", "HEMS.command_set_base_position()", "", "")
    create_command("hems_dispatch/reload_config", "HEMS Dispatch - Reload configuration", "HEMS.command_reload_config()", "", "")

    local menu_ok, menu_err = HEMS.ui.init_menu()
    if not menu_ok then
        HEMS.log("WARNING: HEMS Dispatch X-Plane menu could not be created: " .. tostring(menu_err))
    end

    local base_ok, base_err = HEMS.movingmap.load_base_position()
    if not base_ok and base_err then
        HEMS.log("WARNING: Stored base position could not be loaded: " .. tostring(base_err))
    end

    local track_ok, track_err = HEMS.movingmap.load_track()
    if not track_ok and track_err then
        HEMS.log("WARNING: Stored flight track could not be loaded: " .. tostring(track_err))
    end

    HEMS.mission.write_idle_output()
    HEMS.status_message = "Ready. Create a new mission via Plugins > HEMS Dispatch."
    HEMS.initialized = true
    HEMS.log("Initialization complete.")
end

local ok_boot, boot_err = pcall(bootstrap)
if not ok_boot then
    HEMS.status_message = "Initialization error: " .. tostring(boot_err)
    HEMS.log(HEMS.status_message)
end

-- FlyWithLua calls this during a normal script reload / shutdown.
do_on_exit("if HEMS and HEMS.shutdown then HEMS.shutdown() end")

-- Moving-Map ImGui buttons execute inside a draw callback. XPLM instance
-- operations and FlyWithLua floating-window creation must never be triggered
-- directly there. Deferred mission actions and Hospital-window requests are
-- processed in FlyWithLua's pre-flightmodel flight-loop callback.
HEMS_DISPATCH_PROCESS_PENDING_ACTION = function()
    if HEMS then
        HEMS.process_pending_action()
        if HEMS.hospitals and HEMS.hospitals.preflight_update then
            HEMS.hospitals.preflight_update()
        end
    end
end
if type(do_every_frame_before) == "function" then
    do_every_frame_before("HEMS_DISPATCH_PROCESS_PENDING_ACTION()")
else
    -- Compatibility fallback for older FlyWithLua versions.
    do_every_frame("HEMS_DISPATCH_PROCESS_PENDING_ACTION()")
end

-- Track sampling continues even if the Moving Map window is temporarily closed.
-- FlyWithLua calls do_often at a modest cadence; movingmap.background_update()
-- applies its own configurable 0.5 s interval and 3 m movement threshold.
HEMS_DISPATCH_BACKGROUND_UPDATE = function()
    if HEMS and HEMS.initialized then
        if HEMS.movingmap then HEMS.movingmap.background_update() end
        if HEMS.hospitals and HEMS.hospitals.background_update then
            HEMS.hospitals.background_update()
        end
    end
end
do_often("HEMS_DISPATCH_BACKGROUND_UPDATE()")
