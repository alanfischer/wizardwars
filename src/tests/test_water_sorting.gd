extends "res://src/tests/test_base.gd"
## Where a liquid's depth-prepass twin sorts, which is what decides whether anything drawn after
## the water can be inside it. Effect sprites sort at render_priority 2 and priority outranks
## depth in the transparent queue, so with no liquid depth in the buffer a fireball sunk in
## ww_hunt's harbour draws at full strength on top of it.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.

const COLOUR_PRIORITY := 0  # what the converter gives the liquid colour pass


## A liquid surface and its twin, named and shaped the way goldsrc_bsp.cpp emits them.
func _water_pair() -> Node3D:
	var parent := Node3D.new()
	var surface := MeshInstance3D.new()
	surface.name = "!waterblue"
	var mesh := BoxMesh.new()
	mesh.surface_set_material(0, ShaderMaterial.new())
	surface.mesh = mesh
	surface.set_meta("is_water_surface", true)
	parent.add_child(surface)
	var twin := MeshInstance3D.new()
	twin.name = "!waterblue_depth"
	twin.mesh = mesh
	var depth_mat := ShaderMaterial.new()
	# A real twin's shader declares depth_push; without the uniform the parameter would be
	# silently dropped and the test below could not tell a set push from a missing one.
	var depth_shader := Shader.new()
	depth_shader.code = "shader_type spatial;\nuniform float depth_push = 1.002;\nvoid fragment() { ALPHA = 0.0; }"
	depth_mat.shader = depth_shader
	depth_mat.render_priority = -1
	twin.material_override = depth_mat
	parent.add_child(twin)
	_root().add_child(parent)
	_spawned.append(parent)
	return parent


func _twin(root: Node3D) -> MeshInstance3D:
	return root.get_child(1)


func test_twin_stamps_before_the_colour_pass_without_absorption() -> void:
	var root := _water_pair()
	WaterSurfaces.apply(root, false)
	var twin := _twin(root)
	assert_true(twin.visible, "the twin draws")
	assert_lt(twin.material_override.render_priority, COLOUR_PRIORITY,
			"and stamps ahead of the colour pass, so far water cannot blend over near water")


func test_twin_stamps_before_the_colour_pass_with_absorption_too() -> void:
	# The twin used to be moved BEHIND the colour pass here (and before that, hidden outright),
	# to keep its depth out of the DEPTH_TEXTURE the colour pass reads for thickness. It cost
	# water-over-water sorting on the whole High preset: ww_golem's moat showed the far wall of
	# every water brush standing up across the surface as a vertical band. The twin's shader now
	# asks for the depth texture itself, so Godot's one lazy copy is taken at the twin's draw,
	# before any liquid depth exists — and the twin can stay where sorting needs it.
	var root := _water_pair()
	WaterSurfaces.apply(root, true)
	var twin := _twin(root)
	assert_true(twin.visible, "the twin still draws")
	assert_lt(twin.material_override.render_priority, COLOUR_PRIORITY,
			"and still stamps ahead of the colour pass, absorption or no absorption")


func test_the_twin_always_precedes_effect_sprites() -> void:
	# AssetLoader's sprite template, and every effect built on it, sorts at 2.
	var sprite_priority: int = AssetLoader.get_sprite_material_template().render_priority
	for enabled in [false, true]:
		var root := _water_pair()
		WaterSurfaces.apply(root, enabled)
		assert_lt(_twin(root).material_override.render_priority, sprite_priority,
				"liquid depth is stamped before a spell sprite tests against it (absorption %s)"
						% ("on" if enabled else "off"))


func test_absorption_reaches_the_colour_pass() -> void:
	var root := _water_pair()
	assert_eq(WaterSurfaces.apply(root, true), 1, "one liquid surface touched")
	var surface: MeshInstance3D = root.get_child(0)
	var mat := surface.mesh.surface_get_material(0) as ShaderMaterial
	assert_eq(mat.get_shader_parameter(WaterSurfaces.PARAM), true, "and it has the flag")


## A liquid slab resting on y=0, the way a map's pool is built (see test_shallow_liquid_damage).
func _pool(height := 4.0) -> Area3D:
	var area := Area3D.new()
	area.collision_layer = GameConsts.MASK_WATER
	area.collision_mask = 0
	area.monitorable = true
	area.monitoring = false
	var box := BoxShape3D.new()
	box.size = Vector3(8.0, height, 8.0)
	var col := CollisionShape3D.new()
	col.shape = box
	col.position = Vector3(0.0, height * 0.5, 0.0)
	area.add_child(col)
	_root().add_child(area)
	_spawned.append(area)
	return area


