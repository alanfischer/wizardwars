class_name FreezeRayWeapon
extends RayWeapon

## Freeze Ray — sustained beam, 5 dmg/pulse; ICE damage auto-applies frost via StatusSystem.

const DAMAGE := 5.0
const COOLDOWN := 0.25
const MANA_COST := 4.0
const MANA_DRAIN := 1.0


func _init() -> void:
	super()
	cooldown = COOLDOWN
	mana_cost = MANA_COST
	mana_drain = MANA_DRAIN


func _get_outer_beam_color() -> Color:
	return Color(0.5, 0.5, 1.0, 0.8)


func precache() -> void:
	SoundSystem.precache("spells/rayspell_aqua.wav")
	AssetLoader.get_beam_material()
	AssetLoader.get_spark_particle_material("freezeray")
	AssetLoader.get_spark_quad(Vector2(0.06, 0.06))


func play_attack_sound(attacker: Node3D) -> void:
	SoundSystem.spawn_on(attacker, "spells/rayspell_aqua.wav", true, 20.0, "FreezeRayLoop")


func stop_firing(attacker: Node3D, _secondary: bool = false) -> void:
	var snd := attacker.get_node_or_null("FreezeRayLoop")
	if snd:
		snd.queue_free()
	_stop_beam(attacker, "icerayshootend")


func _apply_ray_hit(attacker: Node3D, target: Node, damage_mult: float = 1.0) -> void:
	target.take_damage(DAMAGE * damage_mult, GameConsts.DamageType.ICE, attacker)


func fire(attacker: Node3D, aim_from: Vector3 = Vector3.INF, aim_dir: Vector3 = Vector3.ZERO, _charge_percent: float = 0.0, secondary: bool = false) -> bool:
	if secondary:
		return false
	_fire_ray(attacker, aim_from, aim_dir, Color(0.3, 0.6, 1.0), "freezeray")
	return true
