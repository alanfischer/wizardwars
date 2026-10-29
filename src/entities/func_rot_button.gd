class_name FuncRotButton
extends FuncDoorBase
# func_rot_button — button that rotates instead of sliding (HL CRotButton).
# Like func_button it always auto-returns; like func_door_rotating it spins
# around the axis picked by the rotate spawnflags, `distance` degrees.
#
# Spawnflags are the button's, not the door's: 1 is SF_ROTBUTTON_NOTSOLID and
# 256 is SF_BUTTON_TOUCH_ONLY (without it the button is +use / damage only).
const SF_NOTSOLID := 1
const SF_TOUCH_ONLY := 256

var angle1: Vector3  # unpressed rotation (euler radians)
var angle2: Vector3  # pressed rotation
var _rot_axis: Vector3
var _shootable := false  # "health" key: any damage presses the button


func _ready() -> void:
	super()
	_parse_common_properties(get_meta("entity", {}))
	# Buttons default to wait=1 (doors default to 3)
	wait_time = parse_float(ent, "wait", 1.0)
	rot_speed = parse_float(ent, "speed", 100.0)

	_rot_axis = parse_rotation_axis(spawn_flags)
	angle1 = Vector3.ZERO
	angle2 = _rot_axis * deg_to_rad(parse_float(ent, "distance", 90.0))

	var aabb := _compute_brush_aabb()
	_build_body(aabb)
	rotation = _base_rotation + angle1

	if spawn_flags & SF_NOTSOLID:
		_anim_body.collision_layer = 0
		_anim_body.collision_mask = 0

	_shootable = parse_float(ent, "health", 0.0) > 0.0
	if spawn_flags & SF_TOUCH_ONLY:
		_setup_touch_area(aabb)

	EntityRender.apply_render_properties(self, ent)


## CBaseButton::ObjectCaps — a button is +usable unless it has a "health" key,
## in which case it is shot, not pressed. (Touch-only buttons stay +usable too.)
func is_player_usable() -> bool:
	return not _shootable


func _door_hit_top() -> void:
	state = State.AT_TOP
	_fire_target()
	# Buttons always return after wait (no SF_NO_AUTO_RETURN check)
	if wait_time >= 0.0:
		get_tree().create_timer(wait_time).timeout.connect(
			func():
				if is_instance_valid(self) and state == State.AT_TOP:
					_door_go_down(),
			CONNECT_ONE_SHOT)


## A button with a "health" key is pressed by any hit, whatever the amount —
## the health pool is never depleted, so shooting it repeatedly keeps working.
func take_damage(_amount: float, _type: int = GameConsts.DamageType.PHYSICAL,
		attacker: Node3D = null) -> void:
	if not _shootable or _is_network_client():
		return
	if not _check_team(attacker):
		return
	# Deferred for the same reason the touch path is: moving an AnimatableBody3D
	# from inside a physics query re-enters the physics server mid-step.
	call_deferred("_door_activate", attacker)


func _move_open(callback: Callable) -> void:
	_angular_move(angle2, callback)


func _move_closed(callback: Callable) -> void:
	_angular_move(angle1, callback)


## CBaseButton has no Blocked handler, so a blocked button just stalls against
## whatever is in the way and finishes its move once that clears.
func _handle_blocked(_blocker: CharacterBody3D) -> void:
	_hold_for_blocker()
