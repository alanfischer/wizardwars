extends Node
## Print every liquid surface's world AABB for a map, so a capture camera can be aimed at water
## without guessing. Scene-run (MapConverter needs the Log autoload).

func _ready() -> void:
	var map_name := "ww_hunt"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--map="):
			map_name = a.substr(6)
	var converter := MapConverter.new()
	add_child(converter)
	if not converter.convert(map_name):
		printerr("convert failed")
		get_tree().quit(1)
		return
	var scn := ResourceLoader.load("user://resources/maps/%s.scn" % map_name, "",
			ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	var root: Node3D = scn.instantiate()
	add_child(root)
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		if not mi.has_meta("is_water_surface") and not String(mi.name).ends_with("_depth"):
			continue
		var aabb := (mi as MeshInstance3D).get_aabb()
		var g := (mi as MeshInstance3D).global_transform * aabb
		if String(mi.name).ends_with("_depth"):
			continue
		var verts: PackedVector3Array = (mi as MeshInstance3D).mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var xf := (mi as MeshInstance3D).global_transform
		# One representative point per triangle fan is enough to aim a camera.
		var seen := {}
		for i in range(0, verts.size(), 3):
			var c := xf * ((verts[i] + verts[i + 1] + verts[i + 2]) / 3.0)
			var key := "%d,%d,%d" % [roundi(c.x / 4.0), roundi(c.y), roundi(c.z / 4.0)]
			seen[key] = c
		var pts: PackedStringArray = []
		for k in seen:
			pts.append("(%.1f,%.1f,%.1f)" % [seen[k].x, seen[k].y, seen[k].z])
		print("%-34s y=%.2f  %d faces  %s" % [mi.get_path(), g.position.y, verts.size() / 3, " ".join(pts)])
	get_tree().quit(0)
