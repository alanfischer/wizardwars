class_name GrimfeastWeapon
extends Weapon

const GRIMFEAST_RADIUS := 2.0
const COOLDOWN := 3.0
const MANA_COST := 25.0


func _init() -> void:
	cooldown = COOLDOWN
	mana_cost = MANA_COST


func precache() -> void:
	SoundSystem.precache("spells/necro_grimfeast.wav")

func fire(attacker: Node3D, _aim_from: Vector3 = Vector3.INF, _aim_dir: Vector3 = Vector3.ZERO, _charge_percent: float = 0.0, secondary: bool = false) -> bool:
	if secondary:
		return false
	if not NetworkManager.is_authoritative_fire(attacker):
		_fire_tail(attacker)
		return true

	var target := _find_target(attacker)

	if target == null:
		SoundSystem.play_3d("spells/combos/comet_miss.wav", attacker.global_position)
		_fire_tail(attacker)
		return true

	SoundSystem.play_3d("spells/necro_grimfeast.wav", attacker.global_position)

	if is_instance_valid(attacker) and attacker.has_method("heal"):
		attacker.heal(attacker.max_health, attacker, true)

	target._entity.destroy()
	_fire_tail(attacker)
	return true


## The nearest body in the open. The group holds only raisable bodies — a dead bird is not
## something a necromancer can feed on — so membership is the whole test.
func _find_target(attacker: Node3D) -> TumblingCorpse:
	var best_target: TumblingCorpse = null
	var best_dist := GRIMFEAST_RADIUS

	for node in attacker.get_tree().get_nodes_in_group("corpses"):
		if not node is TumblingCorpse:
			continue
		if not node.is_inside_tree():
			continue

		var dist := attacker.global_position.distance_to(node.global_position)
		if dist > best_dist:
			continue

		# The corpse origin IS the body's centre (see TumblingCorpse.wizard_payload).
		var target_center : Vector3 = node.global_position
		var space := attacker.get_world_3d().direct_space_state
		var params := PhysicsRayQueryParameters3D.create(attacker.global_position, target_center)
		params.collision_mask = GameConsts.MASK_WORLD
		params.exclude = [attacker.get_rid()]
		var result := space.intersect_ray(params)
		if not result.is_empty():
			continue

		best_dist = dist
		best_target = node

	return best_target
