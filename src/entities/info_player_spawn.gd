class_name InfoPlayerSpawn
extends EntityBase
# info_player_spawn — player spawn point entity.
# Handles: info_player_start, info_player_spawn, info_player_teamspawn,
# i_p_t, info_player_deathmatch, info_dragonrider_spawn.
#
# Registers with SpawnSystem and supports trigger-based enable/disable
# for control point maps.

# GoldSrc player origin is at hull center (36 units up from feet).
# Godot CharacterBody3D position is at feet.
const _Y_OFFSET := 36.0 * GameConsts.SCALE_FACTOR

var team_no: int = 0
var goal_no: int = 0
var group_no: int = 0
var items: int = 0  # item_tfgoal goal_no to auto-give on spawn
func _ready() -> void:
	super()
	if ent.has("angle") or ent.has("angles"):
		rotation.y = parse_yaw(ent)
	team_no = parse_int(ent, "team_no", 0)
	goal_no = parse_int(ent, "goal_no", 0)
	group_no = parse_int(ent, "group_no", 0)
	items = parse_int(ent, "items", 0)
	SpawnSystem.register(self, goal_no, group_no)


func _exit_tree() -> void: 
	super()
	SpawnSystem.unregister(self)


## Returns player feet position (GoldSrc origin is hull center, Godot is feet).
func get_spawn_position() -> Vector3:
	return position - Vector3(0, _Y_OFFSET, 0)


func trigger(_activator: Node, type: TriggerSystem.Type) -> void:
	match type:
		TriggerSystem.Type.ON:
			SpawnSystem.restore_spawn(goal_no)
		TriggerSystem.Type.OFF:
			SpawnSystem.remove_spawn(goal_no)
		TriggerSystem.Type.TOGGLE:
			if SpawnSystem.is_spawn_disabled(goal_no):
				SpawnSystem.restore_spawn(goal_no)
			else:
				SpawnSystem.remove_spawn(goal_no)
