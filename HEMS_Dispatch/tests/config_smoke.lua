-- Validates unchanged mission road_groups and new optional edition semantics.
HEMS = {}
local mission = dofile("HEMS_Dispatch/modules/mission.lua")
local cfg = dofile("HEMS_Dispatch/config.lua")
assert(mission.validate_config(cfg))
assert(cfg.simheaven.edition == "standard")
assert(cfg.missions[1].road_groups[1].id == "local")
assert(cfg.missions[1].units.RTW.min == 1)
cfg.simheaven.edition = "pro"
assert(mission.validate_config(cfg))
cfg.simheaven = { road_scenery_folder = "simHeaven_X-WORLD-Pro_Europe-13-net3-roads" }
assert(mission.validate_config(cfg))
cfg.simheaven = { edition = "unknown" }
assert(not mission.validate_config(cfg))
cfg.simheaven = { edition = "pro", road_scenery_folder = "../bad" }
assert(not mission.validate_config(cfg))
cfg.simheaven = { edition = "pro" }
cfg.missions[1].road_groups[1].id = "footway"
assert(not mission.validate_config(cfg))
print("PASS: mission config compatibility and edition/group validation")
