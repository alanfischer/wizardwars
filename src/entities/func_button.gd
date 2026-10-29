class_name FuncButton
extends FuncDoorBase
# func_button — pushable button brush entity.
# Mechanically identical to func_door but always auto-returns.
#
# Button spawnflags are NOT the door's: 1 is SF_BUTTON_DONTMOVE (fire without
# moving — the common case for wall runes/plaques), and 256 is
# SF_BUTTON_TOUCH_ONLY, the inverse of the door's SF_USE_ONLY: without it a
# button is +use / damage only, never touch.
const SF_DONTMOVE := 1
const SF_TOUCH_ONLY := 256

var move_dir: Vector3
var lip: float
var _shootable := false  # "health" key: any damage presses the button (CBaseButton::TakeDamage)


func _ready() -> void:
	super()
	_parse_common_properties(get_meta("entity", {}))
	# Buttons default to wait=1 (doors default to 3)
	wait_time = parse_float(ent, "wait", 1.0)
	move_dir = parse_movedir(ent)
	move_speed = parse_float(ent, "speed", 40.0) * GameConsts.SCALE_FACTOR
	# CBaseButton::Spawn defaults the lip to 4; CBaseDoor::Spawn leaves it at 0.
	lip = parse_float(ent, "lip", 4.0) * GameConsts.SCALE_FACTOR

	var aabb := _compute_brush_aabb()

	# Travel = projection of AABB onto move direction, minus lip
	var travel := absf(move_dir.dot(aabb.size)) - lip

	position1 = Vector3.ZERO
	position2 = Vector3.ZERO if (spawn_flags & SF_DONTMOVE) else move_dir * travel

	_build_body(aabb)
	position = _base_position + position1

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
	_linear_move(position2, callback)


func _move_closed(callback: Callable) -> void:
	_linear_move(position1, callback)


## CBaseButton has no Blocked handler, so a blocked button just stalls against
## whatever is in the way and finishes its move once that clears.
func _handle_blocked(_blocker: CharacterBody3D) -> void:
	_hold_for_blocker()
