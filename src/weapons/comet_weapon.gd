class_name CometWeapon
extends Weapon

## Comet spell — homes a comet onto the nearest visible enemy in front of the caster.

const COMET_RANGE := 102.4  # 4096 GS units * 0.025
const COMET_FOV := 0.25    # tight forward cone (dot product threshold)
const COOLDOWN := 3.0
const MANA_COST := 45.0


func _init() -> void:
	cooldown = COOLDOWN
	mana_cost = MANA_COST


func precache() -> void:
	AssetLoader.precache_sprite("sprites/animglow01.spr")
	AssetLoader.precache_sprite("sprites/zerogxplode.spr")
	SoundSystem.precache("spells/combos/comet_cast.wav")
	SoundSystem.precache("spells/combos/comet_hit.wav")
	SoundSystem.precache("spells/combos/comet_miss.wav")
	SoundSystem.precache("ambience/explode3.wav")
	AssetLoader.get_sprite_material_template()
	AssetLoader.get_spark_particle_material("spotbolt")
	AssetLoader.get_spark_quad(Vector2(0.15, 0.15))

func fire(attacker: Node3D, aim_from: Vector3 = Vector3.INF, aim_dir: Vector3 = Vector3.ZERO, _charge_percent: float = 0.0, secondary: bool = false) -> bool:
	if secondary:
		return false
	if not NetworkManager.is_authoritative_fire(attacker):
		# client only plays the cast anim; host handles targeting/spawn/sounds
		_fire_tail(attacker)
		return true

	var aim := Combat.get_aim(attacker, aim_from, aim_dir)
	var target := _find_target(attacker, aim.from, aim.aim_dir)

	if target == null:
		SoundSystem.play_3d("spells/combos/comet_miss.wav", attacker.global_position)
		_fire_tail(attacker)
		return true

	Comet.spawn(target, attacker, attacker.get_rid())

	SoundSystem.play_3d("spells/combos/comet_cast.wav", attacker.global_position)
	_fire_tail(attacker)
	return true


func _find_target(attacker: Node3D, from: Vector3, aim_dir: Vector3) -> Node3D:
	var best_target: Node3D = null
	var best_dot := COMET_FOV

	var space := attacker.get_world_3d().direct_space_state
	for node in attacker.get_tree().get_nodes_in_group("damageable"):
		if node == attacker:
			continue
		if not node.is_inside_tree():
			continue
		# Same rule as Combat.find_homing_target: a window and a bird are damageable, not
		# targets. nodes_friendly spares neither — a team of NONE has no allies.
		if node.is_in_group("unhunted"):
			continue
		if Teams.nodes_friendly(attacker, node):
			continue
		if node.get("is_dead"):
			continue

		var target_center: Vector3 = SpatialQuery.collision_center(node)
		var to_target := target_center - from
		var dist := to_target.length()
		if dist > COMET_RANGE or dist < 0.1:
			continue

		var dir := to_target / dist
		var dot := aim_dir.dot(dir)
		if dot < COMET_FOV:
			continue

		var params := PhysicsRayQueryParameters3D.create(from, target_center)
		params.collision_mask = GameConsts.MASK_WORLD
		params.exclude = [attacker.get_rid(), node.get_rid()]
		var result := space.intersect_ray(params)
		if not result.is_empty():
			continue

		# "best" = most centered in view (highest dot), not nearest
		if dot > best_dot:
			best_dot = dot
			best_target = node

	return best_target
