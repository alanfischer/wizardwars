class_name BlenderMapAdapter
extends RefCounted
# Any Blender object with a "classname" custom property becomes an entity for
# EntityRegistry.apply_scripts; its other custom properties become string-valued keys
# (matching BSP, where every .map value is a string). Godot's GLTF importer surfaces
# those properties either as individual meta keys or nested under an `extras` dict;
# we accept both.


static func adapt(root: Node3D) -> void:
	var entities := _collect_entities(root)
	for node in entities:
		var ent := _build_entity_dict(node)
		node.set_meta("entity", ent)
		# apply_scripts only walks direct children of root; reparent nested entities up.
		if node.get_parent() != root:
			var gxform: Transform3D = node.global_transform
			node.get_parent().remove_child(node)
			root.add_child(node)
			node.global_transform = gxform
	var collided := _add_world_collision(root)
	var added_env := _ensure_world_environment(root)
	if entities.size() > 0 or collided > 0:
		Log.info("[BlenderMap] %d entities, %d mesh colliders%s" % [
			entities.size(), collided, ", default WorldEnvironment" if added_env else ""])


# Blender maps have no BSP lightmaps; without ambient light, surfaces facing away
# from the sun lamp render pure black. Add a default sky-lit environment if needed.
static func _ensure_world_environment(root: Node3D) -> bool:
	if _find_world_environment(root) != null:
		return false
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.5
	var we := WorldEnvironment.new()
	we.name = "WorldEnvironment"
	we.environment = env
	root.add_child(we)
	return true


static func _find_world_environment(node: Node) -> WorldEnvironment:
	if node is WorldEnvironment:
		return node as WorldEnvironment
	for child in node.get_children():
		var found := _find_world_environment(child)
		if found != null:
			return found
	return null


# Every mesh gets a static trimesh collider unless `collide` is false or it's
# already under a manually-authored CollisionObject3D.
static func _add_world_collision(node: Node) -> int:
	var count := 0
	for child in node.get_children():
		count += _add_world_collision(child)
	if node is MeshInstance3D and not _is_under_collision_object(node) and _collide_flag(node):
		var mi := node as MeshInstance3D
		if mi.mesh != null:
			mi.create_trimesh_collision()
			var body := mi.get_node_or_null(NodePath("%s_col" % mi.name)) as StaticBody3D
			if body != null:
				body.collision_layer = GameConsts.MASK_WORLD
				body.collision_mask = 0
				count += 1
	return count


static func _is_under_collision_object(n: Node) -> bool:
	var p := n.get_parent()
	while p != null:
		if p is CollisionObject3D:
			return true
		p = p.get_parent()
	return false


static func _collide_flag(n: Node) -> bool:
	var v: Variant = _meta_or_extra(n, "collide")
	return bool(v) if v != null else true


static func _collect_entities(node: Node) -> Array:
	var out: Array = []
	if node is Node3D and _meta_or_extra(node, "classname") != null:
		out.append(node)
	for child in node.get_children():
		out.append_array(_collect_entities(child))
	return out


static func _build_entity_dict(node: Node3D) -> Dictionary:
	var ent := {}
	var extras: Dictionary = _get_extras(node)
	for k in extras:
		ent[str(k)] = _stringify(extras[k])
	for key in node.get_meta_list():
		if key == "extras":
			continue
		ent[str(key)] = _stringify(node.get_meta(key))
	return ent


# Direct meta wins over a nested `extras` entry when both are present.
static func _meta_or_extra(node: Node, key: String) -> Variant:
	if node.has_meta(key):
		return node.get_meta(key)
	var extras := _get_extras(node)
	return extras[key] if extras.has(key) else null


static func _get_extras(node: Node) -> Dictionary:
	if not node.has_meta("extras"):
		return {}
	var x = node.get_meta("extras")
	return x if x is Dictionary else {}


static func _stringify(v: Variant) -> String:
	if v is String:
		return v
	if v is bool:
		return "1" if v else "0"
	return str(v)
