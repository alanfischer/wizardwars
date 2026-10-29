class_name SatchelBurstEffect
extends Node3D

## A satchel blast built around the original's single sprite sheet: per element, the sheet, its
## flashes, and particle layers that fill out the blast radius.
##   life:  white-green sparks, healing motes rising, a ring of motes sweeping out to the edge
##   wind:  a flat gust sweeping out over the knockback radius, a violet vortex spiralling up
##   death: toxic droplets thrown up and raining back, green wisps seeping up through the smoke

## The original's TE_EXPLOSION / R_Explosion: [path, scale, framerate, height above the satchel]
const SPRITES := {
	GameConsts.Element.LIFE: ["sprites/b-tele1.spr", 2.5, 40.0, 0.0],
	GameConsts.Element.WIND: ["sprites/c-tele1.spr", 2.0, 30.0, 32.0 * GameConsts.SCALE_FACTOR],
	GameConsts.Element.DEATH: ["sprites/stmbal1.spr", 7.0, 40.0, 0.0],
}
## [color, energy, range, fade] per flash
const FLASHES := {
	GameConsts.Element.LIFE: [[Color(0.9, 1.0, 0.9), 5.0, 4.0, 0.2], [Color(0.4, 1.0, 0.5), 3.0, 4.0, 1.0]],
	GameConsts.Element.WIND: [[Color(0.85, 0.8, 1.0), 4.0, 4.0, 0.2], [Color(0.55, 0.3, 0.75), 3.0, 4.0, 0.8]],
	GameConsts.Element.DEATH: [[Color(0.3, 0.9, 0.2), 3.0, 4.0, 1.2]],
}
## [AssetLoader spark type, amount, lifetime, size] per layer
const SPARKS := {
	GameConsts.Element.LIFE: [["lifesatchel", 48, 0.8, 0.12], ["lifemote", 40, 1.8, 0.09],
		["lifering", 64, 0.8, 0.12]],
	GameConsts.Element.WIND: [["windgust", 80, 0.6, 0.1], ["windswirl", 72, 1.3, 0.13]],
	GameConsts.Element.DEATH: [["necrosplash", 40, 1.1, 0.12], ["necrowisp", 56, 2.0, 0.12]],
}
## The blast sound when the satchel's own isn't enough; the rest are silent here.
const SOUNDS := {
	GameConsts.Element.DEATH: "ambience/explode3.wav",
}

var element: int = GameConsts.Element.LIFE

var _effect := EffectBehavior.new()
var _register := false


static func has_burst(for_element: int) -> bool:
	return SPRITES.has(for_element)


## Build every element's materials at map load so the warmup pass compiles them, not the first blast.
static func precache() -> void:
	AssetLoader.get_sprite_material_template()
	for e in SPRITES:
		AssetLoader.precache_sprite(SPRITES[e][0])
		for layer in SPARKS[e]:
			AssetLoader.get_spark_particle_material(layer[0])
			AssetLoader.get_spark_quad(Vector2(layer[3], layer[3]))
	for path in SOUNDS.values():
		SoundSystem.precache(path)


static func spawn(scene_root: Node, pos: Vector3, for_element: int, register := false) -> void:
	var effect := SatchelBurstEffect.new()
	effect.position = pos
	effect.element = for_element
	effect._register = register
	effect._build()
	scene_root.add_child.call_deferred(effect)


func setup(data: Dictionary, _is_host: bool = false) -> void:
	position = data.get("position", Vector3.ZERO)
	element = data.get("element", GameConsts.Element.LIFE)
	_build()


func _build() -> void:
	_effect.initialize(self)
	_effect.lifetime = 2.2
	if not has_burst(element):
		return
	var sprite: Array = SPRITES[element]
	var sheet := _effect.add_sprite(sprite[0], BaseMaterial3D.BILLBOARD_ENABLED, sprite[1], sprite[2]) as Node3D
	if sheet:
		sheet.position.y = sprite[3]
	for f in FLASHES[element]:
		_effect.add_flash(f[0], f[1], f[2], f[3])
	# Particles only, no EffectBehavior.add_ring: under gl_compatibility the warmup pass doesn't
	# reach the torus's pipeline, and its compile stalled the first blast ~110ms.
	for layer in SPARKS[element]:
		_effect.add_sparks(layer[0], layer[1], layer[2], layer[3])
	if SOUNDS.has(element):
		_effect.add_sound(SOUNDS[element], 30.0)


func _ready() -> void:
	_effect.start("res://src/effects/satchel_burst_effect.gd" if _register else "",
		{"element": element})
