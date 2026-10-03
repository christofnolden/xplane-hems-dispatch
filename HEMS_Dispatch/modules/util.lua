local M = {}

local floor = math.floor
local ceil = math.ceil

function M.clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

function M.round(v)
    if v >= 0 then return floor(v + 0.5) end
    return ceil(v - 0.5)
end

function M.file_exists(path)
    local f = io.open(path, "rb")
    if f then f:close(); return true end
    return false
end

function M.read_all(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local d = f:read("*a")
    f:close()
    return d
end

function M.path_join(a, b)
    local sep = DIRECTORY_SEPARATOR or "/"
    if a:sub(-1) == "/" or a:sub(-1) == "\\" then
        return a .. b
    end
    return a .. sep .. b
end

function M.u16le(s, pos)
    local b1, b2 = s:byte(pos, pos + 1)
    if not b2 then return nil end
    return b1 + b2 * 256
end

function M.u32le(s, pos)
    local b1, b2, b3, b4 = s:byte(pos, pos + 3)
    if not b4 then return nil end
    return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

function M.i32le(s, pos)
    local v = M.u32le(s, pos)
    if not v then return nil end
    if v >= 2147483648 then v = v - 4294967296 end
    return v
end

function M.pack_u16(v)
    v = v % 65536
    local b1 = v % 256
    local b2 = floor(v / 256) % 256
    return string.char(b1, b2)
end

function M.pack_u32(v)
    v = v % 4294967296
    local b1 = v % 256
    local b2 = floor(v / 256) % 256
    local b3 = floor(v / 65536) % 256
    local b4 = floor(v / 16777216) % 256
    return string.char(b1, b2, b3, b4)
end

function M.pack_i32(v)
    if v < 0 then v = v + 4294967296 end
    return M.pack_u32(v)
end

function M.bytes_to_hex(s)
    return (s:gsub('.', function(c) return string.format('%02x', string.byte(c)) end))
end

function M.file_footer_hex(path, bytes)
    bytes = bytes or 16
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local size = f:seek("end")
    if not size or size < bytes then
        f:close()
        return nil, "Datei ist zu klein."
    end
    f:seek("set", size - bytes)
    local raw = f:read(bytes)
    f:close()
    if not raw or #raw ~= bytes then return nil, "Footer could not be read." end
    return M.bytes_to_hex(raw)
end

function M.weighted_pick(items, weight_field)
    weight_field = weight_field or "weight"
    local total = 0
    for _, item in ipairs(items or {}) do
        local w = tonumber(item[weight_field] or 0) or 0
        if w > 0 then total = total + w end
    end
    if total <= 0 then return nil end

    local r = math.random() * total
    local acc = 0
    for _, item in ipairs(items) do
        local w = tonumber(item[weight_field] or 0) or 0
        if w > 0 then
            acc = acc + w
            if r <= acc then return item end
        end
    end
    return items[#items]
end

function M.random_int(minv, maxv)
    minv = tonumber(minv) or 0
    maxv = tonumber(maxv) or minv
    if maxv < minv then minv, maxv = maxv, minv end
    return math.random(minv, maxv)
end

function M.random_choice(items)
    if not items or #items == 0 then return nil end
    return items[math.random(1, #items)]
end

function M.format_coord(lat, lon, decimals)
    decimals = decimals or 5
    local ns = lat >= 0 and "N" or "S"
    local ew = lon >= 0 and "E" or "W"
    local fmt = "%s%." .. tostring(decimals) .. "f %s%." .. tostring(decimals) .. "f"
    return string.format(fmt, ns, math.abs(lat), ew, math.abs(lon))
end

function M.format_tile(lat_i, lon_i)
    local lat = string.format("%+03d", lat_i)
    local lon = string.format("%+04d", lon_i)
    return lat .. lon
end

function M.tile_bucket(value)
    return floor(value / 10) * 10
end

function M.safe_tonumber(v, fallback)
    local n = tonumber(v)
    if n == nil then return fallback end
    return n
end

return M
