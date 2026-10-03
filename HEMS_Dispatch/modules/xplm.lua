local M = {}

local ffi = require("ffi")
local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

ffi.cdef[[
typedef void * XPLMDataRef;
typedef void * XPLMProbeRef;
typedef void * XPLMObjectRef;
typedef void * XPLMInstanceRef;
typedef void * XPLMMenuID;
typedef void * XPLMCommandRef;

typedef struct {
    int structSize;
    float locationX;
    float locationY;
    float locationZ;
    float normalX;
    float normalY;
    float normalZ;
    float velocityX;
    float velocityY;
    float velocityZ;
    int is_wet;
} XPLMProbeInfo_t;

typedef struct {
    int structSize;
    float x;
    float y;
    float z;
    float pitch;
    float heading;
    float roll;
} XPLMDrawInfo_t;

typedef void (*XPLMLibraryEnumerator_f)(const char * inFilePath, void * inRef);

void XPLMWorldToLocal(double inLatitude, double inLongitude, double inAltitude,
                      double * outX, double * outY, double * outZ);
void XPLMLocalToWorld(double inX, double inY, double inZ,
                      double * outLatitude, double * outLongitude, double * outAltitude);

XPLMProbeRef XPLMCreateProbe(int inProbeType);
void XPLMDestroyProbe(XPLMProbeRef inProbe);
int XPLMProbeTerrainXYZ(XPLMProbeRef inProbe, float inX, float inY, float inZ,
                        XPLMProbeInfo_t * outInfo);

int XPLMLookupObjects(const char * inPath, float inLatitude, float inLongitude,
                      XPLMLibraryEnumerator_f enumerator, void * ref);
XPLMObjectRef XPLMLoadObject(const char * inPath);
void XPLMUnloadObject(XPLMObjectRef inObject);

XPLMInstanceRef XPLMCreateInstance(XPLMObjectRef obj, const char ** datarefs);
void XPLMDestroyInstance(XPLMInstanceRef instance);
void XPLMInstanceSetPosition(XPLMInstanceRef instance,
                             const XPLMDrawInfo_t * new_position,
                             const float * data);

XPLMMenuID XPLMFindPluginsMenu(void);
XPLMMenuID XPLMCreateMenu(const char * inName, XPLMMenuID inParentMenu,
                          int inParentItem, void * inHandler, void * inMenuRef);
void XPLMDestroyMenu(XPLMMenuID inMenuID);
int XPLMAppendMenuItem(XPLMMenuID inMenu, const char * inItemName,
                       void * inItemRef, int inDeprecatedAndIgnored);
void XPLMAppendMenuSeparator(XPLMMenuID inMenu);
int XPLMAppendMenuItemWithCommand(XPLMMenuID inMenu, const char * inItemName,
                                  XPLMCommandRef inCommandToExecute);
void XPLMRemoveMenuItem(XPLMMenuID inMenu, int inIndex);
XPLMCommandRef XPLMFindCommand(const char * inName);
]]

M.ffi = ffi
M.lib = nil
M.probe = nil
M.lookup_callback = nil
M.lookup_result = nil
M.null_drefs = ffi.new("const char *[1]")
M.dummy_instance_data = ffi.new("float[1]", 0.0)

local function xplm_library_name()
    if SYSTEM == "IBM" then
        return "XPLM_64"
    elseif SYSTEM == "LIN" then
        return "Resources/plugins/XPLM_64.so"
    elseif SYSTEM == "APL" then
        return "Resources/plugins/XPLM.framework/XPLM"
    end
    return nil
end

function M.init()
    if M.lib then return true end

    local libname = xplm_library_name()
    if not libname then
        return false, "Unsupported operating system: " .. tostring(SYSTEM)
    end

    local ok, lib_or_error = pcall(ffi.load, libname)
    if not ok then
        return false, tostring(lib_or_error)
    end
    M.lib = lib_or_error

    M.probe = M.lib.XPLMCreateProbe(0) -- xplm_ProbeY
    if M.probe == nil then
        M.lib = nil
        return false, "XPLMCreateProbe() lieferte NULL."
    end

    M.lookup_callback = ffi.cast("XPLMLibraryEnumerator_f", function(inFilePath, inRef)
        if M.lookup_result == nil and inFilePath ~= nil then
            M.lookup_result = ffi.string(inFilePath)
        end
    end)

    return true
end

