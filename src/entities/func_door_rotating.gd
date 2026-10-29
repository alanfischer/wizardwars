class_name FuncDoorRotating
extends FuncDoorBase
# func_door_rotating — rotating door brush entity.
# Separate from func_door since movement is rotational, not translational.

var angle1: Vector3  # closed rotation (euler radians)
var angle2: Vector3  # open rotation (euler radians)
var _rot_axis: Vector3  # signed rotation axis (for computing push velocity)
var _base_angle2: Vector3  # original open angle (before player-side flip)
var _base_rot_axis: Vector3  # original rotation axis
var _is_yaw_door: bool  # only yaw doors get player-side flipping


func _ready() -> void:
	super()
	_parse_common_properties(get_meta("entity", {}))
	var distance := parse_float(ent, "distance", 90.0)
	rot_speed = parse_float(ent, "speed", 100.0)

	_rot_axis = parse_rotation_axis(spawn_flags)
	angle1 = Vector3.ZERO
	angle2 = _rot_axis * deg_to_rad(distance)
	_is_yaw_door = not (spawn_flags & (SF_ROTATE_X | SF_ROTATE_Z))

	if spawn_flags & SF_START_OPEN:
		var tmp := angle1
		angle1 = angle2
		angle2 = tmp

	_base_angle2 = angle2
	_base_rot_axis = _rot_axis

	# BSP compiler pre-centers vertices around the entity origin and the
	# importer places the node at that pivot, so root rotation is the door
	# motion. _base_position (captured in super._ready) is already the pivot.
	var aabb := _compute_brush_aabb()
	_build_body(aabb)
	rotation = _base_rotation + angle1

	if not _has_targetname and not (spawn_flags & SF_USE_ONLY):
		_setup_touch_area(aabb)


func _door_go_up(_activator: Node3D = null) -> void:
	# HL DoorGoUp: 2D cross product of (player->door) vs (player's walking direction)
	# picks swing side; yaw doors only. GoldSrc XY maps to Godot XZ (GS.x = -Godot.x/S,
	# GS.y = Godot.z/S), which is why the cross product below is vec.z/vec.x, not x/y.
	if _activator and is_instance_valid(_activator) and _is_yaw_door and state == State.AT_BOTTOM:
		var swing_dir := 1.0
		var vec := _activator.global_position - global_position
		var player_fwd := -_activator.global_transform.basis.z  # player forward in Godot
		var vnext := (_activator.global_position + player_fwd * 10.0) - global_position
		var cross := vec.z * vnext.x - vec.x * vnext.z
		if cross < 0:
			swing_dir = -1.0
		angle2 = _base_angle2 * swing_dir
		_rot_axis = _base_rot_axis * swing_dir
	super._door_go_up(_activator)


func _move_open(callback: Callable) -> void:
	_angular_move(angle2, callback)


func _move_closed(callback: Callable) -> void:
	_angular_move(angle1, callback)


## A rotating door's motion is angular, so its linear velocity stays zero and
## the SDK's compare (`pDoor->velocity == velocity && pDoor->avelocity ==
## velocity`) only passes for a sibling that is standing still — zero on every
## term. That sibling gets snapped onto this door's angles and stopped before
## it reverses.
func _blocked_realign(sibling: FuncDoorBase) -> void:
	if sibling.state == State.GOING_UP or sibling.state == State.GOING_DOWN:
		return
	if sibling._tween:
		sibling._tween.kill()
	sibling.rotation = rotation
