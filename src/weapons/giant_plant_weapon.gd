class_name GiantPlantWeapon
extends Weapon

## Giant plant spell — grows a lumbering carnivorous plant on the ground ahead of the caster.
## It hunts on its own and its bite is lethal,
## and once it is out the caster has no hold on it at all — it is not tied to their life, class
## or session, and casting another does nothing to the ones already walking around.
##
## The spellbook holds one cast. It costs no mana and spends itself instead: a successful cast
## takes the spell back out of the loadout, so another plant means finding another book — which
## is the only thing limiting how many a wizard can have out.

const SCALE := GameConsts.SCALE_FACTOR
const PLACE_DISTANCE := 120.0 * SCALE   # 3.0m forward, as in the original spell
const TRACE_DOWN := 96.0 * SCALE        # ground has to be within 2.4m of the cast height
const COOLDOWN := 2.0


func _init() -> void:
	cooldown = COOLDOWN
	# No mana: the book itself is the cost, and it's gone after one cast (see fire).


func precache() -> void:
	AssetLoader.precache_model(GiantPlant.MODEL)
	AssetLoader.precache_sprite(ExplosionEffect.DEFAULT_SPR)
	for sound_path in ["spells/combos/giantplant_cast.wav", GiantPlant.BITE_SOUND,
			ExplosionEffect.DEFAULT_SOUND, "misc/talk.wav"]:
		SoundSystem.precache(sound_path)


## Ground position the plant would take, or Vector3.INF when there's nowhere to put it —
## no ground within reach, or not enough clear space for the plant's hull.
func _placement(attacker: Node3D, aim_dir: Vector3) -> Vector3:
	var aim := Combat.get_aim(attacker, Vector3.INF, aim_dir)
	var forward: Vector3 = aim.aim_dir
	forward.y = 0.0
	if forward.length_squared() < 0.001:
		forward = -attacker.global_transform.basis.z
		forward.y = 0.0
	forward = forward.normalized()

	var from: Vector3 = aim.from + forward * PLACE_DISTANCE
	var ray := Combat.raycast_world(attacker, from, Vector3.DOWN, TRACE_DOWN, attacker.get_rid())
	if ray.result.is_empty():
		return Vector3.INF
	var ground: Vector3 = ray.result.position
	return ground if _has_room(attacker, ground) else Vector3.INF


## The plant's own hull, swept nowhere: anything solid already standing there — world, a player,
## another giant plant — means it has no room to grow. Nothing is exempt but the caster: a plant
## they cast earlier is just another body in the way, the same as anyone else's.
func _has_room(attacker: Node3D, ground: Vector3) -> bool:
	var space := attacker.get_world_3d().direct_space_state
	var cyl := CylinderShape3D.new()
	cyl.radius = GiantPlant.RADIUS
	cyl.height = GiantPlant.HEIGHT
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = cyl
	params.transform = Transform3D(Basis.IDENTITY, ground + Vector3(0.0, GiantPlant.HEIGHT * 0.5, 0.0))
	params.collision_mask = GameConsts.MASK_WORLD | GameConsts.MASK_CLIP \
			| GameConsts.MASK_ENTITY | GameConsts.MASK_PLAYER
	params.exclude = Combat.collect_hitscan_excludes(attacker)
	return space.intersect_shape(params, 1).is_empty()


func can_fire(attacker: Node3D, aim_dir: Vector3 = Vector3.ZERO) -> bool:
	if _placement(attacker, aim_dir) != Vector3.INF:
		return true
	SoundSystem.play_3d("misc/talk.wav", attacker.global_position)
	# Only the caster's own view has a HUD, so the message is shown from there rather than
	# rpc'd back from the server's identical refusal.
	if attacker is LocalPlayer:
		if Game.hud:
			Game.hud.show_center_message("There is no room for a giant plant here!",
				Color(0.2, 0.8, 0.1), 3.0, true)
	return false


func fire(attacker: Node3D, aim_from: Vector3 = Vector3.INF, aim_dir: Vector3 = Vector3.ZERO, _charge_percent: float = 0.0, secondary: bool = false) -> bool:
	if secondary:
		return false
	if not NetworkManager.is_authoritative_fire(attacker):
		_fire_tail(attacker)  # client plays the cast; the host owns the summon
		return true

	var aim := Combat.get_aim(attacker, aim_from, aim_dir)
	var ground := _placement(attacker, aim.aim_dir)
	if ground == Vector3.INF:
		_fire_tail(attacker)
		return true

	_spend(attacker)

	NetworkManager.spawn_projectile("res://src/monsters/giant_plant.gd", {
		"sync_state": true,  # bite and death are one-shot events, not convergent properties
		"position": ground,
		# Facing back down the cast, at the wizard who grew it (look-at yaw toward -aim_dir).
		"yaw": atan2(aim.aim_dir.x, aim.aim_dir.z),
		"owner_peer_id": int(attacker.get("peer_id")),
		"team": int(attacker.get("team")),
	}, attacker)

	_fire_tail(attacker)
	return true


## Take the spell back out of the caster's loadout — one book, one plant. Deferred because the
## server is mid-fire: it still has to stamp last_fired_weapon_idx and broadcast the shot by slot
## index, and dropping a slot now would renumber the loadout under both.
func _spend(attacker: Node3D) -> void:
	if attacker.has_method("revoke_weapon"):
		attacker.call_deferred(&"revoke_weapon", SpawnRegistry.name_for(get_script()))


func cleanup(_attacker: Node3D) -> void:
	pass  # nothing to tear down: the plant is the world's once cast, not the loadout's
