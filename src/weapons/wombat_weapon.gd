class_name WombatWeapon
extends Weapon

## Wombat spell — throws a wombat underarm into a fight. It bounces at whoever it can see for
## forty seconds, biting enemies and healing teammates, and which of those it does next is not
## the caster's to decide.
##
## The spellbook holds one cast. It costs no mana and spends itself instead: a successful cast
## takes the spell back out of the loadout, so another wombat means finding another book.

const SCALE := GameConsts.SCALE_FACTOR
const CAST_DISTANCE := 64.0 * SCALE    # 1.6 m out of the caster's hands, as in the original
const COOLDOWN := 2.0


func _init() -> void:
	cooldown = COOLDOWN
	# No mana: the book itself is the cost, and it's gone after one cast (see fire).


func precache() -> void:
	AssetLoader.precache_model(Wombat.MODEL)
	SoundSystem.precache(Wombat.LAUNCH_SOUND)
	SoundSystem.precache(Wombat.BLESS_SOUND)
	for sound_path in Wombat.BITE_SOUNDS:
		SoundSystem.precache(sound_path)


func fire(attacker: Node3D, aim_from: Vector3 = Vector3.INF, aim_dir: Vector3 = Vector3.ZERO, _charge_percent: float = 0.0, secondary: bool = false) -> bool:
	if secondary:
		return false
	if not NetworkManager.is_authoritative_fire(attacker):
		_fire_tail(attacker)  # client plays the cast; the host owns the wombat
		return true

	var aim := Combat.get_aim(attacker, aim_from, aim_dir)

	_spend(attacker)

	# Thrown with whatever the caster was already carrying, so one flung from a run goes further
	# than one dropped standing still — the original added the player's velocity to the throw.
	var carried: Vector3 = attacker.velocity if "velocity" in attacker else Vector3.ZERO
	NetworkManager.spawn_projectile("res://src/monsters/wombat.gd", {
		"sync_state": true,  # its death is a one-shot event, not a convergent property
		"position": _cast_spot(attacker, aim),
		"velocity": aim.aim_dir * Wombat.LAUNCH_SPEED + carried,
		"owner_peer_id": int(attacker.get("peer_id")),
		"team": int(attacker.get("team")),
	}, attacker)

	_fire_tail(attacker)
	return true


## Where it leaves the hand. The original traced the same 1.6 m and simply cast nothing at all
## when the way was blocked — a book spent on a wall with no sign of why. Here the throw starts
## short of whatever is in the way instead, the way every other spell in the set places itself.
func _cast_spot(attacker: Node3D, aim: Dictionary) -> Vector3:
	var ray := Combat.raycast_world(attacker, aim.from, aim.aim_dir, CAST_DISTANCE,
			attacker.get_rid(), GameConsts.MASK_WORLD | GameConsts.MASK_CLIP)
	var spot: Vector3 = ray.impact_pos
	if not ray.result.is_empty():
		spot -= aim.aim_dir * (Wombat.RADIUS * 2.0)
	return spot


## Take the spell back out of the caster's loadout — one book, one wombat. Deferred because the
## server is mid-fire: it still has to stamp last_fired_weapon_idx and broadcast the shot by slot
## index, and dropping a slot now would renumber the loadout under both.
func _spend(attacker: Node3D) -> void:
	if attacker.has_method("revoke_weapon"):
		attacker.call_deferred(&"revoke_weapon", SpawnRegistry.name_for(get_script()))


func cleanup(_attacker: Node3D) -> void:
	pass  # nothing to tear down: the wombat is the world's once thrown, not the loadout's
