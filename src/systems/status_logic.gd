class_name StatusLogic

const Movement = preload("res://addons/pmove/movement.gd")

## Pure status-effect logic. No static state, no autoload dependencies.
## StatusSystem owns one instance; tests create their own per test.

const POISON_DPS := 2.0
const BURN_DPS := 2.0
const BURN_DURATION := 5.0
const DOT_INTERVAL := 0.5
const FROST_FRICTION_MULT := 0.15
const FROST_DURATION := 1.0
const MAX_FROST_DURATION := 4.0

# Per-target state keyed by instance ID.
# Each entry: { poison: bool, burn_time: float, dot_timer: float, frost_time: float }
var _states: Dictionary = {}


## Returns true if this is a new application (caller should propagate it to the network layer).
func apply_status(target: Node, status_type: int) -> bool:
	var id := target.get_instance_id()
	if not _states.has(id):
		_states[id] = { "poison": false, "burn_time": 0.0, "dot_timer": 0.0, "frost_time": 0.0 }
	var state: Dictionary = _states[id]
	var was_active := _has_status(state, status_type)
	match status_type:
		GameConsts.StatusType.POISON:
			state["poison"] = true
		GameConsts.StatusType.BURNING:
			state["burn_time"] = BURN_DURATION
	if not was_active and target.has_method("show_status"):
		target.show_status(status_type)
	return not was_active


## Duration stacks additively, capped at MAX_FROST_DURATION. Returns true if this is the
## first frost application.
func apply_frost(target: Node, duration: float) -> bool:
	var id := target.get_instance_id()
	if not _states.has(id):
		_states[id] = { "poison": false, "burn_time": 0.0, "dot_timer": 0.0, "frost_time": 0.0 }
	var state: Dictionary = _states[id]
	var was_frosted: bool = state["frost_time"] > 0.0
	state["frost_time"] = min(state["frost_time"] + duration, MAX_FROST_DURATION)
	if not was_frosted and target.has_method("show_status"):
		target.show_status(GameConsts.StatusType.FROSTED)
	return not was_frosted


func contribute_movement_modifiers(target: Node, mods: Movement.MovementModifiers) -> void:
	var mult := get_friction_multiplier(target)
	mods.friction_scale = mult
	mods.accel_scale = mult


## Returns FROST_FRICTION_MULT if frosted, 1.0 otherwise.
func get_friction_multiplier(target: Node) -> float:
	var id := target.get_instance_id()
	if not _states.has(id):
		return 1.0
	if _states[id]["frost_time"] > 0.0:
		return FROST_FRICTION_MULT
	return 1.0


## Returns true if it was active (caller should sync).
func clear_status(target: Node, status_type: int) -> bool:
	var id := target.get_instance_id()
	if not _states.has(id):
		return false
	var state: Dictionary = _states[id]
	if not _has_status(state, status_type):
		return false
	match status_type:
		GameConsts.StatusType.POISON:
			state["poison"] = false
		GameConsts.StatusType.BURNING:
			state["burn_time"] = 0.0
		GameConsts.StatusType.FROSTED:
			state["frost_time"] = 0.0
	if target.has_method("hide_status"):
		target.hide_status(status_type)
	return true


## Clear all statuses. Returns { statuses: Array[int], frost: bool } of what was cleared.
func clear_all(target: Node) -> Dictionary:
	var id := target.get_instance_id()
	var cleared_statuses: Array[int] = []
	var frost_cleared := false
	if not _states.has(id):
		return { "statuses": cleared_statuses, "frost": false }
	var state: Dictionary = _states[id]
	if state["poison"]:
		state["poison"] = false
		cleared_statuses.append(GameConsts.StatusType.POISON)
		if target.has_method("hide_status"):
			target.hide_status(GameConsts.StatusType.POISON)
	if state["burn_time"] > 0.0:
		state["burn_time"] = 0.0
		cleared_statuses.append(GameConsts.StatusType.BURNING)
		if target.has_method("hide_status"):
			target.hide_status(GameConsts.StatusType.BURNING)
	if state["frost_time"] > 0.0:
		state["frost_time"] = 0.0
		frost_cleared = true
		if target.has_method("hide_status"):
			target.hide_status(GameConsts.StatusType.FROSTED)
	_states.erase(id)
	return { "statuses": cleared_statuses, "frost": frost_cleared }


func has_status(target: Node, status_type: int) -> bool:
	var id := target.get_instance_id()
	if not _states.has(id):
		return false
	return _has_status(_states[id], status_type)


## Tick all status effects. is_authority should be true on the host/offline client.
## Returns sync events for the caller to propagate to the network:
##   { "target": Node, "status": int, "active": bool }   — status changed
##   { "target": Node, "frost_clear": true }              — frost expired
func tick(delta: float, is_authority: bool) -> Array:
	var sync_events: Array = []
	var to_remove: Array[int] = []

	for id in _states:
		var state: Dictionary = _states[id]
		var target = instance_from_id(id)
		if not target or not is_instance_valid(target):
			to_remove.append(id)
			continue
		if target.get("is_dead"):
			to_remove.append(id)
			continue

		var has_dot := false

		if is_authority:
			if state["burn_time"] > 0.0:
				state["burn_time"] -= delta
				if state["burn_time"] <= 0.0:
					state["burn_time"] = 0.0
					if target.has_method("hide_status"):
						target.hide_status(GameConsts.StatusType.BURNING)
					sync_events.append({ "target": target,
						"status": GameConsts.StatusType.BURNING, "active": false })
				else:
					has_dot = true

			if state["poison"]:
				has_dot = true

		if state["frost_time"] > 0.0:
			state["frost_time"] -= delta
			if state["frost_time"] <= 0.0:
				state["frost_time"] = 0.0
				if is_authority:
					if target.has_method("hide_status"):
						target.hide_status(GameConsts.StatusType.FROSTED)
					sync_events.append({ "target": target, "frost_clear": true })

		if has_dot:
			state["dot_timer"] += delta
			if state["dot_timer"] >= DOT_INTERVAL:
				state["dot_timer"] -= DOT_INTERVAL
				if state["burn_time"] > 0.0 and target.has_method("take_damage"):
					target.take_damage(BURN_DPS * DOT_INTERVAL, GameConsts.DamageType.PHYSICAL, null)
				if state["poison"] and not target.get("is_dead"):
					var current_hp: float = target.get("health")
					if current_hp <= 1.0:
						state["poison"] = false
						if target.has_method("hide_status"):
							target.hide_status(GameConsts.StatusType.POISON)
						sync_events.append({ "target": target,
							"status": GameConsts.StatusType.POISON, "active": false })
					else:
						var poison_damage := POISON_DPS * DOT_INTERVAL
						if current_hp - poison_damage <= 1.0:
							target.take_damage(current_hp - 1.0, GameConsts.DamageType.PHYSICAL, null)
							state["poison"] = false
							if target.has_method("hide_status"):
								target.hide_status(GameConsts.StatusType.POISON)
							sync_events.append({ "target": target,
								"status": GameConsts.StatusType.POISON, "active": false })
						else:
							target.take_damage(poison_damage, GameConsts.DamageType.PHYSICAL, null)
		elif state["frost_time"] <= 0.0:
			to_remove.append(id)

	for id in to_remove:
		_states.erase(id)

	return sync_events


func _has_status(state: Dictionary, status_type: int) -> bool:
	match status_type:
		GameConsts.StatusType.POISON:
			return state["poison"]
		GameConsts.StatusType.BURNING:
			return state["burn_time"] > 0.0
		GameConsts.StatusType.FROSTED:
			return state["frost_time"] > 0.0
	return false
