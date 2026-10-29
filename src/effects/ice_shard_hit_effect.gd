class_name IceShardHitEffect
extends Node3D

## Blue ice spark burst at ice shard impact point, auto-frees after 1.0s.

var _effect := EffectBehavior.new()


static func spawn(scene_root: Node, pos: Vector3) -> IceShardHitEffect:
	var effect := IceShardHitEffect.new()
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
	_effect.add_flash(Color(0.4, 0.7, 1.0), 2.0, 2.5, 0.3)
	_effect.add_sparks("iceshard", 12, 0.4, 0.08)


func _ready() -> void:
	_effect.start()
