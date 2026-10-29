class_name VRHUDPanel
extends VRPanel3D
# Transparent 3D HUD panel that floats with the player's view; always rendered on top of world geometry.

func _is_transparent() -> bool:
	return true


func _configure_material(mat: StandardMaterial3D, msh: MeshInstance3D) -> void:
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# Render on top of world geometry so HUD isn't occluded by walls/players.
	mat.no_depth_test = true
	msh.sorting_offset = 10.0
