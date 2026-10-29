class_name SpotboltWeapon
extends Weapon

## Spot Bolt — charged lightning strike from the sky.
## Hold attack to charge, targeting dot appears on ground, release to fire.
## Damage scales 10%-100% with charge time. Overcharging past 10s backfires.

const MIN_CHARGE := 1.5    # seconds to minimum ready
const MAX_CHARGE := 11.0   # seconds to full charge
const OVERCHARGE := 16.0   # seconds before it blows up in your face
const DAMAGE := 80.0
const SELF_DAMAGE := 40.0  # damage when overcharge backfires
const RANGE := 205.0       # 8192 GS * 0.025 — max aim distance
const EFFECT_OFFSET := 0.1

const ZOOM_FOV := 25.0  # degrees — roughly 3x magnification for sniping

var _charge_time := 0.0
var _charging := false
var _was_full := false
var _crackle_started := false
var _zoomed := false
var _dot: MeshInstance3D
var _dot_mat: ShaderMaterial

static var _dot_tex: ImageTexture
static var _projector_shader: Shader = preload("res://shaders/decal_projector.gdshader")

static func _ensure_dot_texture() -> void:
	if not _dot_tex:
		const SIZE := 64
		var img := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
		var center := Vector2(SIZE * 0.5, SIZE * 0.5)
		var r := SIZE * 0.5
		for y in SIZE:
			for x in SIZE:
				var d := Vector2(x + 0.5, y + 0.5).distance_to(center) / r
				var a := smoothstep(0.5, 0.35, 1.0 - d)
				if d > 0.5: a = 0.0
				img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a))
		_dot_tex = ImageTexture.create_from_image(img)


func precache() -> void:
	SoundSystem.precache("spells/spotbolt.wav")
	SoundSystem.precache("spells/lightningzap.wav")
	SoundSystem.precache("ambience/thunder.wav")
	AssetLoader.get_additive_material()
	AssetLoader.get_spark_particle_material("spotbolt")
	AssetLoader.get_spark_quad(Vector2(0.15, 0.15))
	_ensure_dot_texture()

const COOLDOWN := 1.5
const MANA_COST := 5.0


func _init() -> void:
	supports_charging = true
	cooldown = COOLDOWN
	mana_cost = MANA_COST


func begin_charge(attacker: Node3D) -> void:
	_charging = true
	_charge_time = 0.0
	_was_full = false
	_crackle_started = false

	var anim_player: AnimationPlayer = attacker.get("_hand_anim_player")
	if anim_player and anim_player.has_animation("spotboltchargestart"):
		var anim_res := anim_player.get_animation("spotboltchargestart")
		anim_res.loop_mode = Animation.LOOP_NONE
		anim_player.play("spotboltchargestart")

	_create_dot(attacker)


func update_charge(attacker: Node3D, delta: float) -> void:
	if not _charging:
		return
	_charge_time += delta
	_update_dot_position(attacker)

	# Crackling sound when nearing overcharge (last 4 seconds)
	if _charge_time >= OVERCHARGE - 4.0 and not _crackle_started:
		_crackle_started = true
		SoundSystem.spawn_on(attacker, "spells/lightningzap.wav", true, 15.0, "SpotboltCrackle")

	if _charge_time >= OVERCHARGE:
		_charging = false
		_cleanup_dot()
		_stop_crackle(attacker)
		SoundSystem.spawn_on(attacker, "spells/spotbolt.wav")
		var bp: AnimationPlayer = attacker.get("_hand_anim_player")
		if bp and bp.has_animation(hand_idle_anim):
			bp.play(hand_idle_anim)
		Log.info("Spotbolt BACKFIRE! Dealing %.0f self-damage" % SELF_DAMAGE)
		# Online, the server owns the charge timer (ChargeBehavior.tick) and backfires
		# there — this client-side timer only drives local prediction, never the damage.
		if NetworkManager.is_authoritative_fire(attacker):
			if attacker.has_method("take_damage"):
				attacker.take_damage(SELF_DAMAGE, GameConsts.DamageType.LIGHTNING, attacker)
		if attacker.has_method("_on_charge_backfire"):
			attacker._on_charge_backfire()
		return

	var pct := _get_charge_percent()

	# Hand animation transitions: chargestart → charge (loop) → chargefull (loop)
	var anim_player: AnimationPlayer = attacker.get("_hand_anim_player")
	if anim_player:
		if pct >= 1.0 and not _was_full:
			_was_full = true
			if anim_player.has_animation("spotboltchargefull"):
				var anim_res := anim_player.get_animation("spotboltchargefull")
				anim_res.loop_mode = Animation.LOOP_LINEAR
				anim_player.play("spotboltchargefull")
		elif not _was_full and not anim_player.is_playing():
			# chargestart finished → transition to charge loop
			if anim_player.has_animation("spotboltcharge"):
				var anim_res := anim_player.get_animation("spotboltcharge")
				anim_res.loop_mode = Animation.LOOP_LINEAR
				anim_player.play("spotboltcharge")

	# Color: smooth yellow → red over full charge duration, flashing at end
	if _dot_mat:
		var t := clampf(_charge_time / OVERCHARGE, 0.0, 1.0)
		var r := 1.0
		var g := 0.9 * (1.0 - t)
		var b := 0.1 * (1.0 - t)
		if _charge_time >= OVERCHARGE - 2.0:
			var flash := 0.5 + 0.5 * sin(_charge_time * 12.0)
			g *= flash
			b *= flash
		_dot_mat.set_shader_parameter("modulate", Color(r, g, b, 0.9))