function M.world_to_local(lat, lon, alt_m)
    local x = ffi.new("double[1]")
    local y = ffi.new("double[1]")
    local z = ffi.new("double[1]")
    M.lib.XPLMWorldToLocal(lat, lon, alt_m or 0.0, x, y, z)
    return tonumber(x[0]), tonumber(y[0]), tonumber(z[0])
end

function M.local_to_world(x, y, z)
    local lat = ffi.new("double[1]")
    local lon = ffi.new("double[1]")
    local alt = ffi.new("double[1]")
    M.lib.XPLMLocalToWorld(x, y, z, lat, lon, alt)
    return tonumber(lat[0]), tonumber(lon[0]), tonumber(alt[0])
end

local function probe_local(x, y, z)
    local info = ffi.new("XPLMProbeInfo_t[1]")
    info[0].structSize = ffi.sizeof("XPLMProbeInfo_t")

    local result = M.lib.XPLMProbeTerrainXYZ(M.probe, x, y, z, info)
    if result ~= 0 then
        return nil, "Terrain-Probe lieferte Status " .. tostring(result)
    end

    return {
        x = tonumber(info[0].locationX),
        y = tonumber(info[0].locationY),
        z = tonumber(info[0].locationZ),
        normal_x = tonumber(info[0].normalX),
        normal_y = tonumber(info[0].normalY),
        normal_z = tonumber(info[0].normalZ),
        is_wet = tonumber(info[0].is_wet) ~= 0,
    }
end

function M.probe_world(lat, lon, max_slope_deg)
    if not M.probe then return nil, "Terrain probe is not initialized." end

    -- IMPORTANT:
    -- X-Plane's local +Y axis is only truly vertical at the local-coordinate origin.
    -- Therefore X/Z obtained from WorldToLocal(lat, lon, 10000 m) are NOT the same
    -- X/Z as the ground point at the same geographic lat/lon when the target is some
    -- distance from that origin. Reusing high-altitude X/Z values for the ground
    -- probe can therefore hit terrain horizontally offset from the requested road
    -- coordinate.
    --
    -- Pass 1 keeps X/Z from the requested lat/lon at sea level and only raises local Y.
    local base_x, base_y, base_z = M.world_to_local(lat, lon, 0.0)
    local first, first_err = probe_local(base_x, base_y + 12000.0, base_z)
    if not first then return nil, first_err end

    -- Convert the first hit back to MSL altitude, then recompute X/Z at the REQUESTED
    -- geographic lat/lon near the actual terrain elevation. A second Y-probe removes
    -- the small residual caused by Earth's curvature/local-coordinate geometry.
    local _, _, terrain_alt = M.local_to_world(first.x, first.y, first.z)
    local target_x, target_y, target_z = M.world_to_local(lat, lon, terrain_alt)
    local info, second_err = probe_local(target_x, target_y + 1500.0, target_z)
    if not info then return nil, second_err end

    if info.is_wet then
        return nil, "Water surface"
    end

    local ny = math.max(-1.0, math.min(1.0, info.normal_y))
    local slope = math.deg(math.acos(ny))
    if max_slope_deg and slope > max_slope_deg then
        return nil, string.format("Terrain slope %.1f° > %.1f°", slope, max_slope_deg)
    end

    local hit_lat, hit_lon, hit_alt = M.local_to_world(info.x, info.y, info.z)
    local position_error_m = nil
    if HEMS and HEMS.geo then
        position_error_m = HEMS.geo.distance_km(lat, lon, hit_lat, hit_lon) * 1000.0
    end

    return {
        x = info.x,
        y = info.y,
        z = info.z,
        normal_x = info.normal_x,
        normal_y = info.normal_y,
        normal_z = info.normal_z,
        slope_deg = slope,
        hit_lat = hit_lat,
        hit_lon = hit_lon,
        hit_alt_m = hit_alt,
        position_error_m = position_error_m,
    }
end

function M.local_heading(lat, lon, true_heading_deg)
    local lat2, lon2 = HEMS.geo.destination(lat, lon, true_heading_deg, 0.02) -- 20 m
    local x1, _, z1 = M.world_to_local(lat, lon, 0.0)
    local x2, _, z2 = M.world_to_local(lat2, lon2, 0.0)
    local dx = x2 - x1
    local dz = z2 - z1
    local h = math.deg(atan2(dx, -dz))
    return (h + 360.0) % 360.0
end

