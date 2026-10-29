extends Node
## GoldSrc render properties and BSP/MDL material handling: rendermode/renderamt/rendercolor,
## overbright scaling, and the lightmap colour-space push. Split out of entity_util.gd — these
## are what every brush and point entity needs and the only part of the old singleton that a
## generic GoldSrc entity runtime would carry with it.


## Apply GoldSrc 2x overbright scaling to lightmapped materials.
func apply_overbright(bsp: Node, scale: float) -> void:
	for mesh_inst in find_mesh_instances(bsp):
		var mesh: Mesh = mesh_inst.mesh
		if not mesh:
			continue
		for surf_idx in mesh.get_surface_count():
			var mat := mesh.surface_get_material(surf_idx)
			if mat is ShaderMaterial:
				mat.set_shader_parameter("overbright", scale)
			elif mat is StandardMaterial3D and mat.detail_enabled:
				mat.albedo_color = Color(scale, scale, scale)


## True when the active renderer shades in linear space and encodes on output
## (forward+/mobile). gl_compatibility shades in sRGB and does not, so the lightmap
## shaders have to know which space to composite in — see mdl_ambient_cube.gdshader.
func renderer_is_linear() -> bool:
	return RenderingServer.get_current_rendering_method() != "gl_compatibility"


## Push renderer_is_linear() onto every lightmap/ambient-cube material under node.
## Runs per map load rather than at conversion: the cached .scn outlives any one
## renderer choice, so this cannot be baked in.
func apply_color_space(root: Node) -> void:
	_apply_color_space_recursive(root, renderer_is_linear())


## Not find_mesh_instances: this one descends INTO a MeshInstance3D as well, because a BSP nests
## submodel meshes under their parent mesh and every one of them needs the flag.
func _apply_color_space_recursive(node: Node, is_linear: bool) -> void:
	for child in node.get_children():
		if child is MeshInstance3D:
			var mesh: Mesh = child.mesh
			if mesh:
				for surf_idx in mesh.get_surface_count():
					var mat := mesh.surface_get_material(surf_idx)
					if mat is ShaderMaterial:
						mat.set_shader_parameter("linear_output", is_linear)
					var over: Material = child.get_surface_override_material(surf_idx)
					if over is ShaderMaterial:
						over.set_shader_parameter("linear_output", is_linear)
		_apply_color_space_recursive(child, is_linear)


## Recursively find all MeshInstance3D descendants of node.
func find_mesh_instances(node: Node) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	for child in node.get_children():
		if child is MeshInstance3D:
			result.append(child)
		else:
			result.append_array(find_mesh_instances(child))
	return result


