extends Object
## Client-side debug drawing for /debug_rewind: the lag-compensated hitboxes a shot was actually
## traced against, as they stood at the rewound instant.
##
## Pure presentation — the wire half (send_debug_rewind_ghosts and its RPC) stays in
## NetworkManager, which hands the geometry here. Boxes arrive as plain geometry (transform +
## size) rather than a pose for the client to re-derive: the rewind re-poses the skeleton to a
## recorded animation frame, which no client-side reconstruction could reproduce.
##
## No class_name — preloaded by its consumers; see README, "class_name and preload".

const FADE := 0.8  # seconds a ghost stays up


## `root` only has to be something in the tree to parent the meshes to; they free themselves.
static func spawn(root: Node, origins: PackedVector3Array, xforms: PackedVector3Array,
		sizes: PackedVector3Array, groups: PackedInt32Array) -> void:
	for origin in origins:
		_spawn_marker(root, origin)
	for i in sizes.size():
		var b := i * 4
		var xform := Transform3D(
			Basis(xforms[b], xforms[b + 1], xforms[b + 2]), xforms[b + 3])
		_spawn_box(root, xform, sizes[i], groups[i] == GameConsts.HITBOX_GROUP_HEAD)


## Small sphere on the rewound body origin — the "did the rewind fire at all" signal,
## readable even when the boxes land off-screen.
static func _spawn_marker(root: Node, pos: Vector3) -> void:
	var mi := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.1
	sphere.height = 0.2
	sphere.radial_segments = 8
	sphere.rings = 4
	mi.mesh = sphere
	mi.material_override = _material(Color(1.0, 0.4, 0.0, 0.6))
	_add_fading(root, mi, Transform3D(Basis(), pos))


## One hitbox drawn as its 12 edges. Lines rather than a translucent solid so overlapping
## limb boxes stay separable, and no_depth_test so the rig reads through the live model.
static func _spawn_box(root: Node, xform: Transform3D, size: Vector3, head: bool) -> void:
	var h := size * 0.5
	var corners: Array[Vector3] = []
	for x in [-h.x, h.x]:
		for y in [-h.y, h.y]:
			for z in [-h.z, h.z]:
				corners.append(Vector3(x, y, z))
	# Corner index bits are x,y,z — two corners share an edge when they differ in one bit.
	var verts := PackedVector3Array()
	for a in 8:
		for bit in [1, 2, 4]:
			var b: int = a | bit
			if b != a:
				verts.append(corners[a])
				verts.append(corners[b])
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = _material(
		Color(1.0, 0.25, 0.25, 0.9) if head else Color(1.0, 0.6, 0.1, 0.7))
	_add_fading(root, mi, xform)


static func _material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	mat.albedo_color = color
	return mat


static func _add_fading(root: Node, mi: MeshInstance3D, xform: Transform3D) -> void:
	root.add_child(mi)
	mi.global_transform = xform
	var tween := mi.create_tween()
	tween.tween_property(mi.material_override, "albedo_color:a", 0.0, FADE)
	tween.tween_callback(mi.queue_free)
