class_name PlantBehavior
extends RefCounted

## The one beanstalk and one thornplant a nature wizard may have standing, plus the HUD bars
## the owner watches them on. Held by Player as `plants`.
##
## Tracked here and nowhere else: weapon instances are rebuilt on every respawn/class change
## but a plant survives its caster's death, so a weapon-local copy would desync. Plants are
## only cleared on a class change or a goal's destroy-plants edict.

const HUD_INTERVAL := 0.25

var beanstalk: Node3D
var thornplant: Node3D

## Last plant HP pushed to the owner's HUD (-1 = nothing shown).
var _hp_sent: Dictionary = {"beanstalk": -1.0, "thornplant": -1.0}
var _hud_timer := 0.0
var _host: Node

var has_beanstalk: bool:
	get: return beanstalk != null and is_instance_valid(beanstalk)

var has_thornplant: bool:
	get: return thornplant != null and is_instance_valid(thornplant)


func initialize(host: Node) -> void:
	_host = host


## The plant registry of a node that has one, or null — an attacker or a summon's owner is
## not always a player, and a client's LocalPlayer carries no plant state online.
##
## `node` is untyped on purpose: callers hand over an owner that may already be freed (a stalk
## outlives its caster), and GDScript refuses a freed object at ANY typed parameter — `Object`
## included, verified — which would drop the call before the is_instance_valid below could
## answer. Untyped is the only signature that lets this screen its own input.
static func of(node) -> PlantBehavior:
	return node.get("plants") if is_instance_valid(node) else null


func set_beanstalk(stalk: Node3D) -> void:
	beanstalk = stalk
	_notify_indicator("beanstalk", true)


func on_beanstalk_destroyed() -> void:
	beanstalk = null
	_notify_indicator("beanstalk", false)


func set_thornplant(plant: Node3D) -> void:
	thornplant = plant
	_notify_indicator("thornplant", true)


func on_thornplant_destroyed() -> void:
	thornplant = null
	_notify_indicator("thornplant", false)


## Every live player's plants, for the destroy-plants edict (a TF goal, PotatoC's RemovePlants).
static func remove_all_everywhere() -> void:
	for p in NetworkManager.player_roster().values():
		var p_plants := of(p)
		if p_plants:
			p_plants.remove_all()


## Destroy both plants (networked despawn + ref clear).
func remove_all() -> void:
	if has_beanstalk:
		beanstalk._kill_chain()
		beanstalk = null
	if has_thornplant:
		thornplant.destroy_plant()
		thornplant = null


## Authority-side poll that pushes plant health to the owner's HUD bars as the
## plants take damage and regen. Toggles ride _notify_indicator instead.
func tick_indicators(delta: float) -> void:
	_hud_timer -= delta
	if _hud_timer > 0.0:
		return
	_hud_timer = HUD_INTERVAL
	_refresh_indicator("beanstalk")
	_refresh_indicator("thornplant")


## Tell the owning client to show/hide/fill their persistent-plant HUD bar.
## These set/clear paths only run on the authoritative body; send_to_owner
## dispatches locally when the owner is this process (offline/host) and rpc_id's
## the remote client otherwise.
func _notify_indicator(kind: String, active: bool) -> void:
	var hp := _health(kind) if active else Vector2.ZERO
	_hp_sent[kind] = hp.x if active else -1.0
	NetworkManager.send_to_owner(_host.peer_id, &"sync_plant_indicator", [kind, active, hp.x, hp.y])


## Current (health, max_health) of this player's plant, or zero if it's gone.
func _health(kind: String) -> Vector2:
	if kind == "beanstalk":
		return beanstalk.chain_health() if has_beanstalk else Vector2.ZERO
	return Vector2(thornplant.health, thornplant.max_health) if has_thornplant else Vector2.ZERO


func _refresh_indicator(kind: String) -> void:
	if not (has_beanstalk if kind == "beanstalk" else has_thornplant):
		_hp_sent[kind] = -1.0
		return
	var hp := _health(kind)
	if absf(hp.x - _hp_sent[kind]) < 1.0:
		return
	_notify_indicator(kind, true)
