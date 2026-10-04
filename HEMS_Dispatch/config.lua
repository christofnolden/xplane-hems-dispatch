-- HEMS Dispatch v1.0.16 configuration
-- This file can be reloaded from Plugins > HEMS Dispatch > Reload configuration.

return {
    dispatch = {
        min_radius_km = 5.0,
        max_radius_km = 50.0,

        -- The target distance is sampled uniformly between min/max radius:
        -- equally wide distance ranges have the same base probability.
        -- HEMS Dispatch then looks for a suitable SimHeaven road around that target.
        road_search_radius_km = 7.0,
        max_target_attempts = 15,

        -- Candidate points are sampled from the SimHeaven road centreline.
        -- Changing this value invalidates/rebuilds affected HRI cache files.
        candidate_spacing_m = 50,

        -- Local road path used for scene placement. Emergency vehicles follow
        -- the actual SimHeaven road geometry at this resolution. This value
        -- does not change the 50 m mission-candidate cache density.
        scene_path_resolution_m = 2.0,

        -- Reject very steep/wet terrain after the SimHeaven road selection.
        max_slope_deg = 12.0,

        -- Highway and single-lane incidents are currently disabled.
        allow_highway_incidents = false,
        allow_single_lane_incidents = false,
    },

    missions = {
        {
            id = "medical",
            name = "Medical emergency",
            probability = 60,
            road_groups = {
                { id = "local", weight = 100 },
            },
            -- Any of the four emergency-unit types can be combined here:
            -- RTW, NEF, FIRE, POLICE
            -- Example for an optional police car:
            -- POLICE = { min = 0, max = 1 },
            units = {
                RTW = { min = 1, max = 1 },
            },
        },
        {
            id = "traffic_accident",
            name = "Traffic accident",
            probability = 40,
            road_groups = {
                { id = "primary",   weight = 35 },
                { id = "secondary", weight = 45 },
                { id = "local",     weight = 20 },
            },
            units = {
                RTW =    { min = 1, max = 3 },
                NEF =    { min = 1, max = 2 },
                FIRE =   { min = 2, max = 5 },
                POLICE = { min = 1, max = 2 },
            },
            include_crashed_vehicle = true,
        },
    },

    rescuex = {
        -- Explicit virtual RescueX paths from RescueX_Lib/library.txt.
        -- The library itself is NOT bundled with HEMS Dispatch.
        objects = {
            RTW = {
                "RescueX/cars/RTW_DRK_Bayern.obj",
                "RescueX/cars/RTW_ASB_1.obj",
                "RescueX/cars/RTW_ASB_2.obj",
                "RescueX/cars/RTW_FEU_GUT.obj",
            },
            NEF = {
                "RescueX/cars/NEF_Passat_sb1099.obj",
            },
            FIRE = {
                "RescueX/cars/FW_BF_Karlsruhe_HLF.obj",
                "RescueX/cars/FW_FF_Stuehlingen_RW1.obj",
                "RescueX/cars/FW_GEN_DLK.obj",
            },
            POLICE = {
                "RescueX/cars/Polizei_FuStw_01.obj",
            },
            CRASHED = {
                "RescueX/cars/Crashed_CLK.obj",
                "RescueX/cars/Crashed_Kia_Picanto.obj",
                "RescueX/cars/Crashed_Kia_Picanto2.obj",
                "RescueX/cars/Crashed_Opel_Insignia.obj",
            },
        },

        -- Small lateral offset from the SimHeaven road centreline.
        lateral_offset_m = 1.8,
        object_height_offset_m = 0.05,
    },

    moving_map = {
        -- Floating OpenStreetMap moving map (North-Up). Follow Aircraft keeps the
        -- helicopter centered; manual panning disables Follow until recentered.
        auto_open_on_new_mission = true,
        window_width = 620,
        window_height = 620,

        min_zoom = 10,
        max_zoom = 16,
        default_zoom = 14,

        -- Navigation geometry is updated at 10 Hz; ETA/text at 1 Hz. The ImGui
        -- window itself is rendered by FlyWithLua every frame, but these calculations
        -- and all tile-management work are throttled independently.
        nav_update_hz = 10,
        info_update_hz = 1,
        tile_prepare_interval_seconds = 0.5,

        -- Flight-track sampling. A position is considered at most every 0.5 s and
        -- stored only after at least 3 m movement from the previous recorded point.
        track_interval_seconds = 0.5,
        track_min_distance_m = 3.0,

        -- OpenStreetMap standard tile server. Keep attribution visible in the map.
        tile_url = "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
        user_agent = "HEMS-Dispatch/1.0.16 (X-Plane 12; FlyWithLua NG+)",

        -- curl is included with current Windows versions and commonly available on
        -- macOS/Linux. Downloads run asynchronously so X-Plane is not blocked.
        curl_executable = (SYSTEM == "IBM") and "curl.exe" or "curl",
        connect_timeout_seconds = 5,
        download_timeout_seconds = 15,
        max_concurrent_downloads = 4,
        download_launch_gap_seconds = 0.0,

        -- FlyWithLua owns loaded image textures and has no per-texture unload call.
        -- This limit prevents unbounded GPU-memory growth during very long sessions.
        max_loaded_textures = 384,
    },

    hospitals = {
        -- The Hospitals window initially displays the 50 km dataset.
        -- The 100 km dataset is used only after pressing Load more.
        initial_radius_km = 50,
        extended_radius_km = 100,

        -- Public OpenStreetMap Overpass API endpoint used for hospital POIs.
        overpass_url = "https://overpass-api.de/api/interpreter",
        user_agent = "HEMS-Dispatch/1.0.16 (X-Plane 12; FlyWithLua NG+)",

        curl_executable = (SYSTEM == "IBM") and "curl.exe" or "curl",
        connect_timeout_seconds = 5,
        request_timeout_seconds = 35,

        -- Successful hospital datasets are cached persistently. Reopening the
        -- Hospitals window only recalculates distances/sorting from the current
        -- helicopter position. A new Overpass request is made only with the
        -- explicit Reload hospital list action (or when no cache exists yet).
    },

    output = {
        coordinate_decimals = 5,
        auto_open_info_window = true,
        include_debug_details = true,
    },
}
