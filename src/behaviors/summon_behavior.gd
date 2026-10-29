class_name SummonBehavior
extends RefCounted

## Placement, health and the death handshake shared by the spawned, owned, damageable things —
## the skeleton, the wombat, the giant plant, the thornplant, the beanstalk, the spirit wizard
## and the cockleburr.
##
## A behavior rather than a base class because they extend three different engine bases:
## CharacterBody3D (skeleton, giant_plant, spirit_wiz), RigidBody3D (wombat, cockleburr) and
## Node3D (thornplant, beanstalk). It composes the EntityBehavior + HealthBehavior pair each of
## them carried separately, and delegates the handful of calls they all made through it.
##
## The host keeps its own owner_node/owner_peer_id/team/is_dead/health/max_health properties.
## Combat's damage walk and Teams' friend-or-foe checks read them off the node, the dynamic-entity
## spawner writes owner_node onto it after the spawn, and GDScript gives a behavior no way to graft
## a property onto the class holding it.

## The green every summon's owner message is drawn in.
const OWNER_MSG_COLOR := Color(0.2, 0.8, 0.1)

var entity := EntityBehavior.new()
var vitals := HealthBehavior.new()

var is_host: bool:
	get: return entity.is_host
## Settable: the dynamic-entity spawner writes the shared id here after setup (see main.gd).
var entity_id: int:
	get: return entity.entity_id
	set(value): entity.entity_id = value
var is_dead: bool:
	get: return vitals.is_dead
var health: float:
	get: return vitals.health
	set(value): vitals.health = value
var max_health: float:
	get: return vitals.max_health
	set(value): vitals.max_health = value

var _host: Node3D


## Places the summon and brings both behaviors up. `hp` is passed rather than read from the data —
## it is a constant per creature, and per growth level for the thornplant.
func setup(host: Node3D, data: Dictionary, as_host: bool, hp: float, on_death: Callable) -> void:
	_host = host
	host.position = data.get("position", Vector3.ZERO)
	if data.has("yaw"):
		host.rotation.y = data["yaw"]
	entity.initialize(host, as_host)
	vitals.initialize(host, hp, as_host, on_death)


func set_regen(amount: float, interval: float) -> void:
	vitals.regen_amount = amount
	vitals.regen_interval = interval


func tick(delta: float) -> void:
	vitals.tick(delta)


func take_damage(amount: float, type: int, attacker: Node3D) -> void:
	vitals.take_damage(amount, type, attacker)


func kill() -> void:
	vitals.kill()


func destroy() -> void:
	entity.destroy()


func set_anim_player(anim_player: AnimationPlayer) -> void:
	entity.set_anim_player(anim_player)


func publish_event(event: Dictionary, near := Vector3.INF) -> void:
	entity.publish_event(event, near)


func die_at(pos: Vector3, extra: Dictionary = {}, pvs := false) -> void:
	entity.die_at(pos, extra, pvs)


## Centre-screen note to whoever cast it. Offline there is no peer to send to, so it goes
## straight to the local HUD. The peer id is passed rather than read off the host: it lives on
## the node (see the note above) and GDScript cannot reach it through a Node3D-typed reference.
func tell_owner(peer_id: int, text: String) -> void:
	if NetworkManager.is_online():
		if NetworkManager.is_peer_connected(peer_id):
			NetworkManager.sync_hud_text.rpc_id(peer_id, text, NetworkManager.HUD_CENTER,
				OWNER_MSG_COLOR.r, OWNER_MSG_COLOR.g, OWNER_MSG_COLOR.b, 3.0, true)
		return
	if Game.hud:
		Game.hud.show_center_message(text, OWNER_MSG_COLOR, 3.0, true)
