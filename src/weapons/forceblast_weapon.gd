class_name ForceBlastWeapon
extends Weapon

## Force Blast — AoE knockback centered on the caster: pushes enemies away + minor damage,
## and gives the caster a small kick along their current direction of travel (ww_forceblast.cpp).

const DAMAGE := 5.0
const RADIUS := 12.8
const STRENGTH := 50.0
const SELF_BOOST := 6.0
const COOLDOWN := 1.5
const MANA_COST := 5.0
## The fewest input ticks between two honoured kicks: a little under COOLDOWN, so every real cast
## counts while a client sending the flag on its own gets no more than one cast's worth.
const BOOST_MIN_TICKS := 80

## A cast whose kick hasn't gone out yet, and when it was cast: one that didn't make it into an
## input promptly (weapon switched away that tick) is dropped, not sent whenever this is next held.
var _boost_pending := false
var _boost_cast_ms := 0
const BOOST_PENDING_MS := 100
var _last_boost_seq := -BOOST_MIN_TICKS


## A player's kick rides their input (CMF_FORCEBLAST) rather than being added when the server's
## fire() runs: then their own prediction applies it on the same tick the server does, instead of
## getting it a round trip later as a correction.
func contribute_input_flags(cmd) -> void:
	if _boost_pending and Time.get_ticks_msec() - _boost_cast_ms <= BOOST_PENDING_MS:
		cmd.custom_flags |= GameConsts.CMF_FORCEBLAST
	_boost_pending = false


## Along the direction of travel going into the tick, as ww_forceblast.cpp does; nothing when
## barely moving.
func contribute_modifiers(mods: Movement.MovementModifiers, cmd, state: Movement.MovementState) -> void:
	if cmd.custom_flags & GameConsts.CMF_FORCEBLAST and cmd.seq - _last_boost_seq >= BOOST_MIN_TICKS:
		_last_boost_seq = cmd.seq
		if state.velocity.length() > 0.1:
			mods.velocity_add += state.velocity.normalized() * SELF_BOOST


func _init() -> void:
	cooldown = COOLDOWN
	mana_cost = MANA_COST


func precache() -> void:
	SoundSystem.precache("spells/forceblast.wav")

func play_attack_sound(attacker: Node3D) -> void:
	SoundSystem.spawn_on(attacker, "spells/forceblast.wav")


func fire(attacker: Node3D, _aim_from: Vector3 = Vector3.INF, _aim_dir: Vector3 = Vector3.ZERO, _charge_percent: float = 0.0, secondary: bool = false) -> bool:
	if secondary:
		return false
	var flash := OmniLight3D.new()
	flash.light_color = Color(0.8, 0.9, 1.0)  # cool white
	flash.light_energy = 3.0
	flash.omni_range = RADIUS
	flash.omni_attenuation = 2.0
	flash.shadow_enabled = false
	flash.light_cull_mask = GameConsts.LIGHT_CULL_ALL
	attacker.get_tree().current_scene.add_child(flash)
	flash.global_position = attacker.global_position + GameConsts.PLAYER_CENTER
	var tween := flash.create_tween()
	tween.tween_property(flash, "light_energy", 0.0, 0.3)
	tween.tween_callback(flash.queue_free)

	if attacker is LocalPlayer:
		_boost_pending = true  # the kick rides the next input; see contribute_input_flags
		_boost_cast_ms = Time.get_ticks_msec()

	if NetworkManager.is_authoritative_fire(attacker):
		var origin := attacker.global_position + GameConsts.PLAYER_CENTER
		var space := attacker.get_world_3d().direct_space_state

		# A bot (or anything else no client predicts) gets the kick directly; a player's comes
		# through their input, so adding it here too would double it.
		# (Offline, the local player is authoritative too — still a player, still through its input.)
		var is_player: bool = attacker is LocalPlayer or (attacker is RemotePlayer and attacker.peer_id > 0)
		if not is_player and attacker is CharacterBody3D and attacker.velocity.length() > 0.1:
			attacker.velocity += attacker.velocity.normalized() * SELF_BOOST

		var candidates := attacker.get_tree().get_nodes_in_group("damageable") + \
				attacker.get_tree().get_nodes_in_group("projectile")
		for node in candidates:
			if not node.is_inside_tree():
				continue
			# nodes_friendly() reports self as NOT friendly, so exclude the caster explicitly
			if Teams.is_same_player(attacker, node):
				continue
			if node.get("is_dead"):
				continue
			if Teams.nodes_friendly(attacker, node):
				continue
			if node is Cockleburr and node._attached:
				continue

			var is_damageable := node.is_in_group("damageable")
			var center: Vector3 = SpatialQuery.collision_center(node) if is_damageable else node.global_position
			var diff := center - origin
			var dist := diff.length()
			if dist > RADIUS or dist < 0.1:
				continue

			var params := PhysicsRayQueryParameters3D.create(origin, center)
			params.collision_mask = GameConsts.MASK_WORLD
			var exclude := [attacker.get_rid()]
			if node is PhysicsBody3D:
				exclude.append(node.get_rid())
			params.exclude = exclude
			if not space.intersect_ray(params).is_empty():
				continue

			var factor := 1.0 - dist / RADIUS
			var push_vel := diff.normalized() * STRENGTH * factor

			if node is CharacterBody3D:
				node.velocity += push_vel
			elif node is RigidBody3D:
				node.linear_velocity += push_vel
			elif node is Projectile:
				var vel: Vector3 = node.direction * node.speed + push_vel
				var new_speed := vel.length()
				if new_speed > 0.01:
					node.direction = vel / new_speed
					node.speed = new_speed

			if is_damageable and node.has_method("take_damage"):
				node.take_damage(DAMAGE, GameConsts.DamageType.PHYSICAL, attacker)

	_fire_tail(attacker)
	return true
