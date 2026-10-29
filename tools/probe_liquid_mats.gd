extends Node
## Dump every liquid surface's material identity and parameters, so two pools that shade
## differently can be told apart by something other than eye.

func _ready() -> void:
	var map_name := "ww_golem"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--map="):
			map_name = a.substr(6)
	var converter := MapConverter.new()
	add_child(converter)
	converter.convert(map_name)
	var scn := ResourceLoader.load("user://resources/maps/%s.scn" % map_name, "",
			ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	var root: Node3D = scn.instantiate()
	add_child(root)
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		if not mi.has_meta("is_water_surface"):
			continue
		var m := (mi as MeshInstance3D).mesh
		for s in m.get_surface_count():
			var mat := m.surface_get_material(s) as ShaderMaterial
			if mat == null:
				print("%s surface %d: no ShaderMaterial" % [mi.get_path(), s])
				continue
			var params := {}
			for p in mat.shader.get_shader_uniform_list():
				var v = mat.get_shader_parameter(p.name)
				if v != null:
					params[p.name] = v
			var tex = mat.get_shader_parameter("albedo_texture")
			print("%-46s surf%d mat=%d shader=%d tex=%s %s" % [
				mi.get_path(), s, mat.get_instance_id(), mat.shader.get_instance_id(),
				(tex.resource_path if tex else "<none>"), params])
	get_tree().quit(0)
