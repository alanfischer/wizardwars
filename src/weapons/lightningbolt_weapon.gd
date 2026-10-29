class_name LightningboltWeapon
extends Weapon

## Lightning Bolt — auto-repeat hitscan zap, 4 ticks/sec while held. Each tick costs
## mana_cost directly (no sustained drain).

const DAMAGE := 10.0
const RANGE := 205.0          # 8192 GS * 0.025

const BEAM_BONE := "Bip01 L Finger12"
const BEAM_BONE_FALLBACK := "Bip01 L Finger1"

const BEAM_SEGMENTS := 12
const BEAM_JITTER := 0.15
const BEAM_WIDTH := 0.08
const BEAM_FADE_TIME := 0.2
const BEAM_COLOR := Color(1.0, 1.0, 0.4, 1.0)
const EFFECT_OFFSET := 0.1


const COOLDOWN := 0.25
const MANA_COST := 2.0


func _init() -> void:
	auto_repeat = true
	cooldown = COOLDOWN
	mana_cost = MANA_COST


func precache() -> void:
	SoundSystem.precache("spells/lightningzap.wav")
	AssetLoader.get_beam_material()
	AssetLoader.get_spark_particle_material("lightning")
	AssetLoader.get_spark_quad(Vector2(0.1, 0.1))

func play_attack_sound(attacker: Node3D) -> void:
	# discrete zap, not sustained — sample (0.36s) outlives the 0.25s cooldown so held fire
	# overlaps into a crackle; the non-looping player frees itself, nothing for stop_firing to clean up
	SoundSystem.spawn_on(attacker, "spells/lightningzap.wav", false, 20.0)


func fire(attacker: Node3D, aim_from: Vector3 = Vector3.INF, aim_dir: Vector3 = Vector3.ZERO, _charge_percent: float = 0.0, secondary: bool = false) -> bool:
	if secondary:
		return false
	var aim := Combat.get_aim(attacker, aim_from, aim_dir)
	var excludes := Combat.collect_hitscan_excludes(attacker)
	var ray := Combat.hitscan(attacker, aim.from, aim.aim_dir, RANGE, RID(),
		GameConsts.MASK_HITSCAN, true, excludes)

	if NetworkManager.is_authoritative_fire(attacker):
		Combat.apply_hitscan_damage(ray, DAMAGE, GameConsts.DamageType.LIGHTNING, attacker)
		var scene_root := attacker.get_tree().current_scene
		var effect := LightningZapEffect.spawn(scene_root, ray.impact_pos + ray.impact_norm * EFFECT_OFFSET)
		NetworkManager.register_effect(effect, "res://src/effects/lightning_zap_effect.gd")

	# beam is cosmetic-only, so both client and host draw it (unlike damage above)
	_spawn_beam(attacker, aim, ray.impact_pos)

	_fire_tail(attacker)
	return true


func _spawn_beam(attacker: Node3D, aim: Dictionary, impact_pos: Vector3) -> void:
	var scene_root := attacker.get_tree().current_scene
	if not scene_root:
		return

	var beam_origin := Combat.get_beam_origin(attacker, aim, BEAM_BONE, BEAM_BONE_FALLBACK)
	var beam_vec := impact_pos - beam_origin
	if beam_vec.length() < 0.01:
		return

	var beam_right := beam_vec.cross(Vector3.UP).normalized()
	var beam_up := beam_vec.cross(beam_right).normalized()
	if beam_right.length_squared() < 0.001:
		beam_right = Vector3.RIGHT
		beam_up = Vector3.FORWARD
	var jitter_fn := func(t: float) -> Vector3:
		if t <= 0.0 or t >= 1.0:
			return Vector3.ZERO
		return beam_right * randf_range(-BEAM_JITTER, BEAM_JITTER) + beam_up * randf_range(-BEAM_JITTER, BEAM_JITTER)

	BeamSystem.create_oneshot(scene_root, beam_origin, impact_pos, {
		"color": BEAM_COLOR,
		"width": BEAM_WIDTH,
		"segments": BEAM_SEGMENTS,
		"noise_fn": jitter_fn,
		"fade_time": BEAM_FADE_TIME,
	})
