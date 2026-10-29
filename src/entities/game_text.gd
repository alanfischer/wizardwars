class_name GameText
extends EntityBase
# game_text — HUD text message displayed on trigger.

const SF_ALL_PLAYERS := 1

var _message: String
var _x: float
var _y: float
var _channel: int
var _effect: int
var _color: Color
var _fadein: float
var _fadeout: float
var _holdtime: float
var _spawnflags: int
var _target_key: String


func _ready() -> void:
	super()

	_message = GoalMessages.translate(ent.get("message", ""))
	_x = parse_float(ent, "x", -1.0)
	_y = parse_float(ent, "y", -1.0)
	_channel = parse_int(ent, "channel", 0)
	_effect = parse_int(ent, "effect", 0)
	_fadein = parse_float(ent, "fadein", 0.0)
	_fadeout = parse_float(ent, "fadeout", 0.0)
	_holdtime = parse_float(ent, "holdtime", 2.0)
	_spawnflags = parse_spawnflags(ent)
	_target_key = ent.get("target", "")

	var color_str: String = ent.get("color", "255 255 255")
	_color = _parse_color_rgb(color_str)


func trigger(_activator: Node, _type: TriggerSystem.Type) -> void:
	if not _is_network_client():
		NetworkManager.sync_hud_text.rpc(_message, _channel,
			_color.r, _color.g, _color.b, _holdtime, true, _x, _y,
			_fadein, _fadeout, _effect)
	if not _target_key.is_empty():
		TriggerSystem.fire(_target_key, self, TriggerSystem.Type.TOGGLE)


static func _parse_color_rgb(s: String) -> Color:
	var parts := s.strip_edges().split(" ", false)
	var r := float(parts[0]) / 255.0 if parts.size() > 0 else 1.0
	var g := float(parts[1]) / 255.0 if parts.size() > 1 else 1.0
	var b := float(parts[2]) / 255.0 if parts.size() > 2 else 1.0
	return Color(r, g, b)
