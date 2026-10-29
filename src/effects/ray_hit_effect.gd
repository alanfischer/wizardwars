class_name RayHitEffect
extends Node3D

## Generic ray beam impact sparks (death ray, life ray), parameterized by color and
## particle type. Auto-frees after 0.5s.

var _effect := EffectBehavior.new()
var _light_color := Color(1, 1, 1)
var _particle_type := "deathray"


static func spawn(scene_root: Node, pos: Vector3, light_color: Color, particle_type: String) -> RayHitEffect:
	var effect := RayHitEffect.new()
	effect.position = pos
	effect._light_color = light_color
	effect._particle_type = particle_type
	effect._build()
	scene_root.add_child.call_deferred(effect)
	return effect


func setup(data: Dictionary, _is_host: bool = false) -> void:
	position = data.get("position", Vector3.ZERO)
	_light_color = data.get("light_color", Color(1, 1, 1))
	_particle_type = data.get("particle_type", "deathray")
	_build()


func _build() -> void:
	_effect.initialize(self)
	_effect.lifetime = 0.5
	_effect.add_flash(_light_color, 1.5, 2.0, 0.2)
	_effect.add_sparks(_particle_type, 8, 0.25, 0.06)


func _ready() -> void:
	_effect.start()