## Apply GoldSrc render properties (rendermode, renderamt, rendercolor) to a brush entity's
## mesh materials. Duplicates materials to avoid affecting other entities.
func apply_render_properties(node: Node3D, ent: Dictionary) -> void:
	# Entities that render procedurally (env_beam) apply the properties
	# themselves — the mesh-material path below can't reach them.
	if node.has_method("apply_render_properties"):
		node.apply_render_properties(ent)
		return
	var mode := int(ent.get("rendermode", "0"))
	if mode == 0:
		return

	var amt := int(ent.get("renderamt", "0"))
	var alpha := amt / 255.0

	# GoldSrc mappers build invisible-but-solid brushes by leaving renderamt blank (0) — the
	# entity stays solid, only its meshes go invisible. Solid (mode 4) is an alpha TEST, so a
	# '{'-masked surface keeps drawing its own mask whatever the amount; an unmasked one in
	# that mode has nothing left to show, which is how ww_golem's two crystal shells — the
	# gib sources wrapped around each gem — stay out of sight. The importer splits a brush
	# into one MeshInstance3D per texture, so this is a per-surface question. Assign
	# `visible` (not just hide) so a later env_render raising the amount brings it back.
	var drawn: Array[MeshInstance3D] = []
	for mesh_inst in find_mesh_instances(node):
		mesh_inst.visible = amt > 0 or (mode == 4 and _mesh_is_masked(mesh_inst))
		if mesh_inst.visible:
			drawn.append(mesh_inst)
	if drawn.is_empty():
		return

	for mesh_inst in drawn:
		for surf_idx in mesh_inst.mesh.get_surface_count():
			var base_mat := mesh_inst.get_active_material(surf_idx)
			if not base_mat:
				continue

			# Solid is an alpha TEST: a masked texture already has its scissor material, and a
			# non-masked texture at full renderamt is opaque — both keep the BSP-built
			# lightmapped material rather than going through the conversion below.
			if mode == 4 and (amt >= 255 or _has_alpha_texture(base_mat)):
				continue

			var mat: StandardMaterial3D
			if base_mat is StandardMaterial3D:
				mat = base_mat.duplicate()
			elif base_mat is ShaderMaterial:
				mat = convert_shader_to_standard(base_mat)
			else:
				continue

			match mode:
				1: # Color — solid color with alpha
					var rc_parts: PackedStringArray = str(ent.get("rendercolor", "255 255 255")).split(" ")
					mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
					mat.albedo_color = Color(
						float(rc_parts[0]) / 255.0,
						float(rc_parts[1]) / 255.0 if rc_parts.size() > 1 else 1.0,
						float(rc_parts[2]) / 255.0 if rc_parts.size() > 2 else 1.0,
						alpha)
				2, 4: # Texture, and Solid below full renderamt — no mask to test against
					mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
					mat.albedo_color.a = alpha
				5: # Additive — additive blend with alpha
					mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
					AssetLoader.set_additive_blend(mat)
					mat.albedo_color.a = alpha

			mesh_inst.set_surface_override_material(surf_idx, mat)


## Apply GoldSrc render properties to a POINT entity's studio model. The brush path above
## rebuilds materials, which would strip an MDL's ambient-cube lighting, so models instead
## go through AssetLoader's fade shader — the same one the invisibility and corpse fades use.
## Only renderamt is honoured; an unset renderamt leaves the model opaque.
func apply_model_render_properties(model: Node3D, ent: Dictionary) -> void:
	if int(ent.get("rendermode", "0")) == 0 or not ent.has("renderamt"):
		return
	var alpha := clampf(int(ent["renderamt"]) / 255.0, 0.0, 1.0)
	if alpha < 1.0:
		AssetLoader.set_model_alpha(model, alpha)


## True when any surface of a mesh draws through a '{'-masked texture.
func _mesh_is_masked(mesh_inst: MeshInstance3D) -> bool:
	for surf_idx in mesh_inst.mesh.get_surface_count():
		if _has_alpha_texture(mesh_inst.get_active_material(surf_idx)):
			return true
	return false


## True when a BSP surface material's albedo texture carries a transparency mask.
## The BSP plugin only produces an alpha channel for '{'-prefixed (masked) textures.
func _has_alpha_texture(base_mat: Material) -> bool:
	var tex: Texture2D = null
	if base_mat is ShaderMaterial:
		tex = (base_mat as ShaderMaterial).get_shader_parameter("albedo_texture")
	elif base_mat is BaseMaterial3D:
		tex = (base_mat as BaseMaterial3D).get_texture(BaseMaterial3D.TEXTURE_ALBEDO)
	if not (tex is ImageTexture):
		return false
	var img := (tex as ImageTexture).get_image()
	return img != null and img.detect_alpha() != Image.ALPHA_NONE


## Convert a BSP ShaderMaterial (lightmapped) to a StandardMaterial3D, preserving
## the albedo texture. Returns a new StandardMaterial3D. Callers can set additional
## properties (cull_mode, transparency, etc.) on the result.
func convert_shader_to_standard(shader_mat: ShaderMaterial) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var tex = shader_mat.get_shader_parameter("albedo_texture")
	if tex:
		mat.set_texture(BaseMaterial3D.TEXTURE_ALBEDO, tex)
		mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	return mat
