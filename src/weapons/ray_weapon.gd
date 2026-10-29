class_name RayWeapon
extends Weapon

## Base class for sustained hitscan beam weapons (freeze ray, death ray, life ray) — dual-layer
## beam visuals (noisy outer + straight inner core), per-frame tracking, and cleanup.
## Subclasses override beam colors and implement fire().

const RANGE := 12.5             # 500 GS * 0.025

const BEAM_BONE := "Bip01 L Finger12"  # GoldSrc attachment point on the hand model
const BEAM_BONE_FALLBACK := "Bip01 L Finger1"

const BEAM_SEGMENTS := 16
const OUTER_WIDTH := 0.12
## Wide enough that the glow pass, which works off downsampled copies of the screen, still finds
## the core at range — at the old 0.025 the beam was a pixel or two and washed out of the bloom
## buffer entirely, which is why only the impact end ever glowed.
const INNER_WIDTH := 0.045
const NOISE_AMPLITUDE := 0.06   # max perpendicular offset for outer beam noise
const EFFECT_OFFSET := 0.1

# managed by BeamSystem
var _outer_beam_id := -1
var _inner_beam_id := -1
var _noise_offset := 0.0
var _attacker: Node3D
var _beam_connected := false


func _init() -> void:
	auto_repeat = true
	sustained = true
	bot_range = RANGE  # bots pulse the beam at medium range (each fire() is one damage tick)


func _get_outer_beam_color() -> Color:
	return Color(1.0, 1.0, 1.0, 0.8)


## Full white at full alpha on purpose: additive blending scales the source by alpha before adding,
## so the old 0.8 grey at 0.9 alpha topped out at 0.72 and never reached the glow threshold. The
## weapon's own colour comes from the outer beam, which this core sits inside.
func _get_inner_beam_color() -> Color:
	return Color(1.0, 1.0, 1.0, 1.0)


## Call from subclass stop_firing() after stopping sound.
func _stop_beam(attacker: Node3D, end_anim: String) -> void:
	_auto_anim_held = false
	_disconnect_beam_update()
	_destroy_beams()
	var anim_player: AnimationPlayer = attacker.get("_hand_anim_player")
	if anim_player and anim_player.has_animation(end_anim):
		anim_player.play(end_anim)


## Authority-only; never called with the caster as target. damage_mult is 2.0 on a head hitbox, else 1.0.
func _apply_ray_hit(_ray_attacker: Node3D, _target: Node, _damage_mult: float = 1.0) -> void:
	pass


## Walk up from a hitscan collider (usually a per-bone hitbox Area3D) to the body that takes the
## hit. Null for world geometry, and null for the caster's own bodies: a beam never touches the
## wizard casting it, whether it damages, freezes or heals. Only the death ray feeds its owner,
## and it does that from the drain, not from a hit on itself.
func _resolve_ray_target(attacker: Node3D, collider: Node) -> Node:
	var target := Combat.find_damageable(collider)
	if target == null or Teams.is_same_player(attacker, target):
		return null
	return target


func _fire_ray(attacker: Node3D, aim_from: Vector3, aim_dir: Vector3,
		hit_color: Color, particle_type: String) -> void:
	var aim := Combat.get_aim(attacker, aim_from, aim_dir)
	var excludes := Combat.collect_hitscan_excludes(attacker)
	var ray := Combat.hitscan(attacker, aim.from, aim.aim_dir, RANGE, RID(),
		GameConsts.MASK_HITSCAN, true, excludes)

	if NetworkManager.is_authoritative_fire(attacker):
		if not ray.result.is_empty():
			var collider: Node = ray.result.collider
			var damage_mult := 1.0
			if collider and collider.has_meta("hitbox_group"):
				if int(collider.get_meta("hitbox_group")) == GameConsts.HITBOX_GROUP_HEAD:
					damage_mult = GameConsts.HEADSHOT_MULT
			var target := _resolve_ray_target(attacker, collider)
			if target:
				_apply_ray_hit(attacker, target, damage_mult)

		var scene_root := attacker.get_tree().current_scene
		var effect := RayHitEffect.spawn(scene_root, ray.impact_pos + ray.impact_norm * EFFECT_OFFSET, hit_color, particle_type)
		NetworkManager.register_effect(effect, "res://src/effects/ray_hit_effect.gd",
			{"light_color": hit_color, "particle_type": particle_type})

	_fire_beam(attacker)


