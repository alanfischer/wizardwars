class_name MapSun
extends Object
## The map's sun as a real light with shadows, crossing the sky with the `time` server var, the
## moon after it at night.
##
## hlrad baked the sun into the lightmaps, where it cannot move. Conversion splits each luxel's
## direct sun out from the rest (GoldSrcBSP's lm_sun g, the light grid's sun_slices g, and the
## root's "sun" meta: its direction, colour and brightness), so the shaders can take it back out
## and this light puts it back where the sun now is (goldsrc_hook.gdshaderinc's goldsrc_light,
## mdl_ambient_cube.gdshaderinc's light()). Off, or on a map with no light_environment, the sun
## stays baked exactly as before. RenderQuality decides whether it is on.

## Metres of shadow from the camera. Maps are small (2fort is about 40 m across).
const SHADOW_DISTANCE := 60.0
## Layers it lights: models (1) and the BSP (2).
const CULL_MASK := 3
## Layers that cast its shadows: the BSP, whose meshes cast only where hlrad let them block the sun
## (GoldSrcBSP). Never models, which the original never shadowed with.
const CASTER_MASK := 2
## The lowest a noon sun goes. A sun compiled near the horizon (ww_ravine's has pitch 0) has no
## arc to cross the sky on, so it keeps its bearing and climbs to this.
const MIN_NOON_ELEVATION := deg_to_rad(30.0)

static var _light: DirectionalLight3D
static var _info: Dictionary = {}
static var _enabled := false


## After the map's root is in the tree, before the sky is built (Skybox asks moving()).
static func setup(map_root: Node3D) -> void:
	clear()
	_info = map_root.get_meta("sun", {}) if map_root else {}
	if _info.is_empty():
		return
	_light = DirectionalLight3D.new()
	_light.name = "MapSun"
	_light.shadow_enabled = true
	_light.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	_light.directional_shadow_max_distance = SHADOW_DISTANCE
	_light.light_cull_mask = CULL_MASK
	_light.shadow_caster_mask = CASTER_MASK
	_light.light_specular = 0.0
	map_root.add_child(_light)
	_light.visible = moving()


## The map frees the light; this forgets it.
static func clear() -> void:
	_light = null
	_info = {}


## Whether the map has a sun to cross its sky: a light_environment, its direct light split out.
static func has_sun() -> bool:
	return not _info.is_empty()


## Whether a real-time sun lights the map: the sun is no longer where it was baked.
static func moving() -> bool:
	return is_instance_valid(_light) and _enabled


static func enabled() -> bool:
	return _enabled


## RenderQuality's say. Takes hold at once on a loaded map.
static func set_enabled(on: bool) -> void:
	_enabled = on
	if is_instance_valid(_light):
		_light.visible = on
	if Game.map_root:
		NightMode.apply(Game.map_root)


## Where the sun stands at noon, toward it: where it was compiled, unless that was too low to
## arc from. Vector3.ZERO with none.
static func noon_dir() -> Vector3:
	var dir: Vector3 = _info.get("dir", Vector3.ZERO)
	if dir == Vector3.ZERO or asin(clampf(dir.y, -1.0, 1.0)) >= MIN_NOON_ELEVATION:
		return dir
	var flat := Vector3(dir.x, 0.0, dir.z).normalized()
	return (flat * cos(MIN_NOON_ELEVATION) + Vector3.UP * sin(MIN_NOON_ELEVATION)).normalized()


## Points the light for `hours` and returns its brightness on a surface facing it: linear
## lightmap units for the world, and the light grid's gamma terms for models. `style` is the
## light_environment's lightstyle, linear. Zeros when no real-time sun. "baked" is how much of the
## baked direct sun stays: with no real-time sun, the baked one fades as the sky's sun sinks,
## gone at sunset, and the moon brings it back by night. Its shadows keep the noon sun's
## direction, so they soften away rather than fall the wrong way.
static func update(hours: float, style: float) -> Dictionary:
	var out := {"world": Vector3.ZERO, "model": Vector3.ZERO, "baked": 1.0}
	if not has_sun():
		return out
	var noon := noon_dir()
	var phase := NightMode.moon()
	var dir := OvercastSky.light_dir_at(noon, hours, phase)
	var strength := OvercastSky.light_strength_at(hours, phase)
	# Down behind the horizon, nothing.
	strength *= smoothstep(-0.02, 0.06, dir.y)
	if not moving():
		out["baked"] = clampf(dir.y / maxf(noon.y, 1e-3), 0.0, 1.0) * strength
		return out
	out["baked"] = 0.0
	var up := Vector3.UP if absf(dir.y) < 0.99 else Vector3.FORWARD
	_light.basis = Basis.looking_at(-dir, up)  # the map root stands at the origin, unturned
	_light.visible = strength > 0.0
	var tint := NightMode.night_light() * strength * style
	var c: Color = _info["color"]
	out["world"] = Vector3(c.r, c.g, c.b) * float(_info["light"]) * tint
	var grid := AssetLoader.light_grid
	if grid:
		# The grid holds gamma: a linear multiplier goes in through the curve.
		out["model"] = grid.sun_color() * NightMode.to_gamma(tint)
	return out