func _projectile() -> Projectile:
	var p := Projectile.new()
	_root().add_child(p)
	_spawned.append(p)
	p._create_sprite("sprites/animglow01.spr")
	return p


func test_a_submerged_effect_sorts_under_the_liquid_it_is_in() -> void:
	# The whole point of PRIORITY_SUBMERGED: it has to clear the twin as well as the colour pass,
	# or a twin stamping at PRIORITY_BEFORE depth-rejects the effect instead of dimming it.
	assert_lt(WaterSurfaces.PRIORITY_SUBMERGED, WaterSurfaces.PRIORITY_BEFORE,
			"a submerged effect is drawn before any liquid depth is stamped")
	assert_lt(WaterSurfaces.PRIORITY_SUBMERGED, AssetLoader.EFFECT_PRIORITY,
			"and before the liquid colour pass, so the water blends over it")


func test_sort_for_liquid_moves_a_material_both_ways() -> void:
	var mat := AssetLoader.get_sprite_material_template().duplicate()
	AssetLoader.sort_for_liquid([mat], true)
	assert_eq(mat.render_priority, WaterSurfaces.PRIORITY_SUBMERGED, "into the water")
	AssetLoader.sort_for_liquid([mat], false)
	assert_eq(mat.render_priority, AssetLoader.EFFECT_PRIORITY, "and back out of it")


func test_a_projectile_sinks_and_surfaces_with_its_sprite() -> void:
	_pool()
	var p := _projectile()
	assert_false(p._liquid_sorted.is_empty(), "the sprite registered its own material")
	var mat: Material = p._liquid_sorted[0]

	p.global_position = Vector3(0.0, 1.0, 0.0)  # inside the pool
	await _physics_frame()
	p._process(0.0)
	assert_eq(mat.render_priority, WaterSurfaces.PRIORITY_SUBMERGED, "in the pool it sorts under")

	p.global_position = Vector3(0.0, 6.0, 0.0)  # clear of the surface
	await _physics_frame()
	p._process(0.0)
	assert_eq(mat.render_priority, AssetLoader.EFFECT_PRIORITY, "out of it, it sorts over again")


func test_a_projectile_with_no_sprite_pays_nothing() -> void:
	# Skull, ice shard and bird are MDL models: opaque geometry already sorts correctly against
	# the water, so they register nothing and _process has no query to run.
	var p := Projectile.new()
	_root().add_child(p)
	_spawned.append(p)
	assert_true(p._liquid_sorted.is_empty(), "no sprite, no liquid bookkeeping")
	p._process(0.0)


func test_depth_push_is_off_except_on_compatibility() -> void:
	# The push opens a band 0.2% of view distance deep behind the surface, and every liquid face
	# inside it draws too — a moat's floor and back wall blinking in and out as the band breathes
	# with the camera. Only gl_compatibility still needs it: the RenderingDevice renderers draw
	# reverse-Z at GEQUAL, where the prepass at equal depth lets the colour pass through anyway.
	var root := _water_pair()
	WaterSurfaces.apply(root, true)
	var got: float = _twin(root).material_override.get_shader_parameter(WaterSurfaces.PUSH_PARAM)
	var compat := RenderingServer.get_current_rendering_method() == "gl_compatibility"
	assert_almost_eq(got, WaterSurfaces.PUSH_COMPAT if compat else WaterSurfaces.PUSH_NONE, 0.0000001,
			"depth push for the %s renderer" % RenderingServer.get_current_rendering_method())


func test_the_sky_is_drawn_before_any_liquid_depth() -> void:
	# The sky writes no depth of its own but IS depth-tested, so a sky face behind water that
	# draws after the prepass is rejected outright and the water blends over a cleared buffer
	# instead of over the sky. Both sat at -1 — the same rung, order left to the renderer — and
	# ww_golem's moat carried hard-edged slabs of flat opaque blue whose edges were sky-mesh
	# boundaries, unchanged by absorption, by absorb_distance, or by swapping the sky art.
	assert_lt(Skybox.PRIORITY, WaterSurfaces.PRIORITY_BEFORE,
			"the sky is in the buffer before liquid stamps depth over it")
	assert_lt(Skybox.PRIORITY, WaterSurfaces.PRIORITY_SUBMERGED,
			"and before anything sitting inside a pool, so it cannot paint over it either")


