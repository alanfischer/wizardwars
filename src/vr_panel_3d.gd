class_name VRPanel3D
extends Node3D
# Base for in-world VR UI panels: a SubViewport rendered onto a QuadMesh placed
# in front of the camera. Subclasses override the virtual hooks to configure
# background opacity, depth handling, and post-ready behavior.

const VIEWPORT_SIZE := Vector2i(1024, 768)
const PANEL_SIZE := Vector2(2.0, 1.5)

var viewport: SubViewport
var mesh: MeshInstance3D
var material: StandardMaterial3D


func _ready() -> void:
	viewport = SubViewport.new()
	viewport.name = "PanelViewport"
	viewport.size = VIEWPORT_SIZE
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.transparent_bg = _is_transparent()
	add_child(viewport)
	_populate_viewport(viewport)

	mesh = MeshInstance3D.new()
	mesh.name = "PanelMesh"
	var quad := QuadMesh.new()
	quad.size = PANEL_SIZE
	mesh.mesh = quad
	material = StandardMaterial3D.new()
	material.albedo_texture = viewport.get_texture()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_configure_material(material, mesh)
	mesh.material_override = material
	add_child(mesh)
	_on_panel_ready()


func _is_transparent() -> bool:
	return false

func _populate_viewport(_vp: SubViewport) -> void:
	pass

func _configure_material(_mat: StandardMaterial3D, _msh: MeshInstance3D) -> void:
	pass

func _on_panel_ready() -> void:
	pass
