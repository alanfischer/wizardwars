class_name FuncDoor
extends FuncDoorBase
# func_door — sliding door brush entity.
# Ported from source/cpp/Components/DoorComponent.cpp.

var move_dir: Vector3
var lip: float


func _ready() -> void:
	super()
	_parse_common_properties(get_meta("entity", {}))
	move_dir = parse_movedir(ent)
	move_speed = parse_float(ent, "speed", 100.0) * GameConsts.SCALE_FACTOR
	lip = parse_float(ent, "lip", 0.0) * GameConsts.SCALE_FACTOR

	var aabb := _compute_brush_aabb()

	# Travel = projection of AABB onto move direction, minus lip
	var travel := absf(move_dir.dot(aabb.size)) - lip

	position1 = Vector3.ZERO
	position2 = move_dir * travel

	if spawn_flags & SF_START_OPEN:
		var tmp := position1
		position1 = position2
		position2 = tmp

	_build_body(aabb)
	position = _base_position + position1

	if not _has_targetname and not (spawn_flags & SF_USE_ONLY):
		_setup_touch_area(aabb)

	Log.debug("func_door '%s': dir=%s aabb_size=%s travel=%.3f speed=%.3f wait=%.1f lip=%.3f pos1=%s pos2=%s" % [
		name, move_dir, aabb.size, travel, move_speed, wait_time, lip, position1, position2])


func _move_open(callback: Callable) -> void:
	_linear_move(position2, callback)


func _move_closed(callback: Callable) -> void:
	_linear_move(position1, callback)
