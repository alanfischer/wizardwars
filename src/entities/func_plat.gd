class_name FuncPlat
extends FuncDoorBase
# func_plat — elevator platform brush entity.
# No targetname: starts at bottom, rises when player enters the travel zone.
#   Auto-returns to bottom after wait_time seconds at top.
# Has targetname: starts at top, descends when triggered.

# position1 = top, position2 = bottom


func _ready() -> void:
	super()
	_parse_common_properties(get_meta("entity", {}))
	wait_time = parse_float(ent, "wait", 3.0)
	move_speed = parse_float(ent, "speed", 150.0) * GameConsts.SCALE_FACTOR

	var aabb := _compute_brush_aabb()

	# Height: explicit "height" key, or AABB height minus 8 GoldSrc units
	var height := parse_float(ent, "height", 0.0)
	if height == 0.0:
		height = aabb.size.y / GameConsts.SCALE_FACTOR - 8.0
	height *= GameConsts.SCALE_FACTOR

	position1 = Vector3.ZERO
	position2 = Vector3(0, -height, 0)

	_build_body(aabb)

	if _has_targetname:
		# Triggered: start at top, player cannot call it — only external triggers move it
		position = _base_position + position1
		state = State.AT_TOP
		var touch_aabb := AABB(
			Vector3(aabb.position.x, aabb.position.y + aabb.size.y - 0.1, aabb.position.z),
			Vector3(aabb.size.x, 0.2, aabb.size.z)
		)
		_setup_touch_area(touch_aabb)
	else:
		# Freestanding: start at bottom, call trigger spans full vertical travel zone
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


func _door_hit_bottom() -> void:
	state = State.AT_BOTTOM
	_play_door_sound(_stop_sound)
	_fire_target()
	_retouch()   # whoever it just landed under is still asking for it


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
	_play_door_sound(_move_sound)
	_move_closed(_door_hit_top)


func _door_go_down() -> void:
	state = State.GOING_DOWN
	_play_door_sound(_move_sound)
	_move_open(_door_hit_bottom)


func _move_open(callback: Callable) -> void:
	_linear_move(position2, callback)


func _move_closed(callback: Callable) -> void:
	_linear_move(position1, callback)


## CFuncPlat::Blocked — a plat is not a door: it always crushes for 1 and always
## sends itself back where it came from, with no wait check and no gang.
func _handle_blocked(blocker: CharacterBody3D) -> void:
	_push_frames += 1
	if _push_frames < PUSH_GRACE_FRAMES:
		return
	_push_frames = 0
	if blocker and blocker.has_method("take_damage"):
		blocker.take_damage(1.0)
	if state == State.GOING_UP:
		_door_go_down()
	elif state == State.GOING_DOWN:
		_door_go_up()
