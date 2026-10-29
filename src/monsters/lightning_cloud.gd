class_name LightningCloud
extends Projectile

## Lightning cloud summon — the Wizard Wars combo spell "weapon_lightningcloudspell". A slow
## thundercloud that drifts away from the caster in a dead straight line, forever, snapping at
## whichever enemy it can see for 80 every half second.
##
## It does not hunt. Where you aim it is where it goes, so it is artillery rather than a summon:
## sent down a corridor or across a courtyard it holds that ground and shocks anyone who comes
## into view of it. The only thing that stops one is running into something — the first solid
## surface or body it touches takes 600 and the cloud goes with it.

const SCALE := GameConsts.SCALE_FACTOR
const SPEED := 8.0 * 0.4               # sv_maxspeed * LIGHTNINGCLOUD_VELOCITY — 3.2 m/s
const ZAP_DAMAGE := 80.0
const ZAP_RANGE := 700.0 * SCALE       # 17.5 m
const ZAP_INTERVAL := 0.5
const FIRST_ZAP := 1.0                 # it takes a second to build up to the first one
const TOUCH_DAMAGE := 600.0
const THINK_INTERVAL := 0.1
## The original had no lifetime at all — a cloud that met nothing simply flew on. Ours needs a
## backstop, so this is one map's width at the cloud's own speed rather than a balance number.
const MAX_LIFETIME := 64.0
const SPRITE := "sprites/poison.spr"
const SPRITE_SCALE := 2.0              # pev->scale 2
const SPRITE_FPS := 10.0               # one frame per think, as the original stepped it
const ZAP_SOUND := "spells/combos/lightningcloud_zap.wav"
const BEAM_COLOR := Color(0.6, 0.75, 1.0, 1.0)
const BEAM_WIDTH := 0.05
const BEAM_SEGMENTS := 10
const BEAM_JITTER := 0.35
const BEAM_FADE := 0.3

var _think_timer := THINK_INTERVAL
var _zap_timer := FIRST_ZAP
var _spent := false


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
		var sap = sprite.get_node_or_null(^"SpriteAnimationPlayer")
		if sap:
			sap.fps = SPRITE_FPS
			sap.loop_animation = true
		var mat := AssetLoader.get_sprite_material_template().duplicate()
		if sprite.texture:
			mat.albedo_texture = sprite.texture
		sprite.material_override = mat
		add_child(sprite)

	_create_light(Color(0.5, 0.6, 1.0), 2.0, 4.0)


func _host_physics(delta: float) -> void:
	# It outlives its caster, so a freed owner must not reach target filtering or damage credit.
	if not is_instance_valid(owner_node):
		owner_node = null

	_age += delta
	if _age >= MAX_LIFETIME:
		_die()
		return

	_zap_timer -= delta
	_think_timer -= delta
	if _think_timer <= 0.0:
		_think_timer = THINK_INTERVAL
		if _zap_timer <= 0.0:
			_zap_timer = ZAP_INTERVAL
			_zap()

	# Straight on, into whatever is in the way. Both halves of the contact test, as every
	# projectile here does it: the swept ray for world geometry, the segment sweep for bodies.
	var result := _trace_step(delta)
	if not result.is_empty():
		global_position = result.position
		_burst(result.collider)
		return
	var victim := _player_contact(_step_from, _step_to)
	if victim != null:
		global_position = SpatialQuery.collision_center(victim)
		_burst(victim)
		return
	global_position = _step_to


## The half-second snap: the nearest enemy it can actually see, shocked wherever they stand.
## No falloff and nothing to dodge — being in the open in front of one is the whole cost.
func _zap() -> void:
	var target := Combat.find_homing_target(self, owner_node, team, ZAP_RANGE,
			RID(), global_position)
	if target == null:
		return
	var hit: Vector3 = SpatialQuery.collision_center(target)
	if target.has_method("take_damage"):
		target.take_damage(ZAP_DAMAGE, GameConsts.DamageType.LIGHTNING, owner_node)
	_show_zap(hit)
	SoundSystem.play_3d(ZAP_SOUND, global_position, 1.0, 0.0, 30.0)
	if _entity_id >= 0 and NetworkManager.is_online():
		NetworkManager.sync_entity_event.rpc(_entity_id, {"zap": hit})


## Everything it runs into takes 600 and it goes out with them — including a teammate who walks
## through it, who takes nothing (the target rejects friendly fire) but pops the cloud all the
## same. That is the original's bargain: aim it down an empty lane or lose it to your own side.
func _burst(struck: Object) -> void:
	if _spent:
		return
	_spent = true
	if struck != null and struck.has_method("take_damage"):
		struck.take_damage(TOUCH_DAMAGE, GameConsts.DamageType.LIGHTNING, owner_node)
	var pos := global_position
	_show_burst(pos)
	if _entity_id >= 0 and NetworkManager.is_online():
		NetworkManager.sync_entity_event.rpc(_entity_id, {"burst": pos})
	_die()


## Zap and burst are one-shot events, not properties that converge — a zap landing between two
## acks would simply be lost if it rode the synchronizer. Unreliable, as the original's TE_BEAMENTS
## zap was (MSG_PAS); the burst is the port's own.
func _apply_sync_state(state: Dictionary) -> void:
	if "zap" in state:
		_show_zap(state.zap)
	if "burst" in state:
		_show_burst(state.burst)


func _show_zap(hit: Vector3) -> void:
	if not is_instance_valid(_scene_root):
		return
	BeamSystem.create_oneshot(_scene_root, global_position, hit, {
		"color": BEAM_COLOR,
		"width": BEAM_WIDTH,
		"segments": BEAM_SEGMENTS,
		"noise_fn": _bolt_noise(),
		"fade_time": BEAM_FADE,
	})
	LightningZapEffect.spawn(_scene_root, hit)


func _show_burst(pos: Vector3) -> void:
	if is_instance_valid(_scene_root):
		ExplosionEffect.spawn(_scene_root, pos, false, ExplosionEffect.DEFAULT_SPR,
			Color(0.55, 0.65, 1.0), ExplosionEffect.DEFAULT_SOUND, 1.5)


## Fixed per-segment jitter, sampled by BeamSystem along the bolt — the same shape the spotbolt
## strike uses, scattered in every direction because these run flat rather than down from a sky.
func _bolt_noise() -> Callable:
	var offsets: Array[Vector3] = []
	offsets.resize(BEAM_SEGMENTS + 1)
	offsets[0] = Vector3.ZERO
	offsets[BEAM_SEGMENTS] = Vector3.ZERO
	for i in range(1, BEAM_SEGMENTS):
		offsets[i] = Vector3(
			randf_range(-BEAM_JITTER, BEAM_JITTER),
			randf_range(-BEAM_JITTER, BEAM_JITTER),
			randf_range(-BEAM_JITTER, BEAM_JITTER))
	return func(t: float) -> Vector3:
		return offsets[clampi(int(t * BEAM_SEGMENTS), 0, BEAM_SEGMENTS)]

