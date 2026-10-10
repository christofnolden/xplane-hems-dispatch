local M = {}

M.window = nil
M.items = {}
M.display_items = {}
M.loaded_radius_km = 0
M.display_radius_km = 50
M.reference_lat = nil
M.reference_lon = nil
M.last_sort_lat = nil
M.last_sort_lon = nil
M.last_sort_time = -1000
M.request = nil
M.pending_radius_km = nil
M.pending_force_reload = false
M.close_requested = false
M.show_requested = false
M.status = "idle"
M.error_message = nil
M.request_counter = 0
M.last_requested_radius_km = nil
M.last_requested_force_reload = false
M.gettime = os.clock

local ok_socket, socket_mod = pcall(require, "socket")
if ok_socket and socket_mod and type(socket_mod.gettime) == "function" then
    M.gettime = socket_mod.gettime
end

local function cfg()
    return (HEMS.config and HEMS.config.hospitals) or {}
end

local function monotonic_seconds()
    return M.gettime()
end

local function initial_radius_km()
    return tonumber(cfg().initial_radius_km) or 50
end

local function extended_radius_km()
    return tonumber(cfg().extended_radius_km) or 100
end

local function current_position()
    local lat = tonumber(LATITUDE)
    local lon = tonumber(LONGITUDE)
    if not lat or not lon or lat < -90 or lat > 90 or lon < -180 or lon > 180 then
        return nil, nil
    end
    return lat, lon
end

local function path_for(radius_km, suffix)
    local stem = "hospitals_" .. tostring(math.floor(radius_km + 0.5))
    return HEMS.paths.cache .. stem .. suffix
end

local function trim(value)
    value = tostring(value or "")
    return value:match("^%s*(.-)%s*$") or ""
end

