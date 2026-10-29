class_name EnvRender
extends EntityBase
# env_render — point entity that changes render properties of its target on trigger.

func _ready() -> void:
	super()
	_register_for_sync()


func trigger(_activator: Node, _type: TriggerSystem.Type) -> void:
	var target_key: String = ent.get("target", "")
	if target_key.is_empty():
		return
	for node in TriggerSystem.get_nodes(target_key):
		if node is Node3D:
			EntityRender.apply_render_properties(node, ent)
	_sync_notify()


func _get_sync_state() -> Dictionary:
	if not _state_dirty:
		return {}
	return {
		"render_target": ent.get("target", ""),
		"renderamt": parse_int(ent, "renderamt", 0),
		"rendermode": parse_int(ent, "rendermode", 0),
		"rendercolor": ent.get("rendercolor", "255 255 255"),
	}


func _apply_sync_state(state: Dictionary) -> void:
	if "render_target" in state:
		var target_key: String = state["render_target"]
		for node in TriggerSystem.get_nodes(target_key):
			if node is Node3D:
				EntityRender.apply_render_properties(node, state)
