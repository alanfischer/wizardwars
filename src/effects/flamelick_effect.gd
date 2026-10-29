class_name FlamelickEffect
extends Node3D

## Flamelick fire burst — animated mushroom.spr billboard at impact, auto-frees after 1.5s.

const SPRITE_FPS := 20.0

var _effect := EffectBehavior.new()


static func spawn(scene_root: Node, pos: Vector3) -> FlamelickEffect:
	var effect := FlamelickEffect.new()
	effect.position = pos
	effect._build()
	scene_root.add_child.call_deferred(effect)
	return effect


func setup(data: Dictionary, _is_host: bool = false) -> void:
	position = data.get("position", Vector3.ZERO)
	_build()


func _build() -> void:
	_effect.initialize(self)
	_effect.lifetime = 1.5
	_effect.add_sprite("sprites/mushroom.spr", BaseMaterial3D.BILLBOARD_FIXED_Y, 1.0, SPRITE_FPS)
	# ported from HL dynlight (r128, duration=0.5)
	_effect.add_flash(Color(1.0, 0.4, 0.2), 3.0, 3.2, 0.5)
	_effect.add_sound("spells/flamelick_hit.wav")


func _ready() -> void:
	_effect.start()