func release_charge(attacker: Node3D) -> float:
	if not _charging:
		return 0.0
	_charging = false
	var pct := _get_charge_percent()
	_cleanup_dot()
	_stop_crackle(attacker)
	return pct


func cancel_charge(attacker: Node3D) -> void:
	_charging = false
	_charge_time = 0.0
	_cleanup_dot()
	_stop_crackle(attacker)


## Toggle zoom on secondary fire; force-unzoom on stop (weapon switch / death).
func stop_firing(attacker: Node3D, secondary: bool = false) -> void:
	if secondary and _zoomed:
		_zoomed = false
		if attacker.has_method("set_zoom"):
			attacker.set_zoom(0.0)


func play_attack_sound(attacker: Node3D) -> void:
	SoundSystem.spawn_on(attacker, "spells/spotbolt.wav")


## Host-only: raycast to aim point, apply damage, spawn strike effect.
## secondary=true toggles the sniper zoom instead of firing.
func fire(attacker: Node3D, aim_from: Vector3 = Vector3.INF, aim_dir: Vector3 = Vector3.ZERO, charge_percent: float = 0.0, secondary: bool = false) -> bool:
	if secondary:
		_zoomed = not _zoomed
		if attacker.has_method("set_zoom"):
			attacker.set_zoom(ZOOM_FOV if _zoomed else 0.0)
		return true
	var aim := Combat.get_aim(attacker, aim_from, aim_dir)
	var excludes := Combat.collect_hitscan_excludes(attacker)
	var ray := Combat.hitscan(attacker, aim.from, aim.aim_dir, RANGE, RID(),
		GameConsts.MASK_HITSCAN, true, excludes)
	var pct := clampf(charge_percent, 0.1, 1.0)

	if NetworkManager.is_authoritative_fire(attacker):
		Combat.apply_hitscan_damage(ray, pct * DAMAGE, GameConsts.DamageType.LIGHTNING, attacker)
		SpotBoltStrike.summon(ray.impact_pos + ray.impact_norm * EFFECT_OFFSET, pct)

	_fire_tail(attacker)
	return true


## Calculate charge percentage (0.1 to 1.0, linear over MAX_CHARGE seconds).
func _get_charge_percent() -> float:
	return charge_percent_at(_charge_time)


# --- Server-authoritative charge model (see Weapon base) ---
func overcharge_time() -> float: return OVERCHARGE
func backfire_damage() -> float: return SELF_DAMAGE
func backfire_damage_type() -> int: return GameConsts.DamageType.LIGHTNING
func charge_percent_at(elapsed: float) -> float:
	return clampf(elapsed / MAX_CHARGE, 0.0, 1.0) * 0.9 + 0.1


## Create the targeting dot (small yellow projected box on the ground).
func _create_dot(attacker: Node3D) -> void:
	_cleanup_dot()
	_dot = MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(1, 1, 1)
	_dot.mesh = box

	_dot_mat = ShaderMaterial.new()
	_ensure_dot_texture()
	_dot_mat.shader = _projector_shader
	_dot_mat.set_shader_parameter("decal_tex", _dot_tex)
	_dot_mat.set_shader_parameter("modulate", Color(1.0, 0.5, 0.1, 0.9))
	_dot_mat.render_priority = 2  # on top of decals
	_dot.material_override = _dot_mat

	# Add to scene root so it stays in world space
	attacker.get_tree().current_scene.add_child(_dot)
	_update_dot_position(attacker)


func _update_dot_position(attacker: Node3D) -> void:
	if not is_instance_valid(_dot) or not _dot.is_inside_tree():
		return
	var aim := Combat.get_aim(attacker)
	var excludes := Combat.collect_hitscan_excludes(attacker)
	var ray := Combat.raycast_world(attacker, aim.from, aim.aim_dir, RANGE, RID(),
		GameConsts.MASK_HITSCAN, true, excludes)

	if not ray.result.is_empty():
		var n = ray.result.normal
		var up := GeomUtil.safe_up(n, Vector3.RIGHT)
		var tangent = n.cross(up).normalized()
		var bitangent = tangent.cross(n)
		
		_dot.global_position = ray.result.position
		# Basis: Y is normal (projection axis), X and Z are tangent/bitangent
		_dot.global_transform.basis = Basis(tangent * 0.3, n * 0.4, bitangent * 0.3)
		_dot.visible = true
	else:
		_dot.global_position = ray.to
		_dot.visible = false


func _cleanup_dot() -> void:
	if is_instance_valid(_dot):
		_dot.queue_free()
	_dot = null
	_dot_mat = null


func _stop_crackle(attacker: Node3D) -> void:
	_crackle_started = false
	var snd := attacker.get_node_or_null("SpotboltCrackle")
	if snd:
		snd.queue_free()
