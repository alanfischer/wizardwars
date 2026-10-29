class_name LightningZapEffect
extends Node3D

## Small electric spark burst at lightning bolt impact — lighter than SpotBoltStrike (no
## beam or sound), auto-frees after 1.0s.

var _effect := EffectBehavior.new()


static func spawn(scene_root: Node, pos: Vector3) -> LightningZapEffect:
	var effect := LightningZapEffect.new()
	effect.position = pos
	effect._build()
	scene_root.add_child.call_deferred(effect)
	return effect


func setup(data: Dictionary, _is_host: bool = false) -> void:
	position = data.get("position", Vector3.ZERO)
	_build()


func _build() -> void:
	_effect.initialize(self)
	_effect.lifetime = 1.0
	_effect.add_flash(Color(0.7, 0.8, 1.0), 2.0, 3.0, 0.2)
	_effect.add_sparks("lightning", 16, 0.3, 0.1)


func _ready() -> void:
	_effect.start()