function M.lookup_library_object(virtual_path, lat, lon)
    M.lookup_result = nil
    local count = M.lib.XPLMLookupObjects(virtual_path, lat, lon, M.lookup_callback, nil)
    if count <= 0 or M.lookup_result == nil then
        return nil, "Library path not found: " .. tostring(virtual_path)
    end
    return M.lookup_result
end

function M.load_object(real_path)
    local obj = M.lib.XPLMLoadObject(real_path)
    if obj == nil then
        return nil, "XPLMLoadObject fehlgeschlagen: " .. tostring(real_path)
    end
    return obj
end

function M.create_instance(object_ref)
    local inst = M.lib.XPLMCreateInstance(object_ref, M.null_drefs)
    if inst == nil then return nil, "XPLMCreateInstance lieferte NULL." end
    return inst
end

-- Convert X-Plane's local terrain normal into the pitch/roll Euler angles needed
-- by XPLMDrawInfo_t while keeping the already determined road heading as yaw.
--
-- X-Plane object axes are: +X right, +Y up, -Z forward. XPLMDrawInfo applies
-- roll, then pitch, then heading. We therefore rotate the terrain normal back by
-- the chosen heading and solve the remaining pitch/roll from that heading-local
-- vector. This makes the object's +Y axis coincide with the terrain normal.
function M.terrain_pitch_roll(terrain, local_heading)
    local nx = tonumber(terrain.normal_x) or 0.0
    local ny = tonumber(terrain.normal_y) or 1.0
    local nz = tonumber(terrain.normal_z) or 0.0

    local length = math.sqrt(nx * nx + ny * ny + nz * nz)
    if length < 1e-6 then
        return 0.0, 0.0
    end

    nx = nx / length
    ny = ny / length
    nz = nz / length

    local heading_rad = math.rad(local_heading or 0.0)
    local ch = math.cos(heading_rad)
    local sh = math.sin(heading_rad)

    -- Components of the terrain normal in the vehicle frame after removing yaw:
    -- +X = vehicle right, +Y = vehicle up, +Z = vehicle tail.
    local normal_right = nx * ch + nz * sh
    local normal_up = ny
    local normal_tail = -nx * sh + nz * ch

    -- Robust Euler solution. For the configured road-slope limits we remain far
    -- away from the singularity at +/-90 degrees.
    local roll = math.deg(atan2(
        normal_right,
        math.sqrt(math.max(0.0, normal_up * normal_up + normal_tail * normal_tail))
    ))
    local pitch = math.deg(atan2(normal_tail, normal_up))

    return pitch, roll
end

function M.set_instance_position(instance, terrain, local_heading, height_offset_m)
    local pitch, roll = M.terrain_pitch_roll(terrain, local_heading)
    local offset = height_offset_m or 0.0

    local nx = tonumber(terrain.normal_x) or 0.0
    local ny = tonumber(terrain.normal_y) or 1.0
    local nz = tonumber(terrain.normal_z) or 0.0
    local normal_length = math.sqrt(nx * nx + ny * ny + nz * nz)
    if normal_length < 1e-6 then
        nx, ny, nz = 0.0, 1.0, 0.0
    else
        nx, ny, nz = nx / normal_length, ny / normal_length, nz / normal_length
    end

    local draw = ffi.new("XPLMDrawInfo_t[1]")
    draw[0].structSize = ffi.sizeof("XPLMDrawInfo_t")

    -- Apply the tiny anti-clipping offset along the terrain normal rather than
    -- along local +Y. On sloped ground this keeps the vehicle consistently above
    -- the surface after pitch/roll are applied.
    draw[0].x = terrain.x + nx * offset
    draw[0].y = terrain.y + ny * offset
    draw[0].z = terrain.z + nz * offset
    draw[0].pitch = pitch
    draw[0].heading = local_heading or 0.0
    draw[0].roll = roll

    M.lib.XPLMInstanceSetPosition(instance, draw, M.dummy_instance_data)
    return pitch, roll
end

function M.destroy_instance(instance)
    if M.lib and instance ~= nil then
        M.lib.XPLMDestroyInstance(instance)
    end
end

function M.unload_object(object_ref)
    if M.lib and object_ref ~= nil then
        M.lib.XPLMUnloadObject(object_ref)
    end
end

function M.shutdown()
    if M.probe and M.lib then
        M.lib.XPLMDestroyProbe(M.probe)
        M.probe = nil
    end
    if M.lookup_callback then
        M.lookup_callback:free()
        M.lookup_callback = nil
    end
    M.lib = nil
end

return M
