class_name EnvFade
extends EntityBase
# env_fade — screen color fade effect (gas clouds, teleport flashes, etc.)

const SF_FADE_FROM := 1        # start at full color and fade out (reverse)
const SF_MODULATE := 2         # modulate (multiply) instead of additive blend
const SF_ACTIVATOR_ONLY := 4   # only affect the triggering player

var _color: Color
var _duration: float
var _holdtime: float
var _reverse: bool
var _activator_only: bool


func _ready() -> void:
	super()
	var rc := parse_color(ent.get("rendercolor", "0 0 0"))
	var ra := parse_int(ent, "renderamt", 255)
	_color = Color(rc.r, rc.g, rc.b, ra / 255.0)
	_duration = parse_float(ent, "duration", 2.0)
	_holdtime = parse_float(ent, "holdtime", 0.0)
	var spawnflags := parse_spawnflags(ent)
	_reverse = bool(spawnflags & SF_FADE_FROM)
	_activator_only = bool(spawnflags & SF_ACTIVATOR_ONLY)


func trigger(_activator: Node, _type: TriggerSystem.Type) -> void:
	if _is_network_client():
		return
	var target: Node = _activator if _activator_only else null
	NetworkManager.send_screen_fade(_color, _duration, _holdtime, _reverse, target)
