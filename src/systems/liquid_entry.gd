class_name LiquidEntry
extends RefCounted

## One body's crossing into a pool, heard and seen once — the splash bank plus a spray of
## droplets. Anything that falls (a corpse, a rolling stone) keeps one of these and feeds it
## a position each tick; nothing collides with a liquid volume, so entry is a point query.

const SURFACE_STEPS := 4  # bisections between the last dry sample and the first wet one

var size := 1.0  ## the body against the water, on LiquidSounds' scale of 1.0 = a person

var _splashed := false
var _dry := Vector3.INF


## Splash the first time `pos` lands inside a liquid. `broadcast` is the usual split: false
## when every peer runs the same fall, true when only the host can see it.
func check(node: Node3D, pos: Vector3, speed: float, rng: RandomNumberGenerator,
		broadcast := false) -> void:
	if _splashed:
		return
	var liquid := SpatialQuery.liquid_at_point(node, pos)
	if liquid == GameConsts.Liquid.NONE:
		_dry = pos
		return
	_splashed = true
	# No dry sample means it was born under the surface: it was already in there, it did not
	# arrive. Below MIN_SPEED it is drifting in rather than falling in.
	if not _dry.is_finite() or speed < LiquidSounds.MIN_SPEED:
		return
	var surface := _surface_between(node, _dry, pos)
	LiquidSounds.splash(surface, liquid, size, speed, rng, broadcast)
	SplashEffect.spawn(node.get_tree().current_scene, surface, liquid, size, broadcast)


## The last point still above the water, bisected out of the tick that crossed it: a body at
## speed covers a third of a metre a tick, and the spray has to sit on the surface.
func _surface_between(node: Node3D, dry: Vector3, wet: Vector3) -> Vector3:
	for _i in SURFACE_STEPS:
		var mid := dry.lerp(wet, 0.5)
		if SpatialQuery.liquid_at_point(node, mid) == GameConsts.Liquid.NONE:
			dry = mid
		else:
			wet = mid
	return dry
