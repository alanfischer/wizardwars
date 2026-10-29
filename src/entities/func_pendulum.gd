class_name FuncPendulum
extends EntityBase
# func_pendulum — oscillating brush entity (swinging signs, pendulums).

const SF_START_OFF := 1

var _axis: Vector3
var _distance: float  # max angle in radians
var _speed: float     # oscillation rate (degrees/sec from entity)
var _active := true
var _time := 0.0
var _base_rotation: Vector3


func _ready() -> void:
	super()
	var spawnflags := parse_spawnflags(ent)
	_speed = parse_float(ent, "speed", 100.0)
	_distance = deg_to_rad(parse_float(ent, "distance", 90.0))
	_axis = parse_rotation_axis(spawnflags)

	if spawnflags & SF_START_OFF:
		_active = false

	_anim_body.sync_to_physics = false
	# Importer places the node at the ORIGIN-brush pivot; geometry is local.
	_base_rotation = rotation
	_register_for_sync()
	EntityRender.apply_render_properties(self, ent)


func _physics_process(delta: float) -> void:
	# Client: body transforms come from host sync
	if _is_network_client():
		return
	if not _active:
		return
	_time += delta
	var angle := _distance * sin(_time * _speed * TAU / 360.0)
	rotation = _base_rotation + _axis * angle
	flush_mover_transform()


func trigger(_activator: Node, _type: TriggerSystem.Type) -> void:
	# Client: body transforms come from host sync
	if _is_network_client():
		return
	_active = not _active
