extends Node

## BeamSystem — camera-facing beam visuals (triangle strips written in place each frame).
## create_oneshot() fades out and auto-destroys; create_tracked() persists until destroy().
## config.camera_aligned uses the camera basis instead of per-vertex facing, for
## first-person beams that run parallel to view. config.use_local_space keeps 'to' in
## parent-local space for rock-solid attachment to moving bones/hands.

## Attribute buffer layout, verified against RenderingServer.mesh_get_surface for a
## VERTEX|COLOR|TEX_UV surface: RGBA8 colour then two float32 UVs, 12 bytes per vertex.
const ATTR_STRIDE := 12

var _beams := {}
var _next_id := 0

## /fx 0 stops beams and TrailFader ribbons updating their geometry at all. Kept as a measurement
## lever now that both write in place: it still isolates the whole per-frame effect cost.
var fx_enabled := true


func _process(_delta: float) -> void:
	if not fx_enabled:
		return
	var cam := get_viewport().get_camera_3d()
	if not cam:
		return
	for id in _beams.keys():
		var b: Dictionary = _beams[id]
		if not b.tracked:
			continue
		if not is_instance_valid(b.mesh_inst):
			_beams.erase(id)
			continue
		_rebuild(b, cam)


func create_oneshot(parent: Node, from: Vector3, to: Vector3, config := {}) -> int:
	var id := _next_id
	_next_id += 1
	var b := _make_beam(parent, from, to, config, false)
	# One-shot needs its own material for fading
	b.mesh_inst.material_override = AssetLoader.create_beam_material()
	_beams[id] = b

	var cam := get_viewport().get_camera_3d()
	if cam:
		_rebuild(b, cam)

	var fade_time: float = config.get("fade_time", 0.3)
	var mat: StandardMaterial3D = b.mesh_inst.material_override
	var mesh_inst: MeshInstance3D = b.mesh_inst
	var tween := parent.create_tween()
	tween.tween_method(func(alpha: float):
		if is_instance_valid(mesh_inst):
			mat.albedo_color = Color(1, 1, 1, alpha)
	, 1.0, 0.0, fade_time)
	tween.tween_callback(func(): destroy(id))
	return id


func create_tracked(parent: Node, from: Vector3, to: Vector3, config := {}) -> int:
	var id := _next_id
	_next_id += 1
	var b := _make_beam(parent, from, to, config, true)
	_beams[id] = b
	# Build immediately so it's visible this frame
	var cam := get_viewport().get_camera_3d()
	if cam:
		_rebuild(b, cam)
	return id


func update(beam_id: int, from: Vector3, to: Vector3) -> void:
	if _beams.has(beam_id):
		_beams[beam_id].from = from
		_beams[beam_id].to = to


func destroy(beam_id: int) -> void:
	if not _beams.has(beam_id):
		return
	var b: Dictionary = _beams[beam_id]
	if is_instance_valid(b.mesh_inst):
		b.mesh_inst.queue_free()
	_beams.erase(beam_id)


## The strip is allocated once at its final size and then only ever overwritten in place. An
## ImmediateMesh cannot do that — clear_surfaces() frees the GPU buffer and the rebuild allocates a
## new one, which on Apple's Intel GL driver is a kernel round trip per beam per frame.
func _make_beam(parent: Node, from: Vector3, to: Vector3, config: Dictionary, tracked: bool) -> Dictionary:
	var segments: int = config.get("segments", 8)
	var vcount := (segments + 1) * 2
	var mesh := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array(); arrays[Mesh.ARRAY_VERTEX].resize(vcount)
	arrays[Mesh.ARRAY_COLOR] = PackedColorArray(); arrays[Mesh.ARRAY_COLOR].resize(vcount)
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array(); arrays[Mesh.ARRAY_TEX_UV].resize(vcount)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLE_STRIP, arrays)
	var mesh_inst := MeshInstance3D.new()
	mesh_inst.mesh = mesh
	mesh_inst.material_override = config.get("material", AssetLoader.get_beam_material())
	parent.add_child(mesh_inst)
	return {
		"mesh_inst": mesh_inst,
		"mesh": mesh,
		"verts": PackedVector3Array(), "attrs": PackedByteArray(),  # scratch, resized on first use
		"vcount": vcount,
		"from": from,
		"to": to,
		"color": config.get("color", Color(1, 1, 1, 1)),
		"width": config.get("width", 0.1),
		"segments": segments,
		"noise_fn": config.get("noise_fn", Callable()),
		"color_fn": config.get("color_fn", Callable()),
		"uv_tiles": config.get("uv_tiles", 1.0),
		"camera_aligned": config.get("camera_aligned", false),
		"use_local_space": config.get("use_local_space", false),
		"tracked": tracked,
	}