## Call from subclass fire() after damage/effects to set up beam visuals.
func _fire_beam(attacker: Node3D) -> void:
	# host's own hidden puppet skips the tracked beam; its 1P view draws its own cosmetic one
	if not _fire_cosmetics(attacker):
		return
	_attacker = attacker
	_ensure_beams()
	_refresh_beam()
	_connect_beam_update()
	_fire_tail(attacker)


func _ensure_beams() -> void:
	if _outer_beam_id >= 0:
		return
	var scene_root := _attacker.get_tree().current_scene
	if not scene_root:
		return
	
	var parent := BoneUtil.get_bone_attachment(_attacker, BEAM_BONE, BEAM_BONE_FALLBACK)
	var noise_fn := func(t: float) -> Vector3:
		var cam := _attacker.get_viewport().get_camera_3d() if is_instance_valid(_attacker) else null
		if not cam or not is_instance_valid(parent):
			return Vector3.ZERO
		# Convert world-space camera up into local space of the attachment
		var world_up := cam.global_transform.basis.y
		var local_up := parent.global_transform.basis.inverse() * world_up
		var noise_phase := t * 8.0 + _noise_offset
		var noise_val: float = sin(noise_phase) * NOISE_AMPLITUDE * (1.0 - abs(t * 2.0 - 1.0))
		return local_up * noise_val
	
	_outer_beam_id = BeamSystem.create_tracked(parent, Vector3.ZERO, Vector3.ZERO, {
		"color": _get_outer_beam_color(),
		"width": OUTER_WIDTH,
		"segments": BEAM_SEGMENTS,
		"noise_fn": noise_fn,
		"camera_aligned": true,
		"use_local_space": true,
	})
	_inner_beam_id = BeamSystem.create_tracked(parent, Vector3.ZERO, Vector3.ZERO, {
		"color": _get_inner_beam_color(),
		"width": INNER_WIDTH,
		"segments": BEAM_SEGMENTS,
		"camera_aligned": true,
		"use_local_space": true,
	})


func _connect_beam_update() -> void:
	if _beam_connected:
		return
	if not _attacker or not is_instance_valid(_attacker):
		return
	var tree := _attacker.get_tree()
	if tree:
		tree.process_frame.connect(_on_beam_frame)
		_beam_connected = true


func _disconnect_beam_update() -> void:
	if not _beam_connected:
		return
	if _attacker and is_instance_valid(_attacker):
		var tree := _attacker.get_tree()
		if tree and tree.process_frame.is_connected(_on_beam_frame):
			tree.process_frame.disconnect(_on_beam_frame)
	_beam_connected = false
	_attacker = null


func _on_beam_frame() -> void:
	# is_instance_valid stays true for a despawned-but-not-freed node; check is_inside_tree() too
	if not _attacker or not is_instance_valid(_attacker) or not _attacker.is_inside_tree():
		_disconnect_beam_update()
		_destroy_beams()
		return
	if _outer_beam_id < 0:
		return
	_refresh_beam()


func _refresh_beam() -> void:
	_noise_offset += 5.0 * _attacker.get_process_delta_time()
	var aim := Combat.get_aim(_attacker)
	var excludes := Combat.collect_hitscan_excludes(_attacker)
	var ray := Combat.hitscan(_attacker, aim.from, aim.aim_dir, RANGE, RID(),
		GameConsts.MASK_HITSCAN, true, excludes)
	
	BeamSystem.update(_outer_beam_id, Vector3.ZERO, ray.impact_pos)
	BeamSystem.update(_inner_beam_id, Vector3.ZERO, ray.impact_pos)


func _destroy_beams() -> void:
	if _outer_beam_id >= 0:
		BeamSystem.destroy(_outer_beam_id)
		_outer_beam_id = -1
	if _inner_beam_id >= 0:
		BeamSystem.destroy(_inner_beam_id)
		_inner_beam_id = -1
