class_name DeathRayWeapon
extends RayWeapon

## Death Ray — sustained beam, 10 dmg/pulse at 0.25s intervals, drains 50% as a heal for the attacker.

const DAMAGE := 10.0
const DRAIN_FRACTION := 0.5
const COOLDOWN := 0.25
const MANA_COST := 2.0
const MANA_DRAIN := 1.0


func _init() -> void:
	super()
	cooldown = COOLDOWN
	mana_cost = MANA_COST
	mana_drain = MANA_DRAIN


func _get_outer_beam_color() -> Color:
	return Color(0.8, 0.0, 0.0, 0.8)


func precache() -> void:
	SoundSystem.precache("spells/rayspell_death.wav")
	AssetLoader.get_beam_material()
	AssetLoader.get_spark_particle_material("deathray")
	AssetLoader.get_spark_quad(Vector2(0.06, 0.06))


func play_attack_sound(attacker: Node3D) -> void:
	SoundSystem.spawn_on(attacker, "spells/rayspell_death.wav", true, 20.0, "DeathRayLoop")


func stop_firing(attacker: Node3D, _secondary: bool = false) -> void:
	var snd := attacker.get_node_or_null("DeathRayLoop")
	if snd:
		snd.queue_free()
	_stop_beam(attacker, "deathrayshootend")


func _apply_ray_hit(attacker: Node3D, target: Node, damage_mult: float = 1.0) -> void:
	if Teams.nodes_friendly(attacker, target):
		return
	var dmg := DAMAGE * damage_mult
	target.take_damage(dmg, GameConsts.DamageType.DEATH, attacker)
	if attacker.has_method("heal"):
		attacker.heal(dmg * DRAIN_FRACTION, attacker, true)


func fire(attacker: Node3D, aim_from: Vector3 = Vector3.INF, aim_dir: Vector3 = Vector3.ZERO, _charge_percent: float = 0.0, secondary: bool = false) -> bool:
	if secondary:
		return false
	_fire_ray(attacker, aim_from, aim_dir, Color(0.8, 0.2, 0.2), "deathray")
	return true
