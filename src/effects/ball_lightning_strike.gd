class_name BallLightningStrike
extends Node3D

## The moment the ball lightning spell lands: a flash blown out of the impact point and four
## arcs of lightning thrown up and away from it, into the sky. Cosmetic only — the 500 damage
## and the ball itself are the weapon's business.

const SCALE := GameConsts.SCALE_FACTOR
const BOLTS := 4
const BOLT_RISE := 1024.0 * SCALE      # 25.6 m straight up
const BOLT_SPREAD := 1024.0 * SCALE    # and up to that far sideways, scattered per bolt
const BOLT_WIDTH := 0.19               # beam width 75, in GoldSrc tenths of a unit
const BOLT_NOISE := 1.5                # beam noise 60, likewise
const BOLT_SEGMENTS := 12
const FADE_TIME := 1.0                 # beam life 10 = one second
## A real explosion sheet, not the ball's own sprite blown up large — scaled up, that just
## read as a giant ball of lightning sitting in the crater.
const BURST_SPRITE := "sprites/zerogxplode.spr"
const SPRITE_SCALE := 5.0
const SPRITE_FPS := 15.0
## Expanding ring under the blast, in the same violet as the arcs — what carries the shock
## through a burst whose sheet is a fireball.
const RING_COLOR := Color(0.75, 0.4, 1.0, 0.8)
const RING_EXPAND := 10.0
const RING_TIME := 0.45

var _effect := EffectBehavior.new()


## Spawned through the dynamic-entity spawner rather than register_effect: the bolts are
## parented to the scene root, so they need the node to exist on every peer (as SpotBoltStrike).
static func summon(pos: Vector3) -> void:
	NetworkManager.spawn_dynamic_entity({
		"script_path": "res://src/effects/ball_lightning_strike.gd",
		"position": pos,
	})


func setup(data: Dictionary, _is_host: bool = false) -> void:
	position = data.get("position", Vector3.ZERO)
	_build()


func _build() -> void:
	_effect.initialize(self)
	_effect.lifetime = 2.0
	# Silent — the cast sound comes off the caster's own hands, not from where the bolt landed.
	_effect.add_sprite(BURST_SPRITE, BaseMaterial3D.BILLBOARD_ENABLED,
		SPRITE_SCALE, SPRITE_FPS)
	_effect.add_ring(RING_COLOR, RING_EXPAND, RING_TIME)
	_effect.add_flash(Color(0.8, 0.7, 1.0), 6.0, 10.0, FADE_TIME)
	_effect.add_sparks("lightning", 32, 0.6, 0.12)


func _ready() -> void:
	# Beams need tree access for global_position, so they can't be built in _build().
	for i in BOLTS:
		var to := global_position + Vector3(
			randf_range(-BOLT_SPREAD, BOLT_SPREAD),
			BOLT_RISE,
			randf_range(-BOLT_SPREAD, BOLT_SPREAD))
		BeamSystem.create_oneshot(get_tree().current_scene, global_position, to, {
			# Random red and blue with the green channel held at zero, as the original rolled
			# its bolt colour — every arc lands somewhere in the magenta family.
			"color": Color(randf_range(0.5, 1.0), 0.0, randf_range(0.5, 1.0), 1.0),
			"width": BOLT_WIDTH,
			"segments": BOLT_SEGMENTS,
			"noise_fn": _make_bolt_noise(),
			"fade_time": FADE_TIME,
		})
	_effect.start()


## Fixed per-segment jitter, sampled by BeamSystem along the arc. Unlike a strike from the sky
## these run in every direction, so the offset is spherical rather than horizontal.
func _make_bolt_noise() -> Callable:
	var offsets: Array[Vector3] = []
	offsets.resize(BOLT_SEGMENTS + 1)
	offsets[0] = Vector3.ZERO
	offsets[BOLT_SEGMENTS] = Vector3.ZERO
	for i in range(1, BOLT_SEGMENTS):
		offsets[i] = Vector3(
			randf_range(-BOLT_NOISE, BOLT_NOISE),
			randf_range(-BOLT_NOISE, BOLT_NOISE),
			randf_range(-BOLT_NOISE, BOLT_NOISE))
	return func(t: float) -> Vector3:
		return offsets[clampi(int(t * BOLT_SEGMENTS), 0, BOLT_SEGMENTS)]


func _exit_tree() -> void:
	# Spawner-managed: despawn + tree_exiting hooks handle cleanup; nothing to unregister.
	_effect.entity_id = -1
