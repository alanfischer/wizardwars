extends SceneTree

# Headless check: does bake_light_grid produce a grid in the shader_lightstyles
# path after the lm_atlases guard fix? Run:
#   Godot --headless --path . --script res://tools/verify_light_grid.gd

func _init() -> void:
	var maps := ["ww_chasm", "ww_2fort", "ww_castle", "ww_storm"]
	if not ClassDB.class_exists(&"GoldSrcBSP"):
		print("FAIL: GoldSrcBSP plugin not available")
		quit(1)
		return
	for name in maps:
		var path := "res://maps/%s.bsp" % name
		if not FileAccess.file_exists(path):
			print("%-12s SKIP (no bsp)" % name)
			continue
		var bsp = ClassDB.instantiate(&"GoldSrcBSP")
		bsp.set_scale_factor(0.025)
		bsp.shader_lightstyles = true
		bsp.load_bsp(path)
		bsp.build_mesh()
		var grid: Dictionary = bsp.bake_light_grid(32.0)
		if grid.is_empty():
			print("%-12s NO GRID (empty dict)" % name)
		else:
			var dims = grid.get("grid_dims", Vector3i.ZERO)
			var slices = grid.get("dir_slices", [])
			print("%-12s GRID OK  dims=%s dir_slices=%d" % [name, str(dims), slices.size()])
		bsp.free()
	quit(0)
