class_name StoneDustEffect
extends Node3D

## Dust puff kicked up where a rolling stone lands, fading out over a second.

var _effect := EffectBehavior.new()
var _mat: StandardMaterial3D
var _register := false


static func spawn(scene_root: Node, pos: Vector3, register := false) -> StoneDustEffect:
	var effect := StoneDustEffect.new()
	effect._register = register
	effect.position = pos + Vector3(0, 0.1, 0)
	effect._build()
	scene_root.add_child.call_deferred(effect)
	return effect


func setup(data: Dictionary, _is_host: bool = false) -> void:
	position = data.get("position", Vector3.ZERO)
	_build()


func _build() -> void:
	_effect.initialize(self)
	_effect.lifetime = 0.0  # freed by the fade below, not on a timer
	var dust := _effect.add_sprite("sprites/stmbal1.spr")
	if dust:
		_mat = dust.material_override
		_mat.albedo_color = Color(1.0, 0.85, 0.4, 1.0)


func _ready() -> void:
	_effect.start("res://src/effects/stone_dust_effect.gd" if _register else "")
	if not _mat:
		_effect.finish()
		return
	var tween := create_tween()
	tween.tween_property(_mat, "albedo_color:a", 0.0, 1.0)
	tween.tween_callback(_effect.finish)
