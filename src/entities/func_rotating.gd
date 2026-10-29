class_name FuncRotating
extends EntityBase
# func_rotating — continuously rotating brush (fans, decorative objects).

# HL CFuncRotating spawnflags. The bit values differ from CFuncDoorRotating's,
# but the axis convention is the same one parse_rotation_axis already encodes:
# the flag names an *angles component* (pitch/yaw/roll), not a world axis. So
# "X Axis" is pitch — a spin about world Y — and the unflagged default is yaw,
# the ceiling fan. Taking the names literally tumbles wall-mounted discs and
# halos out of their own plane.
#
# Flag 1 is SF_BRUSH_ROTATE_INSTANT: set = spin from spawn, clear = idle until
# triggered. It is NOT a start-off flag; nearly every mapper sets it.
const SF_INSTANT := 1
const SF_REVERSE := 2
const SF_Z_AXIS := 4
const SF_X_AXIS := 8
const SF_ACCDCC := 16
const SF_NOT_SOLID := 64

# HL ramps the fan by max_speed * fanfriction once per 0.1s think.
const RAMP_THINKS_PER_SEC := 10.0

var _axis: Vector3
var _max_speed: float  # radians/sec at full tilt
var _speed := 0.0  # current radians/sec, ramping toward the commanded speed
var _friction: float  # fraction of max speed gained/shed per think
var _accdcc := false
var _spinning := false
var _base_position: Vector3


func _ready() -> void:
	super()
	var spawnflags := parse_spawnflags(ent)
	_max_speed = deg_to_rad(parse_float(ent, "speed", 100.0))
	# fanfriction is a percentage; HL clamps a missing/zero one to 100% (instant ramp).
	_friction = parse_float(ent, "fanfriction", 20.0) / 100.0
	if _friction <= 0.0:
		_friction = 1.0
	_accdcc = (spawnflags & SF_ACCDCC) != 0

	# Translate onto the door's flag bits so the pitch/yaw/roll → world axis
	# mapping (and its signs) stays in one place.
	var axis_flags := 0
	if spawnflags & SF_X_AXIS:
		axis_flags |= SF_ROTATE_X
	elif spawnflags & SF_Z_AXIS:
		axis_flags |= SF_ROTATE_Z
	if spawnflags & SF_REVERSE:
		axis_flags |= SF_ROTATE_BACKWARDS
	_axis = parse_rotation_axis(axis_flags)

	if spawnflags & SF_NOT_SOLID:
		var root: Node3D = self
		if root is CollisionObject3D:
			(root as CollisionObject3D).collision_layer = 0

	_spinning = (spawnflags & SF_INSTANT) != 0
	# Only an acc/dcc fan winds up; a plain rotator is at speed immediately.
	if _spinning and not _accdcc:
		_speed = _max_speed

	_anim_body.sync_to_physics = false
	# Importer places the node at the ORIGIN-brush pivot; geometry is local.
	_base_position = position
	_register_for_sync()
	EntityRender.apply_render_properties(self, ent)


func _physics_process(delta: float) -> void:
	# Client: body transforms come from host sync
	if _is_network_client():
		return
	_ramp_speed(delta)
	if _speed != 0.0:
		rotation += _axis * _speed * delta
		flush_mover_transform()


## HL SpinUp/SpinDown: the brush gains or sheds max_speed * fanfriction every
## 0.1s. Stopping always ramps — CFuncRotating::RotatingUse routes both the
## acc/dcc and the plain branch through SpinDown — so a rotator switched off
## coasts to a halt instead of freezing mid-turn.
func _ramp_speed(delta: float) -> void:
	var target := _max_speed if _spinning else 0.0
	if is_equal_approx(_speed, target):
		_speed = target
		return
	_speed = move_toward(_speed, target,
		absf(_max_speed) * _friction * RAMP_THINKS_PER_SEC * delta)


func trigger(_activator: Node, _type: TriggerSystem.Type) -> void:
	# Client: body transforms come from host sync
	if _is_network_client():
		return
	_spinning = not _spinning
	if _spinning and not _accdcc:
		_speed = _max_speed
