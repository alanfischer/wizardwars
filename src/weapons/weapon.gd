class_name Weapon
extends Resource

const Movement = preload("res://addons/pmove/movement.gd")

## How far off a wall a pellet still reaches a body, for the shotgun's second pass at a shot
## that hit geometry instead of a hitbox.
const SPLASH_REACH := 0.8

@export var element: int = GameConsts.Element.FIRE
@export var hand_model_path := ""
@export var hand_idle_anim := ""
@export var hand_attack_anims: Array[String] = []  # miss/swing
@export var hand_hit_anims: Array[String] = []     # hit something
@export var player_attack_prefix := ""
@export var cooldown := 1.0
@export var mana_cost := 0.0       # one-time mana cost on fire (0 = free, e.g. staves)
@export var mana_drain := 0.0      # per-second mana drain for sustained weapons (rays, levitate)

var supports_charging := false

## Preferred engagement distance for AI bots (metres); 0 = bots won't use this in combat.
var bot_range := 0.0

## Flight speed of what this weapon throws (m/s), so a bot can aim where a moving target WILL be
## rather than where it is (BotBrain._lead_point). 0 = nothing to lead: a hitscan weapon, or a
## spell that homes and does its own chasing. Set it from the projectile's own speed constant —
## there is no second source of truth for it.
var bot_lead_speed := 0.0

## Display name shown in the weapon row HUD. If empty, derived from class name.
var weapon_name := ""

var auto_repeat := false
## True holds the attack anim (rays); false restarts it each fire (projectiles, AOE).
var sustained := false
var _auto_anim_held := false

func get_display_name() -> String:
	if not weapon_name.is_empty():
		return weapon_name
	var cn := str(get_script().get_global_name()).trim_suffix("Weapon")
	if cn.is_empty():
		return "Weapon"
	var result := ""
	for i in cn.length():
		var c := cn[i]
		if i > 0 and c >= "A" and c <= "Z":
			result += " "
		result += c
	return result


## state is the movement state going into this tick, for a contribution that depends on it.
func contribute_modifiers(_mods: Movement.MovementModifiers, _cmd, _state: Movement.MovementState) -> void:
	pass

func contribute_input_flags(_cmd) -> void:
	pass

## False suppresses the fire entirely — no mana spent, fire() never called.
func can_fire(_attacker: Node3D, _aim_dir: Vector3 = Vector3.ZERO) -> bool:
	return true

## Checked before can_fire() and before mana_cost is deducted; override for casts cheaper than mana_cost (e.g. Thornplant healing with leftover mana).
func min_mana_to_fire(_attacker: Node3D, _aim_dir: Vector3 = Vector3.ZERO) -> float:
	return mana_cost

## Override alongside min_mana_to_fire() when a weapon's cost varies per cast.
func actual_mana_cost(_attacker: Node3D) -> float:
	return mana_cost

func begin_charge(_attacker: Node3D) -> void: pass
func update_charge(_attacker: Node3D, _delta: float) -> void: pass
func release_charge(_attacker: Node3D) -> float: return 0.0
func cancel_charge(_attacker: Node3D) -> void: pass

## Server owns the charge timer (ChargeBehavior.tick); client-side charge is predictive only. 0 = never backfires.
func overcharge_time() -> float: return 0.0
func backfire_damage() -> float: return 0.0
func backfire_damage_type() -> int: return GameConsts.DamageType.PHYSICAL
func charge_percent_at(_elapsed: float) -> float: return 0.0
func stop_firing(_attacker: Node3D, _secondary: bool = false) -> void:
	_auto_anim_held = false
func cleanup(_attacker: Node3D) -> void: pass
func precache() -> void:
	pass


func get_hand_attack_anim() -> String:
	if hand_attack_anims.is_empty():
		return ""
	return hand_attack_anims[randi() % hand_attack_anims.size()]


func get_hand_hit_anim() -> String:
	if hand_hit_anims.is_empty():
		return ""
	return hand_hit_anims[randi() % hand_hit_anims.size()]


func is_attack_anim(anim_name: String) -> bool:
	return anim_name in hand_attack_anims or anim_name in hand_hit_anims


func get_attack_anim(crouched: bool) -> String:
	if crouched:
		return "crouch_shoot_%s" % player_attack_prefix
	return "ref_shoot_%s" % player_attack_prefix


func play_attack_anim(anim_player: AnimationPlayer) -> void:
	if not anim_player:
		return
	var anim := get_hand_attack_anim()
	if anim_player.has_animation(anim):
		if auto_repeat and sustained:
			if anim_player.current_animation == anim or (not anim_player.is_playing() and _auto_anim_held):
				return
			_auto_anim_held = true
		var anim_res := anim_player.get_animation(anim)
		anim_res.loop_mode = Animation.LOOP_NONE
		anim_player.stop()
		anim_player.play(anim)


