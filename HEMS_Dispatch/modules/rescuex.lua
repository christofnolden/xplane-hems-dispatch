local M = {}

M.instances = {}
M.model_cache = {}

local CONFIG_UNIT_ORDER = { "RTW", "NEF", "FIRE", "POLICE" }
local TRAFFIC_SCENE_SAFETY_MARGIN_M = 4.0

local CRASH_SLOTS = {
    { forward_m = 0.0,  lateral_factor = 0.0 },
    { forward_m = 5.5,  lateral_factor = 0.85 },
    { forward_m = -5.5, lateral_factor = -0.85 },
}

local function get_model(virtual_path, lat, lon)
    local cached = M.model_cache[virtual_path]
    if cached then return cached.object_ref end

    local real_path, lookup_err = HEMS.xplm.lookup_library_object(virtual_path, lat, lon)
    if not real_path then return nil, lookup_err end

    local obj, load_err = HEMS.xplm.load_object(real_path)
    if not obj then return nil, load_err end

    M.model_cache[virtual_path] = {
        object_ref = obj,
        real_path = real_path,
    }
    HEMS.log("RescueX loaded: " .. virtual_path .. " -> " .. real_path)
    return obj
end

local function spawn_object(unit_type, virtual_path, lat, lon, true_heading)
    local terrain, terrain_err = HEMS.xplm.probe_world(
        lat,
        lon,
        HEMS.config.dispatch.max_slope_deg
    )
    if not terrain then
        return nil, "Terrain invalid for " .. unit_type .. ": " .. tostring(terrain_err)
    end

    local obj, obj_err = get_model(virtual_path, lat, lon)
    if not obj then return nil, obj_err end

    local inst, inst_err = HEMS.xplm.create_instance(obj)
    if not inst then return nil, inst_err end

    local local_heading = HEMS.xplm.local_heading(lat, lon, true_heading)
    local pitch, roll = HEMS.xplm.set_instance_position(
        inst,
        terrain,
        local_heading,
        HEMS.config.rescuex.object_height_offset_m
    )

    HEMS.log(string.format(
        "Placing %s: Target=%.6f/%.6f | TerrainHit=%.6f/%.6f | Probe offset=%.2f m | Heading=%.1f° | Pitch=%.1f° | Roll=%.1f° | Slope=%.1f° | Object=%s",
        unit_type,
        lat, lon,
        terrain.hit_lat or lat, terrain.hit_lon or lon,
        terrain.position_error_m or 0.0,
        true_heading,
        pitch or 0.0,
        roll or 0.0,
        terrain.slope_deg or 0.0,
        virtual_path
    ))

    local entry = {
        instance = inst,
        unit_type = unit_type,
        virtual_path = virtual_path,
        lat = lat,
        lon = lon,
        heading = true_heading,
        terrain_hit_lat = terrain.hit_lat,
        terrain_hit_lon = terrain.hit_lon,
        probe_error_m = terrain.position_error_m,
        pitch = pitch,
        roll = roll,
        slope_deg = terrain.slope_deg,
    }
    M.instances[#M.instances + 1] = entry
    return entry
end

function M.destroy_scene()
    for _, entry in ipairs(M.instances) do
        pcall(HEMS.xplm.destroy_instance, entry.instance)
    end
    M.instances = {}
end

local function unit_count(definition)
    if not definition then return 0 end
    return HEMS.util.random_int(definition.min or 0, definition.max or definition.min or 0)
end

local function copy_counts(source)
    local out = {}
    for k, v in pairs(source or {}) do out[k] = v end
    return out
end

local function build_unit_queue(counts)
    local queue = {}
    for _, unit_type in ipairs(CONFIG_UNIT_ORDER) do
        local count = counts[unit_type] or 0
        for _ = 1, count do queue[#queue + 1] = unit_type end
    end
    return queue
end

function M.plan_scene(mission_def)
    local plan = {
        requested_counts = {},
        include_crashed_vehicle = mission_def.include_crashed_vehicle == true,
        crash_count = 0,
    }

    for unit_type, definition in pairs(mission_def.units or {}) do
        plan.requested_counts[unit_type] = unit_count(definition)
    end

    if plan.include_crashed_vehicle then
        local crash_pool = HEMS.config.rescuex.objects.CRASHED or {}
        plan.crash_count = HEMS.util.random_int(1, math.min(3, #crash_pool))
        plan.requested_counts.CRASHED = plan.crash_count
        HEMS.log(string.format("Crashed vehicles selected: %d", plan.crash_count))
    end

    plan.unit_queue = build_unit_queue(plan.requested_counts)
    return plan
end

local function build_crash_unit_slots(plan)
    local slots = {}
    local crash_count = plan.crash_count or 1
    local clearance = crash_count > 1 and 14 or 10

    local fire_count = plan.requested_counts.FIRE or 0
    for i = 1, fire_count do
        slots[#slots + 1] = {
            unit_type = "FIRE",
            forward_m = -clearance - (i - 1) * 8,
            side_index = i,
        }
    end

    local police_count = plan.requested_counts.POLICE or 0
    for i = 1, police_count do
        slots[#slots + 1] = {
            unit_type = "POLICE",
            forward_m = -clearance - fire_count * 8 - i * 8,
            side_index = fire_count + i,
        }
    end

    local rtw_count = plan.requested_counts.RTW or 0
    for i = 1, rtw_count do
        slots[#slots + 1] = {
            unit_type = "RTW",
            forward_m = clearance + (i - 1) * 8,
            side_index = i,
        }
    end

    local nef_count = plan.requested_counts.NEF or 0
    for i = 1, nef_count do
        slots[#slots + 1] = {
            unit_type = "NEF",
            forward_m = clearance + rtw_count * 8 + (i - 1) * 8,
            side_index = rtw_count + i,
        }
    end

    return slots
end

local function traffic_required_extents(plan)
    local negative = 0.0
    local positive = 0.0

    for i = 1, plan.crash_count or 0 do
        local slot = CRASH_SLOTS[i]
        if slot then
            if slot.forward_m < 0 then negative = math.max(negative, -slot.forward_m) end
            if slot.forward_m > 0 then positive = math.max(positive, slot.forward_m) end
        end
    end

    for _, slot in ipairs(build_crash_unit_slots(plan)) do
        if slot.forward_m < 0 then negative = math.max(negative, -slot.forward_m) end
        if slot.forward_m > 0 then positive = math.max(positive, slot.forward_m) end
    end

    return negative + TRAFFIC_SCENE_SAFETY_MARGIN_M,
        positive + TRAFFIC_SCENE_SAFETY_MARGIN_M
end

function M.required_path_extent(mission_def, plan)
    if mission_def.include_crashed_vehicle then
        local neg, pos = traffic_required_extents(plan)
        return math.max(neg, pos)
    end

    local count = #(plan.unit_queue or {})
    if count <= 1 then return 0.0 end
    return 10.0 + math.max(0, count - 2) * 8.0
end

local function direction_order(candidate)
    if candidate.one_way then return { 1 } end
    if math.random() < 0.5 then return { 1, -1 } end
    return { -1, 1 }
end

local function allocate_generic_slots(plan, road_path, scene_direction)
    local queue = plan.unit_queue or {}
    if #queue == 0 then return nil, "No emergency units planned." end

    local available_positive, available_negative = HEMS.dsf.path_availability(road_path, scene_direction)
    local slots = {
        { unit_type = queue[1], forward_m = 0.0, side_index = 1 },
    }

    local next_positive = 10.0
    local next_negative = 10.0

    for index = 2, #queue do
        local prefer_positive = ((index - 2) % 2) == 0
        local forward_m = nil

        if prefer_positive then
            if available_positive + 0.01 >= next_positive then
                forward_m = next_positive
                next_positive = next_positive + 8.0
            elseif available_negative + 0.01 >= next_negative then
                forward_m = -next_negative
                next_negative = next_negative + 8.0
            end
        else
            if available_negative + 0.01 >= next_negative then
                forward_m = -next_negative
                next_negative = next_negative + 8.0
            elseif available_positive + 0.01 >= next_positive then
                forward_m = next_positive
                next_positive = next_positive + 8.0
            end
        end

        if not forward_m then
            return nil, string.format(
                "Insufficient continuous road for %d emergency units (%.1f m forward, %.1f m backward available).",
                #queue, available_positive, available_negative
            )
        end

        slots[#slots + 1] = {
            unit_type = queue[index],
            forward_m = forward_m,
            side_index = index,
        }
    end

    return slots
end

local function crash_layout_fits(plan, road_path, scene_direction)
    local available_positive, available_negative = HEMS.dsf.path_availability(road_path, scene_direction)
    local required_negative, required_positive = traffic_required_extents(plan)
    return available_positive + 0.01 >= required_positive
        and available_negative + 0.01 >= required_negative,
        available_positive, available_negative, required_positive, required_negative
end

function M.plan_layout(mission_def, plan, candidate, road_path)
    local last_reason = nil

    for _, scene_direction in ipairs(direction_order(candidate)) do
        if mission_def.include_crashed_vehicle then
            local fits, available_positive, available_negative, required_positive, required_negative =
                crash_layout_fits(plan, road_path, scene_direction)
            if fits then
                return {
                    scene_direction = scene_direction,
                    unit_slots = build_crash_unit_slots(plan),
                }
            end
            last_reason = string.format(
                "Traffic accident requires %.1f/%.1f m of road path; %.1f/%.1f m are available.",
                required_negative, required_positive, available_negative, available_positive
            )
        else
            local slots, err = allocate_generic_slots(plan, road_path, scene_direction)
            if slots then
                return {
                    scene_direction = scene_direction,
                    unit_slots = slots,
                }
            end
            last_reason = err
        end
    end

    return nil, last_reason or "Road candidate does not provide enough continuous road path."
end

local function slot_centerline(road_path, layout, forward_m)
    return HEMS.dsf.path_point(road_path, forward_m, layout.scene_direction)
end

local function heading_toward_incident(local_scene_heading, forward_m, one_way)
    if one_way then return local_scene_heading end
    if forward_m > 0 then return (local_scene_heading + 180.0) % 360.0 end
    return local_scene_heading
end

local function add_unit(scene, candidate, road_path, layout, slot)
    local unit_type = slot.unit_type
    local pool = HEMS.config.rescuex.objects[unit_type]
    local virtual = HEMS.util.random_choice(pool)
    if not virtual then
        scene.errors[#scene.errors + 1] = "No RescueX objects configured for " .. unit_type .. "."
        return false
    end

    local center_lat, center_lon, local_scene_heading = slot_centerline(road_path, layout, slot.forward_m)
    if not center_lat then
        scene.errors[#scene.errors + 1] = "Road path could not be resolved for " .. unit_type .. "."
        return false
    end

    local lateral = HEMS.config.rescuex.lateral_offset_m or 0.0
    if slot.side_index % 2 == 0 then lateral = -lateral end
    local lat, lon = HEMS.geo.offset_m(center_lat, center_lon, local_scene_heading, 0.0, lateral)
    local heading = heading_toward_incident(local_scene_heading, slot.forward_m, candidate.one_way)

    local placed, err = spawn_object(unit_type, virtual, lat, lon, heading)
    if not placed then
        scene.errors[#scene.errors + 1] = tostring(err)
        HEMS.log("WARNING: " .. tostring(err))
        return false
    end

    scene.actual_counts[unit_type] = (scene.actual_counts[unit_type] or 0) + 1
    scene.used_objects[#scene.used_objects + 1] = virtual
    scene.emergency_count = scene.emergency_count + 1
    return true
end

local function crash_heading(local_scene_heading, index, one_way)
    local heading = local_scene_heading
    if not one_way and index % 2 == 0 then
        heading = (heading + 180.0) % 360.0
    end
    return (heading + math.random(-18, 18)) % 360.0
end

local function pick_unique_crash_models(pool, count)
    local available = {}
    for i, value in ipairs(pool or {}) do available[i] = value end

    local selected = {}
    for _ = 1, math.min(count, #available) do
        local index = math.random(1, #available)
        selected[#selected + 1] = table.remove(available, index)
    end
    return selected
end

local function spawn_crashed_vehicles(scene, candidate, plan, road_path, layout)
    local crash_pool = HEMS.config.rescuex.objects.CRASHED
    if type(crash_pool) ~= "table" or #crash_pool == 0 then
        scene.errors[#scene.errors + 1] = "No RescueX crashed vehicles configured."
        return 0
    end

    local models = pick_unique_crash_models(crash_pool, plan.crash_count or 1)
    local lateral_base = HEMS.config.rescuex.lateral_offset_m or 0.0
    local placed_count = 0

    for index, crash_virtual in ipairs(models) do
        local slot = CRASH_SLOTS[index] or CRASH_SLOTS[#CRASH_SLOTS]
        local center_lat, center_lon, local_scene_heading = slot_centerline(road_path, layout, slot.forward_m)
        if center_lat then
            local lateral_m = lateral_base * slot.lateral_factor
            local lat, lon = HEMS.geo.offset_m(center_lat, center_lon, local_scene_heading, 0.0, lateral_m)
            local heading = crash_heading(local_scene_heading, index, candidate.one_way)
            local placed, err = spawn_object("CRASHED", crash_virtual, lat, lon, heading)

            if placed then
                placed_count = placed_count + 1
                scene.used_objects[#scene.used_objects + 1] = crash_virtual
            else
                scene.errors[#scene.errors + 1] = tostring(err)
                HEMS.log("WARNING: Crashed vehicle not placed: " .. tostring(err))
            end
        else
            scene.errors[#scene.errors + 1] = "Road path for crashed vehicle could not be resolved."
        end
    end

    scene.actual_counts.CRASHED = placed_count
    return placed_count
end

function M.spawn_scene(mission_def, candidate, plan, road_path, layout)
    M.destroy_scene()

    local _, _, scene_heading = HEMS.dsf.path_point(road_path, 0.0, layout.scene_direction)
    scene_heading = scene_heading or candidate.heading

    local scene = {
        lat = candidate.lat,
        lon = candidate.lon,
        road_heading = scene_heading,
        actual_counts = {},
        requested_counts = copy_counts(plan.requested_counts),
        used_objects = {},
        errors = {},
        emergency_count = 0,
        scene_direction = layout.scene_direction,
    }

    if mission_def.include_crashed_vehicle then
        spawn_crashed_vehicles(scene, candidate, plan, road_path, layout)
    end

    for _, slot in ipairs(layout.unit_slots or {}) do
        add_unit(scene, candidate, road_path, layout, slot)
    end

    if scene.emergency_count <= 0 then
        M.destroy_scene()
        return nil, "No emergency units were placed for this mission."
    end

    return scene
end

function M.shutdown()
    M.destroy_scene()
    for virtual_path, model in pairs(M.model_cache) do
        if model.object_ref then
            pcall(HEMS.xplm.unload_object, model.object_ref)
        end
        M.model_cache[virtual_path] = nil
    end
end

return M
