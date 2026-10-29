class_name BlobShadow
extends Node3D

const MAX_HEIGHT := 8.0
const MAX_ALPHA := 0.55
const CAST_ORIGIN_OFFSET := 0.2  # start ray above entity to avoid starting inside floor geometry

var radius := 0.4

var _mesh_inst: MeshInstance3D
var _mat: ShaderMaterial

static var _shared_tex: ImageTexture
static var _projector_shader: Shader = preload("res://shaders/decal_projector.gdshader")


func _init(r := 0.4) -> void:
	radius = r


func _ready() -> void:
	if not _shared_tex:
		_shared_tex = _make_shadow_texture()

	_mat = ShaderMaterial.new()
	_mat.shader = _projector_shader
	_mat.set_shader_parameter("decal_tex", _shared_tex)
	_mat.set_shader_parameter("modulate", Color(0.0, 0.0, 0.0, MAX_ALPHA))
	_mat.set_shader_parameter("depth_remap", DecalSystem.depth_remap())
	_mat.render_priority = 1

	var box := BoxMesh.new()
	box.size = Vector3(1.0, 1.0, 1.0)

	_mesh_inst = MeshInstance3D.new()
	_mesh_inst.mesh = box
	_mesh_inst.material_override = _mat
	_mesh_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Placed from _process every frame; physics interpolation would make it trail its owner.
	_mesh_inst.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	get_tree().current_scene.add_child(_mesh_inst)


func _process(_delta: float) -> void:
	if not is_instance_valid(_mesh_inst):
		return
	# Mesh lives under current_scene (not the owner), so PVS culling of the owner never
	# reaches it directly -- mirror owner visibility here or a culled entity leaves a floating shadow.
	if not is_visible_in_tree():
		_mesh_inst.visible = false
		return
	var origin := global_position + Vector3.UP * CAST_ORIGIN_OFFSET
	var space := get_world_3d().direct_space_state
	var params := PhysicsRayQueryParameters3D.create(
		origin, origin + Vector3.DOWN * (MAX_HEIGHT + CAST_ORIGIN_OFFSET)
	)
	params.collision_mask = GameConsts.MASK_WORLD
	var result := space.intersect_ray(params)
	if result.is_empty():
		_mesh_inst.visible = false
		return
	
	var dist : float = origin.y - result.position.y
	var alpha := MAX_ALPHA * clampf(1.0 - dist / MAX_HEIGHT, 0.0, 1.0)
	_mat.set_shader_parameter("modulate", Color(0, 0, 0, alpha))
	_mesh_inst.visible = true
	
	var normal: Vector3 = result.normal
	var up := GeomUtil.safe_up(normal, Vector3.RIGHT)
	var tangent := normal.cross(up).normalized()
	var bitangent := tangent.cross(normal)
	
	var d := radius * 2.0
	var h := 0.5 # Projection depth
	
	_mesh_inst.global_position = result.position
	# Basis: Y is normal (projection axis), X and Z are tangent/bitangent
	_mesh_inst.global_transform.basis = Basis(tangent * d, normal * h, bitangent * d)


func _exit_tree() -> void:
	if is_instance_valid(_mesh_inst):
		_mesh_inst.queue_free()


static func _make_shadow_texture() -> ImageTexture:
	const SIZE := 64
	var img := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	var center := Vector2(SIZE * 0.5, SIZE * 0.5)
	var r := SIZE * 0.5
	for y in SIZE:
		for x in SIZE:
			var d := Vector2(x + 0.5, y + 0.5).distance_to(center) / r
			var a := clampf(1.0 - d, 0.0, 1.0)
			a = a * a  # quadratic falloff for soft edge
			# Shadow texture is white; we modulate it to black in the shader
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a))
	return ImageTexture.create_from_image(img)
