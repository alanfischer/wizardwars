class_name CometExplosionEffect
extends Node3D

## Comet impact — bigger/more intense than a normal explosion; sprite + flash + screen
## shake + shockwave ring, auto-frees after 2.5s.

const SPRITE_FPS := 15.0
const SPRITE_SCALE := 3.0  # much bigger than normal explosion
const SHAKE_RANGE := 30.0
const SHAKE_AMPLITUDE := 120.0   # GoldSrc shake units, as big as a meteor's
const SHAKE_DURATION := 0.4
const SHAKE_FREQUENCY := 20.0    # shakes per second

var _effect := EffectBehavior.new()


static func spawn(scene_root: Node, pos: Vector3) -> void:
	var effect := CometExplosionEffect.new()
	effect.position = pos
	effect._build()
	scene_root.add_child.call_deferred(effect)


func _build() -> void:
	_effect.initialize(self)
	_effect.lifetime = 2.5
	_effect.add_sprite("sprites/zerogxplode.spr", BaseMaterial3D.BILLBOARD_ENABLED,
			SPRITE_SCALE, SPRITE_FPS)
	_effect.add_flash(Color(1.0, 0.5, 0.1), 8.0, 8.0, 0.5)
	_effect.add_flash(Color(1.0, 1.0, 0.9), 6.0, 12.0, 0.2)  # white core, snaps out faster
	# reuse spotbolt spark material for fiery debris
	_effect.add_sparks("spotbolt", 32, 1.0, 0.15)
	_effect.add_ring(Color(0.4, 0.6, 1.0, 0.9), 12.0, 1.2)
	_effect.add_sound("ambience/biggun3.wav", 40.0)


func _ready() -> void:
	_effect.start()

	# Every peer spawns its own copy of this effect, so the shake is local and needs no RPC.
	Game.shake_view_local(global_position, SHAKE_AMPLITUDE, SHAKE_RANGE,
			SHAKE_DURATION, SHAKE_FREQUENCY)
