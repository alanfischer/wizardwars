class_name Skybox
extends Node

## Stands in for the shipped 256px cubemap while dynamic weather is on, on every renderer: the
## moving clouds and the storm deck closing over are what show the weather coming. Applied as a
## material_override on the sky meshes rather than by re-pointing the map's own shared sky
## material: the BSP importer caches one material per texture and hands it to every mesh that
## needs it (goldsrc_bsp.cpp), so mutating it would edit a resource the map cache may hand back
## on the next load. An override is per-instance and clears by assigning null.
const ProceduralSkyShader = preload("res://shaders/sky_procedural.gdshader")
## Where the sky sorts in the transparent queue. Must match RENDER_PRIORITY_SKY in
## goldsrc_bsp.cpp, which is where the stock sky material gets the same number: an override
## replaces that material outright, so a mismatch here moves the sky only under dynamic weather.
##
## Strictly below WaterSurfaces.PRIORITY_BEFORE, and that is the whole point of the number.
## The liquid's depth prepass writes depth at the water surface; the sky writes none and is
## drawn with depth TEST on, so a sky face behind water that draws after the prepass is
## rejected and the water blends over a cleared buffer instead of over the sky.
const PRIORITY := -3

var _sky_surfaces: Array[MeshInstance3D] = []
var _cubemap: Cubemap
var _params: Dictionary = {}
var _enhanced_material: ShaderMaterial
var _enhanced_on := false
## How far the procedural sky has closed over for rain, 0 to 1. See set_storm.
var storm := 0.0
## How much of the sky's share of the light a cloud overhead takes off the ground.
const CLOUD_SHADOW := 0.65
## Cloud cover once a storm has closed the sky over.
const STORM_COVER := 0.97
## Tiling cloud noise for the procedural sky, made once: sampling it costs a fraction of
## computing the octaves per pixel, which pays for the extra samples the cloud shading takes.
static var _cloud_noise: Texture2D


## `sun_ent` is the map's light_environment entity dict, used to point the procedural sun the way
## the mapper lit the level. Optional — SkyPreset falls back to the sky art, then to a default.
func setup(sky_name: String, map_root: Node = null, sun_ent: Dictionary = {}) -> void:
	# The cloud globals outlive a map; a sky with no clouds must not inherit the last one's.
	RenderingServer.global_shader_parameter_set("cloud_shadow", 0.0)
	if not ServerVars.value_changed.is_connected(_on_server_var_changed):
		ServerVars.value_changed.connect(_on_server_var_changed)
	if sky_name.is_empty():
		return

	# Cubemap layer order +X,-X,+Y,-Y,+Z,-Z maps to GoldSrc rt,lf,up,dn,bk,ft
	# (gl_warp.c convention: ft=-Y, bk=+Y); shader maps cubemap Y->GS Z(up), Z->GS Y(forward).
	var suffixes := ["rt", "lf", "up", "dn", "bk", "ft"]

	var images: Array[Image] = []
	for suffix in suffixes:
		var img := AssetLoader.load_sky_image(sky_name, suffix)
		if img == null:
			var path := "sky/%s%s.tga" % [sky_name, suffix]
			var tex := load(path) as Texture2D
			if tex == null:
				push_warning("Sky texture not found: %s" % path)
				return
			img = tex.get_image()
		images.append(img)

	# HL's up/down face orientation (MakeSkyVec st_to_vec) doesn't match OpenGL cubemap convention.
	images[2].rotate_90(COUNTERCLOCKWISE)
	images[3].rotate_90(CLOCKWISE)

	_cubemap = Cubemap.new()
	_cubemap.create_from_images(images)

	var env := Environment.new()
	# BSP sky surfaces sample the cubemap themselves; black background just covers gaps.
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color.BLACK
	# Flat ambient approximates GoldSrc's per-entity lightmap sampling for models w/o baked light.
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.15, 0.15, 0.15)
	env.ambient_light_energy = 1.0

	var world_env := WorldEnvironment.new()
	world_env.name = "WorldEnvironment"
	world_env.environment = env
	add_child(world_env)

	# Measured after the two rotations above, so the face orientations SkyPreset reasons about
	# are the ones the cubemap actually ended up with.
	_params = SkyPreset.build(sky_name, images,
		SkyPreset.sun_dir_from_light_environment(sun_ent),
		SkyPreset.sun_color_from_light_environment(sun_ent))

	if map_root != null:
		_collect_sky_surfaces(map_root)
		warn_if_baked_priority_is_stale()
		_apply_sky_cubemap(map_root, _cubemap)
		apply_enhanced(procedural())

	Log.info("Skybox loaded: %s (%d sky surfaces)" % [sky_name, _sky_surfaces.size()])


