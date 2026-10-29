extends "res://src/tests/test_base.gd"
## func_water surfaces keep GoldSrc's backface culling: unlike world '!' water (double-sided by
## the compiler), a func_water brush's buried bottom/sides never draw — rendering it double-sided
## z-fights ww_ravine2's water with the rock.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.


## A water brush stand-in: the script goes onto an AnimatableBody3D carrying one mesh,
## the same way main.gd attaches it to the BSP's node.
func _water(keys := {}) -> FuncWater:
	var body = AnimatableBody3D.new()
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	var mat := StandardMaterial3D.new()
	mesh.surface_set_material(0, mat)
	mi.mesh = mesh
	body.add_child(mi)
	var e := {"classname": "func_water", "skin": "-3"}
	e.merge(keys, true)  # overwrite: some tests override a default key
	body.set_meta("entity", e)
	body.set_script(FuncWater)
	_root().add_child(body)
	_spawned.append(body)
	return body


func _material_of(w: FuncWater) -> Material:
	var mi: MeshInstance3D = w.get_child(0)
	return mi.get_active_material(0)


func test_translucent_water_keeps_backfaces_culled() -> void:
	# ww_ravine2's water: mode 2 at 100. It must not go double-sided, or the faces
	# buried in the rock draw and fight it.
	var w: FuncWater = _water({"rendermode": "2", "renderamt": "100"})
	var mat := _material_of(w)
	assert_eq(mat.cull_mode, BaseMaterial3D.CULL_BACK, "water is single-sided, as in GoldSrc")
	assert_almost_eq(mat.albedo_color.a, 100.0 / 255.0, 0.01, "and the FX Amount still blends")


func test_plain_water_is_translucent_without_a_rendermode() -> void:
	var w: FuncWater = _water({})
	var mat := _material_of(w)
	assert_almost_eq(mat.albedo_color.a, 0.6, 0.001, "untagged water still reads as see-through")
	assert_eq(mat.cull_mode, BaseMaterial3D.CULL_BACK, "and stays single-sided")


func test_opaque_liquid_keeps_the_bsp_material() -> void:
	# Slime/lava with no rendermode are opaque, so there is nothing to apply — and
	# rebuilding the material as a StandardMaterial3D would flatten the baked lightmap
	# (and the importer's turbulent-water shader).
	var w: FuncWater = _water({"skin": "-5"})
	var mi: MeshInstance3D = w.get_child(0)
	assert_eq(mi.get_surface_override_material(0), null, "the BSP's own material is left in place")
