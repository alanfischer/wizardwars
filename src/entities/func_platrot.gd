class_name FuncPlatRot
extends FuncDoorBase
# func_platrot — elevator platform that rotates while moving.
# Like func_plat but spins around the vertical (Y) axis during travel.
# "rotation" key = degrees/sec angular speed while the platform moves.
# No targetname: starts at bottom. Has targetname: starts at top.

# position1 = top, position2 = bottom

var _rot_speed: float  # degrees/second


func _ready() -> void:
	super()
	_parse_common_properties(get_meta("entity", {}))
	wait_time = parse_float(ent, "wait", 3.0)
	move_speed = parse_float(ent, "speed", 150.0) * GameConsts.SCALE_FACTOR
	_rot_speed = parse_float(ent, "rotation", 0.0)

	var aabb := _compute_brush_aabb()

	var height := parse_float(ent, "height", 0.0)
	if height == 0.0:
		height = aabb.size.y / GameConsts.SCALE_FACTOR - 8.0
	height *= GameConsts.SCALE_FACTOR

	# Importer places the node at the ORIGIN-brush pivot (the platform's top),
	# so _base_position is already the pivot; dests are relative to it.
	position1 = Vector3.ZERO
	position2 = Vector3(0, -height, 0)

	_build_body(aabb)

	if _has_targetname:
		position = _base_position + position1
		state = State.AT_TOP
		var touch_aabb := AABB(
			Vector3(aabb.position.x, aabb.position.y + aabb.size.y - 0.1, aabb.position.z),
			Vector3(aabb.size.x, 0.2, aabb.size.z)
		)
		_setup_touch_area(touch_aabb)
	else:
		position = _base_position + position2
		state = State.AT_BOTTOM
		var call_aabb := AABB(aabb.position, Vector3(aabb.size.x, aabb.size.y + height, aabb.size.z))
		_setup_touch_area(call_aabb)

	EntityRender.apply_render_properties(self, ent)


func _door_hit_top() -> void:
	state = State.AT_TOP
	_play_door_sound(_stop_sound)
	_fire_target()
	if not _has_targetname and wait_time >= 0.0:
		get_tree().create_timer(wait_time).timeout.connect(
			func():
				if is_instance_valid(self) and state == State.AT_TOP:
					_door_go_down(),
			CONNECT_ONE_SHOT)
	else:
		_enable_touch()


func _door_hit_bottom() -> void:
	state = State.AT_BOTTOM
	_play_door_sound(_stop_sound)
	_fire_target()
	_retouch()   # whoever it just landed under is still asking for it
	_enable_touch()


## Plats ride on touch or on a trigger, never on +use — and spawnflag 256 does
## not mean SF_USE_ONLY here, so don't inherit the door's rule.
func is_player_usable() -> bool:
	return false


func trigger(_activator: Node, _type: TriggerSystem.Type) -> void:
	if _is_network_client():
		return
	if state == State.AT_TOP:
		_door_go_down()


func _door_activate(_activator: Node3D = null) -> void:
	if _is_network_client():
		return
	if state == State.AT_BOTTOM:
		_door_go_up()
	elif state == State.AT_TOP and _has_targetname:
		_door_go_down()


func _door_go_up(_activator: Node3D = null) -> void:
	state = State.GOING_UP
	_disable_touch()
	_play_door_sound(_move_sound)
	_move_closed(_door_hit_top)


func _door_go_down() -> void:
	state = State.GOING_DOWN
	_disable_touch()
	_play_door_sound(_move_sound)
	_move_open(_door_hit_bottom)


func _move_open(callback: Callable) -> void:
	_linear_rotating_move(position2, callback)


func _move_closed(callback: Callable) -> void:
	_linear_rotating_move(position1, callback)


func _linear_rotating_move(dest_pos: Vector3, done_callback: Callable) -> void:
	var target_pos := _base_position + dest_pos
	var dist := (target_pos - position).length()
	if dist < 0.001:
		done_callback.call()
		return

	var duration := dist / move_speed
	var rot_delta := deg_to_rad(_rot_speed)
	var dest_rot := rotation + Vector3(0, rot_delta, 0)

	if _tween:
		_tween.kill()
	_tween = create_tween()
	_tween.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	_tween.set_parallel(true)
	_tween.tween_property(self, "position", target_pos, duration)
	_tween.tween_property(self, "rotation", dest_rot, duration)
	var dp := target_pos
	_tween.finished.connect(
		func(): position = dp; done_callback.call(),
		CONNECT_ONE_SHOT)
