class_name Bird
extends Projectile

## Homing bird for the earth wizard — faster than skull, weaker homing, direct-hit only (no AoE).
##
## A bird that spends itself on a body, or runs out of life, climbs away and fades out. A bird
## that runs into world geometry dies there and leaves a body that falls.

const SPEED := 12.5            # 500 GS * 0.025
const TURN_SPEED := 150.0      # deg/s
const SEARCH_RADIUS := 12.8    # 512 GS * 0.025
const LIFE_NO_TARGET := 2.0    # seconds before expiry with no lock
const LIFE_TOTAL := 7.0        # max lifetime from birth (even if hunting)
const ESCAPE_TURN := 120.0     # deg/s toward straight up
const ESCAPE_SPEED := 1.4      # climb speed multiplier
const DAMAGE := 20.0
const THINK_INTERVAL := 0.2    # target search tick (slower than skull)
const FADE_TIME := 1.6         # seconds to fade out while climbing away
const PROJECTILE_HP := 20.0
const MODEL := "models/npc/bird.mdl"
const MODEL_YAW := PI * 0.5    # the .mdl faces +X; see reference on GoldSrc model facing
## What is left of a bird that took a big enough hit — see _shot_down. A bird's worth of
## debris, which is barely any: five pieces inside half a metre. It bursts with the same flesh
## and the same squelch every other body does (GibEffect.FLESH_BURST_SOUND), there being no
## bird death sound in the assets.
const GIB_EXTENT := Vector3(0.4, 0.4, 0.4)
const GIB_COUNT := 5

var _health := HealthBehavior.new()
var _homing := HomingBehavior.new()
var _lifetime := LIFE_NO_TARGET
var _escaping := false
var _dropped := false
var _model: Node3D


func setup(data: Dictionary, is_host := true) -> void:
	speed = SPEED
	super(data, is_host)
	_health.initialize(self, PROJECTILE_HP, is_host, _shot_down)
	add_to_group("unhunted")  # shot down, never aimed at — Combat.find_homing_target
	_homing.initialize(self, team, _on_target_acquired)
	_homing.search_radius = SEARCH_RADIUS
	_homing.turn_speed = TURN_SPEED
	_homing.think_interval = THINK_INTERVAL
	contact_radius = 0.8


func _ready() -> void:
	_orient_to_direction()

	_model = AssetLoader.load_model(MODEL)
	if _model:
		_model.rotation.y = MODEL_YAW
		add_child(_model)
		var anim_player: AnimationPlayer = _model.find_child("AnimationPlayer")
		if anim_player:
			var anims := anim_player.get_animation_list()
			if anims.size() > 0:
				var anim_res := anim_player.get_animation(anims[0])
				anim_res.loop_mode = Animation.LOOP_LINEAR
				anim_player.play(anims[0])

	if _is_host:
		_register_entity({
			"script_path": "res://src/projectiles/bird.gd",
			"position": position,
			"direction": direction,
			"team": team,
		})


func _physics_process(delta: float) -> void:
	var age = _age
	_age += delta
	if age < _lifetime and _age >= _lifetime:
		_begin_escape()

	if _is_host:
		_forget_freed_owner()
		if _process_pending_death(delta):
			return
		_host_physics(delta)
	_orient_to_direction()


## _age is advanced by _physics_process above, which owns the escape, so this flies the sweep
## half of _fly_step only.
func _host_physics(delta: float) -> void:
	if _escaping:
		direction = _steer_to_sky(delta)
		global_position += direction * speed * delta
		return
	direction = _homing.steer(direction, delta)
	_sweep_and_advance(delta)


## The bird is done — it spent its hit, or it ran out of life with nothing to chase — so it
## climbs away, fading as it goes. On its way out it is scenery: it touches nothing and
## nothing touches it, it just thins out until there is nothing left.
func _begin_escape() -> void:
	if _escaping:
		return
	_escaping = true
	_homing.target = null
	speed = SPEED * ESCAPE_SPEED
	remove_from_group("damageable")
	var tween := create_tween()
	tween.tween_method(func(alpha): AssetLoader.set_model_alpha(_model, alpha), 1.0, 0.0, FADE_TIME)
	tween.tween_callback(_perform_die)


## Flew into a wall, which is the end of the bird: it dies where it struck and what is left of
## it drops off the surface and falls. The flight pose goes with it, so the corpse can build a
## ragdoll on the bird's own rig and fold up on the way down (TumblingCorpse.spawn).
func _drop(normal: Vector3) -> void:
	if _dropped:
		return
	_dropped = true
	var pose := RagdollBuilder.capture_pose(RagdollBuilder.find_skeleton(_model)) if _model \
		else PackedFloat32Array()
	# A corpse is built upright, so the heading the bird was flying has to be handed over on
	# top of the model's own facing correction — the flight pitch is about to be the fall's.
	var yaw := atan2(-direction.x, -direction.z) + MODEL_YAW
	TumblingCorpse.spawn_deflected(MODEL, global_position, direction, SPEED, normal, yaw, pose)
	_perform_die()


func _steer_to_sky(delta: float) -> Vector3:
	var angle := direction.angle_to(Vector3.UP)
	if angle <= 0.001:
		return Vector3.UP
	var max_turn := deg_to_rad(ESCAPE_TURN) * delta
	return direction.slerp(Vector3.UP, clampf(max_turn / angle, 0.0, 1.0)).normalized()


## A wall is not a body, so the bird breaks against it rather than spending itself on it.
func _on_world_hit(result: Dictionary) -> void:
	_drop(result.get("normal", Vector3.UP))


## Any live body ends the bird's hunt, whether it had anything to take or not — a teammate
## body-blocks it exactly as they body-block a skull, take_damage refusing the hit and the
## bird leaving as though it had landed one.
func _on_actor_hit(victim) -> void:
	victim.take_damage(DAMAGE, GameConsts.DamageType.PHYSICAL, owner_node)
	_begin_escape()


func _on_target_acquired() -> void:
	_lifetime = LIFE_TOTAL  # measured from birth (_age), not from now


func take_damage(amount: float, _type: int = 0, attacker: Node3D = null) -> void:
	if _escaping:
		return
	_health.take_damage(amount, _type, attacker)


## Shot out of the air. Hooked on the health behaviour rather than on `_die` so it answers for
## the damage death alone: a bird that flies into a wall leaves a body (_drop) and one that
## simply runs out of life climbs away, and neither of those is this.
##
## What it leaves follows the rule every other death follows — a blow over
## GameConsts.GIB_DAMAGE bursts it. Under that it still just stops, because there is nothing
## left of a bird to fall: the corpse it would drop is the one _drop already builds, and a bird
## picked off mid-flight is more often than not nowhere near a surface to fall against.
func _shot_down() -> void:
	if GameConsts.damage_gibs(_health.last_damage):
		_burst()
	_die()


## Split out so a test can watch it: a burst is headless-guarded and leaves nothing behind to
## look at afterwards, the whole point of it being a one-shot.
func _burst() -> void:
	GibEffect.burst(global_position, GibEffect.MAT_FLESH, GIB_EXTENT, GIB_COUNT,
		GibEffect.FLESH_BURST_SOUND, get_tree().current_scene)
