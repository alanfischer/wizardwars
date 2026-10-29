class_name TrailFader
extends MeshInstance3D

## Self-managing ribbon trail. Call add_point() each frame from the projectile.
## When the projectile dies, the trail naturally fades and frees itself.

## Autoload name, so the type has to come from the script itself to call its statics.
const BeamSystemScript = preload("res://src/systems/beam_system.gd")

var _points: Array[Vector3] = []
var _ages: Array[float] = []
## Grown to fit and then reused. A trail's point count moves every tick, so the strip is padded out
## to its allocated size with degenerate (zero-area) triangles rather than reallocated — an
## ImmediateMesh rebuild frees and reallocates the GPU buffer every frame, which is the cost this
## avoids. Same attribute layout as BeamSystem: RGBA8 colour then two float32 UVs.
var _mesh: ArrayMesh
var _cap := 0
var _verts := PackedVector3Array()
var _attrs := PackedByteArray()
var max_life := 0.3
var width := 0.2
var _alive := true  # false once projectile stops adding points

## Trail color palette. Set before adding points to change from default fire colors.
## Array of 4 Colors: [head_start, head_end, tail_start, tail_end]
## null = default fire gradient.
var color_palette: Array = []


func _ready() -> void:
	material_override = AssetLoader.get_trail_material()


## Sink the ribbon with its projectile. The trail material is shared by every trail in the game,
## so the first call takes this trail a private copy of it.
func set_submerged(submerged: bool) -> void:
	if material_override == AssetLoader.get_trail_material():
		material_override = material_override.duplicate()
	AssetLoader.sort_for_liquid([material_override], submerged)


func add_point(pos: Vector3) -> void:
	_points.append(pos)
	_ages.append(0.0)


func stop() -> void:
	_alive = false


func _physics_process(delta: float) -> void:
	var i := 0
	while i < _ages.size():
		_ages[i] += delta
		if _ages[i] > max_life:
			_points.remove_at(i)
			_ages.remove_at(i)
		else:
			i += 1

	if not _alive and _points.size() < 2:
		queue_free()
		return

	_rebuild()


## Allocate (or grow) the strip. Only ever called when a trail gets longer than it has ever been,
## so in steady state this does nothing.
func _ensure_cap(vcount: int) -> void:
	if vcount <= _cap:
		return
	_cap = vcount + 16  # slack, so a trail that grows by a point a frame does not realloc each time
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array(); arrays[Mesh.ARRAY_VERTEX].resize(_cap)
	arrays[Mesh.ARRAY_COLOR] = PackedColorArray(); arrays[Mesh.ARRAY_COLOR].resize(_cap)
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array(); arrays[Mesh.ARRAY_TEX_UV].resize(_cap)
	_mesh = ArrayMesh.new()
	_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLE_STRIP, arrays)
	mesh = _mesh
	_verts.resize(_cap)
	_attrs.resize(_cap * BeamSystemScript.ATTR_STRIDE)


func _rebuild() -> void:
	if not BeamSystem.fx_enabled:
		return
	if _points.size() < 2:
		visible = false
		return
	var cam := get_viewport().get_camera_3d()
	if not cam:
		return
	visible = true
	_ensure_cap(_points.size() * 2)
	var cam_pos := cam.global_position
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	var vi := 0

	for i in _points.size():
		var pos: Vector3 = _points[i]
		var t := _ages[i] / max_life

		var color: Color
		if color_palette.size() >= 4:
			if t < 0.33:
				color = (color_palette[0] as Color).lerp(color_palette[1] as Color, t / 0.33)
			elif t < 0.66:
				color = (color_palette[1] as Color).lerp(color_palette[2] as Color, (t - 0.33) / 0.33)
			else:
				color = (color_palette[2] as Color).lerp(color_palette[3] as Color, (t - 0.66) / 0.34)
		else:
			# Default fire gradient: yellow -> orange -> dark -> bluish
			if t < 0.33:
				var u := t / 0.33
				color = Color(1.0, lerp(1.0, 0.6, u), lerp(0.0, 0.1, u), 1.0)
			elif t < 0.66:
				var u := (t - 0.33) / 0.33
				color = Color(lerp(1.0, 0.6, u), lerp(0.6, 0.3, u), lerp(0.1, 0.3, u), 1.0)
			else:
				var u := (t - 0.66) / 0.34
				color = Color(lerp(0.6, 0.3, u), 0.3, lerp(0.3, 0.9, u), 1.0)
		color.a *= 1.0 - t

		var w: float = lerp(width, 0.0, t)

		var to_cam := (cam_pos - pos).normalized()
		var trail_dir: Vector3
		if i < _points.size() - 1:
			trail_dir = (_points[i + 1] - pos).normalized()
		elif i > 0:
			trail_dir = (pos - _points[i - 1]).normalized()
		else:
			trail_dir = Vector3.FORWARD
		var side := trail_dir.cross(to_cam).normalized() * w * 0.5
		if side.length_squared() < 0.0001:
			side = Vector3.UP * w * 0.5

		var a := pos + side
		var b := pos - side
		_verts[vi] = a
		BeamSystemScript.write_attr(_attrs, vi, color, 0.0, 0.0)
		_verts[vi + 1] = b
		BeamSystemScript.write_attr(_attrs, vi + 1, color, 0.0, 1.0)
		vi += 2
		lo = lo.min(a).min(b)
		hi = hi.max(a).max(b)

	# Pad the unused tail onto the last vertex: the strip is drawn at its allocated length, and
	# repeated points make zero-area triangles that rasterise to nothing.
	var last: Vector3 = _verts[vi - 1] if vi > 0 else Vector3.ZERO
	var clear := Color(0, 0, 0, 0)
	while vi < _cap:
		_verts[vi] = last
		BeamSystemScript.write_attr(_attrs, vi, clear, 0.0, 0.0)
		vi += 1

	_mesh.surface_update_vertex_region(0, 0, _verts.to_byte_array())
	_mesh.surface_update_attribute_region(0, 0, _attrs)
	custom_aabb = AABB(lo, (hi - lo).max(Vector3.ONE * 0.001))