func test_a_converted_map_gives_its_sky_that_priority() -> void:
	# Skybox.PRIORITY only moves the High preset's override. The stock material is built in
	# goldsrc_bsp.cpp and baked into the .scn, so the two numbers can drift apart without a
	# single caller changing — which would leave the slab in place for everyone else.
	var converter := MapConverter.new()
	_root().add_child(converter)
	_spawned.append(converter)
	assert_true(converter.convert("ww_golem"), "ww_golem converts")
	var scn := ResourceLoader.load("user://resources/maps/ww_golem.scn", "",
			ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	var map: Node3D = scn.instantiate()
	_root().add_child(map)
	_spawned.append(map)
	var skies := 0
	var twins := 0
	for mi in map.find_children("*", "MeshInstance3D", true, false):
		if mi.has_meta("is_sky_surface"):
			skies += 1
			assert_lt((mi as MeshInstance3D).get_active_material(0).render_priority,
					WaterSurfaces.PRIORITY_BEFORE, "%s sorts behind liquid depth" % mi.name)
		elif String(mi.name).ends_with("_depth"):
			twins += 1
			assert_eq((mi as MeshInstance3D).material_override.render_priority,
					WaterSurfaces.PRIORITY_BEFORE, "%s stamps at the prepass rung" % mi.name)
	assert_gt(skies, 0, "ww_golem has sky to sort")
	assert_gt(twins, 0, "and liquid twins to sort it against")


func test_the_fancy_sky_keeps_that_priority_across_a_quality_toggle() -> void:
	# The lobby's quality dropdown reaches Skybox.apply_enhanced on every change, and the two
	# sky materials come from different places: the procedural override is built here, the
	# stock one in goldsrc_bsp.cpp. Either can be the sky behind a pool, so both have to sort
	# behind liquid's prepass — and the override is built once and cached, so a toggle cycle is
	# where a priority set at the wrong moment would show up.
	var converter := MapConverter.new()
	_root().add_child(converter)
	_spawned.append(converter)
	assert_true(converter.convert("ww_golem"), "ww_golem converts")
	var scn := ResourceLoader.load("user://resources/maps/ww_golem.scn", "",
			ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	var map: Node3D = scn.instantiate()
	_root().add_child(map)
	_spawned.append(map)
	var sky := Skybox.new()
	_root().add_child(sky)
	_spawned.append(sky)
	var ws := map.get_node_or_null("worldspawn")
	sky.setup(str(ws.get_meta("entity", {}).get("skyname", "")), map, {})

	var surf: MeshInstance3D = null
	for mi in map.find_children("*", "MeshInstance3D", true, false):
		if mi.has_meta("is_sky_surface"):
			surf = mi
			break
	assert_true(surf != null, "ww_golem has a sky surface to check")
	for enabled in [true, false, true]:
		sky.apply_enhanced(enabled)
		var mat: Material = surf.material_override if enabled else surf.get_active_material(0)
		assert_eq(mat.render_priority, Skybox.PRIORITY,
				"the %s sky sorts at Skybox.PRIORITY" % ("procedural" if enabled else "stock"))
		assert_lt(mat.render_priority, WaterSurfaces.PRIORITY_BEFORE,
				"and behind liquid's prepass either way")


## A sky surface as the importer emits one: the material lives on the MESH, which is what an
## override shadows and what a stale extension gets wrong.
func _sky_surface(baked_priority: int) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = "sky"
	var mesh := BoxMesh.new()
	var mat := ShaderMaterial.new()
	mat.render_priority = baked_priority
	mesh.surface_set_material(0, mat)
	mi.mesh = mesh
	mi.set_meta("is_sky_surface", true)
	_root().add_child(mi)
	_spawned.append(mi)
	return mi


func test_a_stale_extension_says_so_instead_of_looking_like_a_water_bug() -> void:
	# The half-broken state is the dangerous one: the procedural override shadows the baked
	# material, so High renders perfectly and every level below it draws water over a hole.
	# Nothing about that points at the sky, so the sky has to point at itself.
	var sky := Skybox.new()
	_root().add_child(sky)
	_spawned.append(sky)
	sky._sky_surfaces.append(_sky_surface(Skybox.PRIORITY))
	assert_false(sky.warn_if_baked_priority_is_stale(), "a matching pair is quiet")
	sky._sky_surfaces.clear()
	sky._sky_surfaces.append(_sky_surface(WaterSurfaces.PRIORITY_BEFORE))
	assert_true(sky.warn_if_baked_priority_is_stale(),
			"a map baked by an extension that still sorts sky on the prepass rung must warn")
