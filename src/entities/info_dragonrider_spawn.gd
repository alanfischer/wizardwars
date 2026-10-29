class_name InfoDragonriderSpawn
extends InfoPlayerSpawn

## Spawn point that creates a fresh dragon for each rider on demand.
func spawn_dragon_for_rider() -> Node:
	if not NetworkManager.is_authority():
		return null
	var dragon := NetworkManager.spawn_dynamic_entity({
		"script_path": "res://src/monsters/dragon.gd",
		"sync_state": true,  # for the entity_id sync_dragon_mount addresses; state rides the snapshot
		"team_no": team_no,
	})
	if dragon:
		dragon.spawn_locked = true
		dragon.global_position = get_spawn_position()  # client gets it via the synchronizer
	return dragon
