extends Node

## Runtime-tunable server vars, each exposed by its own chat command; host owns state and replicates via NetworkManager.sync_server_var.

## Fired for local or replicated changes; only needed by tunables that must reconfigure something, not just be read.
signal value_changed(key: String, value: Variant)

enum Type { INT, FLOAT, BOOL, STRING }

const _RESULT_OK := 0
const _RESULT_UNKNOWN := 1
const _RESULT_PARSE := 2

var _vars: Dictionary = {}  # key: String -> { value, default, type, replicate }


func _ready() -> void:
	_register_defaults()


func _register_defaults() -> void:
	register("hitscan_radius", 0.075, Type.FLOAT)  # ray fattening, sv_clienttrace-style
	register("golem_interp", true, Type.BOOL)  # true = client rebuilds limb pose locally instead of streaming each limb
	# Replicated: changes the geometry movement prediction runs against, so host/client must agree. See Main._apply_bsp_hulls.
	register("bsp_hulls", true, Type.BOOL)
	# Combo chaos: "auto" leaves it to the map (info_wwdetect "combo_chaos"), on/off force it
	# either way. Replicated so a client dresses the pickups the same as the host. See
	# GoalSystem.is_combo_chaos.
	register("combo_chaos", "auto", Type.STRING)
	# Whether allied wizards can clash staves for a combo spell (mp_allowcombos). See Staff._combo_swing.
	register("allow_combos", true, Type.BOOL)
	# Dead wizards ragdoll off their model's own MDL hitboxes. Three states in the one var:
	# "off" falls back to the six die_* clips in a body-sized box, which is what the corpse was
	# before; "box" builds the bones out of the hitboxes as they stand; "capsule" fits a capsule
	# inside each one instead, which is the shape Godot's own ragdolls use, kept so the two can
	# be watched side by side. Replicated: a client runs its own copy of the ragdoll and has to
	# build the same one. Read it through RagdollBuilder.mode(), never raw.
	register("ragdolls", "box", Type.STRING)
	# Aim skill every new bot is built with: 0 sloppy … 1 crack shot, scaling its reaction delay,
	# turn rate, aim wobble and how much of a moving target's motion it leads (BotBrain.setup).
	# Negative — the default — means each bot rolls its own, which is the mix bots always had.
	# Host-only: bot AI runs on the host and no client has any use for the number.
	register("bot_skill", -1.0, Type.FLOAT, false)
	# Co-op PvE: waves of monsters against an altar the wizards defend. Any map, no map declaration
	# — SiegeSystem derives the arena from what the map already has. Replicated so a client knows
	# which mode it is in; everything about the arena itself stays server-side.
	register("siege", false, Type.BOOL)
	# Match limits, both 0 = off. MatchSystem owns what happens when one is reached; they replicate
	# so a client can show how long is left without asking.
	register("timelimit", 20, Type.INT)  # minutes
	register("scorelimit", 0, Type.INT)  # team points
	register("fraglimit", 0, Type.INT)  # one player's frags (kills + objective points)


func register(key: String, default_value, type: int, replicate: bool = true) -> void:
	if _vars.has(key):
		push_warning("ServerVars: %s already registered" % key)
		return
	_vars[key] = {
		"value": default_value,
		"default": default_value,
		"type": type,
		"replicate": replicate,
	}


func has_key(key: String) -> bool:
	return _vars.has(key)


func get_value(key: String, fallback = null):
	var entry = _vars.get(key)
	if entry == null:
		return fallback
	return entry["value"]


func keys() -> Array:
	return _vars.keys()


## Returns {ok, value, error} for the caller to format.
func set_from_string(key: String, str_value: String) -> Dictionary:
	var entry = _vars.get(key)
	if entry == null:
		return {"ok": false, "error": "unknown var '%s'" % key}
	var parsed = _parse_value(str_value, entry["type"])
	if parsed == null:
		return {"ok": false, "error": "could not parse '%s' as %s" % [str_value, _type_name(entry["type"])]}
	entry["value"] = parsed
	if entry["replicate"] and NetworkManager.is_online() and NetworkManager.is_host():
		NetworkManager.sync_server_var.rpc(key, parsed)
	value_changed.emit(key, parsed)
	return {"ok": true, "value": parsed}


func apply_remote(key: String, value) -> void:
	var entry = _vars.get(key)
	if entry == null:
		return
	entry["value"] = value
	value_changed.emit(key, value)


func snapshot() -> Dictionary:
	var out := {}
	for k in _vars:
		var e = _vars[k]
		if e["replicate"]:
			out[k] = e["value"]
	return out


func _parse_value(s: String, type: int):
	match type:
		Type.INT:
			if not s.is_valid_int():
				return null
			return s.to_int()
		Type.FLOAT:
			if not s.is_valid_float():
				return null
			return s.to_float()
		Type.BOOL:
			var lower := s.to_lower()
			if lower in ["1", "true", "yes", "on"]:
				return true
			if lower in ["0", "false", "no", "off"]:
				return false
			return null
		Type.STRING:
			return s
	return null


func _type_name(type: int) -> String:
	match type:
		Type.INT: return "int"
		Type.FLOAT: return "float"
		Type.BOOL: return "bool"
		Type.STRING: return "string"
	return "?"
