extends Node

const Movement = preload("res://addons/pmove/movement.gd")

## Network-aware status effect manager: owns a StatusLogic instance plus RPC sync to clients.
## POISON: 2 dmg/sec indefinite, stops at 1 HP. BURNING: 2 dmg/sec for 5s or until healed/death. FROSTED: reduced friction, duration stacks.

const STATUS_SPRITES := {
	GameConsts.StatusType.POISON: "sprites/icons/yuck.spr",
	GameConsts.StatusType.BURNING: "sprites/fire.spr",
	GameConsts.StatusType.FROSTED: "sprites/animglow01.spr",
}

var _logic := StatusLogic.new()


func apply_status(target: Node, status_type: int) -> void:
	if _logic.apply_status(target, status_type):
		_sync_status_to_local_player(target, status_type, true)


## Logic-only frost apply, no re-sync: on the host's own view, apply_frost would re-enter via send_to_owner -> handler -> apply_frost forever.
func apply_frost_local(target: Node, duration: float) -> void:
	_logic.apply_frost(target, duration)


func apply_frost(target: Node, duration: float) -> void:
	var is_new := _logic.apply_frost(target, duration)
	if not NetworkManager.is_online() or not NetworkManager.is_host():
		return
	var peer_id: int = int(target.get("peer_id"))
	if peer_id == 0:
		return
	if peer_id > 0:  # bots (negative ids) have no owning client
		NetworkManager.send_to_owner(peer_id, &"sync_player_frost", [duration])
		if is_new:
			NetworkManager.send_to_owner(peer_id, &"sync_player_status",
				[GameConsts.StatusType.FROSTED])


func contribute_movement_modifiers(target: Node, mods: Movement.MovementModifiers) -> void:
	_logic.contribute_movement_modifiers(target, mods)


func get_friction_multiplier(target: Node) -> float:
	return _logic.get_friction_multiplier(target)


func clear_status(target: Node, status_type: int) -> void:
	if _logic.clear_status(target, status_type):
		_sync_status_to_local_player(target, status_type, false)


func reset() -> void:
	_logic._states.clear()


func clear_all(target: Node) -> void:
	var cleared := _logic.clear_all(target)
	for status_type in cleared["statuses"]:
		_sync_status_to_local_player(target, status_type, false)
	if cleared["frost"]:
		_sync_frost_clear(target)


func has_status(target: Node, status_type: int) -> bool:
	return _logic.has_status(target, status_type)


func tick(delta: float) -> void:
	var sync_events := _logic.tick(delta, NetworkManager.is_authority())
	for event in sync_events:
		if event.has("frost_clear"):
			_sync_frost_clear(event["target"])
		else:
			_sync_status_to_local_player(event["target"], event["status"], event["active"])


func on_damage_dealt(target: Node, damage_type: int, attacker: Node3D) -> void:
	if attacker and Teams.nodes_friendly(attacker, target):
		return
	match damage_type:
		GameConsts.DamageType.DEATH:
			apply_status(target, GameConsts.StatusType.POISON)
		GameConsts.DamageType.FIRE:
			apply_status(target, GameConsts.StatusType.BURNING)
		GameConsts.DamageType.ICE:
			apply_frost(target, StatusLogic.FROST_DURATION)


func _sync_status_to_local_player(target: Node, status_type: int, active: bool) -> void:
	if not NetworkManager.is_online() or not NetworkManager.is_host():
		return
	var peer_id: int = int(target.get("peer_id"))
	if peer_id == 0:
		return
	if peer_id > 0:  # bots (negative ids) have no owning client
		if active:
			NetworkManager.send_to_owner(peer_id, &"sync_player_status", [status_type])
		else:
			NetworkManager.send_to_owner(peer_id, &"sync_player_clear_status", [status_type])


func _sync_frost_clear(target: Node) -> void:
	if not NetworkManager.is_online() or not NetworkManager.is_host():
		return
	var peer_id: int = int(target.get("peer_id"))
	if peer_id == 0:
		return
	if peer_id > 0:
		NetworkManager.send_to_owner(peer_id, &"sync_player_clear_status",
			[GameConsts.StatusType.FROSTED])