local function parse_tsv_line(line)
    local fields = {}
    local current = {}
    local quoted = false
    local i = 1

    while i <= #line do
        local c = line:sub(i, i)
        if quoted then
            if c == '"' then
                if line:sub(i + 1, i + 1) == '"' then
                    current[#current + 1] = '"'
                    i = i + 1
                else
                    quoted = false
                end
            else
                current[#current + 1] = c
            end
        else
            if c == '"' and #current == 0 then
                quoted = true
            elseif c == "\t" then
                fields[#fields + 1] = table.concat(current)
                current = {}
            else
                current[#current + 1] = c
            end
        end
        i = i + 1
    end
    fields[#fields + 1] = table.concat(current)
    return fields
end

local function parse_hospital_file(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end

    local result = {}
    local seen = {}
    local by_name = {}
    local first_content_line = true
    for line in f:lines() do
        line = line:gsub("\r$", "")
        if line ~= "" then
            if first_content_line then
                first_content_line = false
                local leading = line:match("^%s*(.)")
                if leading == "<" then
                    f:close()
                    return nil, "Overpass returned an error response instead of hospital data"
                end
            end
            local fields = parse_tsv_line(line)
            if #fields < 7 then
                f:close()
                return nil, "Overpass returned malformed hospital data"
            end
            local osm_id = trim(fields[1])
            local osm_type = trim(fields[2])
            local name = trim(fields[3])
            local operator = trim(fields[4])
            local emergency = trim(fields[5])
            local lat = tonumber(fields[6])
            local lon = tonumber(fields[7])

            if lat and lon and lat >= -90 and lat <= 90 and lon >= -180 and lon <= 180 then
                local key = osm_type .. ":" .. osm_id
                if key == ":" then
                    key = string.format("%.7f:%.7f:%s", lat, lon, name)
                end
                if not seen[key] then
                    seen[key] = true
                    if name == "" then name = operator end
                    if name == "" then name = "Unnamed hospital" end

                    -- The same hospital can occasionally be mapped as more than one
                    -- OSM object (for example a node plus a campus relation). Suppress
                    -- only very close objects with the same name to avoid obvious
                    -- duplicates without merging different hospitals.
                    local duplicate = false
                    local normalized_name = name:lower()
                    local same_name = by_name[normalized_name]
                    if normalized_name ~= "unnamed hospital" and same_name then
                        for _, existing in ipairs(same_name) do
                            if HEMS.geo.distance_km(existing.lat, existing.lon, lat, lon) <= 0.25 then
                                duplicate = true
                                break
                            end
                        end
                    end

                    if not duplicate then
                        local item = {
                            key = key,
                            osm_id = osm_id,
                            osm_type = osm_type,
                            name = name,
                            operator = operator,
                            emergency = emergency,
                            lat = lat,
                            lon = lon,
                            distance_km = nil,
                        }
                        result[#result + 1] = item
                        if normalized_name ~= "unnamed hospital" then
                            if not same_name then
                                same_name = {}
                                by_name[normalized_name] = same_name
                            end
                            same_name[#same_name + 1] = item
                        end
                    end
                end
            end
        end
    end
    f:close()
    return result
end

local function write_cache_meta(radius_km, lat, lon)
    local path = path_for(radius_km, ".meta")
    local f = io.open(path, "wb")
    if not f then return false end
    f:write(string.format("radius_km=%.1f\n", radius_km))
    f:write(string.format("lat=%.8f\n", lat))
    f:write(string.format("lon=%.8f\n", lon))
    f:write("saved_at=" .. tostring(os.time()) .. "\n")
    f:close()
    return true
end

local function read_cache_meta(radius_km)
    local f = io.open(path_for(radius_km, ".meta"), "rb")
    if not f then return nil end
    local values = {}
    for line in f:lines() do
        local key, value = line:match("^([%w_]+)=(.*)$")
        if key then values[key] = value end
    end
    f:close()

    local lat = tonumber(values.lat)
    local lon = tonumber(values.lon)
    local saved_at = tonumber(values.saved_at)
    local stored_radius = tonumber(values.radius_km)
    if not lat or not lon or not saved_at or not stored_radius then return nil end
    return {
        lat = lat,
        lon = lon,
        saved_at = saved_at,
        radius_km = stored_radius,
    }
end

local function cache_exists(radius_km)
    local file = io.open(path_for(radius_km, ".tsv"), "rb")
    if not file then return false end
    file:close()
    return true
end

local function rebuild_display_items(force)
    local lat, lon = current_position()
    if not lat or not lon then
        M.display_items = {}
        return
    end

    local now = monotonic_seconds()
    if not force and M.last_sort_lat and M.last_sort_lon then
        local moved_km = HEMS.geo.distance_km(lat, lon, M.last_sort_lat, M.last_sort_lon)
        if moved_km < 0.05 and now - M.last_sort_time < 1.0 then return end
    end

    local items = {}
    local radius = tonumber(M.display_radius_km) or initial_radius_km()
    for _, item in ipairs(M.items) do
        local d = HEMS.geo.distance_km(lat, lon, item.lat, item.lon)
        item.distance_km = d
        if d <= radius + 0.001 then
            items[#items + 1] = item
        end
    end

    table.sort(items, function(a, b)
        if math.abs((a.distance_km or 0) - (b.distance_km or 0)) > 0.001 then
            return (a.distance_km or math.huge) < (b.distance_km or math.huge)
        end
        return tostring(a.name):lower() < tostring(b.name):lower()
    end)

    M.display_items = items
    M.last_sort_lat = lat
    M.last_sort_lon = lon
    M.last_sort_time = now
end

local function activate_items(items, radius_km, reference_lat, reference_lon)
    M.items = items or {}
    M.loaded_radius_km = radius_km
    M.display_radius_km = radius_km
    M.reference_lat = reference_lat
    M.reference_lon = reference_lon
    M.status = "ready"
    M.error_message = nil
    M.last_sort_time = -1000
    rebuild_display_items(true)
end

local function load_cached(radius_km)
    if not cache_exists(radius_km) then return false end

    local items, err = parse_hospital_file(path_for(radius_km, ".tsv"))
    if not items then
        HEMS.log("Hospitals: cached data could not be read: " .. tostring(err))
        return false
    end

    local meta = read_cache_meta(radius_km)
    activate_items(items, radius_km, meta and meta.lat or nil, meta and meta.lon or nil)
    HEMS.log(string.format("Hospitals: loaded %d cached entries for %.0f km.", #items, radius_km))
    return true
end

local function load_initial_cached()
    local candidates = {}
    for _, radius in ipairs({ initial_radius_km(), extended_radius_km() }) do
        if cache_exists(radius) then
            local meta = read_cache_meta(radius)
            candidates[#candidates + 1] = {
                radius = radius,
                saved_at = meta and meta.saved_at or 0,
            }
        end
    end

    table.sort(candidates, function(a, b)
        return (a.saved_at or 0) > (b.saved_at or 0)
    end)

    for _, candidate in ipairs(candidates) do
        if load_cached(candidate.radius) then
            M.display_radius_km = initial_radius_km()
            rebuild_display_items(true)
            return true
        end
    end
    return false
end

local function build_query(radius_km, lat, lon)
    local radius_m = math.floor(radius_km * 1000 + 0.5)
    return string.format([[
[out:csv(::id,::type,name,operator,emergency,::lat,::lon;false;"\t")][timeout:25];
(
  nwr["amenity"="hospital"](around:%d,%.7f,%.7f);
  nwr["healthcare"="hospital"](around:%d,%.7f,%.7f);
);
out center;
]], radius_m, lat, lon, radius_m, lat, lon)
end

local function shell_quote(value)
    value = tostring(value or "")
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function windows_quote_arg(arg)
    arg = tostring(arg or "")
    if arg == "" then return '""' end
    if not arg:find('[%s"]') then return arg end

    local out = {'"'}
    local backslashes = 0
    for i = 1, #arg do
        local c = arg:sub(i, i)
        if c == "\\" then
            backslashes = backslashes + 1
        elseif c == '"' then
            out[#out + 1] = string.rep("\\", backslashes * 2 + 1)
            out[#out + 1] = '"'
            backslashes = 0
        else
            if backslashes > 0 then
                out[#out + 1] = string.rep("\\", backslashes)
                backslashes = 0
            end
            out[#out + 1] = c
        end
    end
    if backslashes > 0 then
        out[#out + 1] = string.rep("\\", backslashes * 2)
    end
    out[#out + 1] = '"'
    return table.concat(out)
end

local function start_windows_request(args)
    -- osm.init() initializes the Win32 FFI declarations used for headless curl.
    local ok_osm, osm_err = HEMS.osm.init()
    if not ok_osm then return nil, osm_err end

    local ok_ffi, ffi = pcall(require, "ffi")
    if not ok_ffi then return nil, "LuaJIT FFI is unavailable: " .. tostring(ffi) end
    local ok_kernel, kernel = pcall(ffi.load, "kernel32")
    if not ok_kernel then return nil, "kernel32 could not be loaded: " .. tostring(kernel) end

    local CP_UTF8 = 65001
    local CREATE_NO_WINDOW = 0x08000000
    local quoted = {}
    for i, arg in ipairs(args) do quoted[i] = windows_quote_arg(arg) end
    local command_line = table.concat(quoted, " ")

    local needed = kernel.MultiByteToWideChar(CP_UTF8, 0, command_line, #command_line, nil, 0)
    if needed <= 0 then return nil, "UTF-8 -> UTF-16 conversion failed." end
    local cmd_w = ffi.new("HEMS_WCHAR[?]", needed + 1)
    local written = kernel.MultiByteToWideChar(CP_UTF8, 0, command_line, #command_line, cmd_w, needed)
    if written ~= needed then return nil, "UTF-8 -> UTF-16 conversion incomplete." end
    cmd_w[needed] = 0

    local si = ffi.new("HEMS_STARTUPINFOW[1]")
    local pi_info = ffi.new("HEMS_PROCESS_INFORMATION[1]")
    si[0].cb = ffi.sizeof("HEMS_STARTUPINFOW")

    local ok = kernel.CreateProcessW(nil, cmd_w, nil, nil, 0, CREATE_NO_WINDOW, nil, nil, si, pi_info)
    if ok == 0 then
        return nil, "CreateProcessW(curl) failed, Win32 " .. tostring(tonumber(kernel.GetLastError()))
    end
    if pi_info[0].hThread ~= nil then kernel.CloseHandle(pi_info[0].hThread) end

    return {
        ffi = ffi,
        kernel = kernel,
        process_handle = pi_info[0].hProcess,
        STILL_ACTIVE = 259,
    }
end

local function start_posix_request(args, status_path)
    local quoted = {}
    for i, arg in ipairs(args) do quoted[i] = shell_quote(arg) end
    local command = table.concat(quoted, " ")
    local shell = string.format(
        "(%s >/dev/null 2>&1; printf '%%s' $? > %s) >/dev/null 2>&1 &",
        command,
        shell_quote(status_path)
    )
    local rc = os.execute(shell)
    if rc == true or rc == 0 then return { posix = true } end
    return nil, "curl could not be started."
end

local function start_request(radius_km, force_reload)
    M.last_requested_radius_km = radius_km
    M.last_requested_force_reload = force_reload == true
    local lat, lon = current_position()
    if not lat or not lon then
        M.status = "error"
        M.error_message = "Aircraft position unavailable."
        return false
    end

    if not force_reload and load_cached(radius_km) then
        return true
    end

    M.request_counter = M.request_counter + 1
    local token = string.format("%d_%d_%d", os.time(), math.floor(radius_km + 0.5), M.request_counter)
    local part_path = HEMS.paths.cache .. "hospitals_" .. token .. ".part"
    local status_path = HEMS.paths.cache .. "hospitals_" .. token .. ".status"
    os.remove(part_path)
    os.remove(status_path)

    local query = build_query(radius_km, lat, lon)
    local overpass_url = tostring(cfg().overpass_url or "https://overpass-api.de/api/interpreter")
    local user_agent = tostring(cfg().user_agent or "HEMS-Dispatch/1.0.17 (X-Plane 12; FlyWithLua NG+)")
    local curl = tostring(cfg().curl_executable or ((SYSTEM == "IBM") and "curl.exe" or "curl"))
    local connect_timeout = tonumber(cfg().connect_timeout_seconds) or 5
    local request_timeout = tonumber(cfg().request_timeout_seconds) or 35

    local args = {
        curl,
        "--fail",
        "--silent",
        "--show-error",
        "--location",
        "--connect-timeout", tostring(connect_timeout),
        "--max-time", tostring(request_timeout),
        "--user-agent", user_agent,
        "--output", part_path,
        "--data-urlencode", "data=" .. query,
        overpass_url,
    }

    local process, err
    if SYSTEM == "IBM" then
        process, err = start_windows_request(args)
    else
        process, err = start_posix_request(args, status_path)
    end
    if not process then
        M.status = "error"
        M.error_message = "Hospital data request could not be started: " .. tostring(err)
        HEMS.log("Hospitals: " .. M.error_message)
        return false
    end

    M.request = {
        radius_km = radius_km,
        force_reload = force_reload == true,
        reference_lat = lat,
        reference_lon = lon,
        part_path = part_path,
        status_path = status_path,
        started_at = monotonic_seconds(),
        started_at_wall = os.time(),
        process = process,
    }
    M.status = "loading"
    M.error_message = nil
    HEMS.log(string.format("Hospitals: requesting hospitals within %.0f km from %.6f/%.6f.", radius_km, lat, lon))
    return true
end

local function close_windows_process(request, terminate)
    if SYSTEM ~= "IBM" or not request or not request.process or not request.process.process_handle then return end
    local p = request.process
    if terminate then
        pcall(function() p.kernel.TerminateProcess(p.process_handle, 1) end)
    end
    pcall(function() p.kernel.CloseHandle(p.process_handle) end)
    p.process_handle = nil
end

local function finish_request(success, exit_code, error_text)
    local request = M.request
    if not request then return end
    close_windows_process(request, false)

    if success then
        local items, parse_err = parse_hospital_file(request.part_path)
        if not items then
            success = false
            error_text = "Hospital data could not be parsed: " .. tostring(parse_err)
        else
            local final_path = path_for(request.radius_km, ".tsv")
            os.remove(final_path)
            local renamed, rename_err = os.rename(request.part_path, final_path)
            if not renamed then
                HEMS.log("Hospitals: cache file could not be finalized: " .. tostring(rename_err))
            else
                write_cache_meta(request.radius_km, request.reference_lat, request.reference_lon)
                if request.radius_km < extended_radius_km() then
                    -- A fresh 50 km dataset may have been loaded from a completely
                    -- different area. Do not let an older 100 km cache from another
                    -- query origin silently reappear on the next Load more.
                    os.remove(path_for(extended_radius_km(), ".tsv"))
                    os.remove(path_for(extended_radius_km(), ".meta"))
                end
            end

            activate_items(items, request.radius_km, request.reference_lat, request.reference_lon)
            HEMS.log(string.format("Hospitals: loaded %d entries for %.0f km.", #items, request.radius_km))
        end
    end

    if not success then
        os.remove(request.part_path)
        M.status = "error"
        if error_text then
            M.error_message = error_text
        elseif exit_code ~= nil then
            M.error_message = "Hospital data request failed (curl exit " .. tostring(exit_code) .. ")."
        else
            M.error_message = "Hospital data request failed."
        end
        HEMS.log("Hospitals: " .. M.error_message)
    end

    os.remove(request.status_path)
    M.request = nil
end

local function poll_request()
    local request = M.request
    if not request then return end

    local timeout = (tonumber(cfg().request_timeout_seconds) or 35) + 5
    if os.time() - (request.started_at_wall or os.time()) > timeout then
        close_windows_process(request, true)
        finish_request(false, nil, "Hospital data request timed out.")
        return
    end

    if SYSTEM == "IBM" then
        local p = request.process
        local exit_code = p.ffi.new("HEMS_DWORD[1]")
        local ok = p.kernel.GetExitCodeProcess(p.process_handle, exit_code)
        if ok == 0 then
            finish_request(false, nil, "Hospital data request process status could not be read.")
            return
        end
        local code = tonumber(exit_code[0])
        if code ~= p.STILL_ACTIVE then
            finish_request(code == 0, code)
        end
        return
    end

    local f = io.open(request.status_path, "rb")
    if f then
        local code = tonumber(trim(f:read("*a")))
        f:close()
        if code ~= nil then
            finish_request(code == 0, code)
        end
    end
end

function M.request_radius(radius_km, force_reload)
    radius_km = tonumber(radius_km)
    if not radius_km then return false, "invalid radius" end
    if M.request or M.pending_radius_km then return false, "hospital request already in progress" end
    M.pending_radius_km = radius_km
    M.pending_force_reload = force_reload == true
    M.status = "queued"
    M.error_message = nil
    return true
end

function M.reload()
    local radius = tonumber(M.display_radius_km) or initial_radius_km()
    if radius >= extended_radius_km() and M.loaded_radius_km >= extended_radius_km() then
        radius = extended_radius_km()
    else
        radius = initial_radius_km()
    end
    return M.request_radius(radius, true)
end

function M.load_more()
    local radius = extended_radius_km()
    if M.loaded_radius_km >= radius then
        M.display_radius_km = radius
        rebuild_display_items(true)
        return true
    end
    return M.request_radius(radius)
end

function M.request_show()
    -- Moving Map buttons run inside an ImGui draw callback. Creating another
    -- FlyWithLua floating window from there can crash X-Plane/FlyWithLua, so
    -- only queue the request here. preflight_update() creates/brings forward
    -- the Hospitals window from the safe pre-flightloop callback.
    M.show_requested = true
    return true
end

function M.show()
    return M.request_show()
end

function M.preflight_update()
    if M.close_requested then
        M.close_requested = false
        if M.window then
            local wnd = M.window
            M.window = nil
            pcall(function() float_wnd_destroy(wnd) end)
        end
    end

    if M.show_requested then
        M.show_requested = false
        local ok, err = M.show_now()
        if not ok then
            M.status = "error"
            M.error_message = "Hospital list could not be opened: " .. tostring(err or "unknown error")
            HEMS.status_message = M.error_message
            HEMS.log("Hospitals: " .. M.error_message)
        end
    end

    poll_request()

    if not M.request and M.pending_radius_km then
        local radius = M.pending_radius_km
        local force_reload = M.pending_force_reload == true
        M.pending_radius_km = nil
        M.pending_force_reload = false
        start_request(radius, force_reload)
    end
end

function M.background_update()
    poll_request()
    if M.window then rebuild_display_items(false) end
end

local function content_width()
    if imgui.GetContentRegionAvail then
        local a, b = imgui.GetContentRegionAvail()
        if type(a) == "table" then return tonumber(a[1] or a.x) or 400 end
        return tonumber(a) or 400
    end
    local cursor_x = imgui.GetCursorPosX and imgui.GetCursorPosX() or 8
    return math.max(120, (imgui.GetWindowWidth and imgui.GetWindowWidth() or 520) - cursor_x - 12)
end

local function request_close()
    M.close_requested = true
end

function M.build_window(wnd, x, y)
    rebuild_display_items(false)

    local radius = tonumber(M.display_radius_km) or initial_radius_km()
    imgui.TextUnformatted(string.format("Hospitals within %.0f km", radius))
    imgui.Separator()

    if HEMS.movingmap and HEMS.movingmap.has_hospital_target and HEMS.movingmap.has_hospital_target() then
        local width = math.max(120, content_width() - 4)
        if imgui.Button("Cancel direction to hospital", width, 30) then
            HEMS.movingmap.clear_hospital_target()
            request_close()
        end
        imgui.Separator()
    end

    if M.status == "loading" or M.status == "queued" then
        local loading_radius = M.request and M.request.radius_km or M.pending_radius_km or radius
        imgui.TextUnformatted(string.format("Loading hospitals within %.0f km ...", loading_radius))
    elseif M.status == "error" and M.error_message then
        imgui.TextUnformatted(M.error_message)
        local retry_radius = tonumber(M.last_requested_radius_km) or initial_radius_km()
        if imgui.Button("Retry", 90, 28) then
            M.request_radius(retry_radius, M.last_requested_force_reload)
        end
        imgui.Separator()
    end

    if #M.display_items == 0 and M.status == "ready" then
        imgui.TextUnformatted(string.format("No hospitals found within %.0f km.", radius))
    else
        imgui.TextUnformatted(string.format("%d hospital%s", #M.display_items, (#M.display_items == 1) and "" or "s"))
        imgui.Separator()
        local width = math.max(120, content_width() - 4)
        for index, hospital in ipairs(M.display_items) do
            local visible_name = tostring(hospital.name or "Hospital"):gsub("##", "# #")
            local label = string.format("%s   %.1f km##hospital_%s_%d", visible_name, hospital.distance_km or 0, hospital.key, index)
            if imgui.Button(label, width, 30) then
                if HEMS.movingmap and HEMS.movingmap.set_hospital_target then
                    HEMS.movingmap.set_hospital_target(hospital)
                    request_close()
                end
            end
        end
    end

    if radius < extended_radius_km() and M.loaded_radius_km >= initial_radius_km() then
        local loading_more = (M.request and M.request.radius_km >= extended_radius_km())
            or (M.pending_radius_km and M.pending_radius_km >= extended_radius_km())
        if loading_more or M.status == "ready" then
            imgui.Separator()
            local width = math.max(120, content_width() - 4)
            if loading_more then
                imgui.TextUnformatted(string.format("Loading hospitals up to %.0f km ...", extended_radius_km()))
            elseif imgui.Button(string.format("Load more (up to %.0f km)", extended_radius_km()), width, 30) then
                M.load_more()
            end
        end
    end

    imgui.Separator()
    local reload_width = math.max(120, content_width() - 4)
    local reload_busy = M.request ~= nil or M.pending_radius_km ~= nil
    if reload_busy then
        imgui.TextUnformatted("Reload unavailable while hospital data is loading.")
    elseif imgui.Button("Reload hospital list", reload_width, 30) then
        M.reload()
    end

    imgui.Separator()
    imgui.TextUnformatted("© OpenStreetMap contributors")
end

function M.on_close(wnd)
    M.window = nil
    M.close_requested = false
end

HEMS_DISPATCH_BUILD_HOSPITALS = function(wnd, x, y) M.build_window(wnd, x, y) end
HEMS_DISPATCH_HOSPITALS_CLOSED = function(wnd) M.on_close(wnd) end

function M.show_now()
    if not SUPPORTS_FLOATING_WINDOWS then
        return false, "FlyWithLua does not support floating windows"
    end

    if M.window then
        if float_wnd_bring_to_front then float_wnd_bring_to_front(M.window) end
        return true
    end

    local lat, lon = current_position()
    if not lat or not lon then
        return false, "aircraft position unavailable"
    end

    M.display_radius_km = initial_radius_km()
    M.close_requested = false
    M.error_message = nil

    -- Hospital datasets are intentionally persistent. Reopening the window never
    -- starts a new Overpass request merely because the helicopter has moved.
    -- Distances and sorting are always recalculated from the current position.
    if M.loaded_radius_km >= initial_radius_km() and #M.items > 0 then
        M.status = "ready"
        rebuild_display_items(true)
    elseif load_initial_cached() then
        -- load_initial_cached() already switches the visible list back to 50 km.
    else
        M.items = {}
        M.display_items = {}
        M.loaded_radius_km = 0
        M.reference_lat = nil
        M.reference_lon = nil
        M.request_radius(initial_radius_km(), false)
    end

    M.window = float_wnd_create(540, 520, 1, true)
    if not M.window then
        return false, "hospital selection window could not be created"
    end
    float_wnd_set_title(M.window, "HEMS Dispatch - Hospitals")
    float_wnd_set_imgui_builder(M.window, "HEMS_DISPATCH_BUILD_HOSPITALS")
    float_wnd_set_onclose(M.window, "HEMS_DISPATCH_HOSPITALS_CLOSED")
    if float_wnd_set_resizing_limits then
        float_wnd_set_resizing_limits(M.window, 360, 280, 900, 900)
    end
    return true
end

function M.shutdown()
    M.pending_radius_km = nil
    M.pending_force_reload = false
    M.close_requested = false
    M.show_requested = false
    if M.request then
        close_windows_process(M.request, true)
        os.remove(M.request.part_path)
        os.remove(M.request.status_path)
        M.request = nil
    end
    if M.window then
        local wnd = M.window
        M.window = nil
        pcall(function() float_wnd_destroy(wnd) end)
    end
end

return M
