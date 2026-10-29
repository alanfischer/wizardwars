class_name LightGrid
extends RefCounted
## Ambient cube light grid sampled from BSP lightmaps.
## Baked during map conversion, stored as scene metadata, sampled at runtime.

const OVERBRIGHT := 2.0
const FALLBACK_AMBIENT := Color(0.15, 0.15, 0.15)

var _origin: Vector3
var _dims: Vector3i
var _cell_size: float
var _inv_cell_size: float
var _valid := false

# CPU-side images for omnidirectional sampling (one flattened image per direction)
var _images: Array  # 6 arrays of slice Images

# GPU-side 3D textures for directional shader sampling
var _textures_3d: Array[ImageTexture3D]  # 6 ImageTexture3D

# Grid transform for shader
var _grid_size: Vector3  # world-space extent


static func from_meta(root: Node3D) -> LightGrid:
	var grid := LightGrid.new()
	var data: Dictionary = root.get_meta("light_grid", {})
	if data.is_empty():
		return grid
	grid._origin = data["grid_origin"]
	grid._dims = data["grid_dims"]
	grid._cell_size = data["cell_size"]
	grid._inv_cell_size = 1.0 / grid._cell_size
	grid._grid_size = Vector3(
		grid._dims.x * grid._cell_size,
		grid._dims.y * grid._cell_size,
		grid._dims.z * grid._cell_size)

	var dir_slices: Array = data["dir_slices"]
	if dir_slices.size() != 6:
		return grid

	grid._images = dir_slices
	grid._textures_3d = []
	for dir_idx in 6:
		var slices: Array = dir_slices[dir_idx]
		# ImageTexture3D.create(format, width, height, depth, mipmaps, data_images)
		var tex := ImageTexture3D.new()
		# Slice dimensions: width = dims.x (GS X), height = dims.z (GS Y), depth = dims.y (GS Z = Godot Y)
		tex.create(Image.FORMAT_RGB8, grid._dims.x, grid._dims.z, grid._dims.y, false, slices)
		grid._textures_3d.append(tex)

	grid._valid = grid._textures_3d.size() == 6
	return grid


func is_valid() -> bool:
	return _valid


## CPU-side sampling (average of 6 directions, with overbright) for Environment ambient color.
func sample(world_pos: Vector3) -> Color:
	if not _valid:
		return FALLBACK_AMBIENT

	var local_x := (_origin.x - world_pos.x) * _inv_cell_size
	var local_y := (world_pos.y - _origin.y) * _inv_cell_size
	var local_z := (world_pos.z - _origin.z) * _inv_cell_size

	var gx := int(local_x)
	var gy := int(local_y)
	var gz := int(local_z)

	if gx < 0 or gy < 0 or gz < 0 or gx >= _dims.x or gy >= _dims.y or gz >= _dims.z:
		return FALLBACK_AMBIENT

	# Sample from slice images: slice index = gy (Godot Y = GS Z),
	# pixel within slice = (gx, gz) where gx = GS X, gz = GS Y dimension
	var r := 0.0
	var g := 0.0
	var b := 0.0
	for i in 6:
		var slices: Array = _images[i]
		var c: Color = slices[gy].get_pixel(gx, gz)
		r += c.r
		g += c.g
		b += c.b
	r = r / 6.0 * OVERBRIGHT
	g = g / 6.0 * OVERBRIGHT
	b = b / 6.0 * OVERBRIGHT
	return Color(minf(r, 1.0), minf(g, 1.0), minf(b, 1.0))


## All ambient cube ShaderMaterials created, for broadcasting lightstyle changes.
## Uses WeakRef to avoid preventing garbage collection.
static var _all_acube_materials: Array = []  # Array[WeakRef]


static func set_lightstyle_brightness(brightness: float) -> void:
	var alive: Array = []
	for wr: WeakRef in _all_acube_materials:
		var mat: ShaderMaterial = wr.get_ref() as ShaderMaterial
		if mat:
			mat.set_shader_parameter("lightstyle_brightness", brightness)
			alive.append(wr)
	_all_acube_materials = alive


static func _track_material(mat: ShaderMaterial) -> void:
	_all_acube_materials.append(weakref(mat))


const _ACUBE_PARAMS := [
	"acube_pos_x", "acube_neg_x",
	"acube_pos_y", "acube_neg_y",
	"acube_pos_z", "acube_neg_z",
]


## Call once when the model is created (not per-frame).
func apply_textures_to_node(node: Node) -> void:
	if not _valid:
		return
	_apply_textures_recursive(node)


func _set_grid_on_material(mat: ShaderMaterial) -> void:
	for i in 6:
		mat.set_shader_parameter(_ACUBE_PARAMS[i], _textures_3d[i])
	mat.set_shader_parameter("grid_origin", _origin)
	mat.set_shader_parameter("grid_size", _grid_size)
	LightGrid._track_material(mat)


func _apply_textures_recursive(node: Node) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		var mesh: Mesh = mi.mesh
		if mesh:
			for surf_idx in mesh.get_surface_count():
				var mat: Material = mi.get_active_material(surf_idx)
				if mat is ShaderMaterial:
					_set_grid_on_material(mat)
		# Also bind to skin override materials stored as metadata,
		# so they have textures when set_model_skin() applies them later.
		for key in mi.get_meta_list():
			if key.begins_with("skin_"):
				var skin_mat = mi.get_meta(key)
				if skin_mat is ShaderMaterial:
					_set_grid_on_material(skin_mat)
	for child in node.get_children():
		_apply_textures_recursive(child)
