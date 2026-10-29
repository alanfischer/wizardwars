class_name UpdraftEffect
extends Node3D

## Updraft wind burst: animated updraft.spr billboard at impact, drifts upward.
## Auto-frees after 1.5 seconds.

const SPRITE_FPS := 20.0
const DRIFT_SPEED := 1.6  # 64 GS * 0.025 — upward drift

var _effect := EffectBehavior.new()


static func spawn(scene_root: Node, pos: Vector3) -> UpdraftEffect:
	var effect := UpdraftEffect.new()
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
	_effect.add_sprite("sprites/effects/updraft.spr", BaseMaterial3D.BILLBOARD_FIXED_Y, 1.0, SPRITE_FPS)
	_effect.add_flash(Color(0.4, 0.5, 0.6), 3.0, 3.2, 0.5)  # blue-white wind flash
	_effect.add_sound("spells/updraft_hit.wav")


func _ready() -> void:
	_effect.start()


func _physics_process(delta: float) -> void:
	position.y += DRIFT_SPEED * delta
