class_name BallLightning
extends Projectile

## Ball lightning summon — the second half of the Wizard Wars combo spell
## "weapon_balllightningspell". Left standing where the cast's bolt landed.
##
## Every think it takes the nearest enemy it can see and drifts at it, killing on contact. With
## nobody in sight it wanders the room instead of parking in the crater — a slow, curving drift
## that turns off walls and keeps roughly to the height it was left at, so it goes looking rather
## than waiting to be walked into. The 30s clock is what ends it.

const SCALE := GameConsts.SCALE_FACTOR
const SPEED := 8.0 * 0.8               # sv_maxspeed * BALLLIGHTNING_VELOCITY — 6.4 m/s
const DAMAGE := 600.0
const MAX_LIFETIME := 30.0
const SIGHT_RANGE := 1024.0 * SCALE    # 25.6 m
const HIT_RADIUS := 0.75
const WALL_CLEARANCE := 0.3            # how far off a surface it stops, same as the cast leaves it
const THINK_INTERVAL := 0.1
const WANDER_SPEED := SPEED * 0.45     # an idle drift, not a charge — it still lunges at prey
const WANDER_TURN := 1.4               # per second, how fast the drift swings onto its new heading
const WANDER_HOLD_MIN := 0.7           # and how long it holds one before picking another
const WANDER_HOLD_MAX := 1.8
const WANDER_SWING := 0.7              # how far off the current heading a new one is allowed to sit
const WANDER_RISE := 0.25              # vertical share of any heading, so it hovers rather than climbs
const WANDER_PROBE := 1.8              # it starts turning off a wall this far out
const WANDER_VEER := 0.35              # and turns this hard when it does, rather than easing round
const SPRITE := "sprites/enter1.spr"
const SPRITE_SCALE := 2.0              # pev->scale 2
const SPRITE_FPS := 10.0               # one frame per think, as the original stepped it
const ALPHA := 160.0 / 255.0           # renderamt 160, additive

var _target: Node3D
var _think_timer := THINK_INTERVAL
var _struck := false
var _drift := Vector3.FORWARD       # the heading it is actually on
var _drift_goal := Vector3.FORWARD  # the one it is turning onto
var _drift_hold := 0.0


func setup(data: Dictionary, is_host := true) -> void:
	speed = SPEED
	lifetime = MAX_LIFETIME
	super(data, is_host)


func _ready() -> void:
	_scene_root = get_tree().current_scene

	var sprite := AssetLoader.load_sprite_node(SPRITE)
	if sprite:
		sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		sprite.pixel_size = GameConsts.SCALE_FACTOR * SPRITE_SCALE
		sprite.transparent = true
		sprite.modulate.a = ALPHA
		var sap = sprite.get_node_or_null(^"SpriteAnimationPlayer")
		if sap:
			sap.fps = SPRITE_FPS
			sap.loop_animation = true
		var mat := AssetLoader.get_sprite_material_template().duplicate()
		if sprite.texture:
			mat.albedo_texture = sprite.texture
		sprite.material_override = mat
		add_child(sprite)

	_create_light(Color(0.8, 0.5, 1.0), 3.0, 5.0)

	# It starts out drifting the way the bolt was cast, then wanders off that.
	_drift = _flatten(direction)
	_pick_drift()


func _host_physics(delta: float) -> void:
	# It outlives its caster: a freed owner must not reach target filtering or damage credit.
	if not is_instance_valid(owner_node):
		owner_node = null

	_age += delta
	if _age >= MAX_LIFETIME:
		_die()
		return

	_think_timer -= delta
	if _think_timer <= 0.0:
		_think_timer = THINK_INTERVAL
		_target = Combat.find_homing_target(self, owner_node, team, SIGHT_RANGE,
				RID(), global_position)

	var hunting := is_instance_valid(_target) and _target.is_inside_tree()
	if hunting:
		var to_target := SpatialQuery.collision_center(_target) - global_position
		if to_target.length_squared() > 0.0001:
			direction = to_target.normalized()

	# Prey is a straight charge; with nobody in sight it wanders, and takes whoever it meets.
	var step := direction * speed * delta if hunting else _wander_step(delta)
	var victim := _enemy_contact(global_position, global_position + step)
	if victim:
		global_position = SpatialQuery.collision_center(victim)
		_strike(victim)
		return
	_advance(step)


