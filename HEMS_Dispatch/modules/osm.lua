local M = {}

local floor = math.floor
local pi = math.pi
local log = math.log
local tan = math.tan
local cos = math.cos
local rad = math.rad
local min = math.min
local max = math.max

M.TILE_SIZE = 256
M.textures = {}
M.pending = {}
M.loaded_texture_count = 0
M.warned_texture_limit = false
M.last_download_launch = 0
M.lfs = nil
M.initialized = false
M.init_failed = false
M.init_error = nil
M.gettime = os.clock
M.win = nil

local ok_socket, socket_mod = pcall(require, "socket")
if ok_socket and socket_mod and type(socket_mod.gettime) == "function" then
    M.gettime = socket_mod.gettime
end

local ok_lfs, lfs_mod = pcall(require, "lfs")
if ok_lfs then M.lfs = lfs_mod end

local function cfg()
    return (HEMS.config and HEMS.config.moving_map) or {}
end

local function path_join(a, b)
    return HEMS.util.path_join(a, b)
end

local function shell_quote(value)
    value = tostring(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

-- Windows OSM I/O intentionally avoids os.execute()/cmd.exe completely.
-- X-Plane is a GUI process; launching shell commands from it creates visible console
-- windows on some systems and can steal input focus. LuaJIT FFI lets us call the
-- Win32 filesystem/process APIs directly and keep downloads truly headless.
local function init_windows_api()
    if SYSTEM ~= "IBM" then return true end
    if M.win then return true end

    local ok_ffi, ffi = pcall(require, "ffi")
    if not ok_ffi then
        return false, "LuaJIT FFI is not available on Windows: " .. tostring(ffi)
    end

    local ok_cdef, cdef_err = pcall(ffi.cdef, [[
typedef void *HEMS_HANDLE;
typedef unsigned long HEMS_DWORD;
typedef unsigned short HEMS_WORD;
typedef int HEMS_BOOL;
typedef unsigned short HEMS_WCHAR;
typedef unsigned char HEMS_BYTE;

typedef struct {
    HEMS_DWORD cb;
    HEMS_WCHAR *lpReserved;
    HEMS_WCHAR *lpDesktop;
    HEMS_WCHAR *lpTitle;
    HEMS_DWORD dwX;
    HEMS_DWORD dwY;
    HEMS_DWORD dwXSize;
    HEMS_DWORD dwYSize;
    HEMS_DWORD dwXCountChars;
    HEMS_DWORD dwYCountChars;
    HEMS_DWORD dwFillAttribute;
    HEMS_DWORD dwFlags;
    HEMS_WORD wShowWindow;
    HEMS_WORD cbReserved2;
    HEMS_BYTE *lpReserved2;
    HEMS_HANDLE hStdInput;
    HEMS_HANDLE hStdOutput;
    HEMS_HANDLE hStdError;
} HEMS_STARTUPINFOW;

typedef struct {
    HEMS_HANDLE hProcess;
    HEMS_HANDLE hThread;
    HEMS_DWORD dwProcessId;
    HEMS_DWORD dwThreadId;
} HEMS_PROCESS_INFORMATION;

HEMS_BOOL CreateDirectoryW(const HEMS_WCHAR *lpPathName, void *lpSecurityAttributes);
HEMS_DWORD GetFileAttributesW(const HEMS_WCHAR *lpFileName);
HEMS_DWORD GetLastError(void);
HEMS_BOOL CreateProcessW(const HEMS_WCHAR *lpApplicationName,
                         HEMS_WCHAR *lpCommandLine,
                         void *lpProcessAttributes,
                         void *lpThreadAttributes,
                         HEMS_BOOL bInheritHandles,
                         HEMS_DWORD dwCreationFlags,
                         void *lpEnvironment,
                         const HEMS_WCHAR *lpCurrentDirectory,
                         HEMS_STARTUPINFOW *lpStartupInfo,
                         HEMS_PROCESS_INFORMATION *lpProcessInformation);
HEMS_BOOL GetExitCodeProcess(HEMS_HANDLE hProcess, HEMS_DWORD *lpExitCode);
HEMS_BOOL TerminateProcess(HEMS_HANDLE hProcess, unsigned int uExitCode);
HEMS_BOOL CloseHandle(HEMS_HANDLE hObject);
int MultiByteToWideChar(unsigned int CodePage, HEMS_DWORD dwFlags,
                        const char *lpMultiByteStr, int cbMultiByte,
                        HEMS_WCHAR *lpWideCharStr, int cchWideChar);
]])
    if not ok_cdef then
        -- A reload can encounter declarations already present in LuaJIT's global FFI
        -- namespace. That is harmless as long as kernel32 can still be loaded.
        local msg = tostring(cdef_err)
        if not msg:find("redefine", 1, true) and not msg:find("attempt to redefine", 1, true) then
            return false, "Win32 FFI declarations could not be loaded: " .. msg
        end
    end

    local ok_kernel, kernel = pcall(ffi.load, "kernel32")
    if not ok_kernel then
        return false, "kernel32 could not be loaded: " .. tostring(kernel)
    end

    M.win = {
        ffi = ffi,
        kernel = kernel,
        CP_UTF8 = 65001,
        CREATE_NO_WINDOW = 0x08000000,
        STILL_ACTIVE = 259,
        INVALID_FILE_ATTRIBUTES = 0xFFFFFFFF,
        FILE_ATTRIBUTE_DIRECTORY = 0x10,
        ERROR_ALREADY_EXISTS = 183,
    }
    return true
end

local function win_utf16(text)
    local win = M.win
    local ffi = win.ffi
    text = tostring(text or "")
    local needed = win.kernel.MultiByteToWideChar(win.CP_UTF8, 0, text, #text, nil, 0)
    if needed <= 0 then return nil, "UTF-8 -> UTF-16 conversion failed." end
    local buffer = ffi.new("HEMS_WCHAR[?]", needed + 1)
    local written = win.kernel.MultiByteToWideChar(win.CP_UTF8, 0, text, #text, buffer, needed)
    if written ~= needed then return nil, "UTF-8 -> UTF-16 conversion incomplete." end
    buffer[needed] = 0
    return buffer
end

local function win_normalize_path(path)
    return tostring(path or ""):gsub("/", "\\")
end

local function win_is_directory(path)
    local wide = win_utf16(win_normalize_path(path))
    if not wide then return false end
    local attrs = tonumber(M.win.kernel.GetFileAttributesW(wide))
    if attrs == M.win.INVALID_FILE_ATTRIBUTES then return false end
    return (attrs % 32) >= M.win.FILE_ATTRIBUTE_DIRECTORY
end

local function ensure_dir_windows(path)
    path = win_normalize_path(path):gsub("\\+$", "")
    if path == "" then return false, "Empty directory path." end
    if win_is_directory(path) then return true end

    -- Drive roots are assumed to exist. UNC paths are not expected for the plugin
    -- directory, but existing UNC parents still work through win_is_directory().
    if path:match("^[A-Za-z]:$") then return true end

    local parent = path:match("^(.*)\\[^\\]+$")
    if parent and parent ~= path and parent ~= "" and not win_is_directory(parent) then
        local ok, err = ensure_dir_windows(parent)
        if not ok then return false, err end
    end

    local wide, conv_err = win_utf16(path)
    if not wide then return false, conv_err end
    if M.win.kernel.CreateDirectoryW(wide, nil) ~= 0 then return true end

    local err = tonumber(M.win.kernel.GetLastError())
    if err == M.win.ERROR_ALREADY_EXISTS and win_is_directory(path) then return true end
    return false, string.format("CreateDirectoryW fehlgeschlagen (Win32 %d): %s", err or -1, path)
end

local function ensure_dir(path)
    if SYSTEM == "IBM" then
        local ok_win, win_err = init_windows_api()
        if not ok_win then return false, win_err end
        return ensure_dir_windows(path)
    end

    if M.lfs then
        local attr = M.lfs.attributes(path)
        if attr and attr.mode == "directory" then return true end
        local parent = tostring(path):match("^(.*)/[^/]+/?$")
        if parent and parent ~= "" and not M.lfs.attributes(parent) then
            local ok_parent, parent_err = ensure_dir(parent)
            if not ok_parent then return false, parent_err end
        end
        local ok, err = M.lfs.mkdir(path)
        if ok then return true end
        attr = M.lfs.attributes(path)
        if attr and attr.mode == "directory" then return true end
        return false, err
    end

    -- Non-Windows fallback only. Windows never reaches a shell.
    local cmd = 'mkdir -p ' .. shell_quote(path) .. ' >/dev/null 2>&1'
    local rc = os.execute(cmd)
    if rc == true or rc == 0 then return true end
    return false, "Directory could not be created: " .. tostring(path)
end

local function is_png(path)
    local f = io.open(path, "rb")
    if not f then return false end
    local sig = f:read(8)
    f:close()
    return sig == "\137PNG\r\n\26\n"
end

local function normalize_tile_x(x, zoom)
    local n = 2 ^ zoom
    x = x % n
    if x < 0 then x = x + n end
    return x
end

local function valid_tile_y(y, zoom)
    local n = 2 ^ zoom
    return y >= 0 and y < n
end

local function tile_key(z, x, y)
    return string.format("%d/%d/%d", z, x, y)
end

local function tile_paths(z, x, y, create_dirs)
    local zdir = path_join(HEMS.paths.osm_cache, tostring(z))
    local xdir = path_join(zdir, tostring(x))
    if create_dirs then
        local ok_z, err_z = ensure_dir(zdir)
        if not ok_z then return nil, nil, err_z end
        local ok_x, err_x = ensure_dir(xdir)
        if not ok_x then return nil, nil, err_x end
    end
    local final_path = path_join(xdir, tostring(y) .. ".png")
    return final_path, final_path .. ".part"
end

function M.init()
    if M.initialized then return true end
    if M.init_failed then return false, M.init_error end

    if SYSTEM == "IBM" then
        local ok_win, win_err = init_windows_api()
        if not ok_win then
            M.init_failed = true
            M.init_error = win_err
            return false, win_err
        end
    end

    HEMS.paths.osm_cache = path_join(HEMS.paths.cache, "osm")
    local ok, err = ensure_dir(HEMS.paths.osm_cache)
    if not ok then
        M.init_failed = true
        M.init_error = err
        return false, err
    end
    M.initialized = true
    HEMS.log("Moving Map: OSM cache ready: " .. tostring(HEMS.paths.osm_cache))
    return true
end

function M.latlon_to_world_px(lat, lon, zoom)
    lat = max(-85.05112878, min(85.05112878, tonumber(lat) or 0))
    lon = tonumber(lon) or 0
    local scale = M.TILE_SIZE * (2 ^ zoom)
    local x = (lon + 180.0) / 360.0 * scale
    local lat_rad = rad(lat)
    local y = (1.0 - log(tan(lat_rad) + 1.0 / cos(lat_rad)) / pi) * 0.5 * scale
    return x, y
end

function M.world_px_to_latlon(x, y, zoom)
    local scale = M.TILE_SIZE * (2 ^ zoom)
    x = tonumber(x) or 0
    y = tonumber(y) or 0

    -- Longitude wraps around the Web-Mercator world; latitude is clamped to
    -- the valid Mercator range.
    x = x % scale
    if x < 0 then x = x + scale end
    y = max(0, min(scale, y))

    local lon = x / scale * 360.0 - 180.0
    local merc_n = pi * (1.0 - 2.0 * y / scale)
    local exp_n = math.exp(merc_n)
    local exp_neg_n = math.exp(-merc_n)
    local sinh_n = (exp_n - exp_neg_n) * 0.5
    local lat = math.deg(math.atan(sinh_n))
    return lat, lon
end

function M.visible_tiles(center_lat, center_lon, zoom, width, height)
    local center_x, center_y = M.latlon_to_world_px(center_lat, center_lon, zoom)
    local left = center_x - width * 0.5
    local top = center_y - height * 0.5
    local first_x = floor(left / M.TILE_SIZE)
    local last_x = floor((left + width) / M.TILE_SIZE)
    local first_y = floor(top / M.TILE_SIZE)
    local last_y = floor((top + height) / M.TILE_SIZE)
    local tiles = {}

    for raw_y = first_y, last_y do
        if valid_tile_y(raw_y, zoom) then
            for raw_x = first_x, last_x do
                local x = normalize_tile_x(raw_x, zoom)
                local sx = raw_x * M.TILE_SIZE - left
                local sy = raw_y * M.TILE_SIZE - top
                local cx = sx + M.TILE_SIZE * 0.5
                local cy = sy + M.TILE_SIZE * 0.5
                tiles[#tiles + 1] = {
                    z = zoom,
                    x = x,
                    y = raw_y,
                    screen_x = sx,
                    screen_y = sy,
                    priority = (cx - width * 0.5) ^ 2 + (cy - height * 0.5) ^ 2,
                }
            end
        end
    end

    -- Load the tiles nearest the aircraft first. This makes the initial map useful
    -- after the first download batch instead of waiting for top-left tiles first.
    table.sort(tiles, function(a, b) return a.priority < b.priority end)
    return tiles, center_x, center_y
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

local function spawn_download_windows(url, part_path)
    local ok_win, win_err = init_windows_api()
    if not ok_win then return nil, win_err end

    local user_agent = tostring(cfg().user_agent or "HEMS-Dispatch/1.0.16 (X-Plane 12; FlyWithLua NG+)")
    local curl = tostring(cfg().curl_executable or "curl.exe")
    local args = {
        curl,
        "--fail",
        "--silent",
        "--show-error",
        "--location",
        "--connect-timeout", tostring(tonumber(cfg().connect_timeout_seconds) or 5),
        "--max-time", tostring(tonumber(cfg().download_timeout_seconds) or 15),
        "--user-agent", user_agent,
        "--output", win_normalize_path(part_path),
        url,
    }

    local quoted = {}
    for i, arg in ipairs(args) do quoted[i] = windows_quote_arg(arg) end
    local command_line = table.concat(quoted, " ")
    local cmd_w, conv_err = win_utf16(command_line)
    if not cmd_w then return nil, conv_err end

    local ffi = M.win.ffi
    local si = ffi.new("HEMS_STARTUPINFOW[1]")
    local pi_info = ffi.new("HEMS_PROCESS_INFORMATION[1]")
    si[0].cb = ffi.sizeof("HEMS_STARTUPINFOW")

    local ok = M.win.kernel.CreateProcessW(
        nil,
        cmd_w,
        nil,
        nil,
        0,
        M.win.CREATE_NO_WINDOW,
        nil,
        nil,
        si,
        pi_info
    )
    if ok == 0 then
        return nil, "CreateProcessW(curl) fehlgeschlagen, Win32 " .. tostring(tonumber(M.win.kernel.GetLastError()))
    end

    -- The thread handle is not needed after process creation. Keep only the process
    -- handle so poll_downloads() can detect completion without blocking X-Plane.
    if pi_info[0].hThread ~= nil then M.win.kernel.CloseHandle(pi_info[0].hThread) end
    return {
        process_handle = pi_info[0].hProcess,
        process_id = tonumber(pi_info[0].dwProcessId),
    }
end

local function spawn_download_posix(url, part_path)
    local user_agent = tostring(cfg().user_agent or "HEMS-Dispatch/1.0.16 (X-Plane 12; FlyWithLua NG+)")
    local curl = tostring(cfg().curl_executable or "curl")
    local args = table.concat({
        shell_quote(curl),
        "--fail",
        "--silent",
        "--show-error",
        "--location",
        "--connect-timeout", tostring(tonumber(cfg().connect_timeout_seconds) or 5),
        "--max-time", tostring(tonumber(cfg().download_timeout_seconds) or 15),
        "--user-agent", shell_quote(user_agent),
        "--output", shell_quote(part_path),
        shell_quote(url),
    }, " ")
    local rc = os.execute(args .. " >/dev/null 2>&1 &")
    if rc == true or rc == 0 then return {posix = true} end
    return nil, "curl could not be started."
end

local function spawn_download(url, part_path)
    if SYSTEM == "IBM" then
        return spawn_download_windows(url, part_path)
    end
    return spawn_download_posix(url, part_path)
end

local function tile_url(z, x, y)
    local template = tostring(cfg().tile_url or "https://tile.openstreetmap.org/{z}/{x}/{y}.png")
    template = template:gsub("{z}", tostring(z))
    template = template:gsub("{x}", tostring(x))
    template = template:gsub("{y}", tostring(y))
    return template
end

local function pending_count()
    local count = 0
    for _ in pairs(M.pending) do count = count + 1 end
    return count
end

local function close_process(state, terminate)
    if SYSTEM ~= "IBM" or not M.win or not state or not state.process_handle then return end
    if terminate then
        pcall(function() M.win.kernel.TerminateProcess(state.process_handle, 1) end)
    end
    pcall(function() M.win.kernel.CloseHandle(state.process_handle) end)
    state.process_handle = nil
end

local function finalize_download(key, state, success, exit_code)
    close_process(state, false)

    if success and is_png(state.part_path) then
        os.remove(state.final_path)
        local ok, rename_err = os.rename(state.part_path, state.final_path)
        if not ok then
            HEMS.log("Moving Map: Tile could not be finalized: " .. tostring(rename_err))
            os.remove(state.part_path)
        end
    else
        os.remove(state.part_path)
        if exit_code ~= nil then
            HEMS.log(string.format("Moving Map: Tile-Download fehlgeschlagen: %s (curl exit %s)", tostring(key), tostring(exit_code)))
        else
            HEMS.log("Moving Map: Invalid tile download discarded: " .. tostring(key))
        end
    end
    M.pending[key] = nil
end

function M.poll_downloads()
    local now = M.gettime()
    local timeout = (tonumber(cfg().download_timeout_seconds) or 15) + 5

    for key, state in pairs(M.pending) do
        if SYSTEM == "IBM" and state.process_handle then
            local exit_code = M.win.ffi.new("HEMS_DWORD[1]")
            local ok = M.win.kernel.GetExitCodeProcess(state.process_handle, exit_code)
            if ok == 0 then
                close_process(state, false)
                os.remove(state.part_path)
                M.pending[key] = nil
                HEMS.log("Moving Map: Process status for tile could not be read: " .. tostring(key))
            elseif tonumber(exit_code[0]) ~= M.win.STILL_ACTIVE then
                local code = tonumber(exit_code[0])
                finalize_download(key, state, code == 0, code)
            elseif now - state.started_at > timeout then
                close_process(state, true)
                os.remove(state.part_path)
                M.pending[key] = nil
                HEMS.log("Moving Map: Tile-Download Timeout: " .. tostring(key))
            end
        elseif SYSTEM ~= "IBM" then
            -- POSIX background downloads do not expose a process handle here. Treat a
            -- complete PNG as finished and otherwise let the timeout clear the request.
            if is_png(state.part_path) then
                finalize_download(key, state, true, 0)
            elseif now - state.started_at > timeout then
                os.remove(state.part_path)
                M.pending[key] = nil
                HEMS.log("Moving Map: Tile-Download Timeout: " .. tostring(key))
            end
        end
    end
end

function M.request_tile(z, x, y)
    if not M.initialized then
        local ok = M.init()
        if not ok then return false end
    end

    x = normalize_tile_x(x, z)
    if not valid_tile_y(y, z) then return false end
    local key = tile_key(z, x, y)
    local final_path, part_path, path_err = tile_paths(z, x, y, true)
    if not final_path then
        HEMS.log("Moving Map: Tile cache path could not be created for " .. key .. ": " .. tostring(path_err))
        return false
    end

    if HEMS.util.file_exists(final_path) and is_png(final_path) then return true end
    if M.pending[key] then return false end

    local max_concurrent = tonumber(cfg().max_concurrent_downloads) or 4
    if pending_count() >= max_concurrent then return false end

    local now_clock = M.gettime()
    local min_gap = tonumber(cfg().download_launch_gap_seconds) or 0.0
    if now_clock - M.last_download_launch < min_gap then return false end

    os.remove(part_path)
    local url = tile_url(z, x, y)
    local process, spawn_err = spawn_download(url, part_path)
    if not process then
        HEMS.log("Moving Map: curl could not be started for " .. key .. ": " .. tostring(spawn_err or "unknown"))
        return false
    end

    M.last_download_launch = now_clock
    M.pending[key] = {
        final_path = final_path,
        part_path = part_path,
        started_at = now_clock,
        process_handle = process.process_handle,
        process_id = process.process_id,
        posix = process.posix,
    }
    return false
end

function M.prepare_tiles(tiles)
    if M.init_failed then return end
    M.poll_downloads()
    for _, tile in ipairs(tiles or {}) do
        M.request_tile(tile.z, tile.x, tile.y)
    end
end

function M.texture_for(z, x, y)
    x = normalize_tile_x(x, z)
    if not valid_tile_y(y, z) then return nil end
    local key = tile_key(z, x, y)
    if M.textures[key] ~= nil then return M.textures[key] end

    local final_path = tile_paths(z, x, y, false)
    if not final_path or not HEMS.util.file_exists(final_path) or not is_png(final_path) then return nil end

    local max_textures = tonumber(cfg().max_loaded_textures) or 384
    if M.loaded_texture_count >= max_textures then
        if not M.warned_texture_limit then
            M.warned_texture_limit = true
            HEMS.log(string.format(
                "Moving Map: Texture limit (%d) reached. New OSM tiles will not be loaded into GPU memory until the next FlyWithLua reload.",
                max_textures
            ))
        end
        return nil
    end

    local ok, texture_or_err = pcall(float_wnd_load_image, final_path)
    if not ok then
        HEMS.log("Moving Map: OSM tile could not be loaded: " .. tostring(texture_or_err))
        return nil
    end
    M.textures[key] = texture_or_err
    M.loaded_texture_count = M.loaded_texture_count + 1
    return texture_or_err
end

function M.pending_count()
    return pending_count()
end


function M.cancel_pending()
    for _, state in pairs(M.pending) do
        close_process(state, true)
        if state.part_path then os.remove(state.part_path) end
    end
    M.pending = {}
end

function M.shutdown()
    M.cancel_pending()
    M.textures = {}
    M.loaded_texture_count = 0
    M.warned_texture_limit = false
end

return M
