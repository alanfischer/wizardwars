class_name TriggerRelay
extends EntityBase
# trigger_relay — point entity that forwards a trigger to its target, with optional delay.
# trigger_auto — same, but fires automatically on spawn.

# Waypoint bake fast-forward: when set, positive relay delays collapse to a
# next-frame fire so a map's automatic round-start trigger chains (e.g. ww_chasm's
# ~30s wall timer) settle during the bake's short frame pump instead of in real
# time. One hop per frame keeps a self-re-triggering chain from running away. Set
# by WaypointBake.run() before the map loads; the process quits after.
static var bake_fast_forward := false

var _target_key: String
var _delay_time: float
var _is_auto: bool = false


func _ready() -> void:
	super()
	_target_key = ent.get("target", "")
	_delay_time = parse_float(ent, "delay", 0.0)
	_is_auto = ent.get("classname", "") == "trigger_auto"

	if _is_auto:
		# Fire on spawn — defer to next frame so all entities are registered first
		if _delay_time > 0:
			_schedule_fire(null)
		else:
			_fire_target.call_deferred(null)


func trigger(activator: Node, _type: TriggerSystem.Type) -> void:
	# Host-only: downstream target is broadcast by the host via TriggerSystem,
	# so clients don't need to create local timers or fire targets.
	if _is_network_client():
		return
	if _delay_time > 0:
		_schedule_fire(activator)
	else:
		_fire_target(activator)


func _schedule_fire(activator: Node) -> void:
	var a := activator
	if bake_fast_forward:
		# One hop per physics frame. A callback connected during a signal's emission fires on the
		# NEXT emission, so a self-re-triggering or periodic relay advances one step per frame instead
		# of cascading within a single frame (which would hang the bake). The frame pump then settles
		# the chain; a never-terminating loop just fires harmlessly once per pumped frame.
		get_tree().physics_frame.connect(
			func():
				if is_instance_valid(self): _fire_target(a if is_instance_valid(a) else null),
			CONNECT_ONE_SHOT)
		return
	get_tree().create_timer(_delay_time).timeout.connect(
		func():
			if not is_instance_valid(self): return
			_fire_target(a if is_instance_valid(a) else null),
		CONNECT_ONE_SHOT)


func _fire_target(activator: Node) -> void:
	if not _target_key.is_empty():
		TriggerSystem.fire(_target_key, activator, TriggerSystem.Type.TOGGLE)