func play_attack_sound(_attacker: Node3D) -> void:
	pass


## False for the host's own hidden puppet, which already renders its own 1P cosmetics — avoids doubling sound/anim/beams.
func _fire_cosmetics(attacker: Node3D) -> bool:
	return not (attacker is RemotePlayer and attacker.peer_id == NetworkManager.multiplayer.get_unique_id())


## Whether this fire builds a straight-flying projectile: the real one, or the shooter's stand-in.
func _fires_projectile(attacker: Node3D) -> bool:
	return NetworkManager.is_authoritative_fire(attacker) or ProjectileStandIn.wanted(attacker)


## A straight-flying projectile, which the shooter's own client draws as a ProjectileStandIn until
## the server's copy can be drawn. The copy carries the firing command so the client can pair them.
func _fire_projectile(attacker: Node3D, script_path: String, data: Dictionary) -> void:
	if ProjectileStandIn.wanted(attacker):
		ProjectileStandIn.spawn(script_path, data, attacker)
		return
	# A client's shot only: the host and bots have no stand-in to pair it with.
	if attacker is RemotePlayer and attacker.shot_seq != 0 and attacker.peer_id > 0 \
			and _fire_cosmetics(attacker):
		data["owner_peer_id"] = attacker.peer_id
		data["shot_seq"] = attacker.shot_seq
	NetworkManager.spawn_projectile(script_path, data, attacker, attacker.get_rid())


func _fire_tail(attacker: Node3D) -> void:
	if not _fire_cosmetics(attacker):
		return
	play_attack_sound(attacker)
	var anim_player: AnimationPlayer = attacker.get("_hand_anim_player")
	if anim_player:
		play_attack_anim(anim_player)


## Spread-cone hitscan pellets with tracer beams, used by thornblast/pebbleblast/etc.
func _fire_shotgun_blast(attacker: Node3D, aim_from: Vector3, aim_dir: Vector3,
		pellet_count: int, spread: float, fire_range: float,
		pellet_damage: float, beam_color: Color, hand_offset: float = 0.3) -> void:
	var aim := Combat.get_aim(attacker, aim_from, aim_dir)

	var axes := GeomUtil.perpendicular_axes(aim.aim_dir)
	var right: Vector3 = axes[0]
	var up: Vector3 = axes[1]

	var scene_root := attacker.get_tree().current_scene

	var hand_right: Vector3 = aim.aim_dir.cross(Vector3.UP).normalized()
	var hand_pos: Vector3 = aim.from + aim.aim_dir * 1.0 - hand_right * hand_offset + Vector3(0, -0.3, 0)

	var excludes := Combat.collect_hitscan_excludes(attacker)
	var cosmetics := _fire_cosmetics(attacker)
	for i in pellet_count:
		var spread_r := randf_range(-spread, spread)
		var spread_u := randf_range(-spread, spread)
		var pellet_dir = (aim.aim_dir + right * spread_r + up * spread_u).normalized()

		var ray := Combat.hitscan(attacker, aim.from, pellet_dir, fire_range, RID(),
			GameConsts.MASK_HITSCAN, true, excludes)

		if scene_root and cosmetics:
			BeamSystem.create_oneshot(scene_root, hand_pos, ray.impact_pos, {
				"color": beam_color,
				"width": 0.06,
				"fade_time": 0.3,
			})

		if NetworkManager.is_authoritative_fire(attacker) and not ray.result.is_empty():
			var hit := Combat.apply_hitscan_damage(ray, pellet_damage, GameConsts.DamageType.PHYSICAL, attacker)
			if not hit:
				# Nudge off the wall along its normal — an embedded LOS ray reports blocked even past it.
				var los_from: Vector3 = ray.impact_pos + ray.impact_norm * 0.05
				for node in SpatialQuery.nodes_near(&"damageable", ray.impact_pos, SPLASH_REACH):
					if node == attacker:
						continue
					var center: Vector3 = SpatialQuery.collision_center(node)
					if ray.impact_pos.distance_to(center) > SPLASH_REACH:
						continue
					if Combat.los_blocked(ray.space, los_from, node):
						continue
					node.take_damage(pellet_damage, GameConsts.DamageType.PHYSICAL, attacker)
					break

	_fire_tail(attacker)


func fire(_attacker: Node3D, _aim_from: Vector3 = Vector3.INF, _aim_dir: Vector3 = Vector3.ZERO, _charge_percent: float = 0.0, _secondary: bool = false) -> bool:
	return false
