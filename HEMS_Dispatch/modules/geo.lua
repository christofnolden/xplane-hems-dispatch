local M = {}

local R_KM = 6371.0088
local DEG = math.pi / 180
local RAD = 180 / math.pi
local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

local function norm_lon(lon)
    while lon > 180 do lon = lon - 360 end
    while lon < -180 do lon = lon + 360 end
    return lon
end

function M.distance_km(lat1, lon1, lat2, lon2)
    local p1 = lat1 * DEG
    local p2 = lat2 * DEG
    local dp = (lat2 - lat1) * DEG
    local dl = (lon2 - lon1) * DEG
    local a = math.sin(dp / 2)^2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2)^2
    return 2 * R_KM * math.asin(math.min(1, math.sqrt(a)))
end

function M.bearing_deg(lat1, lon1, lat2, lon2)
    local p1 = lat1 * DEG
    local p2 = lat2 * DEG
    local dl = (lon2 - lon1) * DEG
    local y = math.sin(dl) * math.cos(p2)
    local x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl)
    local brg = atan2(y, x) * RAD
    return (brg + 360) % 360
end

function M.destination(lat, lon, bearing_deg, distance_km)
    local p1 = lat * DEG
    local l1 = lon * DEG
    local brg = bearing_deg * DEG
    local d = distance_km / R_KM

    local p2 = math.asin(math.sin(p1) * math.cos(d) + math.cos(p1) * math.sin(d) * math.cos(brg))
    local l2 = l1 + atan2(
        math.sin(brg) * math.sin(d) * math.cos(p1),
        math.cos(d) - math.sin(p1) * math.sin(p2)
    )

    return p2 * RAD, norm_lon(l2 * RAD)
end

function M.offset_m(lat, lon, heading_deg, forward_m, right_m)
    local h = heading_deg * DEG
    local north_m = forward_m * math.cos(h) - right_m * math.sin(h)
    local east_m = forward_m * math.sin(h) + right_m * math.cos(h)

    local out_lat = lat + north_m / 111320.0
    local coslat = math.cos(lat * DEG)
    if math.abs(coslat) < 0.000001 then coslat = 0.000001 end
    local out_lon = lon + east_m / (111320.0 * coslat)
    return out_lat, norm_lon(out_lon)
end

-- Fast local approximation, intended for filtering candidates within a few dozen km.
function M.distance_sq_km_approx(lat1, lon1, lat2, lon2)
    local mean_lat = ((lat1 + lat2) * 0.5) * DEG
    local dy = (lat2 - lat1) * 111.32
    local dx = (lon2 - lon1) * 111.32 * math.cos(mean_lat)
    return dx * dx + dy * dy
end

function M.sample_annulus(min_km, max_km)
    -- Dispatch distance is deliberately uniform by radius, not by covered area.
    -- Every equally wide distance interval between min_km and max_km therefore
    -- has the same base probability (e.g. 10-20 km as 30-40 km).
    local distance_km = min_km + math.random() * (max_km - min_km)
    return distance_km, math.random() * 360.0
end

return M