static func write_attr(attrs: PackedByteArray, index: int, c: Color, u: float, v: float) -> void:
	var o := index * ATTR_STRIDE
	attrs.encode_u8(o, int(clampf(c.r, 0.0, 1.0) * 255.0))
	attrs.encode_u8(o + 1, int(clampf(c.g, 0.0, 1.0) * 255.0))
	attrs.encode_u8(o + 2, int(clampf(c.b, 0.0, 1.0) * 255.0))
	attrs.encode_u8(o + 3, int(clampf(c.a, 0.0, 1.0) * 255.0))
	attrs.encode_float(o + 4, u)
	attrs.encode_float(o + 8, v)


func _rebuild(b: Dictionary, cam: Camera3D) -> void:
	var mesh_inst: MeshInstance3D = b.mesh_inst
	var from: Vector3 = b.from
	var to: Vector3 = b.to
	
	var cam_pos := cam.global_position
	var cam_right := cam.global_transform.basis.x
	
	if b.use_local_space:
		to = mesh_inst.to_local(to)
		cam_pos = mesh_inst.to_local(cam_pos)
		# Transform direction vector to local space
		cam_right = mesh_inst.global_transform.basis.inverse() * cam_right
	
	var beam_vec := to - from
	if beam_vec.length() < 0.01:
		mesh_inst.visible = false  # nothing to draw; the buffer stays allocated
		return
	mesh_inst.visible = true
	var segments: int = b.segments
	var width: float = b.width
	var color: Color = b.color
	var noise_fn: Callable = b.noise_fn
	var color_fn: Callable = b.color_fn
	var uv_tiles: float = b.uv_tiles
	var camera_aligned: bool = b.camera_aligned
	var vcount: int = b.vcount
	var verts: PackedVector3Array = b.verts
	var attrs: PackedByteArray = b.attrs
	if verts.size() != vcount:
		verts.resize(vcount); attrs.resize(vcount * ATTR_STRIDE)
		b.verts = verts; b.attrs = attrs
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	var vi := 0
	for i in range(segments + 1):
		var t := float(i) / segments
		var pos := from + beam_vec * t
		if noise_fn.is_valid():
			pos += noise_fn.call(t)
		var side: Vector3
		if camera_aligned:
			side = cam_right * width
		else:
			var to_cam := (cam_pos - pos).normalized()
			var beam_dir: Vector3
			if i < segments:
				beam_dir = (from + beam_vec * (float(i + 1) / segments) - pos).normalized()
			else:
				beam_dir = (pos - (from + beam_vec * (float(i - 1) / segments))).normalized()
			side = beam_dir.cross(to_cam).normalized() * width
			if side.length_squared() < 0.0001:
				side = cam_right * width
		var c := color
		if color_fn.is_valid():
			c = color_fn.call(t)
		var u := t * uv_tiles
		var a := pos + side
		var bb := pos - side
		verts[vi] = a
		write_attr(attrs, vi, c, u, 0.0)
		verts[vi + 1] = bb
		write_attr(attrs, vi + 1, c, u, 1.0)
		vi += 2
		lo = lo.min(a).min(bb)
		hi = hi.max(a).max(bb)
	var mesh: ArrayMesh = b.mesh
	mesh.surface_update_vertex_region(0, 0, verts.to_byte_array())
	mesh.surface_update_attribute_region(0, 0, attrs)
	# The surface AABB was baked when the strip was allocated and does not follow an in-place
	# rewrite, so without this the beam is culled from wherever it was first built.
	mesh_inst.custom_aabb = AABB(lo, (hi - lo).max(Vector3.ONE * 0.001))
