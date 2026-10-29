class_name EnvSound
extends EntityBase
# env_sound — CEnvSound: applies a reverb "roomtype" while the listener is
# within `radius`. ww_countryside's caves (17) and ww_castlerush's dungeon (7)
# are the only users in the map set.
#
# GoldSrc polls this from the entity on a 0.25s think and lets whichever
# env_sound most recently claimed the player win; same here. Client-side only —
# a dedicated server has no listener.

const THINK_INTERVAL := 0.25

var _radius := 0.0
var _roomtype := 0
var _owns_listener := false
var _accum := 0.0


func _ready() -> void:
	super()
	_roomtype = parse_int(ent, "roomtype", 0)
	_radius = parse_float(ent, "radius", 0.0) * GameConsts.SCALE_FACTOR
	if _radius <= 0.0 or DisplayServer.get_name() == "headless":
		set_process(false)


func _process(delta: float) -> void:
	_accum += delta
	if _accum < THINK_INTERVAL:
		return
	_accum = 0.0

	# The audio listener rides the active camera, so that is the position that
	# decides which room we are standing in.
	var cam := get_viewport().get_camera_3d()
	var inside := cam != null and cam.global_position.distance_to(global_position) < _radius
	if inside == _owns_listener:
		return
	_owns_listener = inside
	if inside:
		SoundSystem.set_room_type(_roomtype, self)
	else:
		SoundSystem.release_room_type(self)


func _exit_tree() -> void:
	super()
	if _owns_listener:
		SoundSystem.release_room_type(self)
