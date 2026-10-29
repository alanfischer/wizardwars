extends "res://src/tests/test_base.gd"
## A blank `renderamt` is `renderamt 0` — engine-literal FX Amount. A mapper who left the field
## blank in Hammer ships an invisible-but-solid brush; reading blank as opaque drew them instead.
## Solid (mode 4) is the one mode that can still draw at 0, and only through a '{' texture's mask.
##
## Scene-run only (needs the EntityRender autoload): res://src/tests/run_tests.tscn.


## A brush-entity stand-in: one mesh carrying one material, opaque or '{'-masked.
func _brush(masked := false) -> Node3D:
	var root := Node3D.new()
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color.WHITE
	if masked:
		# _has_alpha_texture reads the albedo image, so the mask has to be a real texture.
		var img := Image.create(2, 2, false, Image.FORMAT_RGBA8)
		img.fill(Color(1, 1, 1, 0))
		mat.albedo_texture = ImageTexture.create_from_image(img)
	mesh.surface_set_material(0, mat)
	mi.mesh = mesh
	root.add_child(mi)
	_root().add_child(root)
	return root


func _mesh_of(root: Node3D) -> MeshInstance3D:
	return root.get_child(0)


func _alpha_of(root: Node3D) -> float:
	return _mesh_of(root).get_active_material(0).albedo_color.a


func test_unset_renderamt_is_not_drawn() -> void:
	var b := _brush()
	EntityRender.apply_render_properties(b, {"classname": "func_wall", "rendermode": "2"})
	assert_false(_mesh_of(b).visible, "a mode-2 brush with a blank FX Amount is invisible")
	b.queue_free()


func test_hidden_brush_keeps_the_entity_node_visible() -> void:
	# Only the meshes are hidden: the entity is still solid, and the game-visibility
	# latches (func_wall_toggle, func_breakable) read the entity node's own `visible`.
	var b := _brush()
	EntityRender.apply_render_properties(b, {"classname": "func_wall", "rendermode": "2"})
	assert_true(b.visible, "the entity node itself is untouched")
	b.queue_free()


func test_explicit_zero_is_invisible_too() -> void:
	var b := _brush()
	EntityRender.apply_render_properties(b,
		{"classname": "func_wall", "rendermode": "2", "renderamt": "0"})
	assert_false(_mesh_of(b).visible, "an explicit renderamt 0 hides the brush the same way")
	b.queue_free()


func test_explicit_partial_alpha_is_honoured() -> void:
	var b := _brush()
	EntityRender.apply_render_properties(b,
		{"classname": "func_wall", "rendermode": "2", "renderamt": "128"})
	assert_true(_mesh_of(b).visible, "a stated FX Amount draws")
	assert_almost_eq(_alpha_of(b), 128.0 / 255.0, 0.01, "and drives the blend")
	b.queue_free()


func test_color_mode_unset_is_not_drawn() -> void:
	var b := _brush()
	EntityRender.apply_render_properties(b,
		{"classname": "func_train", "rendermode": "1", "rendercolor": "0 0 0"})
	assert_false(_mesh_of(b).visible, "mode 1 blends off renderamt as well")
	b.queue_free()


func test_solid_mode_with_no_mask_and_no_amount_is_not_drawn() -> void:
	# TransAlpha is an alpha TEST, and an unmasked surface has nothing to test against, so
	# a blank FX Amount leaves it with nothing to draw. ww_golem's crystal1gibs/crystal2gibs
	# are the map set's only brushes in this shape: glass_bright shells around each gem,
	# there to shed glass gibs when the golem smashes the crystal, not to be seen.
	var b := _brush()
	EntityRender.apply_render_properties(b, {"classname": "func_breakable", "rendermode": "4"})
	assert_false(_mesh_of(b).visible, "an unmasked Solid brush with no FX Amount is invisible")
	b.queue_free()


func test_solid_mode_keeps_a_masked_surface_without_an_amount() -> void:
	# The mask is the alpha test, so it draws whatever the amount says — ww_feudal's two
	# '{blue' func_walls are exactly this, and they must keep their scissor material.
	var b := _brush(true)
	var before := _mesh_of(b).get_active_material(0)
	EntityRender.apply_render_properties(b, {"classname": "func_wall", "rendermode": "4"})
	assert_true(_mesh_of(b).visible, "a masked Solid brush draws with no FX Amount")
	assert_eq(_mesh_of(b).get_active_material(0), before, "and keeps its scissor material")
	b.queue_free()


func test_normal_mode_keeps_the_lightmapped_material() -> void:
	# Not just "it draws": the BSP's own material must survive untouched, because
	# rebuilding it as a StandardMaterial3D flattens the baked lightmap.
	var b := _brush()
	var before := _mesh_of(b).get_active_material(0)
	EntityRender.apply_render_properties(b, {"classname": "func_wall", "rendermode": "0"})
	assert_eq(_mesh_of(b).get_active_material(0), before, "mode 0 is left alone entirely")
	b.queue_free()


func test_raising_the_amount_brings_the_brush_back() -> void:
	# env_render re-applies these keys at runtime, so hiding has to be reversible.
	var b := _brush()
	EntityRender.apply_render_properties(b, {"classname": "func_wall", "rendermode": "2"})
	assert_false(_mesh_of(b).visible, "precondition: hidden")
	EntityRender.apply_render_properties(b,
		{"classname": "func_wall", "rendermode": "2", "renderamt": "255"})
	assert_true(_mesh_of(b).visible, "an env_render raising the FX Amount redraws it")
	b.queue_free()
