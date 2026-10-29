class_name EnvShake
extends EntityBase
# env_shake — CShake: rattles the view of players near `origin` when triggered.
# ww_monoliths fires blue_boom/red_boom off its capture chain; ww_osaka's
# detshake rides a detpack.

const SF_GLOBAL_SHAKE := 1  # ignore radius — shake everyone on the map

var _amplitude: float
var _radius: float
var _duration: float
var _frequency: float


func _ready() -> void:
	super()
	_amplitude = parse_float(ent, "amplitude", 0.0)
	_duration = parse_float(ent, "duration", 0.0)
	_frequency = parse_float(ent, "frequency", 0.0)
	# Radius 0 is the "everyone" signal downstream, which is also what the
	# global-shake spawnflag wants.
	_radius = 0.0 if (parse_spawnflags(ent) & SF_GLOBAL_SHAKE) \
		else parse_float(ent, "radius", 0.0) * GameConsts.SCALE_FACTOR


func trigger(_activator: Node, _type: TriggerSystem.Type) -> void:
	if _is_network_client():
		return
	if _amplitude <= 0.0 or _duration <= 0.0:
		return
	NetworkManager.send_screen_shake(global_position, _amplitude, _radius, _duration, _frequency)
