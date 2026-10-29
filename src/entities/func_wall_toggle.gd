class_name FuncWallToggle
extends EntityBase
# func_wall_toggle — brush entity that toggles visibility and collision.

const SF_START_OFF := 1


func _ready() -> void:
	super()
	_register_for_sync()
	var spawnflags := parse_spawnflags(ent)

	if spawnflags & SF_START_OFF:
		set_entity_visible(false)

	_record_initial_visible()


func trigger(_activator: Node, type: TriggerSystem.Type) -> void:
	match type:
		TriggerSystem.Type.ON: set_entity_visible(true)
		TriggerSystem.Type.OFF: set_entity_visible(false)
		TriggerSystem.Type.TOGGLE: set_entity_visible(not _game_visible)
	_sync_notify()
