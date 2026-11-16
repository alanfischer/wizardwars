class_name NightMode
extends Object
## How much of the sky's light reaches the map: the `time` server var (hours; Overcast's day, dusk
## and night) and any lightstyle a map plays on its light_environment, the map's own lights left as
## they are.
##
## How much of each lightmap luxel the sky put there is baked at conversion (GoldSrcBSP's
## compute_sun_fractions: lm_sun on world materials, sun_slices in the light grid for models).
## Everything here comes down to one linear-light multiplier on that share, `sky_light`. A map
## with no light_environment has no share to turn, so it is left exactly as it was. Where MapSun
## lights the sun itself, its direct share comes out of the bake and the light puts it back.

## Past half night the map's cubemap sky gives way to this one, unless the map's own already reads
## as night. The procedural sky (dynamic weather) does its own night, off the map's day sky.
const SKY := "fullmoon"
const NIGHT_SKIES := ["fullmoon", "night", "space", "space2"]
## hlrad writes pow(light, gamma); a lightstyle scales that stored value, so its linear twin is
## brightness^(1/gamma). Matches goldsrc_bsp.cpp's LIGHTMAP_GAMMA and the shaders' 0.55.
const LIGHTMAP_GAMMA := 0.55


## A linear multiplier as it goes onto lightmap-gamma light.
static func to_gamma(v: Vector3) -> Vector3:
	return Vector3(pow(v.x, LIGHTMAP_GAMMA), pow(v.y, LIGHTMAP_GAMMA), pow(v.z, LIGHTMAP_GAMMA))

static var _root: Node
static var _world_mats: Array[ShaderMaterial] = []
static var _liquid_mats: Array[ShaderMaterial] = []
## A lightning flash on top of everything else, as linear light added to the sky's share.
static var _flash := Vector3.ZERO
## What the world's materials last took of MapSun, so a lightning strike's frames don't resend it.
static var _sun_pushed := {}
## The light_environment's lightstyle, as a brightness (1.0 = 'm').
static var _sun_style := 1.0
## Whether the sun was compiled onto a style of its own (ww_chasm), which the lightstyle texture
## already fades on the world — so only models take _sun_style from here.
static var _sun_has_layer := false


## Times by name, for /time and --time.
const NAMED := {"midnight": 0.0, "night": 0.0, "dawn": 6.0, "sunrise": 6.0, "morning": 9.0,
	"noon": 12.0, "day": 12.0, "afternoon": 15.0, "dusk": 18.0, "sunset": 18.0, "evening": 19.5}


## Hours, as /time, --time and the pause slider give it: a name (NAMED), "h", "h.5" or "h:mm",
## 0 to 24. "" if none of those.
static func parse(text: String) -> String:
	var t := text.strip_edges().to_lower()
	if NAMED.has(t):
		return str(NAMED[t])
	var parts := t.split(":")
	if parts.size() == 2 and parts[0].is_valid_int() and parts[1].is_valid_int():
		var m := int(parts[1])
		if m < 0 or m >= 60:
			return ""
		t = str(int(parts[0]) + m / 60.0)
	if not t.is_valid_float() or float(t) < 0.0 or float(t) > 24.0:
		return ""
	return str(float(t))


## "18:30".
static func format(h: float) -> String:
	var minutes := roundi(h * 60.0) % (24 * 60)
	return "%d:%02d" % [floori(minutes / 60.0), minutes % 60]


## The `time` server var, hours.
static func hours() -> float:
	return float(ServerVars.get_value("time", 12.0))


## The `moon` server var: its phase, 0 new through 0.5 full.
static func moon() -> float:
	return clampf(float(ServerVars.get_value("moon", 0.5)), 0.0, 1.0)


const MOONS := {"new": 0.0, "crescent": 0.12, "half": 0.25, "gibbous": 0.37, "full": 0.5}


## A phase as /moon takes it, a name or 0 to 1, as the var's string; "" if it is neither.
static func parse_moon(text: String) -> String:
	var t := text.strip_edges().to_lower()
	if MOONS.has(t):
		return str(MOONS[t])
	return str(float(t)) if t.is_valid_float() and float(t) >= 0.0 and float(t) <= 1.0 else ""


## 0 by day to 1 at full night, at the server's time.
static func amount() -> float:
	return OvercastSky.night_at(hours())


## Whether conversion found a sky share to turn down: no light_environment, no night.
static func has_sun(map_root: Node) -> bool:
	return map_root != null and (map_root.get_meta("light_grid", {}) as Dictionary).has("sun_slices")


static func sky_for(sky_name: String, map_root: Node) -> String:
	if sky_name.is_empty() or amount() < 0.5 or sky_name in NIGHT_SKIES or not has_sun(map_root):
		return sky_name
	return SKY


## A map load starts back at the sun as compiled.
static func reset() -> void:
	_root = null
	_world_mats.clear()
	_liquid_mats.clear()
	_sun_pushed = {}
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
	_sun_pushed = {}
	if map_root:
		_collect(map_root)
	_push()


## Lightning: `flash` is linear light added to the sky's share for as long as it is non-zero, so
## the open map lights up and a torch-lit room does not. Called every frame of a strike, which is
## why it sets the materials apply() found rather than walking the map again.
static func set_flash(flash: Vector3) -> void:
	_flash = flash
	_push()


## The time of day's linear-light multiplier on the sky's light: ones by day, warm at dusk,
## moonlight at night (OvercastSky.scene_light_at).
static func night_light() -> Vector3:
	var c := OvercastSky.scene_light_at(hours(), OvercastSky.DUSK_LIGHT, OvercastSky.MOON_LIGHT, moon())
	return Vector3(c.r, c.g, c.b).max(Vector3.ZERO)


static func _push() -> void:
	var night := night_light()
	var style := pow(maxf(_sun_style, 0.0), 1.0 / LIGHTMAP_GAMMA)
	var world := (night if _sun_has_layer else night * style) + _flash
	# A sunless map's liquid has no night to match: leave the whole map as it was.
	var liquid := night + _flash if has_sun(_root) else Vector3.ONE
	var sun := MapSun.update(hours(), style)
	sun["unbaked"] = 1.0 if MapSun.moving() else 0.0
	var sun_changed := sun != _sun_pushed
	_sun_pushed = sun
	for mat in _world_mats:
		mat.set_shader_parameter("sky_light", world)
		if sun_changed:
			mat.set_shader_parameter("sun_unbaked", sun["unbaked"])
			mat.set_shader_parameter("sun_light", sun["world"])
			mat.set_shader_parameter("sun_baked", sun["baked"])
	for mat in _liquid_mats:
		mat.set_shader_parameter("sky_light", liquid)
	LightGrid.set_lighting(night * style + _flash, sun["unbaked"], sun["model"], sun["baked"])


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
