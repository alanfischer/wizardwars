class_name Skybox
extends Node

## Stands in for the shipped 256px cubemap while dynamic weather is on, on every renderer: the
## moving clouds and the storm deck closing over are what show the weather coming. Applied as a
## material_override on the sky meshes rather than by re-pointing the map's own shared sky
## material: the BSP importer caches one material per texture and hands it to every mesh that
## needs it (goldsrc_bsp.cpp), so mutating it would edit a resource the map cache may hand back
## on the next load. An override is per-instance and clears by assigning null.
##
## In game, one node for the session: build -> clear per map. Tools call setup() alone.
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
var _world_env: WorldEnvironment
var _map_root: Node3D
var _built_sky := ""  # the skyname setup() last drew: the map's own, or NightMode's
var _cubemap: Cubemap
var _params: Dictionary = {}
## The procedural sky (overcast-godot), drawn on the sky brushes under dynamic weather; the
## weather's sky either way. None until sky art is measured.
var overcast: SkyboxSky


## `sun_ent` is the map's light_environment entity dict, used to point the procedural sun the way
## the mapper lit the level. Optional — SkyPreset falls back to the sky art, then to a default.
## `day_sky` is the sky the procedural one is measured off, when the cubemap shown is the night
## standing in for it: the procedural sky does its own night.
## Safe to call again: each call replaces what the last one built.
func setup(sky_name: String, map_root: Node = null, sun_ent: Dictionary = {}, day_sky := "") -> void:
	if not ServerVars.value_changed.is_connected(_on_server_var_changed):
		ServerVars.value_changed.connect(_on_server_var_changed)
	_teardown()
	# Collected before any art is loaded: passthrough hides the sky faces of a map with none too.
	if map_root != null:
		_collect_sky_surfaces(map_root)
	if sky_name.is_empty():
		return

	var images := _load_faces(sky_name)
	if images.is_empty():
		return

	_cubemap = Cubemap.new()
	_cubemap.create_from_images(images)
	_built_sky = sky_name

	var env := Environment.new()
	# BSP sky surfaces sample the cubemap themselves; black background just covers gaps.
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color.BLACK
	# Flat ambient approximates GoldSrc's per-entity lightmap sampling for models w/o baked light.
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.15, 0.15, 0.15)
	env.ambient_light_energy = 1.0

	_world_env = WorldEnvironment.new()
	_world_env.name = "WorldEnvironment"
	_world_env.environment = env
	add_child(_world_env)

	# Measured after the two rotations above, so the face orientations SkyPreset reasons about
	# are the ones the cubemap actually ended up with.
	var measured := sky_name
	var faces := images
	if not day_sky.is_empty() and day_sky != sky_name:
		var day_faces := _load_faces(day_sky)
		if not day_faces.is_empty():
			measured = day_sky
			faces = day_faces
	_params = SkyPreset.build(measured, faces,
		SkyPreset.sun_dir_from_light_environment(sun_ent),
		SkyPreset.sun_color_from_light_environment(sun_ent))

	var params := _params.duplicate()
	params["drawing"] = false
	overcast = SkyboxSky.new(self, params)
	# The stock sky material carries this so the sky draws before the world and reads as a true
	# background; an override replaces the material outright, so it has to carry it too.
	overcast.render_priority = PRIORITY
	overcast.time_of_day = NightMode.hours()

	if map_root != null:
		warn_if_baked_priority_is_stale()
		_apply_sky_cubemap()
		apply_enhanced(procedural())

	Log.info("Skybox loaded: %s (%d sky surfaces)" % [sky_name, _sky_surfaces.size()])


func _teardown() -> void:
	if _world_env:
		remove_child(_world_env)  # out now, so the replacement is the only WorldEnvironment
		_world_env.queue_free()
	_world_env = null
	for surf in _sky_surfaces:
		if is_instance_valid(surf):
			surf.material_override = null
	_sky_surfaces.clear()
	_cubemap = null
	_params = {}
	overcast = null


func _ready() -> void:
	set_process(false)  # on only while a map's light grid lights the ambient


## Once the map is in the tree, its light grid loaded (MapWorld).
func build(map_root: Node3D) -> void:
	_map_root = map_root
	_setup_for_map()
	set_process(AssetLoader.light_grid != null)


func clear() -> void:
	_teardown()
	_built_sky = ""
	_map_root = null
	set_process(false)


## The gameplay Environment, or null before a map has built one.
func environment() -> Environment:
	return _world_env.environment if _world_env else null


## From the worldspawn skyname, or the night sky standing in for it. The procedural sky is
## measured off the map's own sky either way, and does its own night.
func _setup_for_map() -> void:
	var map_sky := _map_sky_name(_map_root)
	# Read straight off the map rather than waiting for LightEnvironment._ready: entity _ready
	# order follows the BSP lump order, and the sky is built before any of them run.
	setup(NightMode.sky_for(map_sky, _map_root), _map_root,
		_find_entity(_map_root, "light_environment"), map_sky)
	if Game.weather_system:
		Game.weather_system.sky = overcast
	# A fresh Environment per map, so the quality level has to be stamped onto this one —
	# before precache_resources reuses the resource to warm the model shaders.
	RenderQuality.apply(RenderQuality.load_level(), get_viewport(), environment())
	apply_vr_passthrough(XRManager.vr_passthrough)


