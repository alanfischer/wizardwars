extends "res://src/tests/test_base.gd"
## A brush entity in a GoldSrc render mode switches its BSP material to goldsrc's render-mode copy
## (the world shader's "render_shaders" meta), which keeps the texture's animation and alternates.
## The amount and colour ride per mesh as instance uniforms, so one copy serves every entity.
##
## Scene-run only (needs the EntityRender autoload): res://src/tests/run_tests.tscn.

var _mix := Shader.new()
var _add := Shader.new()
var _world := ShaderMaterial.new()


func _init() -> void:
	for shader in [_mix, _add]:
		shader.code = "shader_type spatial;\ninstance uniform float entity_renderamt = 1.0;\n" \
			+ "instance uniform vec3 entity_rendercolor = vec3(1.0);\n"
	var world_shader := Shader.new()
	world_shader.code = "shader_type spatial;\n"
	world_shader.set_meta(&"render_shaders", {"mix": _mix, "add": _add})
	_world.shader = world_shader


func _teardown_test() -> void:
	_despawn_all()


func _brush() -> Node3D:
	var root := Node3D.new()
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.surface_set_material(0, _world)
	mi.mesh = mesh
	root.add_child(mi)
	_root().add_child(root)
	_spawned.append(root)
	return root


func _mesh_of(root: Node3D) -> MeshInstance3D:
	return root.get_child(0)


func test_texture_mode_takes_the_shared_mix_copy() -> void:
	var a := _brush()
	var b := _brush()
	EntityRender.apply_render_properties(a, {"rendermode": "2", "renderamt": "64"})
	EntityRender.apply_render_properties(b, {"rendermode": "2", "renderamt": "200"})
	var mat := _mesh_of(a).get_active_material(0) as ShaderMaterial
	assert_eq(mat.shader, _mix, "Texture draws through the mix build")
	assert_eq(_mesh_of(b).get_active_material(0), mat, "and both entities share the one copy")
	assert_almost_eq(_mesh_of(a).get_instance_shader_parameter(&"entity_renderamt"), 64.0 / 255.0,
		0.0001, "each keeps its own amount")
	assert_almost_eq(_mesh_of(b).get_instance_shader_parameter(&"entity_renderamt"), 200.0 / 255.0,
		0.0001, "on its own mesh")


func test_additive_mode_takes_the_add_copy() -> void:
	var a := _brush()
	EntityRender.apply_render_properties(a, {"rendermode": "5", "renderamt": "255"})
	assert_eq((_mesh_of(a).get_active_material(0) as ShaderMaterial).shader, _add, "Additive adds")


func test_color_mode_tints_per_mesh() -> void:
	var a := _brush()
	EntityRender.apply_render_properties(a, {"rendermode": "1", "renderamt": "255",
		"rendercolor": "255 0 51"})
	assert_eq(_mesh_of(a).get_instance_shader_parameter(&"entity_rendercolor"), Vector3(1, 0, 0.2),
		"rendercolor goes to the mesh")


## env_render on an entity already in a render mode starts from the copy it draws, which has to
## lead back to the world material rather than be copied again.
func test_a_second_render_change_switches_the_blend() -> void:
	var a := _brush()
	EntityRender.apply_render_properties(a, {"rendermode": "2", "renderamt": "100"})
	EntityRender.apply_render_properties(a, {"rendermode": "5", "renderamt": "100"})
	assert_eq((_mesh_of(a).get_active_material(0) as ShaderMaterial).shader, _add,
		"the add copy of the same world material")
