class_name FireSpiralEffect
extends Node3D

## Fire spiral flame burst — animated fexplo1.spr billboard, auto-frees after 1.5s.
## In persistent mode it loops and burns until stop() is called instead.

const SPRITE_FPS := 20.0

var _effect := EffectBehavior.new()
var _is_persistent := false
var _flash: OmniLight3D


static func spawn(scene_root: Node, pos: Vector3, persistent := false) -> FireSpiralEffect:
	var effect := FireSpiralEffect.new()
	effect.position = pos
	effect._is_persistent = persistent
	effect._build()
	scene_root.add_child.call_deferred(effect)
	return effect


func setup(data: Dictionary, _is_host: bool = false) -> void:
	position = data.get("position", Vector3.ZERO)
	_is_persistent = data.get("persistent", false)
	_build()


func _build() -> void:
	_effect.initialize(self)
	# Persistent flames dim and free on stop(), not on a timer.
	_effect.lifetime = 0.0 if _is_persistent else 1.5
	_effect.add_sprite("sprites/fexplo1.spr", BaseMaterial3D.BILLBOARD_ENABLED, 1.0,
			SPRITE_FPS, _is_persistent)
	# ported from HL dynlight (r128, duration=0.5)
	_flash = _effect.add_flash(Color(1.0, 0.4, 0.2), 3.0, 3.2, 0.0 if _is_persistent else 0.5)
	if not _is_persistent:
		_effect.add_sound("spells/flamelick_hit.wav")


func _ready() -> void:
	_effect.start()


func stop() -> void:
	if not _is_persistent:
		return
	_is_persistent = false
	if not is_inside_tree():
		queue_free()
		return
	_effect.fade_light(_flash, 0.5)
	_effect.finish(0.5)
