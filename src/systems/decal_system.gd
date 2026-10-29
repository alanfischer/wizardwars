class_name DecalSystem
extends Node
# Volume-projected decals (BoxMesh + depth-sampling shader), so they work on all
# renderers including legacy gl_compatibility, unlike Godot's native Decal node.

const MAX_DECALS := 64
const _LUM_R := 0.299
const _LUM_G := 0.587
const _LUM_B := 0.114
const _LUM_DARK_THRESHOLD := 0.75
const _LUM_DARK_RANGE := 0.35
const FADE_TIME := 10.0    # seconds before decal starts fading
const FADE_DURATION := 3.0 # seconds to fade out
const PROBE_DIST := 2.0    # raycast distance for surface finding

var _decals: Array[Dictionary] = []  # { "node": MeshInstance3D, "mat": ShaderMaterial, "birth": float }
var _tex_cache: Dictionary = {}  # tex_name -> ImageTexture
var _box_mesh: BoxMesh
var _projector_shader: Shader = preload("res://shaders/decal_projector.gdshader")


func setup() -> void:
	_box_mesh = BoxMesh.new()
	_box_mesh.size = Vector3(1, 1, 1) # Unit box, scaled per-decal


## Scale/offset that turns a depth-buffer sample into NDC z for the live backend.
## OpenGL's NDC z is -1..1; Vulkan/Metal's is already 0..1.
static func depth_remap() -> Vector2:
	if RenderingServer.get_current_rendering_method() == "gl_compatibility":
		return Vector2(2.0, -1.0)
	return Vector2(1.0, 0.0)


## Broadcast decal placement to all peers (authority-only; runs locally via call_local).
## Unreliable, like the original's TE_DECAL / TE_GUNSHOTDECAL temp entities.
## collider_path is the absolute scene-tree path to the hit body (empty = parent to DecalSystem).
@rpc("authority", "call_local", "unreliable")
func place_rpc(tex_name: String, hit_pos: Vector3, normal: Vector3, scale: float, collider_path: NodePath = NodePath()) -> void:
	var collider: Node3D = null
	if not collider_path.is_empty():
		collider = get_node_or_null(collider_path)
	place(tex_name, hit_pos, normal, scale, collider)


## Place a decal at a known hit position + surface normal.
func place(tex_name: String, hit_pos: Vector3, normal: Vector3, scale: float = 1, collider: Node3D = null) -> void:
	var tex := _get_decal_texture(tex_name)
	if tex == null:
		return
	_spawn_decal(tex, hit_pos, normal, scale, collider)


## Place a decal by probing outward from origin to find the nearest surface.
func place_probe(tex_name: String, origin: Vector3, scale: float = 1) -> void:
	var tex := _get_decal_texture(tex_name)
	if tex == null:
		return
	var space := get_tree().root.get_world_3d().direct_space_state
	var best_dist := 1e9
	var best_result: Dictionary
	for dir in [Vector3.DOWN, Vector3.UP, Vector3.FORWARD, Vector3.BACK, Vector3.LEFT, Vector3.RIGHT]:
		var params := PhysicsRayQueryParameters3D.create(origin, origin + dir * PROBE_DIST)
		var result := space.intersect_ray(params)
		if not result.is_empty():
			var dist: float = origin.distance_to(result.position)
			if dist < best_dist:
				best_dist = dist
				best_result = result
	if best_result.is_empty():
		return
	_spawn_decal(tex, best_result.position, best_result.normal, scale, best_result.collider)


func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	var i := 0
	while i < _decals.size():
		var entry: Dictionary = _decals[i]
		var age: float = now - entry.birth
		if age > FADE_TIME + FADE_DURATION:
			entry.node.queue_free()
			_decals.remove_at(i)
			continue
		if age > FADE_TIME:
			var alpha := 1.0 - (age - FADE_TIME) / FADE_DURATION
			entry.mat.set_shader_parameter("modulate", Color(1, 1, 1, alpha))
		i += 1


func _get_decal_texture(tex_name: String) -> ImageTexture:
	if _tex_cache.has(tex_name):
		return _tex_cache[tex_name]
	var tex: ImageTexture = AssetLoader.load_decal_texture(tex_name)
	if tex == null:
		return null
	# Convert to stain overlay: dark pixels become dark marks with luminance-based alpha
	var img := tex.get_image()
	img.decompress()
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			if c.a < 0.5:
				img.set_pixel(x, y, Color(0, 0, 0, 0))
				continue
			var lum: float = c.r * _LUM_R + c.g * _LUM_G + c.b * _LUM_B
			var mark_alpha: float = clampf((_LUM_DARK_THRESHOLD - lum) / _LUM_DARK_RANGE, 0.0, 1.0)
			if mark_alpha < 0.01:
				img.set_pixel(x, y, Color(0, 0, 0, 0))
			else:
				img.set_pixel(x, y, Color(0.06, 0.04, 0.02, mark_alpha))
	img.generate_mipmaps()
	var decal_tex := ImageTexture.create_from_image(img)
	_tex_cache[tex_name] = decal_tex
	return decal_tex


func _spawn_decal(tex: ImageTexture, hit_pos: Vector3, normal: Vector3, scale: float, collider: Node3D = null) -> void:
	while _decals.size() >= MAX_DECALS:
		_decals[0].node.queue_free()
		_decals.remove_at(0)

	var mat := ShaderMaterial.new()
	mat.shader = _projector_shader
	mat.set_shader_parameter("decal_tex", tex)
	mat.set_shader_parameter("depth_remap", depth_remap())
	mat.render_priority = 1

	var mesh_inst := MeshInstance3D.new()
	mesh_inst.mesh = _box_mesh
	mesh_inst.material_override = mat
	mesh_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var tw: float = tex.get_width() * GameConsts.SCALE_FACTOR * scale
	var th: float = tex.get_height() * GameConsts.SCALE_FACTOR * scale
	var td: float = 0.5  # projection depth

	# Parent to the hit body so the decal follows moving geometry (doors etc.)
	var parent: Node = self
	if is_instance_valid(collider):
		parent = collider
	parent.add_child(mesh_inst)

	var up := GeomUtil.safe_up(normal, Vector3.RIGHT)
	var tangent := normal.cross(up).normalized()
	var bitangent := tangent.cross(normal)
	
	mesh_inst.global_position = hit_pos
	# Basis: Y is normal (projection axis), X and Z are tangent/bitangent (UV axes)
	mesh_inst.global_transform.basis = Basis(tangent * tw, normal * td, bitangent * th)

	_decals.append({"node": mesh_inst, "mat": mat, "birth": Time.get_ticks_msec() / 1000.0})