## The sky's sort order is written in two places — here for the procedural override, and in
## goldsrc_bsp.cpp for the material baked into the .scn — and only the first is this file's to
## set. When they disagree the map still renders, and it renders WRONG in a way that points
## anywhere but here: the override covers for the baked material, so dynamic weather looks
## perfect and without it water draws over a hole where the sky should be. That reads as a
## water bug, it reads as a weather bug, and it is neither. Say so instead.
## Returns true when it found the disagreement, so a test can drive it without reading the log.
func warn_if_baked_priority_is_stale() -> bool:
	for surf in _sky_surfaces:
		if not is_instance_valid(surf) or surf.mesh == null:
			continue
		var baked := surf.mesh.surface_get_material(0)
		if baked == null or baked.render_priority == PRIORITY:
			continue
		Log.warn(("Sky sorts at %d in this map's baked material but %d here. The GoldSrcBSP "
			+ "extension that converted it is older than this checkout, or the .scn predates "
			+ "it: rebuild with ./build_extension.sh, which re-keys the map cache and forces "
			+ "a reconvert. Until then the sky draws on liquid's depth-prepass rung and water "
			+ "over it goes flat and opaque without dynamic weather.")
			% [baked.render_priority, PRIORITY])
		return true  # one line is the message; every sky surface in the map shares one material
	return false


## Whether the procedural sky stands in for the art: the `dynamic_weather` server var.
static func procedural() -> bool:
	return bool(ServerVars.get_value("dynamic_weather", false))


func _on_server_var_changed(key: String, _value: Variant) -> void:
	if key == "dynamic_weather":
		apply_enhanced(procedural())


## Swap the procedural sky in or out. Safe to call repeatedly and before/without a map.
func apply_enhanced(enabled: bool) -> void:
	if enabled and _params.is_empty():
		return  # no sky art loaded, so nothing was measured to stand in for it
	var mat := _get_enhanced_material() if enabled else null
	_enhanced_on = enabled
	for surf in _sky_surfaces:
		if is_instance_valid(surf):
			surf.material_override = mat
	_push_clouds()
	if enabled:
		# Which way the sun ended up pointing is the one number a screenshot can't settle when a
		# sky looks wrong, and it comes from the map rather than from anything here.
		Log.info("Procedural sky on: sun %v, clouds %.2f, stars %.2f" % [
			_params["sun_dir"], _params["cloud_amount"], _params["star_amount"]])
	else:
		Log.info("Procedural sky off: drawing the shipped cubemap")


## Light the sky from within, brightest toward `dir` (world space); black puts it out. Lightning.
## Both materials take it — the map's own and the procedural override — so a quality change
## mid-flash cannot leave one lit.
func set_flash(color: Color, dir: Vector3) -> void:
	var c := Vector3(color.r, color.g, color.b)
	var seen := {}
	for surf in _sky_surfaces:
		if not is_instance_valid(surf) or surf.mesh == null:
			continue
		var mat := surf.mesh.surface_get_material(0) as ShaderMaterial
		if mat and not seen.has(mat):
			seen[mat] = true
			mat.set_shader_parameter("flash_color", c)
			mat.set_shader_parameter("flash_dir", dir)
	if _enhanced_material:
		_enhanced_material.set_shader_parameter("flash_color", c)
		_enhanced_material.set_shader_parameter("flash_dir", dir)


