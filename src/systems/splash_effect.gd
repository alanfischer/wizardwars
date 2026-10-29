class_name SplashEffect
extends Node3D

## The crown something throws up going into a pool: a ring spreading across the surface and a
## spray of droplets, both sized by the body that made it. Spawned at the surface, so it sorts
## above the water rather than inside it.

const PARTICLES := {
	GameConsts.Liquid.WATER: "splash_water",
	GameConsts.Liquid.SLIME: "splash_slime",
	GameConsts.Liquid.LAVA: "splash_lava",
}
const RING_COLORS := {
	GameConsts.Liquid.WATER: Color(0.6, 0.85, 1.0, 0.6),
	GameConsts.Liquid.SLIME: Color(0.55, 1.0, 0.4, 0.6),
	GameConsts.Liquid.LAVA: Color(1.0, 0.55, 0.15, 0.8),
}
const DROPS := 14        # at size 1.0, scaled by the body
const DROP_LIFE := 0.6
const DROP_SIZE := 0.09
const RING_TIME := 0.45
const LIFETIME := 1.0

var _effect := EffectBehavior.new()
var _liquid := GameConsts.Liquid.WATER
var _size := 1.0
var _register := false


static func spawn(scene_root: Node, pos: Vector3, liquid: GameConsts.Liquid, size: float,
		register := false) -> SplashEffect:
	var effect := SplashEffect.new()
	effect._liquid = liquid
	effect._size = size
	effect._register = register
	effect.position = pos
	effect._build()
	scene_root.add_child.call_deferred(effect)
	return effect


func setup(data: Dictionary, _is_host: bool = false) -> void:
	position = data.get("position", Vector3.ZERO)
	_liquid = data.get("liquid", GameConsts.Liquid.WATER)
	_size = data.get("size", 1.0)
	_build()


func _build() -> void:
	_effect.initialize(self)
	_effect.lifetime = LIFETIME
	var scaled := clampf(_size, 0.3, 2.0)
	_effect.add_sparks(PARTICLES.get(_liquid, "splash_water"), maxi(4, int(DROPS * scaled)),
		DROP_LIFE, DROP_SIZE * sqrt(scaled))
	_effect.add_ring(RING_COLORS.get(_liquid, RING_COLORS[GameConsts.Liquid.WATER]),
		1.0 + 1.5 * scaled, RING_TIME)


func _ready() -> void:
	_effect.start("res://src/systems/splash_effect.gd" if _register else "",
		{"liquid": int(_liquid), "size": _size})
