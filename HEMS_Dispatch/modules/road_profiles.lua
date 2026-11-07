-- SimHeaven road subtype mappings (X-World Europe / X-World Pro Europe).
-- Keep mission road_groups independent from scenery-specific DSF subtype numbers.
-- Update the revision when changing any subtype group or flag mapping.
local M = {}

local GROUP_IDS = { primary = 1, secondary = 2, ["local"] = 3, single = 4, highway = 5 }
local GROUP_NAMES = {
    primary = "Primary",
    secondary = "Secondary",
    ["local"] = "Local",
    single = "Single Lane",
    highway = "Highway",
}

local DEFAULT_FOLDERS = {
    standard = "simHeaven_X-World_Europe-8-network",
    pro = "simHeaven_X-WORLD-Pro_Europe-13-net3-roads",
}

local function add_range(types, first, last, group, one_way)
    for subtype = first, last do
        types[subtype] = { group = group, one_way = one_way == true }
    end
end

local function create_standard()
    -- Exact v1.1.3 semantics: ranges and one-way flags remain unchanged.
    local types = {}
    add_range(types, 10, 19, "primary")
    add_range(types, 20, 28, "primary", true)
    add_range(types, 30, 39, "secondary")
    add_range(types, 40, 49, "secondary", true)
    add_range(types, 50, 59, "local")
    add_range(types, 60, 69, "local", true)
    types[70] = { group = "single", one_way = false }
    types[71] = { group = "single", one_way = true }
    for _, subtype in ipairs({ 100, 110, 120 }) do
        types[subtype] = { group = "highway", one_way = true }
    end
    return types
end

local function create_pro()
    local types = create_standard()

    -- Verified against supplied XWP_3-roads_EU_left.net (ROAD_DRAPED IDs):
    -- 72-73: single-lane roads with sidewalks (not explicitly one-way).
    -- 74-75: footways; 78-79: cycleways => deliberately not cached.
    -- 76-77: unclassified one-way roads.
    -- 80-81: local entrances; 82-83: residential roads (83 is one-way).
    add_range(types, 72, 73, "single")
    add_range(types, 76, 77, "local", true)
    add_range(types, 80, 82, "local")
    types[83] = { group = "local", one_way = true }

    -- Additional Pro highway variants (city/rural and GK_VFR) and road variants.
    -- Special road subtypes 170-181 are NOT rail or pedestrian network types.
    for _, subtype in ipairs({ 101, 102, 103, 111, 112, 113, 121, 122, 123 }) do
        types[subtype] = { group = "highway", one_way = true }
    end
    add_range(types, 170, 171, "primary")
    add_range(types, 172, 173, "primary", true)
    add_range(types, 174, 175, "secondary")
    add_range(types, 176, 177, "secondary", true)
    add_range(types, 178, 179, "local")
    add_range(types, 180, 181, "local", true)

    -- Explicit exclusions: 74-75/78-79 (pedestrian/bicycle),
    -- 150-155/190-193 (rail), 189 (footway/cycleway).
    return types
end

M.profiles = {
    standard = { edition = "standard", revision = 1, types = create_standard() },
    pro = { edition = "pro", revision = 1, types = create_pro() },
}

function M.resolve(edition, folder)
    -- Older configurations only provided a folder name. Recognize the two
    -- official folder names to avoid silently applying a Standard profile to Pro.
    if edition == nil then
        -- Do not silently use the Standard mapping for an unknown Pro folder.
        if folder == nil or folder:lower() == DEFAULT_FOLDERS.standard:lower() then
            edition = "standard"
        elseif folder:lower() == DEFAULT_FOLDERS.pro:lower() then
            edition = "pro"
        else
            return nil, nil, "Cannot infer SimHeaven edition from a custom folder; set simheaven.edition explicitly."
        end
    end
    local profile = M.profiles[edition]
    if not profile then
        return nil, nil, "simheaven.edition must be 'standard' or 'pro'."
    end
    if folder == nil then folder = DEFAULT_FOLDERS[edition] end

    -- Do not allow a known installation to be parsed using the wrong schema.
    local other = edition == "pro" and "standard" or "pro"
    if folder:lower() == DEFAULT_FOLDERS[other]:lower() then
        return nil, nil, "simheaven.edition does not match simheaven.road_scenery_folder ('" .. folder .. "')."
    end

    return profile, folder
end

function M.cache_tag(profile)
    return profile.edition .. "-v" .. tostring(profile.revision)
end

function M.type_info(profile, subtype)
    return profile and profile.types[subtype] or nil
end

function M.supports(profile, subtype)
    return M.type_info(profile, subtype) ~= nil
end

function M.group_id(profile, subtype)
    local info = M.type_info(profile, subtype)
    return info and GROUP_IDS[info.group] or 0
end

function M.group_name(profile, subtype)
    local info = M.type_info(profile, subtype)
    return info and GROUP_NAMES[info.group] or "Unknown"
end

function M.group_matches(profile, subtype, group, dispatch)
    if type(group) == "table" then
        for _, allowed in ipairs(group) do
            if M.group_matches(profile, subtype, allowed, dispatch) then return true end
        end
        return false
    end
    local info = M.type_info(profile, subtype)
    if not info or info.group ~= group then return false end
    -- These switches were present but unused in v1.1.3. Keep them opt-in.
    if group == "single" and (not dispatch or dispatch.allow_single_lane_incidents ~= true) then return false end
    if group == "highway" and (not dispatch or dispatch.allow_highway_incidents ~= true) then return false end
    return true
end

function M.flags(profile, subtype)
    local info = M.type_info(profile, subtype)
    if not info then return 0 end
    local flags = 0
    if info.one_way then flags = flags + 1 end
    if info.group == "highway" then flags = flags + 2 end
    if info.group == "single" then flags = flags + 4 end
    return flags
end

return M
