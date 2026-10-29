extends SceneTree

# Loads every imported res://models/**/*.mdl, instantiates it, and reports any
# skinned MeshInstance3D whose ARRAY_BONES max index >= its bound skeleton's
# bone count (the "bs > sbs" mismatch in mesh_get_aabb).

func _init() -> void:
	var paths: Array[String] = []
	_collect("res://models", paths)
	var bad := 0
	for p in paths:
		var res = ResourceLoader.load(p)
		if not (res is PackedScene):
			continue
		var inst = (res as PackedScene).instantiate()
		bad += _check(inst, p)
		inst.free()
	print("\n=== done: %d models, %d mismatches ===" % [paths.size(), bad])
	quit()

func _collect(dir: String, out: Array[String]) -> void:
	var d := DirAccess.open(dir)
	if not d:
		return
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		var full := dir + "/" + name
		if d.current_is_dir():
			_collect(full, out)
		elif name.ends_with(".mdl"):
			out.append(full)
		name = d.get_next()
	d.list_dir_end()

func _check(node: Node, path: String) -> int:
	var count := 0
	for mi in _all_mesh_instances(node):
		var skel_path: NodePath = mi.skeleton
		var skel := mi.get_node_or_null(skel_path) as Skeleton3D
		if not skel:
			continue
		var sbs := skel.get_bone_count()
		var mesh: Mesh = mi.mesh
		if not mesh:
			continue
		for s in mesh.get_surface_count():
			var arrays = mesh.surface_get_arrays(s)
			var bones = arrays[Mesh.ARRAY_BONES]
			if bones == null or bones.is_empty():
				continue
			var mx := 0
			for b in bones:
				if b > mx:
					mx = b
			var bs := mx + 1
			if bs > sbs:
				print("BAD  %-40s mesh=%s surf=%d  bs=%d sbs=%d" % [path.get_file(), mi.name, s, bs, sbs])
				count += 1
	return count

func _all_mesh_instances(node: Node) -> Array:
	var out := []
	if node is MeshInstance3D:
		out.append(node)
	for c in node.get_children():
		out.append_array(_all_mesh_instances(c))
	return out
