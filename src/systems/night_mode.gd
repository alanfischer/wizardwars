class_name NightMode
extends Object
## How much of the sky's light reaches the map: the `night` server var (0 day … 1 full night) and
## any lightstyle a map plays on its light_environment, the map's own lights left as they are.
##
## How much of each lightmap luxel the sky put there is baked at conversion (GoldSrcBSP's
## compute_sun_fractions: lm_sun on world materials, sun_slices in the light grid for models).
## Everything here comes down to one linear-light multiplier on that share, `sky_light`. A map
## with no light_environment has no share to turn, so it is left exactly as it was.

## Moonlight, as the multiplier at full night.
const TINT := Color(0.12, 0.14, 0.24)
## Any night at all swaps the map's sky for this one, unless the map's own already reads as night.
const SKY := "fullmoon"
const NIGHT_SKIES := ["fullmoon", "night", "space", "space2"]
## hlrad writes pow(light, gamma); a lightstyle scales that stored value, so its linear twin is
## brightness^(1/gamma). Matches goldsrc_bsp.cpp's LIGHTMAP_GAMMA and the shaders' 0.55.
const LIGHTMAP_GAMMA := 0.55

static var _root: Node
static var _world_mats: Array[ShaderMaterial] = []
static var _liquid_mats: Array[ShaderMaterial] = []
## A lightning flash on top of everything else, as linear light added to the sky's share.
static var _flash := Vector3.ZERO
## The light_environment's lightstyle, as a brightness (1.0 = 'm').
static var _sun_style := 1.0
## Whether the sun was compiled onto a style of its own (ww_chasm), which the lightstyle texture
## already fades on the world — so only models take _sun_style from here.
static var _sun_has_layer := false


## "on"/"off" or a number, as /night, --night and the pause slider give it; "" if neither.
static func parse(text: String) -> String:
	var t := text.strip_edges().to_lower()
	if t == "on":
		return "1"
	if t == "off":
		return "0"
	return str(clampf(float(t), 0.0, 1.0)) if t.is_valid_float() else ""


static func amount() -> float:
	return clampf(float(ServerVars.get_value("night", 0.0)), 0.0, 1.0)


## Whether conversion found a sky share to turn down: no light_environment, no night.
static func has_sun(map_root: Node) -> bool:
	return map_root != null and (map_root.get_meta("light_grid", {}) as Dictionary).has("sun_slices")


static func sky_for(sky_name: String, map_root: Node) -> String:
	if sky_name.is_empty() or amount() <= 0.0 or sky_name in NIGHT_SKIES or not has_sun(map_root):
		return sky_name
	return SKY


## A map load starts back at the sun as compiled.
static func reset() -> void:
	_root = null
	_world_mats.clear()
	_liquid_mats.clear()
	_flash = Vector3.ZERO
	_sun_style = 1.0
	_sun_has_layer = false


## LightEnvironment's lightstyle, e.g. ww_chasm's PotatoC dusk (SetLightStyle('sky', ...)).
static func set_sun_style(brightness: float, has_layer: bool) -> void:
	_sun_style = brightness
	_sun_has_layer = has_layer
	if is_instance_valid(_root):
		apply(_root)


## Push the current sky light onto a loaded map and every model the light grid lights. Safe to
## call again on a live map, which is how the slider, /night and a lightstyle take hold.
static func apply(map_root: Node) -> void:
	_root = map_root
	_world_mats.clear()
	_liquid_mats.clear()
	if map_root:
		_collect(map_root)
	_push()


## Lightning: `flash` is linear light added to the sky's share for as long as it is non-zero, so
## the open map lights up and a torch-lit room does not. Called every frame of a strike, which is
## why it sets the materials apply() found rather than walking the map again.
static func set_flash(flash: Vector3) -> void:
	_flash = flash
	_push()


static func _push() -> void:
	var t := amount()
	var night := Vector3(lerpf(1.0, TINT.r, t), lerpf(1.0, TINT.g, t), lerpf(1.0, TINT.b, t))
	var style := pow(maxf(_sun_style, 0.0), 1.0 / LIGHTMAP_GAMMA)
	var world := (night if _sun_has_layer else night * style) + _flash
	# A sunless map's liquid has no night to match: leave the whole map as it was.
	var liquid := night + _flash if has_sun(_root) else Vector3.ONE
	for mat in _world_mats:
		mat.set_shader_parameter("sky_light", world)
	for mat in _liquid_mats:
		mat.set_shader_parameter("sky_light", liquid)
	LightGrid.set_sky_light(night * style + _flash)


## Descends into MeshInstance3Ds too: a BSP nests submodel meshes under their parent mesh.
static func _collect(node: Node) -> void:
	for child in node.get_children():
		if child is MeshInstance3D:
			var mi := child as MeshInstance3D
			if mi.mesh:
				for i in mi.mesh.get_surface_count():
					_sort(mi.mesh.surface_get_material(i))
					_sort(mi.get_surface_override_material(i))
		_collect(child)


static func _sort(mat: Material) -> void:
	if not mat is ShaderMaterial:
		return
	var smat := mat as ShaderMaterial
	if smat.get_shader_parameter("lm_sun") != null:
		if not smat in _world_mats:
			_world_mats.append(smat)
	elif smat.get_shader_parameter("liquid_type") != null:
		if not smat in _liquid_mats:
			_liquid_mats.append(smat)
