class_name Skybox
extends Node

## Stands in for the shipped 256px cubemap at the "high" quality level. Applied as a
## material_override on the sky meshes rather than by re-pointing the map's own shared sky
## material: the BSP importer caches one material per texture and hands it to every mesh that
## needs it (goldsrc_bsp.cpp), so mutating it would edit a resource the map cache may hand back
## on the next load. An override is per-instance and clears by assigning null.
const ProceduralSkyShader = preload("res://shaders/sky_procedural.gdshader")
## Where the sky sorts in the transparent queue. Must match RENDER_PRIORITY_SKY in
## goldsrc_bsp.cpp, which is where the stock sky material gets the same number: an override
## replaces that material outright, so a mismatch here moves the sky only on the High preset.
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


## `sun_ent` is the map's light_environment entity dict, used to point the procedural sun the way
## the mapper lit the level. Optional — SkyPreset falls back to the sky art, then to a default.
func setup(sky_name: String, map_root: Node = null, sun_ent: Dictionary = {}) -> void:
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
		apply_enhanced(RenderQuality.sky_enhanced())

	Log.info("Skybox loaded: %s (%d sky surfaces)" % [sky_name, _sky_surfaces.size()])


## The sky's sort order is written in two places — here for the procedural override, and in
## goldsrc_bsp.cpp for the material baked into the .scn — and only the first is this file's to
## set. When they disagree the map still renders, and it renders WRONG in a way that points
## anywhere but here: the override covers for the baked material, so the High preset looks
## perfect and every level below it draws water over a hole where the sky should be. That
## reads as a water bug, it reads as a quality-preset bug, and it is neither. Say so instead.
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
			+ "over it goes flat and opaque on every quality level below High.")
			% [baked.render_priority, PRIORITY])
		return true  # one line is the message; every sky surface in the map shares one material
	return false


## Swap the procedural sky in or out. Safe to call repeatedly and before/without a map — the
## lobby's quality dropdown reaches this on every change.
func apply_enhanced(enabled: bool) -> void:
	if enabled and _params.is_empty():
		return  # no sky art loaded, so nothing was measured to stand in for it
	var mat := _get_enhanced_material() if enabled else null
	for surf in _sky_surfaces:
		if is_instance_valid(surf):
			surf.material_override = mat
	if enabled:
		# Which way the sun ended up pointing is the one number a screenshot can't settle when a
		# sky looks wrong, and it comes from the map rather than from anything here.
		Log.info("Procedural sky on: sun %v, clouds %.2f, stars %.2f" % [
			_params["sun_dir"], _params["cloud_amount"], _params["star_amount"]])
	else:
		Log.info("Procedural sky off: drawing the shipped cubemap")


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
	return _enhanced_material


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
