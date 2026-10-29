class_name TornadoWeapon
extends Weapon

## Tornado spell — throws a whirlwind out in front of the caster. It hunts on its own, and
## unlike the giant plant there is nothing to kill: it cannot be hurt and simply blows itself
## out after half a minute.
##
## The spellbook holds one cast. It costs no mana and spends itself instead: a successful cast
## takes the spell back out of the loadout, so another tornado means finding another book.

const SCALE := GameConsts.SCALE_FACTOR
const CAST_DISTANCE := 100.0 * SCALE   # 2.5 m ahead, as in the original spell
const WALL_BACKOFF := 20.0 * SCALE     # kept off a wall the cast would have put it inside
const COOLDOWN := 2.0


func _init() -> void:
	cooldown = COOLDOWN
	# No mana: the book itself is the cost, and it's gone after one cast (see fire).


func precache() -> void:
	AssetLoader.precache_model(Tornado.MODEL)
	for sound_path in [Tornado.CAST_SOUND, Tornado.WIND_SOUND]:
		SoundSystem.precache(sound_path)


func fire(attacker: Node3D, aim_from: Vector3 = Vector3.INF, aim_dir: Vector3 = Vector3.ZERO, _charge_percent: float = 0.0, secondary: bool = false) -> bool:
	if secondary:
		return false
	if not NetworkManager.is_authoritative_fire(attacker):
		_fire_tail(attacker)  # client plays the cast; the host owns the summon
		return true

	var aim := Combat.get_aim(attacker, aim_from, aim_dir)
	var forward: Vector3 = aim.aim_dir
	forward.y = 0.0
	if forward.length_squared() < 0.001:
		forward = -attacker.global_transform.basis.z
		forward.y = 0.0
	forward = forward.normalized()

	_spend(attacker)

	NetworkManager.spawn_projectile("res://src/monsters/tornado.gd", {
		"position": _cast_spot(attacker, forward),
		"direction": forward,
		"owner_peer_id": int(attacker.get("peer_id")),
		"team": int(attacker.get("team")),
	}, attacker)

	_fire_tail(attacker)
	return true


## Where it touches down. The original dropped it a flat 2.5 m ahead with no check at all, which
## puts it inside the wall a caster is standing against; the trace pulls it back to this side of
## anything in the way. Height is the caster's feet — it settles to the ground on its own.
func _cast_spot(attacker: Node3D, forward: Vector3) -> Vector3:
	var from: Vector3 = attacker.global_position + Vector3(0.0, Tornado.EYE_HEIGHT, 0.0)
	var ray := Combat.raycast_world(attacker, from, forward, CAST_DISTANCE, attacker.get_rid(),
			GameConsts.MASK_WORLD | GameConsts.MASK_CLIP)
	var spot: Vector3 = ray.impact_pos
	if not ray.result.is_empty():
		spot -= forward * WALL_BACKOFF
	spot.y = attacker.global_position.y
	return spot


## Take the spell back out of the caster's loadout — one book, one tornado. Deferred because the
## server is mid-fire: it still has to stamp last_fired_weapon_idx and broadcast the shot by slot
## index, and dropping a slot now would renumber the loadout under both.
func _spend(attacker: Node3D) -> void:
	if attacker.has_method("revoke_weapon"):
		attacker.call_deferred(&"revoke_weapon", SpawnRegistry.name_for(get_script()))


func cleanup(_attacker: Node3D) -> void:
	pass  # nothing to tear down: the tornado is the world's once cast, not the loadout's
