class_name MultiManager
extends EntityBase
# multi_manager — point entity that fires a sequence of targets at timed delays.
# Entity keys that aren't standard properties become target_name → delay_time pairs.
# When triggered, fires each target after its specified delay.

const SF_THREAD := 1  # SF_MULTIMAN_THREAD: each trigger runs its own copy of the sequence

# Standard entity keys that are NOT target+time pairs
const RESERVED_KEYS := [
	"classname", "targetname", "origin", "angles", "angle",
	"spawnflags", "model", "target", "team_no", "playerclass",
]

# Additional reserved keys set by the game layer (e.g. TFC goal keys)
static var extra_reserved_keys: PackedStringArray = []

var _targets: Array[Dictionary] = []  # [{name: String, time: float, type: TriggerSystem.Type}], sorted by time
var _running := false


func _ready() -> void:
	super()

	# Parse target+time pairs from unrecognized keys
	for key in ent.keys():
		if key in RESERVED_KEYS or key in extra_reserved_keys:
			continue
		var time_val := float(ent[key])
		# Strip '#' suffix used for deduplication or type override.
		# Numeric suffix (e.g., "target#1") is just dedup. Named suffixes set fire type:
		#   "target#off" → fire with Type.OFF
		#   "target#on"  → fire with Type.ON
		var target_name: String = key
		var fire_type: TriggerSystem.Type = TriggerSystem.Type.TOGGLE
		var hash_idx: int = key.find("#")
		if hash_idx >= 0:
			var suffix = key.substr(hash_idx + 1)
			target_name = key.substr(0, hash_idx)
			match suffix:
				"off": fire_type = TriggerSystem.Type.OFF
				"on":  fire_type = TriggerSystem.Type.ON
		_targets.append({"name": target_name, "time": time_val, "type": fire_type})

	_targets.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["time"] < b["time"]
	)


func trigger(activator: Node, _type: TriggerSystem.Type) -> void:
	# Host-only: each downstream target is broadcast individually by the host
	# via TriggerSystem, so clients don't need to create local timers.
	if _is_network_client():
		return
	# CMultiManager::ManagerUse clears its Use until the last target has fired, so a manager
	# without the thread flag ignores triggers while its sequence is still running.
	if _running:
		return
	var thread := (parse_spawnflags(ent) & SF_THREAD) != 0
	_running = not thread
	for i in _targets.size():
		var entry := _targets[i]
		var target_name: String = entry["name"]
		var delay: float = entry["time"]
		var fire_type: TriggerSystem.Type = entry.get("type", TriggerSystem.Type.TOGGLE)
		var last := i == _targets.size() - 1
		if delay <= 0:
			TriggerSystem.fire(target_name, activator, fire_type)
		else:
			# Local copies needed: GDScript lambdas capture by reference,
			# so without these the loop var would be shared across all closures.
			var t := target_name
			var a := activator
			var ft := fire_type
			get_tree().create_timer(delay).timeout.connect(
				func():
					if not is_instance_valid(self): return
					var act = a if is_instance_valid(a) else null
					TriggerSystem.fire(t, act, ft)
					if last and not thread:
						_running = false,
				CONNECT_ONE_SHOT
			)
	if _targets.is_empty() or _targets[-1]["time"] <= 0:
		_running = false
