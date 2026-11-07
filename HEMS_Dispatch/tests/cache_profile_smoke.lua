-- Lua/LuaJIT lightweight test of HRI-v3 headers and road type filtering.
-- The FFI stub is sufficient here because this test does not decode/build DSFs.
package.preload.ffi = function()
    return { new = function() return {} end }
end
HEMS = {
    road_profiles = dofile("HEMS_Dispatch/modules/road_profiles.lua"),
    util = dofile("HEMS_Dispatch/modules/util.lua"),
    geo = dofile("HEMS_Dispatch/modules/geo.lua"),
    config = {
        dispatch = {
            min_radius_km = 0,
            max_radius_km = 50,
            road_search_radius_km = 1,
            allow_single_lane_incidents = false,
            allow_highway_incidents = false,
        },
    },
}
local dsf = dofile("HEMS_Dispatch/modules/dsf.lua")
local prefix = "HEMS_Dispatch/tests/.hri-v3-test-"
local fake_dsf = prefix .. "tile.dsf"
local fake_hri = prefix .. "tile.hri"
local function write(path, body)
    local f = assert(io.open(path, "wb"))
    assert(f:write(body))
    f:close()
end
local function candidate(lat, lon, subtype)
    return HEMS.util.pack_i32(HEMS.util.round(lat * 1e7))
        .. HEMS.util.pack_i32(HEMS.util.round(lon * 1e7))
        .. HEMS.util.pack_u16(9000)
        .. string.char(subtype, HEMS.road_profiles.flags(HEMS.road_profile, subtype))
        .. HEMS.util.pack_u32(1)
        .. HEMS.util.pack_u32(2500)
end
write(fake_dsf, string.rep("x", 64))
HEMS.road_profile = HEMS.road_profiles.profiles.pro
local sig = assert(HEMS.util.file_footer_hex(fake_dsf, 16))
local function header(magic, profile)
    return table.concat({
        magic, "SOURCE " .. sig, "TILE +50+006", "SPACING 50", "PROFILE " .. profile,
        "CANDIDATES 3", "CHAINS 0", "DATA", "",
    }, "\n")
end
local records = candidate(50.928477, 6.086529, 80)
    .. candidate(50.928477, 6.086529, 74)
    .. candidate(50.928477, 6.086529, 70)
write(fake_hri, header("HEMSHRI 3", "pro-v1") .. records)
assert(dsf.cache_is_valid(fake_hri, fake_dsf, 50))
assert(not dsf.cache_is_valid(fake_hri, fake_dsf, 25))
local found, total = dsf.select_candidates(
    fake_hri, 50.928477, 6.086529, 50.928477, 6.086529,
    "local", 10, { search_radius_km = 0.1, nearest_first = true, ignore_dispatch_radius = true }
)
assert(#found == 1 and total == 1 and found[1].subtype == 80)
assert(dsf.road_group_name(80) == "Local")
found, total = dsf.select_candidates(
    fake_hri, 50.928477, 6.086529, 50.928477, 6.086529,
    "single", 10, { search_radius_km = 0.1, ignore_dispatch_radius = true }
)
assert(#found == 0 and total == 0)
HEMS.road_profile = HEMS.road_profiles.profiles.standard
assert(not dsf.cache_is_valid(fake_hri, fake_dsf, 50))
assert(dsf.road_group_name(80) == "Unknown")
-- An actual v1.1.3 header had no PROFILE line.
write(fake_hri, table.concat({
    "HEMSHRI 2", "SOURCE " .. sig, "TILE +50+006", "SPACING 50",
    "CANDIDATES 3", "CHAINS 0", "DATA", "",
}, "\n") .. records)
assert(not dsf.cache_is_valid(fake_hri, fake_dsf, 50))
os.remove(fake_hri)
os.remove(fake_dsf)
print("PASS: HRI-v3 profile invalidation, old HRI rejection, Pro medical local 80, footway exclusion")
