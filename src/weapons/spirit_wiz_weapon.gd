class_name SpiritWizWeapon
extends Weapon

## Spirit wizard spell — leaves the ghost of a wizard hanging in the air in front of the caster.
## It wanders until it sees someone, then stares them down and flies at them.
##
## The spellbook holds one cast. It costs no mana and spends itself instead: a successful cast
## takes the spell back out of the loadout, so another spirit means finding another book.

const SCALE := GameConsts.SCALE_FACTOR
const CAST_DISTANCE := 56.0 * SCALE    # 1.4 m out of the caster's hands, as in the original
const COOLDOWN := 2.0
const CAST_SOUND := "spells/combos/spritwiz_cast.wav"


func _init() -> void:
	cooldown = COOLDOWN
	# No mana: the book itself is the cost, and it's gone after one cast (see fire).


func precache() -> void:
	AssetLoader.precache_model(SpiritWiz.MODEL)
	AssetLoader.precache_sprite(ExplosionEffect.DEFAULT_SPR)
	AssetLoader.get_beam_material()
	for sound_path in [CAST_SOUND, SpiritWiz.WAIL_SOUND, ExplosionEffect.DEFAULT_SOUND]:
		SoundSystem.precache(sound_path)


func play_attack_sound(attacker: Node3D) -> void:
	SoundSystem.spawn_on(attacker, CAST_SOUND, false, 30.0)


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

	NetworkManager.spawn_projectile("res://src/monsters/spirit_wiz.gd", {
		"sync_state": true,  # its death is a one-shot event, not a convergent property
		"position": _cast_spot(attacker, forward),
		"direction": forward,
		"owner_peer_id": int(attacker.get("peer_id")),
		"team": int(attacker.get("team")),
	}, attacker)

	_fire_tail(attacker)
	return true


## Where it forms. The original dropped it a flat 1.4 m ahead, which puts it inside the wall a
## caster is standing against; the trace keeps it on this side of whatever is in the way. It
## flies rather than falls, so it stays at the height it was cast from.
func _cast_spot(attacker: Node3D, forward: Vector3) -> Vector3:
	var from: Vector3 = attacker.global_position + Vector3(0.0, SpiritWiz.HEIGHT * 0.5, 0.0)
	var ray := Combat.raycast_world(attacker, from, forward, CAST_DISTANCE, attacker.get_rid(),
			GameConsts.MASK_WORLD | GameConsts.MASK_CLIP)
	var spot: Vector3 = ray.impact_pos
	if not ray.result.is_empty():
		spot -= forward * SpiritWiz.RADIUS
	return spot


## Take the spell back out of the caster's loadout — one book, one spirit. Deferred because the
## server is mid-fire: it still has to stamp last_fired_weapon_idx and broadcast the shot by slot
## index, and dropping a slot now would renumber the loadout under both.
func _spend(attacker: Node3D) -> void:
	if attacker.has_method("revoke_weapon"):
		attacker.call_deferred(&"revoke_weapon", SpawnRegistry.name_for(get_script()))


func cleanup(_attacker: Node3D) -> void:
	pass  # nothing to tear down: the spirit is the world's once cast, not the loadout's