## This frame's idle drift. The heading eases onto a goal that is re-rolled every second or
## two and shoved aside by anything the ball is about to run into, which is what makes the path
## curve instead of shuttling between walls.
func _wander_step(delta: float) -> Vector3:
	_drift_hold -= delta
	if _drift_hold <= 0.0:
		_pick_drift()
	_veer_off_walls()
	_drift = _turn_toward(_drift, _drift_goal, minf(WANDER_TURN * delta, 1.0))
	direction = _drift
	return _drift * WANDER_SPEED * delta


## Roll the next heading, off the current one rather than anywhere at all — a ball that picked
## a fresh random direction every second would jitter in place instead of going anywhere.
func _pick_drift() -> void:
	_drift_hold = randf_range(WANDER_HOLD_MIN, WANDER_HOLD_MAX)
	var swing := Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), randf_range(-1.0, 1.0))
	_drift_goal = _flatten(_drift + swing * WANDER_SWING)


## Turn the goal away from whatever the drift is about to meet, and take part of that turn
## immediately: easing round at the usual rate would bury it in the wall first.
func _veer_off_walls() -> void:
	var params := PhysicsRayQueryParameters3D.create(global_position,
			global_position + _drift * WANDER_PROBE)
	params.collision_mask = GameConsts.MASK_WORLD | GameConsts.MASK_ENTITY
	var hit := get_world_3d().direct_space_state.intersect_ray(params)
	if hit.is_empty():
		return
	# Slide along the surface, pushed off it — head-on, the slide cancels and it turns back.
	var normal: Vector3 = hit.normal
	_drift_goal = _flatten(_drift.slide(normal) + normal)
	_drift = _turn_toward(_drift, _drift_goal, WANDER_VEER)
	_drift_hold = maxf(_drift_hold, WANDER_HOLD_MIN)


## Hold a heading near the horizontal: unchecked, a drift that caught an upward normal would
## climb to the ceiling and stay there.
func _flatten(v: Vector3) -> Vector3:
	var flat := Vector3(v.x, clampf(v.y, -WANDER_RISE, WANDER_RISE), v.z)
	if flat.length_squared() < 0.0001:
		return _drift
	return flat.normalized()


func _turn_toward(from: Vector3, to: Vector3, weight: float) -> Vector3:
	var blend := from.lerp(to, weight)
	return to if blend.length_squared() < 0.0001 else blend.normalized()


## Move by `step`, stopping just clear of anything solid in the way. Charging, it only moves at
## something it can see; wandering, _veer_off_walls has already turned it — so this is the last
## word on a corner clipped either way, not pathing.
func _advance(step: Vector3) -> void:
	var to := global_position + step
	var params := PhysicsRayQueryParameters3D.create(global_position, to)
	params.collision_mask = GameConsts.MASK_WORLD | GameConsts.MASK_ENTITY
	var hit := get_world_3d().direct_space_state.intersect_ray(params)
	if hit.is_empty():
		global_position = to
		return
	global_position = hit.position + (hit.normal as Vector3) * WALL_CLEARANCE


## The first enemy the ball's path touches this tick. Allies and the caster are passed straight
## through rather than spending it — the original only detonated on something it could hurt, and
## Projectile._player_contact stops at the first live body of any side.
func _enemy_contact(seg_from: Vector3, seg_to: Vector3) -> Node3D:
	for node in SpatialQuery.nodes_near_segment(&"damageable", seg_from, seg_to, HIT_RADIUS):
		if node == self or not is_instance_valid(node):
			continue
		if not node.is_inside_tree() or node.get("is_dead"):
			continue
		if Teams.summon_spares(team, owner_node, node):
			continue
		var center: Vector3 = SpatialQuery.collision_center(node)
		if GeomUtil.dist_to_segment(center, seg_from, seg_to) <= HIT_RADIUS:
			return node
	return null


## Fire, not lightning, exactly as the original wrote it — the ball's touch is DMG_BURN where
## the cast's bolt is DMG_SHOCK. 600 kills whatever it lands on outright, so the burn it leaves
## behind only ever matters on something that survives the hit.
func _strike(victim: Node3D) -> void:
	if _struck:
		return
	_struck = true
	if victim.has_method("take_damage"):
		victim.take_damage(DAMAGE, GameConsts.DamageType.FIRE, owner_node)
	if is_instance_valid(_scene_root):
		var effect := LightningZapEffect.spawn(_scene_root, global_position)
		NetworkManager.register_effect(effect, "res://src/effects/lightning_zap_effect.gd")
	_die()

