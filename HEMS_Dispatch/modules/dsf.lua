local M = {}

local ffi = require("ffi")
local floor = math.floor
local abs = math.abs
local sqrt = math.sqrt
local cos = math.cos
local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
local DEG = math.pi / 180
local UINT32_RANGE = 4294967296.0
local UINT32_MAX = 4294967295.0

local HRI_MAGIC = "HEMSHRI 2"
local HRI_RECORD_SIZE = 20
local HRI_CHAIN_HEADER_SIZE = 20
local HRI_BUFFER_RECORDS = 2048
local GRAPH_CHAIN_CACHE_LIMIT = 128

M.graph_index_cache = {}

local function u8(ptr, pos)
    return tonumber(ptr[pos])
end

local function u16(ptr, pos)
    return tonumber(ptr[pos]) + tonumber(ptr[pos + 1]) * 256
end

local function u32(ptr, pos)
    return tonumber(ptr[pos])
        + tonumber(ptr[pos + 1]) * 256
        + tonumber(ptr[pos + 2]) * 65536
        + tonumber(ptr[pos + 3]) * 16777216
end

local float_tmp = ffi.new("float[1]")
local function f32(ptr, pos)
    ffi.copy(float_tmp, ptr + pos, 4)
    return tonumber(float_tmp[0])
end

local function atom_id(data, pos)
    return data:sub(pos + 1, pos + 4):reverse()
end

local function parse_atoms(data, ptr, start_pos, end_pos)
    local atoms = {}
    local pos = start_pos
    while pos + 8 <= end_pos do
        local id = atom_id(data, pos)
        local size = u32(ptr, pos + 4)
        if size < 8 or pos + size > end_pos then
            error(string.format("Invalid DSF atom %s at offset %d (size=%d).", id, pos, size))
        end
        atoms[#atoms + 1] = {
            id = id,
            start_pos = pos,
            content_start = pos + 8,
            end_pos = pos + size,
            size = size,
        }
        pos = pos + size
    end
    if pos ~= end_pos then
        error(string.format("DSF atom boundary not reached cleanly (%d != %d).", pos, end_pos))
    end
    return atoms
end

local function find_atom(atoms, id)
    for _, a in ipairs(atoms) do
        if a.id == id then return a end
    end
    return nil
end

