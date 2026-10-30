class_name FireSpiralEffect
extends Node3D

## Fire spiral flame — animated fexplo1.spr billboard. A head flame loops and burns until stop()
## is called. A trail flame plays its burst once while it swirls about the spiral's centre: it
## leaves with the arm's spin, which bleeds off as it drifts out and up.

const HEAD_FPS := 6.1  # the original advanced pev->frame .61 per 0.1s think
const HEAD_SCALE := 0.75
const TRAIL_FPS := 40.0
const TRAIL_SCALE := 0.4
const TRAIL_LIFE := 0.475  # fexplo1's 19 frames at TRAIL_FPS
const TRAIL_SPIN_DECAY := 0.25  # seconds for a trail flame's spin to fall to 1/e
const TRAIL_FLING := 2.5
const TRAIL_RISE := 0.8

var _effect := EffectBehavior.new()
var _is_persistent := false
var _flash: OmniLight3D
var _center := Vector3.ZERO
var _angle := 0.0
var _radius := 0.0
var _spin := 0.0
var _rise := 0.0


static func spawn(scene_root: Node, pos: Vector3, persistent := false) -> FireSpiralEffect:
	var effect := FireSpiralEffect.new()
	effect.position = pos
	effect._is_persistent = persistent
	effect._build()
	scene_root.add_child.call_deferred(effect)
	return effect


## A local trail flame at polar (`angle`, `radius`) about `center`, turning at `spin` rad/s.
static func spawn_trail(scene_root: Node, center: Vector3, angle: float, radius: float,
		spin: float) -> FireSpiralEffect:
	var effect := FireSpiralEffect.new()
	effect._center = center
	effect._angle = angle
	effect._radius = radius
	effect._spin = spin
	effect._place()
	effect._build()
	scene_root.add_child.call_deferred(effect)
	return effect


func setup(data: Dictionary, _is_host: bool = false) -> void:
	position = data.get("position", Vector3.ZERO)
	_is_persistent = data.get("persistent", false)
	_build()


func _build() -> void:
	_effect.initialize(self)
	if _is_persistent:
		# Persistent flames dim and free on stop(), not on a timer.
		_effect.lifetime = 0.0
		_effect.add_sprite("sprites/fexplo1.spr", BaseMaterial3D.BILLBOARD_ENABLED, HEAD_SCALE,
				HEAD_FPS, true)
		# ported from EF_DIMLIGHT
		_flash = _effect.add_flash(Color(1.0, 0.4, 0.2), 3.0, 3.2, 0.0)
	else:
		_effect.lifetime = TRAIL_LIFE
		_effect.add_sprite("sprites/fexplo1.spr", BaseMaterial3D.BILLBOARD_ENABLED, TRAIL_SCALE,
				TRAIL_FPS)


func _ready() -> void:
	# Only a trail flame moves itself; the spiral places its heads.
	set_physics_process(_spin != 0.0)
	_effect.start()


func _physics_process(delta: float) -> void:
	_angle += _spin * delta
	_spin *= exp(-delta / TRAIL_SPIN_DECAY)
	_radius += TRAIL_FLING * delta
	_rise += TRAIL_RISE * delta
	_place()


func _place() -> void:
	position = _center + Vector3(cos(_angle) * _radius, _rise, sin(_angle) * _radius)


func stop() -> void:
	if not _is_persistent:
		return
	_is_persistent = false
	if not is_inside_tree():
		queue_free()
		return
	_effect.fade_light(_flash, 0.5)
	_effect.finish(0.5)
