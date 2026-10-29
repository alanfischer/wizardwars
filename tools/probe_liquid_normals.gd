extends Node
## Which way does each liquid surface FACE? The compiler emits a liquid face twice, wound each
## way; the converter keeps one of each pair. If it keeps the downward copy, the surface is
## still drawn (liquid is cull_disabled) but it is lit from underneath.

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
		var arrays: Array = (mi as MeshInstance3D).mesh.surface_get_arrays(0)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var xf := (mi as MeshInstance3D).global_transform
		var top_y: float = (xf * (mi as MeshInstance3D).get_aabb()).end.y
		var up := 0
		var down := 0
		for i in range(0, verts.size(), 3):
			var c := xf * ((verts[i] + verts[i + 1] + verts[i + 2]) / 3.0)
			if absf(c.y - top_y) > 0.05:
				continue  # only the waterline faces; sides and floor are a separate question
			var n := (xf.basis * norms[i]).normalized()
			if n.y > 0.5:
				up += 1
			elif n.y < -0.5:
				down += 1
		print("%-44s waterline faces: %d up, %d DOWN" % [mi.get_path(), up, down])
	get_tree().quit(0)