func apply_vr_passthrough(enabled: bool) -> void:
	if not XRManager.is_vr:
		return
	# xr/openxr/extensions/meta/passthrough registers XR_FB_passthrough at session creation, so the
	# runtime starts the camera feed automatically when alpha-blend is requested.
	var xr_interface := XRServer.find_interface("OpenXR") as XRInterface
	if xr_interface:
		xr_interface.environment_blend_mode = (
			XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND if enabled
			else XRInterface.XR_ENV_BLEND_MODE_OPAQUE
		)
	get_viewport().transparent_bg = enabled
	for surf in _sky_surfaces:
		if is_instance_valid(surf):
			surf.visible = not enabled
	var env := environment()
	if env:
		env.background_color = Color(0.0, 0.0, 0.0, 0.0 if enabled else 1.0)


func _process(_delta: float) -> void:
	var env := environment()
	var player := Game.local_player
	if env and player:
		env.ambient_light_color = AssetLoader.light_grid.sample(player.global_position)


static func _map_sky_name(map_root: Node) -> String:
	var worldspawn := map_root.get_node_or_null("worldspawn")
	if worldspawn and worldspawn.has_meta("entity"):
		return worldspawn.get_meta("entity").get("skyname", "")
	return ""


## First entity of `classname` in the map's entity list, as its raw key/value dict. Maps carry
## duplicates of the map-wide ones (ww_feudal and ww_golem ship three light_environments each,
## left over from compile tools), and GoldSrc uses the first, so this stops at the first too.
static func _find_entity(map_root: Node, classname: String) -> Dictionary:
	for child in map_root.get_children():
		if not child.has_meta("entity"):
			continue
		var ent: Dictionary = child.get_meta("entity")
		if ent.get("classname", "") == classname:
			return ent
	return {}


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
	elif key == "time":
		if overcast:
			overcast.time_of_day = NightMode.hours()
		if _map_root:
			var sky_name := NightMode.sky_for(_map_sky_name(_map_root), _map_root)
			if sky_name != _built_sky:
				_swap_cubemap(sky_name)


## Night swaps the art only: the procedural sky is measured off the day sky either way. A map
## with no art to swap gets the whole setup.
func _swap_cubemap(sky_name: String) -> void:
	var images := _load_faces(sky_name) if _cubemap else []
	if images.is_empty():
		_setup_for_map()
		return
	_cubemap = Cubemap.new()
	_cubemap.create_from_images(images)
	_built_sky = sky_name
	_apply_sky_cubemap()
	Log.info("Skybox swapped to %s" % sky_name)


## Swap the procedural sky in or out. Safe to call repeatedly and before/without a map.
func apply_enhanced(enabled: bool) -> void:
	if enabled and _params.is_empty():
		return  # no sky art loaded, so nothing was measured to stand in for it
	var mat := overcast if enabled else null
	for surf in _sky_surfaces:
		if is_instance_valid(surf):
			surf.material_override = mat
	if overcast:
		overcast.drawing = enabled
	if enabled:
		# Which way the sun ended up pointing is the one number a screenshot can't settle when a
		# sky looks wrong, and it comes from the map rather than from anything here.
		Log.info("Procedural sky on: sun %v, clouds %.2f, stars %.2f" % [
			_params["sun_dir"], _params["cloud_amount"], _params["star_amount"]])
	else:
		Log.info("Procedural sky off: drawing the shipped cubemap")


## Lightning on the map's own sky material (SkyboxSky.set_flash lights the procedural one), so a
## quality change mid-flash cannot leave one lit.
func flash_stock(color: Color, dir: Vector3) -> void:
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


func _collect_sky_surfaces(node: Node) -> void:
	if node is MeshInstance3D and node.has_meta("is_sky_surface"):
		_sky_surfaces.append(node as MeshInstance3D)
	for child in node.get_children():
		_collect_sky_surfaces(child)


## The map's own material, under any procedural override.
func _apply_sky_cubemap() -> void:
	for surf in _sky_surfaces:
		if not is_instance_valid(surf):
			continue
		var mat := surf.get_surface_override_material(0)
		if mat == null and surf.mesh:
			mat = surf.mesh.surface_get_material(0)
		if mat is ShaderMaterial:
			(mat as ShaderMaterial).set_shader_parameter("sky_cubemap", _cubemap)


## The six faces in cubemap order, rotated as the cubemap needs; empty if any is missing.
static func _load_faces(sky_name: String) -> Array[Image]:
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
				return []
			img = tex.get_image()
		images.append(img)

	# HL's up/down face orientation (MakeSkyVec st_to_vec) doesn't match OpenGL cubemap convention.
	images[2].rotate_90(COUNTERCLOCKWISE)
	images[3].rotate_90(CLOCKWISE)
	return images
