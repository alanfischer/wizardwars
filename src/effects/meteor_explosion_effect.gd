class_name MeteorExplosionEffect
extends Node3D

## What a meteor leaves where it lands. Three of these go off on the same tick around one wizard,
## so it is built to stack: a white core that snaps out, a fireball swelling behind it, debris
## thrown out of the crater, and two rings — a fast shock front and a slower burning wake.
##
## Every peer spawns its own copy off the meteor's despawn, so there is nothing to replicate.

const FIREBALL_SPR := "sprites/zerogxplode.spr"
const CORE_SPR := "sprites/fexplo1.spr"
const SPRITE_FPS := 15.0
const FIREBALL_SCALE := 5.0
const CORE_SCALE := 2.5
const HIT_SOUND := "spells/combos/meteor_hit.wav"
## Layered under the first meteor of a strike only — three of these on one tick is mud, one is
## the floor dropping out.
const BOOM_SOUND := "ambience/biggun3.wav"

var _effect := EffectBehavior.new()
var _boom := false


static func spawn(scene_root: Node, pos: Vector3, boom := false) -> void:
	var effect := MeteorExplosionEffect.new()
	effect.position = pos
	effect._boom = boom
	effect._build()
	scene_root.add_child.call_deferred(effect)


static func precache() -> void:
	AssetLoader.precache_sprite(FIREBALL_SPR)
	AssetLoader.precache_sprite(CORE_SPR)
	AssetLoader.get_additive_material()
	SoundSystem.precache(HIT_SOUND)
	SoundSystem.precache(BOOM_SOUND)


func _build() -> void:
	_effect.initialize(self)
	_effect.lifetime = 2.5
	_effect.add_sprite(FIREBALL_SPR, BaseMaterial3D.BILLBOARD_ENABLED, FIREBALL_SCALE, SPRITE_FPS)
	_effect.add_sprite(CORE_SPR, BaseMaterial3D.BILLBOARD_ENABLED, CORE_SCALE, SPRITE_FPS * 1.6)
	_effect.add_flash(Color(1.0, 1.0, 0.85), 10.0, 14.0, 0.15)  # core, gone almost at once
	_effect.add_flash(Color(1.0, 0.45, 0.12), 7.0, 10.0, 1.0)   # the fire behind it, left burning
	_effect.add_sparks("spotbolt", 48, 1.4, 0.2)
	_effect.add_ring(Color(1.0, 0.95, 0.8, 1.0), 16.0, 0.35)
	_effect.add_ring(Color(1.0, 0.45, 0.1, 0.85), 9.0, 1.0)
	_effect.add_sound(HIT_SOUND, 40.0)
	if _boom:
		_effect.add_sound(BOOM_SOUND, 50.0)


func _ready() -> void:
	_effect.start()
