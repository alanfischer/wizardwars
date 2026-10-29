class_name SacrificeWeapon
extends Weapon

## Sacrifice — the sanomancer sacrifices themselves after a 4-second delay.
## On detonation: expands a white torus, heals nearby enemies by 300 (curing
## any poison in the process), flashes their screen white, then halves their health.
## The caster dies.

const HEAL_AMOUNT := 300.0
const RADIUS := 3.0
const COOLDOWN := 5.0
const MANA_COST := 10.0


func _init() -> void:
	cooldown = COOLDOWN
	mana_cost = MANA_COST


func precache() -> void:
	SoundSystem.precache("spells/healer_sacrifice.wav")


func fire(attacker: Node3D, _aim_from: Vector3 = Vector3.INF, _aim_dir: Vector3 = Vector3.ZERO, _charge_percent: float = 0.0, secondary: bool = false) -> bool:
	if secondary:
		return false
	_fire_tail(attacker)

	if not NetworkManager.is_authoritative_fire(attacker):
		return true

	_trigger_sacrifice(attacker)
	return true


func _trigger_sacrifice(attacker: Node3D) -> void:
	if not is_instance_valid(attacker):
		return
	if attacker.get("is_dead"):
		return

	var origin := attacker.global_position + GameConsts.PLAYER_CENTER
	var scene_root := attacker.get_tree().current_scene

	ExplosionEffect.spawn(scene_root, origin, true,
		"",             # no sprite
		Color.WHITE,    # light color
		"",             # no sound (already played on cast)
		1.0,
		Color(1.0, 1.0, 1.0, 0.9)  # white torus ring
	)

	for node in SpatialQuery.nodes_near(&"damageable", origin, RADIUS):
		if not node.is_inside_tree():
			continue
		if node == attacker:
			continue
		if Teams.nodes_friendly(attacker, node):
			continue
		if node.get("is_dead"):
			continue

		var center: Vector3 = SpatialQuery.collision_center(node)
		if origin.distance_to(center) > RADIUS:
			continue

		# heal() also clears poison/status effects
		if node.has_method("heal"):
			node.heal(HEAL_AMOUNT, attacker, true)

		# White screen blind on the target's client (no-op if non-player).
		NetworkManager.send_screen_fade(Color(1, 1, 1, 1), 4.0, 5.0, true, node)

		if node.has_method("take_damage"):
			node.take_damage(node.health * 0.5, GameConsts.DamageType.PHYSICAL, attacker)

	# die() rather than a huge self-hit: the killing blow's size is what decides whether a
	# body is left (GameConsts.damage_gibs), and the sanomancer leaves a corpse.
	if attacker.has_method("die"):
		attacker.die()
