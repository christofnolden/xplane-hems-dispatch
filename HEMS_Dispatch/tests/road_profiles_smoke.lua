-- Run with lua/luajit from the release root: lua HEMS_Dispatch/tests/road_profiles_smoke.lua
local profiles = dofile("HEMS_Dispatch/modules/road_profiles.lua")
local standard = profiles.profiles.standard
local pro = profiles.profiles.pro

local function check(edition, subtype, group, flags)
    local profile = profiles.profiles[edition]
    local actual = profiles.type_info(profile, subtype)
    assert((actual and actual.group or nil) == group,
        string.format("%s subtype %d: expected group %s, got %s",
            edition, subtype, tostring(group), tostring(actual and actual.group)))
    assert(profiles.flags(profile, subtype) == flags,
        string.format("%s subtype %d: wrong flags", edition, subtype))
end

-- v1.1.3 Standard subtype and directionality regression (every possible DSF byte).
for subtype = 0, 255 do
    local group
    if subtype >= 10 and subtype <= 28 then group = "primary"
    elseif subtype >= 30 and subtype <= 49 then group = "secondary"
    elseif subtype >= 50 and subtype <= 69 then group = "local"
    elseif subtype == 70 or subtype == 71 then group = "single"
    elseif subtype == 100 or subtype == 110 or subtype == 120 then group = "highway" end
    local oneway = (subtype >= 20 and subtype <= 28) or (subtype >= 40 and subtype <= 49)
        or (subtype >= 60 and subtype <= 69) or subtype == 71
        or subtype == 100 or subtype == 110 or subtype == 120
    local flags = (oneway and 1 or 0)
        + (group == "highway" and 2 or 0) + (group == "single" and 4 or 0)
    check("standard", subtype, group, flags)
end

-- New Pro classes: local roads (Medical), single-lane, disallowed foot/cycle/rail.
for _, subtype in ipairs({ 76, 77, 80, 81, 82, 83 }) do
    assert(profiles.group_matches(pro, subtype, "local", {}), "Pro local road not eligible: " .. subtype)
    assert(not profiles.group_matches(standard, subtype, "local", {}))
end
for _, subtype in ipairs({ 74, 75, 78, 79, 150, 151, 152, 153, 154, 155, 189, 190, 191, 192, 193 }) do
    check("pro", subtype, nil, 0)
end
check("pro", 72, "single", 4)
check("pro", 73, "single", 4)
check("pro", 76, "local", 1)
check("pro", 77, "local", 1)
check("pro", 80, "local", 0)
check("pro", 81, "local", 0)
check("pro", 82, "local", 0)
check("pro", 83, "local", 1)
check("pro", 170, "primary", 0)
check("pro", 173, "primary", 1)
check("pro", 176, "secondary", 1)
check("pro", 179, "local", 0)
check("pro", 181, "local", 1)
check("pro", 101, "highway", 3)
check("pro", 111, "highway", 3)
check("pro", 121, "highway", 3)
assert(not profiles.group_matches(pro, 70, "single", { allow_single_lane_incidents = false }))
assert(profiles.group_matches(pro, 70, "single", { allow_single_lane_incidents = true }))
assert(not profiles.group_matches(pro, 100, "highway", { allow_highway_incidents = false }))
assert(profiles.group_matches(pro, 100, "highway", { allow_highway_incidents = true }))
assert(profiles.group_matches(pro, 80, { "primary", "local" }, {}))

local resolved, folder = profiles.resolve(nil, "simHeaven_X-WORLD-Pro_Europe-13-net3-roads")
assert(resolved == pro and folder == "simHeaven_X-WORLD-Pro_Europe-13-net3-roads")
resolved, folder = profiles.resolve(nil, "simHeaven_X-World_Europe-8-network")
assert(resolved == standard and folder == "simHeaven_X-World_Europe-8-network")
resolved, folder = profiles.resolve("pro", nil)
assert(resolved == pro and folder == "simHeaven_X-WORLD-Pro_Europe-13-net3-roads")
resolved, folder = profiles.resolve("standard", nil)
assert(resolved == standard and folder == "simHeaven_X-World_Europe-8-network")
assert(profiles.resolve("pro", "simHeaven_X-World_Europe-8-network") == nil)
assert(profiles.resolve(nil, "custom_unnamed_scenery") == nil)
assert(profiles.cache_tag(pro) ~= profiles.cache_tag(standard))
print("PASS: standard regression, Pro subtypes, disallowed roads, edition selection, opt-in toggles")
