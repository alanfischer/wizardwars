class_name EntityBehavior
extends RefCounted

var entity_id: int = -1
var is_host: bool = false
var _host: Node
var _anim_player: AnimationPlayer = null
var _bridge: NetInterpBridge = null


func initialize(host: Node, as_host: bool = true, anim_player: AnimationPlayer = null) -> void:
	_host = host
	is_host = as_host
	if anim_player:
		set_anim_player(anim_player)


## Safe to call multiple times. Hooks current_animation_changed, not animation_changed —
## the latter only fires for queued animations, not play(), and never published anything.
func set_anim_player(anim_player: AnimationPlayer) -> void:
	if _anim_player and is_instance_valid(_anim_player) \
			and _anim_player.current_animation_changed.is_connected(_publish_anim):
		_anim_player.current_animation_changed.disconnect(_publish_anim)
	_anim_player = anim_player
	# Null offline and for map entities (no synchronizer attached).
	_bridge = _host.get_node_or_null("NetInterp") as NetInterpBridge if _host else null
	if _bridge:
		_bridge.set_anim_player(_anim_player)
	if _anim_player and NetworkManager.is_authority():
		_anim_player.current_animation_changed.connect(_publish_anim)
		_publish_anim(_anim_player.current_animation)


## Uses the name the signal carries — current_animation isn't assigned yet when the
## signal first fires, so reading it back here would publish "".
func _publish_anim(anim_name: String) -> void:
	if _bridge:
		_bridge.net_anim = anim_name


## Safe to call multiple times.
func destroy() -> void:
	# Client replicas must not free themselves — that races the spawner's despawn RPC
	# (ERR_UNAUTHORIZED on a net_id that's already gone). No-op here instead.
	if _host.has_meta("_dyn_spawner_entity") and not NetworkManager.is_authority():
		return
	entity_id = -1
	_host.queue_free()


## One-shot state push the clients holding a replica must not miss — reliable, and parked for an
## entity a client doesn't have yet. No-op offline and before the entity has a network id.
func publish(state: Dictionary) -> void:
	if entity_id >= 0 and NetworkManager.is_online():
		NetworkManager.sync_entity_state.rpc(entity_id, state)


## A one-shot effect — a bite, an attack. The original sent these as temp entities and sounds:
## unreliable, to the PVS around `near` (MSG_PVS), or to everyone when `near` is INF (MSG_BROADCAST,
## and MSG_PAS, which the port has no set for). A client without the entity drops it.
func publish_event(event: Dictionary, near := Vector3.INF) -> void:
	if entity_id >= 0 and NetworkManager.is_online():
		NetworkManager.send_entity_event(entity_id, event, near)


## Publish where it died, then free it. Clients play the gibs or the burst at the spot the host saw
## rather than wherever their replica drifted. A death visual has to be a one-shot like this, or a
## detached node: anything with a duration would need the dying entity kept alive and its state
## replicated. An event (publish_event), as the original's death temp entities were, so one that
## loses the race with its own despawn is dropped rather than parked for an id that is gone.
##
## `extra` rides along for a death that has more to say than where it happened — a dragon sends
## which of its two deaths it was (Dragon._dragon_die). `pvs` keeps it to the PVS around `pos`.
func die_at(pos: Vector3, extra: Dictionary = {}, pvs := false) -> void:
	var state := {"death_pos": pos}
	state.merge(extra)
	publish_event(state, pos if pvs else Vector3.INF)
	destroy()


## Broadcasts sync state to clients. Host must implement _get_sync_state() -> Dictionary.
func sync_notify() -> void:
	if not NetworkManager.is_authority():
		return
	if entity_id < 0:
		return
	var state: Dictionary = _host.call("_get_sync_state")
	if not state.is_empty():
		NetworkManager.sync_entity_state.rpc(entity_id, state)