## Rain on the procedural sky (dynamic weather): 0 clear, 1 a dark overcast deck. The stock
## cubemap has no clouds of its own to thicken, so this leaves it alone.
func set_storm(amount: float) -> void:
	storm = amount
	if _enhanced_material:
		_enhanced_material.set_shader_parameter("storm", amount)
	if _enhanced_on:
		RenderingServer.global_shader_parameter_set("cloud_cover",
			lerpf(_params["cloud_amount"], STORM_COVER, storm))


## The clouds.gdshaderinc globals: the procedural sky's cloud layer, and the shadow it casts on
## the map and models. No shadow unless the procedural sky is drawing clouds.
func _push_clouds() -> void:
	var amount: float = _params.get("cloud_amount", 0.0)
	var casting := _enhanced_on and amount > 0.0
	RenderingServer.global_shader_parameter_set("cloud_shadow", CLOUD_SHADOW if casting else 0.0)
	if not _enhanced_on:
		return
	RenderingServer.global_shader_parameter_set("cloud_noise", cloud_noise())
	RenderingServer.global_shader_parameter_set("cloud_cover", lerpf(amount, STORM_COVER, storm))
	RenderingServer.global_shader_parameter_set("cloud_sun_dir", (_params["sun_dir"] as Vector3).normalized())
	for key in ["cloud_scale", "cloud_speed", "cloud_softness"]:
		RenderingServer.global_shader_parameter_set(key, _params[key])


## The colour the sky draws at the horizon right now, linear, flash aside: what haze over open ground
## fades into (WeatherSystem). Black with no sky art measured. Follows sky_procedural.gdshader's
## storm greying, in the space that shader works in on this renderer (EntityRender.renderer_is_linear).
func horizon_color() -> Color:
	if _params.is_empty():
		return Color.BLACK
	var art: Color = _params["horizon_color"]  # sRGB, measured off the cubemap
	if not _enhanced_on:
		return art.srgb_to_linear()
	var linear := EntityRender.renderer_is_linear()
	var h := art.srgb_to_linear() if linear else art
	var grey := _luma(h) * 0.55
	var col := h.lerp(Color(grey, grey, grey), storm)
	var blend: float = _params.get("cubemap_blend", 0.0)
	if blend > 0.0:
		var a := _luma(h) * 0.5
		col = col.lerp(h.lerp(Color(a, a, a), storm), blend)
	return col if linear else col.srgb_to_linear()


static func _luma(c: Color) -> float:
	return c.r * 0.299 + c.g * 0.587 + c.b * 0.114


func _get_enhanced_material() -> ShaderMaterial:
	if _enhanced_material:
		return _enhanced_material
	_enhanced_material = ShaderMaterial.new()
	_enhanced_material.shader = ProceduralSkyShader
	# The stock sky material carries this so the sky draws before the world and reads as a true
	# background; an override replaces the material outright, so it has to carry it too.
	_enhanced_material.render_priority = PRIORITY
	_enhanced_material.set_shader_parameter("sky_cubemap", _cubemap)
	for key in _params:
		_enhanced_material.set_shader_parameter(key, _params[key])
	_enhanced_material.set_shader_parameter("storm", storm)
	return _enhanced_material


static func cloud_noise() -> Texture2D:
	if _cloud_noise:
		return _cloud_noise
	var noise := FastNoiseLite.new()
	noise.seed = 7
	noise.noise_type = FastNoiseLite.TYPE_PERLIN
	noise.frequency = 8.0 / 512.0
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 6
	var img := noise.get_seamless_image(512, 512)
	img.generate_mipmaps()
	_cloud_noise = ImageTexture.create_from_image(img)
	return _cloud_noise


func _collect_sky_surfaces(node: Node) -> void:
	if node is MeshInstance3D and node.has_meta("is_sky_surface"):
		_sky_surfaces.append(node as MeshInstance3D)
	for child in node.get_children():
		_collect_sky_surfaces(child)


func _apply_sky_cubemap(node: Node, cubemap: Cubemap) -> void:
	if node is MeshInstance3D and node.has_meta("is_sky_surface"):
		var mat = node.get_active_material(0)
		if mat is ShaderMaterial:
			mat.set_shader_parameter("sky_cubemap", cubemap)
	for child in node.get_children():
		_apply_sky_cubemap(child, cubemap)
