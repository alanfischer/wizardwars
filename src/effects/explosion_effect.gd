class_name ExplosionEffect
extends Node3D

## Explosion: animated sprite + light flash + sound, optional expanding torus ring; auto-frees after 2s.

const SPRITE_FPS := 15.0
const DEFAULT_SPR := "sprites/zerogxplode.spr"
const DEFAULT_LIGHT := Color(1.0, 0.59, 0.2)
const DEFAULT_SOUND := "ambience/explode3.wav"

var _effect := EffectBehavior.new()
var _spr_path := DEFAULT_SPR
var _light_color := DEFAULT_LIGHT
var _sound_path := DEFAULT_SOUND
var _spr_scale := 1.0
var _ring_color := Color(0, 0, 0, 0)  # transparent = no ring
var _register_data := {}
var _register := false


static func spawn(scene_root: Node, pos: Vector3, register := false,
		spr_path := DEFAULT_SPR,
		light_color := DEFAULT_LIGHT,
		sound_path := DEFAULT_SOUND,
		spr_scale := 1.0,
		ring_color := Color(0, 0, 0, 0)) -> ExplosionEffect:
	var container := ExplosionEffect.new()
	container.position = pos
	container._spr_path = spr_path
	container._light_color = light_color
	container._sound_path = sound_path
	container._spr_scale = spr_scale
	container._ring_color = ring_color
	container._build()
	scene_root.add_child.call_deferred(container)
	if register:
		# Only the non-default parts ride the spawn payload; setup() fills the rest back in.
		var data := {}
		if spr_path != DEFAULT_SPR:
			data["spr_path"] = spr_path
		if light_color != DEFAULT_LIGHT:
			data["light_color"] = [light_color.r, light_color.g, light_color.b]
		if sound_path != DEFAULT_SOUND:
			data["sound_path"] = sound_path
		if spr_scale != 1.0:
			data["spr_scale"] = spr_scale
		if ring_color.a > 0.0:
			data["ring_color"] = [ring_color.r, ring_color.g, ring_color.b, ring_color.a]
		container._register = true
		container._register_data = data
	return container


func setup(data: Dictionary, _is_host: bool = false) -> void:
	position = data.get("position", Vector3.ZERO)
	_spr_path = data.get("spr_path", DEFAULT_SPR)
	var lc: Array = data.get("light_color", [])
	if lc.size() == 3:
		_light_color = Color(lc[0], lc[1], lc[2])
	_sound_path = data.get("sound_path", DEFAULT_SOUND)
	_spr_scale = data.get("spr_scale", 1.0)
	var rc: Array = data.get("ring_color", [])
	if rc.size() == 4:
		_ring_color = Color(rc[0], rc[1], rc[2], rc[3])
	_build()


func _build() -> void:
	_effect.initialize(self)
	_effect.lifetime = 2.0
	if not _spr_path.is_empty():
		_effect.add_sprite(_spr_path, BaseMaterial3D.BILLBOARD_ENABLED, _spr_scale, SPRITE_FPS)
	if _ring_color.a > 0.0:
		_effect.add_ring(_ring_color, 8.0, 0.5)
	_effect.add_flash(_light_color, 4.0, 3.2, 0.4)
	if not _sound_path.is_empty():
		_effect.add_sound(_sound_path, 30.0)


func _ready() -> void:
	_effect.start("res://src/effects/explosion_effect.gd" if _register else "", _register_data)