local function string_table(data, atom)
    local result = {}
    local raw = data:sub(atom.content_start + 1, atom.end_pos)
    local start = 1
    while start <= #raw do
        local stop = raw:find("\0", start, true)
        if not stop then break end
        result[#result + 1] = raw:sub(start, stop - 1)
        start = stop + 1
    end
    return result
end

local function road_subtype_supported_for_cache(subtype)
    return (subtype >= 10 and subtype <= 71)
        or subtype == 100
        or subtype == 110
        or subtype == 120
end

local function road_group_matches(subtype, group)
    if group == "primary" then return subtype >= 10 and subtype <= 28 end
    if group == "secondary" then return subtype >= 30 and subtype <= 49 end
    if group == "local" then return subtype >= 50 and subtype <= 69 end
    if group == "single" then return subtype == 70 or subtype == 71 end
    if group == "highway" then return subtype == 100 or subtype == 110 or subtype == 120 end
    return false
end

local function road_group_id(subtype)
    if subtype >= 10 and subtype <= 28 then return 1 end
    if subtype >= 30 and subtype <= 49 then return 2 end
    if subtype >= 50 and subtype <= 69 then return 3 end
    if subtype == 70 or subtype == 71 then return 4 end
    if subtype == 100 or subtype == 110 or subtype == 120 then return 5 end
    return 0
end

local function subtype_flags(subtype)
    local oneway = (subtype >= 20 and subtype <= 28)
        or (subtype >= 40 and subtype <= 49)
        or (subtype >= 60 and subtype <= 69)
        or subtype == 71
        or subtype == 100
        or subtype == 110
        or subtype == 120
    local highway = subtype == 100 or subtype == 110 or subtype == 120
    local single = subtype == 70 or subtype == 71

    local flags = 0
    if oneway then flags = flags + 1 end
    if highway then flags = flags + 2 end
    if single then flags = flags + 4 end
    return flags
end

local function flag_is_oneway(flags)
    return (flags % 2) == 1
end

local function walk_commands(ptr, start_pos, end_pos, handler)
    local pos = start_pos
    local state = {
        pool = 0,
        junction_offset = 0,
        definition = 0,
        subtype = 0,
    }

    while pos < end_pos do
        local op = u8(ptr, pos)
        pos = pos + 1

        if op == 1 then
            state.pool = u16(ptr, pos)
            pos = pos + 2
        elseif op == 2 then
            state.junction_offset = u32(ptr, pos)
            pos = pos + 4
        elseif op == 3 then
            state.definition = u8(ptr, pos)
            pos = pos + 1
        elseif op == 4 then
            state.definition = u16(ptr, pos)
            pos = pos + 2
        elseif op == 5 then
            state.definition = u32(ptr, pos)
            pos = pos + 4
        elseif op == 6 then
            state.subtype = u8(ptr, pos)
            pos = pos + 1
        elseif op == 7 then
            pos = pos + 2
        elseif op == 8 then
            pos = pos + 4
        elseif op == 9 then
            local count = u8(ptr, pos)
            pos = pos + 1
            local index_pos = pos
            if handler then handler(state, op, count, index_pos, nil, nil) end
            pos = pos + count * 2
        elseif op == 10 then
            local first = u16(ptr, pos)
            local last_exclusive = u16(ptr, pos + 2)
            if handler then handler(state, op, nil, nil, first, last_exclusive) end
            pos = pos + 4
        elseif op == 11 then
            local count = u8(ptr, pos)
            pos = pos + 1
            local index_pos = pos
            if handler then handler(state, op, count, index_pos, nil, nil) end
            pos = pos + count * 4
        elseif op == 32 then
            local count = u8(ptr, pos)
            pos = pos + 1 + count
        elseif op == 33 then
            local count = u16(ptr, pos)
            pos = pos + 2 + count
        elseif op == 34 then
            local count = u32(ptr, pos)
            pos = pos + 4 + count
        else
            error(string.format(
                "DSF command %d is not supported by the HEMS network parser (offset %d).",
                op, pos - 1
            ))
        end

        if pos > end_pos then
            error("DSF command stream exceeds CMDS atom.")
        end
    end
end

local function decode_plane(ptr, pos, count, encoding, store)
    local arr = nil
    if store then arr = ffi.new("uint32_t[?]", count) end
    local diff = encoding == 1 or encoding == 3
    local rle = encoding == 2 or encoding == 3
    local acc = 0.0
    local out_index = 0

    local function consume_value(v)
        if diff then
            acc = acc + v
            if acc >= UINT32_RANGE then acc = acc - UINT32_RANGE end
            v = acc
        end
        if arr then arr[out_index] = v end
        out_index = out_index + 1
    end

    if not rle then
        while out_index < count do
            local v = u32(ptr, pos)
            pos = pos + 4
            consume_value(v)
        end
    else
        while out_index < count do
            local control = u8(ptr, pos)
            pos = pos + 1
            local run_count = control % 128
            if run_count == 0 then
                error("Invalid DSF RLE run_count=0.")
            end

            if control >= 128 then
                local v = u32(ptr, pos)
                pos = pos + 4
                for _ = 1, run_count do
                    if out_index >= count then break end
                    consume_value(v)
                end
            else
                for _ = 1, run_count do
                    if out_index >= count then break end
                    local v = u32(ptr, pos)
                    pos = pos + 4
                    consume_value(v)
                end
            end
        end
    end

    if out_index ~= count then
        error(string.format("PO32 plane decode mismatch (%d != %d).", out_index, count))
    end
    return arr, pos
end

local function decode_pool(data, ptr, po_atom, sc_atom)
    local pos = po_atom.content_start
    local count = u32(ptr, pos)
    pos = pos + 4
    local planes = u8(ptr, pos)
    pos = pos + 1

    if count <= 0 then
        return { count = 0, planes = planes }
    end
    if planes < 4 then
        error("Network-PO32 besitzt weniger als vier Ebenen.")
    end

    local scales = {}
    local sc_pos = sc_atom.content_start
    for plane = 1, planes do
        scales[plane] = {
            multiplier = f32(ptr, sc_pos),
            offset = f32(ptr, sc_pos + 4),
        }
        sc_pos = sc_pos + 8
    end

    local arrays = {}
    for plane = 1, planes do
        local encoding = u8(ptr, pos)
        pos = pos + 1
        if encoding < 0 or encoding > 3 then
            error("Unknown PO32 plane encoding ID: " .. tostring(encoding))
        end
        local store = plane <= 4
        local arr
        arr, pos = decode_plane(ptr, pos, count, encoding, store)
        if store then arrays[plane] = arr end
    end

    if pos ~= po_atom.end_pos then
        error(string.format("PO32 decode endet bei %d statt %d.", pos, po_atom.end_pos))
    end

    return {
        count = count,
        planes = planes,
        lon = arrays[1],
        lat = arrays[2],
        level = arrays[3],
        junction = arrays[4],
        lon_scale = scales[1],
        lat_scale = scales[2],
        level_scale = scales[3],
    }
end

local function scale_value(raw, scale)
    if scale.multiplier == 0 then return raw end
    return raw * scale.multiplier / UINT32_MAX + scale.offset
end

local function coord(pool, index)
    if index < 0 or index >= pool.count then
        error(string.format("Network index %d outside pool size %d.", index, pool.count))
    end
    local lon = scale_value(tonumber(pool.lon[index]), pool.lon_scale)
    local lat = scale_value(tonumber(pool.lat[index]), pool.lat_scale)
    local level = scale_value(tonumber(pool.level[index]), pool.level_scale)
    local junction = tonumber(pool.junction[index])
    return lat, lon, level, junction
end

local function junction_id(pool, index)
    if index < 0 or index >= pool.count then return 0 end
    return tonumber(pool.junction[index]) or 0
end

local function segment_metrics(lat1, lon1, lat2, lon2)
    local mean_lat = (lat1 + lat2) * 0.5 * DEG
    local north_m = (lat2 - lat1) * 111320.0
    local east_m = (lon2 - lon1) * 111320.0 * cos(mean_lat)
    local len = sqrt(north_m * north_m + east_m * east_m)
    local heading = math.deg(atan2(east_m, north_m))
    if heading < 0 then heading = heading + 360.0 end
    return len, heading
end

local function angle_diff(a, b)
    local d = (a - b + 180.0) % 360.0 - 180.0
    return abs(d)
end

local function new_candidate_writer(path)
    local f, err = io.open(path, "wb")
    if not f then return nil, err end

    local writer = {
        file = f,
        buffer = {},
        buffer_count = 0,
        records = 0,
    }

    function writer:flush()
        if self.buffer_count > 0 then
            self.file:write(table.concat(self.buffer))
            self.buffer = {}
            self.buffer_count = 0
        end
    end

    function writer:add(lat, lon, heading, subtype, chain_id, along_m)
        local lat_e7 = HEMS.util.round(lat * 10000000.0)
        local lon_e7 = HEMS.util.round(lon * 10000000.0)
        local heading_cdeg = HEMS.util.round((heading % 360.0) * 100.0) % 36000
        local flags = subtype_flags(subtype)
        local along_cm = math.max(0, HEMS.util.round(along_m * 100.0))
        local record = HEMS.util.pack_i32(lat_e7)
            .. HEMS.util.pack_i32(lon_e7)
            .. HEMS.util.pack_u16(heading_cdeg)
            .. string.char(subtype, flags)
            .. HEMS.util.pack_u32(chain_id)
            .. HEMS.util.pack_u32(along_cm)
        self.buffer_count = self.buffer_count + 1
        self.buffer[self.buffer_count] = record
        self.records = self.records + 1
        if self.buffer_count >= HRI_BUFFER_RECORDS then self:flush() end
    end

    function writer:close()
        self:flush()
        self.file:close()
    end

    return writer
end

local function new_graph_writer(path)
    local f, err = io.open(path, "wb")
    if not f then return nil, err end
    return {
        file = f,
        chains = 0,
        close = function(self) self.file:close() end,
    }
end

local function write_graph_chain(writer, points, subtype, total_len_m)
    writer.chains = writer.chains + 1
    local chain_id = writer.chains
    local flags = subtype_flags(subtype)
    local start_junction = tonumber(points[1].junction) or 0
    local end_junction = tonumber(points[#points].junction) or 0
    local point_count = #points
    local length_cm = math.max(0, HEMS.util.round(total_len_m * 100.0))

    writer.file:write(
        string.char(subtype, flags),
        HEMS.util.pack_u16(0),
        HEMS.util.pack_u32(start_junction),
        HEMS.util.pack_u32(end_junction),
        HEMS.util.pack_u32(point_count),
        HEMS.util.pack_u32(length_cm)
    )

    local buf = {}
    for i, p in ipairs(points) do
        buf[i] = HEMS.util.pack_i32(HEMS.util.round(p.lat * 10000000.0))
            .. HEMS.util.pack_i32(HEMS.util.round(p.lon * 10000000.0))
    end
    writer.file:write(table.concat(buf))
    return chain_id
end

local function copy_file_into(path, out)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    while true do
        local chunk = f:read(1024 * 1024)
        if not chunk or #chunk == 0 then break end
        out:write(chunk)
    end
    f:close()
    return true
end

local function parse_dsf_structure(data)
    if #data < 28 or data:sub(1, 8) ~= "XPLNEDSF" then
        error("DSF is not uncompressed or has no XPLNEDSF header.")
    end

    local ptr = ffi.cast("const uint8_t *", data)
    local version = u32(ptr, 8)
    if version ~= 1 then error("Unsupported DSF version: " .. tostring(version)) end

    local top = parse_atoms(data, ptr, 12, #data - 16)
    local defn = find_atom(top, "DEFN")
    local geod = find_atom(top, "GEOD")
    local cmds = find_atom(top, "CMDS")
    if not defn or not geod or not cmds then
        error("DSF does not contain complete DEFN/GEOD/CMDS atoms.")
    end

    local def_atoms = parse_atoms(data, ptr, defn.content_start, defn.end_pos)
    local netw = find_atom(def_atoms, "NETW")
    if not netw then error("DSF contains no NETW definition table.") end
    local network_defs = string_table(data, netw)

    local road_definition = nil
    for i, path in ipairs(network_defs) do
        local lower = path:lower()
        if lower:find("roads_eu.net", 1, true) then
            road_definition = i - 1
            break
        end
    end
    if road_definition == nil then
        error("lib/g10/roads_EU.net was not found in the DSF NETW table.")
    end

    local geo_atoms = parse_atoms(data, ptr, geod.content_start, geod.end_pos)
    local po32 = {}
    local sc32 = {}
    for _, a in ipairs(geo_atoms) do
        if a.id == "PO32" then po32[#po32 + 1] = a end
        if a.id == "SC32" then sc32[#sc32 + 1] = a end
    end
    if #po32 ~= #sc32 then
        error(string.format("PO32/SC32 Anzahl unterscheidet sich (%d/%d).", #po32, #sc32))
    end

    return {
        ptr = ptr,
        cmds = cmds,
        po32 = po32,
        sc32 = sc32,
        road_definition = road_definition,
    }
end

local function read_hri_header(f)
    local h = {
        magic = f:read("*l"),
        source = f:read("*l"),
        tile = f:read("*l"),
        spacing = f:read("*l"),
        candidates = f:read("*l"),
        chains = f:read("*l"),
        data = f:read("*l"),
    }
    if not h.magic then return nil end
    h.candidate_count = tonumber((h.candidates or ""):match("^CANDIDATES%s+(%d+)$"))
    h.chain_count = tonumber((h.chains or ""):match("^CHAINS%s+(%d+)$"))
    h.data_offset = f:seek()
    if not h.candidate_count or not h.chain_count or not h.data_offset then return nil end
    return h
end

function M.build_cache(source_dsf, cache_path, tile_name, spacing_m)
    HEMS.log("Baue HRI-v2-Road-Cache aus " .. source_dsf)
    local started = os.clock()

    local data, read_err = HEMS.util.read_all(source_dsf)
    if not data then return nil, "DSF could not be read: " .. tostring(read_err) end

    local signature = HEMS.util.bytes_to_hex(data:sub(-16))
    local dsf = parse_dsf_structure(data)

    local used_pools = {}
    walk_commands(dsf.ptr, dsf.cmds.content_start, dsf.cmds.end_pos, function(state, op)
        if (op == 9 or op == 10 or op == 11)
            and state.definition == dsf.road_definition
            and road_subtype_supported_for_cache(state.subtype) then
            used_pools[state.pool] = true
        end
    end)

    local pools = {}
    for pool_index, _ in pairs(used_pools) do
        local po = dsf.po32[pool_index + 1]
        local sc = dsf.sc32[pool_index + 1]
        if not po or not sc then
            return nil, "CMDS references missing PO32/SC32 pool " .. tostring(pool_index)
        end
        HEMS.log(string.format("Decoding network pool %d ...", pool_index))
        pools[pool_index] = decode_pool(data, dsf.ptr, po, sc)
    end

    local cand_tmp = cache_path .. ".candidates.tmp"
    local graph_tmp = cache_path .. ".graph.tmp"
    local final_tmp = cache_path .. ".new"
    os.remove(cand_tmp)
    os.remove(graph_tmp)
    os.remove(final_tmp)

    local candidate_writer, candidate_err = new_candidate_writer(cand_tmp)
    if not candidate_writer then return nil, "Candidate temporary file could not be created: " .. tostring(candidate_err) end
    local graph_writer, graph_err = new_graph_writer(graph_tmp)
    if not graph_writer then
        candidate_writer:close()
        os.remove(cand_tmp)
        return nil, "Graph temporary file could not be created: " .. tostring(graph_err)
    end

    local function write_ground_run(points, subtype)
        if #points < 2 then return end

        local total_len = 0.0
        local segment_lengths = {}
        local segment_headings = {}
        for i = 1, #points - 1 do
            local seg_len, heading = segment_metrics(points[i].lat, points[i].lon, points[i + 1].lat, points[i + 1].lon)
            segment_lengths[i] = seg_len
            segment_headings[i] = heading
            total_len = total_len + seg_len
        end
        if total_len <= 0.05 then return end

        local chain_id = write_graph_chain(graph_writer, points, subtype, total_len)
        local next_sample = spacing_m * 0.5
        local along_before = 0.0

        for i = 1, #points - 1 do
            local seg_len = segment_lengths[i]
            if seg_len > 0.05 then
                while next_sample <= along_before + seg_len + 1e-6 do
                    local local_m = next_sample - along_before
                    local t = local_m / seg_len
                    local lat = points[i].lat + (points[i + 1].lat - points[i].lat) * t
                    local lon = points[i].lon + (points[i + 1].lon - points[i].lon) * t
                    candidate_writer:add(lat, lon, segment_headings[i], subtype, chain_id, next_sample)
                    next_sample = next_sample + spacing_m
                end
            end
            along_before = along_before + seg_len
        end
    end

    local function process_complete_chain(state, indices)
        local pool = pools[state.pool]
        if not pool or #indices < 2 then return end

        local run = {}
        local function flush_run()
            if #run >= 2 then write_ground_run(run, state.subtype) end
            run = {}
        end

        for _, idx in ipairs(indices) do
            local lat, lon, level, junction = coord(pool, idx)
            if abs(level) < 0.01 then
                run[#run + 1] = { lat = lat, lon = lon, junction = junction }
            else
                flush_run()
            end
        end
        flush_run()
    end

    local function process_sequence(state, get_index, count)
        local pool = pools[state.pool]
        if not pool or pool.count <= 0 or count < 2 then return end

        local active = nil
        for n = 0, count - 1 do
            local idx = get_index(n)
            local jid = junction_id(pool, idx)

            if not active then
                if jid ~= 0 then active = { idx } end
            else
                active[#active + 1] = idx
                if jid ~= 0 then
                    process_complete_chain(state, active)
                    active = { idx }
                end
            end
        end
    end

    local ok_walk, walk_err = pcall(function()
        walk_commands(dsf.ptr, dsf.cmds.content_start, dsf.cmds.end_pos,
            function(state, op, count, index_pos, first, last_exclusive)
                if state.definition ~= dsf.road_definition
                    or not road_subtype_supported_for_cache(state.subtype) then
                    return
                end

                if op == 10 then
                    local n = last_exclusive - first
                    process_sequence(state, function(i)
                        return state.junction_offset + first + i
                    end, n)
                elseif op == 9 then
                    process_sequence(state, function(i)
                        return state.junction_offset + u16(dsf.ptr, index_pos + i * 2)
                    end, count)
                elseif op == 11 then
                    process_sequence(state, function(i)
                        return u32(dsf.ptr, index_pos + i * 4)
                    end, count)
                end
            end)
    end)

    candidate_writer:close()
    graph_writer:close()

    if not ok_walk then
        os.remove(cand_tmp)
        os.remove(graph_tmp)
        return nil, tostring(walk_err)
    end

    local out, out_err = io.open(final_tmp, "wb")
    if not out then
        os.remove(cand_tmp)
        os.remove(graph_tmp)
        return nil, "Cache file could not be created: " .. tostring(out_err)
    end

    out:write(HRI_MAGIC, "\n")
    out:write("SOURCE ", signature, "\n")
    out:write("TILE ", tile_name, "\n")
    out:write("SPACING ", tostring(spacing_m), "\n")
    out:write("CANDIDATES ", tostring(candidate_writer.records), "\n")
    out:write("CHAINS ", tostring(graph_writer.chains), "\n")
    out:write("DATA\n")

    local ok_copy, copy_err = copy_file_into(cand_tmp, out)
    if ok_copy then ok_copy, copy_err = copy_file_into(graph_tmp, out) end
    out:close()
    os.remove(cand_tmp)
    os.remove(graph_tmp)

    if not ok_copy then
        os.remove(final_tmp)
        return nil, "Cache merge failed: " .. tostring(copy_err)
    end

    os.remove(cache_path)
    local renamed, rename_err = os.rename(final_tmp, cache_path)
    if not renamed then
        os.remove(final_tmp)
        return nil, "Cache file could not be activated: " .. tostring(rename_err)
    end

    M.graph_index_cache[cache_path] = nil

    local elapsed = os.clock() - started
    HEMS.log(string.format(
        "HRI-v2 cache %s complete: %d candidates, %d road chains, %.2f s CPU time.",
        tile_name, candidate_writer.records, graph_writer.chains, elapsed
    ))

    pools = nil
    data = nil
    collectgarbage("collect")
    return cache_path
end

local function cache_header(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local h = read_hri_header(f)
    f:close()
    return h
end

function M.cache_is_valid(cache_path, source_dsf, spacing_m)
    if not HEMS.util.file_exists(cache_path) or not HEMS.util.file_exists(source_dsf) then return false end
    local h = cache_header(cache_path)
    if not h or h.magic ~= HRI_MAGIC or h.data ~= "DATA" then return false end

    local expected_sig = HEMS.util.file_footer_hex(source_dsf, 16)
    if not expected_sig then return false end
    if h.source ~= "SOURCE " .. expected_sig then return false end
    if h.spacing ~= "SPACING " .. tostring(spacing_m) then return false end
    return true
end

function M.detect_simheaven_root(system_directory)
    local sep = DIRECTORY_SEPARATOR or "/"
    local ini = system_directory .. "Custom Scenery" .. sep .. "scenery_packs.ini"
    local f = io.open(ini, "r")
    if f then
        for line in f:lines() do
            if line:match("^SCENERY_PACK%s+") then
                local path = line:match("^SCENERY_PACK%s+(.+)%s*$")
                if path and path:lower():find("simheaven_x-world_europe-8-network", 1, true) then
                    f:close()
                    path = path:gsub("[/\\]+$", "")
                    return system_directory .. path
                end
            end
        end
        f:close()
    end

    return nil, "No active SCENERY_PACK entry for simHeaven_X-World_Europe-8-network in " .. ini
end

function M.source_dsf_path(tile_lat, tile_lon)
    local sep = DIRECTORY_SEPARATOR or "/"
    local tile = HEMS.util.format_tile(tile_lat, tile_lon)
    local bucket_lat = HEMS.util.tile_bucket(tile_lat)
    local bucket_lon = HEMS.util.tile_bucket(tile_lon)
    local bucket = HEMS.util.format_tile(bucket_lat, bucket_lon)
    return HEMS.paths.simheaven
        .. sep .. "Earth nav data"
        .. sep .. bucket
        .. sep .. tile .. ".dsf", tile
end

function M.cache_path(tile_name)
    return HEMS.paths.cache .. tile_name .. ".hri"
end

function M.ensure_cache(tile_lat, tile_lon)
    local source, tile_name = M.source_dsf_path(tile_lat, tile_lon)
    if not HEMS.util.file_exists(source) then
        return nil, "SimHeaven DSF missing: " .. source
    end

    local cache = M.cache_path(tile_name)
    local spacing = HEMS.config.dispatch.candidate_spacing_m
    if M.cache_is_valid(cache, source, spacing) then
        return cache
    end

    return M.build_cache(source, cache, tile_name, spacing)
end

local function decode_candidate(chunk, pos)
    local subtype = chunk:byte(pos + 10)
    local flags = chunk:byte(pos + 11)
    return {
        lat = HEMS.util.i32le(chunk, pos) / 10000000.0,
        lon = HEMS.util.i32le(chunk, pos + 4) / 10000000.0,
        heading = HEMS.util.u16le(chunk, pos + 8) / 100.0,
        subtype = subtype,
        flags = flags,
        one_way = flag_is_oneway(flags),
        chain_id = HEMS.util.u32le(chunk, pos + 12),
        along_m = HEMS.util.u32le(chunk, pos + 16) / 100.0,
    }
end

function M.select_candidates(cache_path, target_lat, target_lon, heli_lat, heli_lon, road_group, limit)
    limit = math.max(1, tonumber(limit) or 16)
    local f, err = io.open(cache_path, "rb")
    if not f then return nil, err end

    local h = read_hri_header(f)
    if not h or h.magic ~= HRI_MAGIC or h.data ~= "DATA" then
        f:close()
        return nil, "Invalid HRI-v2 header."
    end

    local search_r2 = HEMS.config.dispatch.road_search_radius_km ^ 2
    local min_r2 = HEMS.config.dispatch.min_radius_km ^ 2
    local max_r2 = HEMS.config.dispatch.max_radius_km ^ 2
    local selected = {}
    local matching = 0
    local remaining = h.candidate_count
    local chunk_records = 4096

    while remaining > 0 do
        local records = math.min(chunk_records, remaining)
        local chunk = f:read(records * HRI_RECORD_SIZE)
        if not chunk or #chunk < records * HRI_RECORD_SIZE then
            f:close()
            return nil, "HRI-v2-Candidatebereich ist abgeschnitten."
        end

        for rec = 0, records - 1 do
            local pos = rec * HRI_RECORD_SIZE + 1
            local subtype = chunk:byte(pos + 10)
            if road_group_matches(subtype, road_group) then
                local lat = HEMS.util.i32le(chunk, pos) / 10000000.0
                local lon = HEMS.util.i32le(chunk, pos + 4) / 10000000.0
                local target_d2 = HEMS.geo.distance_sq_km_approx(target_lat, target_lon, lat, lon)

                if target_d2 <= search_r2 then
                    local heli_d2 = HEMS.geo.distance_sq_km_approx(heli_lat, heli_lon, lat, lon)
                    if heli_d2 >= min_r2 and heli_d2 <= max_r2 then
                        matching = matching + 1
                        local candidate = nil
                        if #selected < limit then
                            candidate = decode_candidate(chunk, pos)
                            selected[#selected + 1] = candidate
                        else
                            local replace = math.random(matching)
                            if replace <= limit then
                                candidate = decode_candidate(chunk, pos)
                                selected[replace] = candidate
                            end
                        end
                    end
                end
            end
        end
        remaining = remaining - records
    end
    f:close()

    for i = #selected, 2, -1 do
        local j = math.random(i)
        selected[i], selected[j] = selected[j], selected[i]
    end

    return selected, matching
end

function M.select_candidate(cache_path, target_lat, target_lon, heli_lat, heli_lon, road_group)
    local candidates, matching_or_err = M.select_candidates(
        cache_path, target_lat, target_lon, heli_lat, heli_lon, road_group, 1
    )
    if not candidates then return nil, matching_or_err end
    return candidates[1], matching_or_err
end

local function load_graph_index(cache_path)
    local cached = M.graph_index_cache[cache_path]
    if cached then return cached end

    local f, err = io.open(cache_path, "rb")
    if not f then return nil, err end
    local h = read_hri_header(f)
    if not h or h.magic ~= HRI_MAGIC or h.data ~= "DATA" then
        f:close()
        return nil, "Invalid HRI-v2 header."
    end

    local chain_count = h.chain_count
    local graph_offset = h.data_offset + h.candidate_count * HRI_RECORD_SIZE
    f:seek("set", graph_offset)

    local graph = {
        path = cache_path,
        header = h,
        chain_count = chain_count,
        subtype = ffi.new("uint8_t[?]", chain_count),
        flags = ffi.new("uint8_t[?]", chain_count),
        start_junction = ffi.new("uint32_t[?]", chain_count),
        end_junction = ffi.new("uint32_t[?]", chain_count),
        point_count = ffi.new("uint32_t[?]", chain_count),
        length_cm = ffi.new("uint32_t[?]", chain_count),
        points_offset = ffi.new("uint32_t[?]", chain_count),
        chain_cache = {},
        chain_cache_order = {},
        adjacency_cache = {},
    }

    for i = 0, chain_count - 1 do
        local raw = f:read(HRI_CHAIN_HEADER_SIZE)
        if not raw or #raw ~= HRI_CHAIN_HEADER_SIZE then
            f:close()
            return nil, "HRI-v2-Graphheader ist abgeschnitten."
        end
        graph.subtype[i] = raw:byte(1)
        graph.flags[i] = raw:byte(2)
        graph.start_junction[i] = HEMS.util.u32le(raw, 5)
        graph.end_junction[i] = HEMS.util.u32le(raw, 9)
        graph.point_count[i] = HEMS.util.u32le(raw, 13)
        graph.length_cm[i] = HEMS.util.u32le(raw, 17)
        graph.points_offset[i] = f:seek()
        f:seek("cur", tonumber(graph.point_count[i]) * 8)
    end
    f:close()

    M.graph_index_cache[cache_path] = graph
    return graph
end

local function evict_chain_cache(graph)
    while #graph.chain_cache_order > GRAPH_CHAIN_CACHE_LIMIT do
        local old_id = table.remove(graph.chain_cache_order, 1)
        graph.chain_cache[old_id] = nil
    end
end

local function load_chain(graph, chain_id)
    local cached = graph.chain_cache[chain_id]
    if cached then return cached end
    if chain_id < 1 or chain_id > graph.chain_count then return nil, "Invalid road chain ID." end

    local i = chain_id - 1
    local count = tonumber(graph.point_count[i])
    local f, err = io.open(graph.path, "rb")
    if not f then return nil, err end
    f:seek("set", tonumber(graph.points_offset[i]))
    local raw = f:read(count * 8)
    f:close()
    if not raw or #raw ~= count * 8 then return nil, "HRI-v2-Road-Chain ist abgeschnitten." end

    local lat = ffi.new("double[?]", count)
    local lon = ffi.new("double[?]", count)
    local cum = ffi.new("double[?]", count)
    cum[0] = 0.0
    for p = 0, count - 1 do
        local pos = p * 8 + 1
        lat[p] = HEMS.util.i32le(raw, pos) / 10000000.0
        lon[p] = HEMS.util.i32le(raw, pos + 4) / 10000000.0
        if p > 0 then
            local seg_len = segment_metrics(lat[p - 1], lon[p - 1], lat[p], lon[p])
            cum[p] = cum[p - 1] + seg_len
        end
    end

    local chain = {
        id = chain_id,
        subtype = tonumber(graph.subtype[i]),
        flags = tonumber(graph.flags[i]),
        one_way = flag_is_oneway(tonumber(graph.flags[i])),
        start_junction = tonumber(graph.start_junction[i]),
        end_junction = tonumber(graph.end_junction[i]),
        point_count = count,
        lat = lat,
        lon = lon,
        cum = cum,
        total_m = count > 0 and tonumber(cum[count - 1]) or 0.0,
    }

    graph.chain_cache[chain_id] = chain
    graph.chain_cache_order[#graph.chain_cache_order + 1] = chain_id
    evict_chain_cache(graph)
    return chain
end

local function chain_point(chain, along_m)
    if chain.point_count < 2 then return nil end
    local total = chain.total_m
    if along_m < 0 then along_m = 0 end
    if along_m > total then along_m = total end

    local seg = 0
    if along_m >= total then
        seg = chain.point_count - 2
    else
        for i = 0, chain.point_count - 2 do
            if along_m <= chain.cum[i + 1] + 1e-6 then
                seg = i
                break
            end
        end
    end

    while seg < chain.point_count - 2 and chain.cum[seg + 1] - chain.cum[seg] <= 0.01 do
        seg = seg + 1
    end
    while seg > 0 and chain.cum[seg + 1] - chain.cum[seg] <= 0.01 do
        seg = seg - 1
    end

    local seg_len = chain.cum[seg + 1] - chain.cum[seg]
    local t = 0.0
    if seg_len > 0.01 then t = (along_m - chain.cum[seg]) / seg_len end
    if t < 0 then t = 0 elseif t > 1 then t = 1 end

    local lat = chain.lat[seg] + (chain.lat[seg + 1] - chain.lat[seg]) * t
    local lon = chain.lon[seg] + (chain.lon[seg + 1] - chain.lon[seg]) * t
    local _, heading = segment_metrics(chain.lat[seg], chain.lon[seg], chain.lat[seg + 1], chain.lon[seg + 1])
    return lat, lon, heading
end

local function adjacent_chains(graph, junction)
    if not junction or junction == 0 then return {} end
    local cached = graph.adjacency_cache[junction]
    if cached then return cached end

    local result = {}
    for i = 0, graph.chain_count - 1 do
        if tonumber(graph.start_junction[i]) == junction or tonumber(graph.end_junction[i]) == junction then
            result[#result + 1] = i + 1
        end
    end
    graph.adjacency_cache[junction] = result
    return result
end

local function outward_options(graph, junction, current_chain_id, incoming_heading, reference_subtype,
                               respect_oneway, canonical_sign, visited)
    local options = {}
    for _, chain_id in ipairs(adjacent_chains(graph, junction)) do
        if chain_id ~= current_chain_id and not visited[chain_id] then
            local chain = load_chain(graph, chain_id)
            if chain and chain.total_m > 0.05 then
                local orientations = {}
                if chain.start_junction == junction then orientations[#orientations + 1] = 1 end
                if chain.end_junction == junction then orientations[#orientations + 1] = -1 end

                for _, orientation in ipairs(orientations) do
                    local allowed = true
                    if respect_oneway and chain.one_way and orientation ~= canonical_sign then
                        allowed = false
                    end
                    if allowed then
                        local _, _, canonical_heading = chain_point(chain, orientation == 1 and 0.0 or chain.total_m)
                        local outward_heading = canonical_heading
                        if orientation == -1 then outward_heading = (outward_heading + 180.0) % 360.0 end

                        local turn = angle_diff(incoming_heading, outward_heading)
                        local bonus
                        if chain.subtype == reference_subtype then
                            bonus = -20.0
                        elseif road_group_id(chain.subtype) == road_group_id(reference_subtype) then
                            bonus = 0.0
                        else
                            bonus = 60.0
                        end

                        options[#options + 1] = {
                            chain = chain,
                            orientation = orientation,
                            outward_heading = outward_heading,
                            score = turn + bonus,
                        }
                    end
                end
            end
        end
    end

    table.sort(options, function(a, b)
        if abs(a.score - b.score) < 0.001 then return a.chain.id < b.chain.id end
        return a.score < b.score
    end)
    return options
end

local function append_route(a, b)
    local out = {}
    for _, seg in ipairs(a or {}) do out[#out + 1] = seg end
    for _, seg in ipairs(b or {}) do out[#out + 1] = seg end
    return out
end

local function best_route_from_junction(graph, junction, current_chain_id, incoming_heading, remaining_m,
                                        reference_subtype, respect_oneway, canonical_sign, visited, depth)
    if remaining_m <= 0.01 then return {}, 0.0, true end
    if not junction or junction == 0 or depth > 32 then return {}, 0.0, false end

    local options = outward_options(
        graph, junction, current_chain_id, incoming_heading, reference_subtype,
        respect_oneway, canonical_sign, visited
    )

    local best_route = {}
    local best_distance = 0.0
    local best_score = math.huge

    for _, option in ipairs(options) do
        local chain = option.chain
        local orientation = option.orientation
        visited[chain.id] = true

        local from_along = orientation == 1 and 0.0 or chain.total_m
        if chain.total_m >= remaining_m - 1e-6 then
            local seg = {
                chain_id = chain.id,
                orientation = orientation,
                from_along = from_along,
                length_m = remaining_m,
            }
            visited[chain.id] = nil
            return { seg }, remaining_m, true
        end

        local far_junction = orientation == 1 and chain.end_junction or chain.start_junction
        local _, _, canonical_far_heading = chain_point(chain, orientation == 1 and chain.total_m or 0.0)
        local travel_far_heading = canonical_far_heading
        if orientation == -1 then travel_far_heading = (travel_far_heading + 180.0) % 360.0 end

        local sub_route, sub_distance, sub_complete = best_route_from_junction(
            graph,
            far_junction,
            chain.id,
            travel_far_heading,
            remaining_m - chain.total_m,
            reference_subtype,
            respect_oneway,
            canonical_sign,
            visited,
            depth + 1
        )

        local first_seg = {
            chain_id = chain.id,
            orientation = orientation,
            from_along = from_along,
            length_m = chain.total_m,
        }
        local total_distance = chain.total_m + sub_distance
        local route = append_route({ first_seg }, sub_route)
        visited[chain.id] = nil

        if sub_complete then return route, total_distance, true end
        if total_distance > best_distance + 0.01
            or (abs(total_distance - best_distance) <= 0.01 and option.score < best_score) then
            best_route = route
            best_distance = total_distance
            best_score = option.score
        end
    end

    return best_route, best_distance, false
end

local function build_direction(graph, candidate, sign, max_distance_m)
    local chain, chain_err = load_chain(graph, candidate.chain_id)
    if not chain then return nil, chain_err end

    local along = math.max(0.0, math.min(candidate.along_m or 0.0, chain.total_m))
    local to_endpoint = sign == 1 and (chain.total_m - along) or along
    local requested = math.max(0.0, max_distance_m or 0.0)
    local route = {}

    if requested <= 0.01 then
        return { route = route, available_m = 0.0, complete = true }
    end

    local first_len = math.min(to_endpoint, requested)
    if first_len > 0.01 then
        route[#route + 1] = {
            chain_id = chain.id,
            orientation = sign,
            from_along = along,
            length_m = first_len,
        }
    end

    if to_endpoint >= requested - 1e-6 then
        return { route = route, available_m = requested, complete = true }
    end

    local endpoint_along = sign == 1 and chain.total_m or 0.0
    local _, _, canonical_endpoint_heading = chain_point(chain, endpoint_along)
    local travel_heading = canonical_endpoint_heading
    if sign == -1 then travel_heading = (travel_heading + 180.0) % 360.0 end

    local junction = sign == 1 and chain.end_junction or chain.start_junction
    local visited = { [chain.id] = true }
    local sub_route, sub_distance, sub_complete = best_route_from_junction(
        graph,
        junction,
        chain.id,
        travel_heading,
        requested - to_endpoint,
        candidate.subtype,
        candidate.one_way,
        sign,
        visited,
        1
    )

    route = append_route(route, sub_route)
    return {
        route = route,
        available_m = math.min(requested, to_endpoint + sub_distance),
        complete = sub_complete,
    }
end

local function route_point(graph, route, distance_m, fallback_lat, fallback_lon, fallback_heading)
    if distance_m <= 0.001 or #route == 0 then
        return fallback_lat, fallback_lon, fallback_heading
    end

    local remaining = distance_m
    for _, seg in ipairs(route) do
        local use = math.min(remaining, seg.length_m)
        if remaining <= seg.length_m + 1e-6 then
            local chain = load_chain(graph, seg.chain_id)
            local along = seg.from_along + seg.orientation * use
            local lat, lon, canonical_heading = chain_point(chain, along)
            local travel_heading = canonical_heading
            if seg.orientation == -1 then travel_heading = (travel_heading + 180.0) % 360.0 end
            return lat, lon, travel_heading
        end
        remaining = remaining - seg.length_m
    end

    local last = route[#route]
    local chain = load_chain(graph, last.chain_id)
    local along = last.from_along + last.orientation * last.length_m
    local lat, lon, canonical_heading = chain_point(chain, along)
    local travel_heading = canonical_heading
    if last.orientation == -1 then travel_heading = (travel_heading + 180.0) % 360.0 end
    return lat, lon, travel_heading
end

local function build_samples(graph, direction, candidate, sign, resolution_m)
    local samples = {}
    local available = direction.available_m or 0.0
    local fallback_heading = candidate.heading
    if sign == -1 then fallback_heading = (fallback_heading + 180.0) % 360.0 end

    local d = 0.0
    while d <= available + 1e-6 do
        local lat, lon, heading = route_point(
            graph, direction.route, d, candidate.lat, candidate.lon, fallback_heading
        )
        samples[#samples + 1] = { distance_m = d, lat = lat, lon = lon, heading = heading }
        d = d + resolution_m
    end

    if #samples == 0 or samples[#samples].distance_m < available - 0.01 then
        local lat, lon, heading = route_point(
            graph, direction.route, available, candidate.lat, candidate.lon, fallback_heading
        )
        samples[#samples + 1] = { distance_m = available, lat = lat, lon = lon, heading = heading }
    end
    return samples
end

function M.build_road_path(cache_path, candidate, max_extent_m, resolution_m)
    resolution_m = tonumber(resolution_m) or 2.0
    if resolution_m <= 0 then resolution_m = 2.0 end
    max_extent_m = math.max(0.0, tonumber(max_extent_m) or 0.0)
    local sample_extent = math.max(max_extent_m, resolution_m * 2.0)

    local graph, graph_err = load_graph_index(cache_path)
    if not graph then return nil, graph_err end

    local positive, pos_err = build_direction(graph, candidate, 1, sample_extent)
    if not positive then return nil, pos_err end
    local negative, neg_err = build_direction(graph, candidate, -1, sample_extent)
    if not negative then return nil, neg_err end

    local path = {
        cache_path = cache_path,
        graph = graph,
        candidate = candidate,
        resolution_m = resolution_m,
        positive_available_m = positive.available_m,
        negative_available_m = negative.available_m,
        positive_samples = build_samples(graph, positive, candidate, 1, resolution_m),
        negative_samples = build_samples(graph, negative, candidate, -1, resolution_m),
    }

    return path
end

local function interpolate_samples(samples, distance_m)
    if not samples or #samples == 0 then return nil end
    if distance_m <= 0 then
        local s = samples[1]
        return s.lat, s.lon, s.heading
    end
    if distance_m >= samples[#samples].distance_m then
        local s = samples[#samples]
        return s.lat, s.lon, s.heading
    end

    for i = 1, #samples - 1 do
        local a = samples[i]
        local b = samples[i + 1]
        if distance_m <= b.distance_m + 1e-6 then
            local span = b.distance_m - a.distance_m
            local t = span > 0 and (distance_m - a.distance_m) / span or 0.0
            local lat = a.lat + (b.lat - a.lat) * t
            local lon = a.lon + (b.lon - a.lon) * t

            local before = samples[math.max(1, i - 1)]
            local after = samples[math.min(#samples, i + 2)]
            local heading = a.heading
            if before and after and (before.lat ~= after.lat or before.lon ~= after.lon) then
                heading = HEMS.geo.bearing_deg(before.lat, before.lon, after.lat, after.lon)
            end
            return lat, lon, heading
        end
    end

    local s = samples[#samples]
    return s.lat, s.lon, s.heading
end

function M.path_availability(path, scene_direction)
    scene_direction = scene_direction == -1 and -1 or 1
    if scene_direction == 1 then
        return path.positive_available_m, path.negative_available_m
    end
    return path.negative_available_m, path.positive_available_m
end

function M.path_point(path, signed_distance_m, scene_direction)
    scene_direction = scene_direction == -1 and -1 or 1
    signed_distance_m = tonumber(signed_distance_m) or 0.0

    if abs(signed_distance_m) < 0.001 then
        local heading = path.candidate.heading
        if scene_direction == -1 then heading = (heading + 180.0) % 360.0 end
        return path.candidate.lat, path.candidate.lon, heading
    end

    local canonical_distance = signed_distance_m * scene_direction
    local samples
    local outward_to_canonical
    if canonical_distance > 0 then
        samples = path.positive_samples
        outward_to_canonical = 0.0
    else
        samples = path.negative_samples
        outward_to_canonical = 180.0
    end

    local lat, lon, outward_heading = interpolate_samples(samples, abs(canonical_distance))
    if not lat then return nil, nil, nil end

    local canonical_heading = (outward_heading + outward_to_canonical) % 360.0
    local scene_heading = canonical_heading
    if scene_direction == -1 then scene_heading = (scene_heading + 180.0) % 360.0 end
    return lat, lon, scene_heading
end

function M.road_group_name(subtype)
    if subtype >= 10 and subtype <= 28 then return "Primary" end
    if subtype >= 30 and subtype <= 49 then return "Secondary" end
    if subtype >= 50 and subtype <= 69 then return "Local" end
    if subtype == 70 or subtype == 71 then return "Single Lane" end
    if subtype == 100 or subtype == 110 or subtype == 120 then return "Highway" end
    return "Unknown"
end

return M
