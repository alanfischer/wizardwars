class_name WaterSurfaces
extends Object
## Turns the liquid shader's depth-driven half on and off.
##
## Depth absorption, shoreline foam and the wave's own shading are the parts of the water that
## cost something per pixel, so they ride the picture-quality preset rather than the renderer —
## the same division WorldMaterials uses for the detail pass. A fast machine on Compatibility
## gets them; a weak one on Forward+ does not. What decides it is the level, not the backend:
## the depth texture these need works on both (shaders/decal_projector.gdshader has shipped on
## the Compatibility default for as long as decals have).
##
## Off, the surface is exactly the turbulent warp it has always been.

const PARAM := &"depth_effects"

## Where a twin sorts against the liquid colour pass, which is render_priority 0. It is always
## ahead of it, absorption or no absorption: the twin stamps liquid depth first, so the colour
## pass survives only where it is the NEAREST liquid fragment and far water cannot blend over
## near water. The twin used to be moved BEHIND the colour pass whenever absorption was on,
## because its depth write landed in the DEPTH_TEXTURE the colour pass reads for thickness. It
## no longer does: the twin's own shader asks for that texture, so Godot takes its one lazy copy
## at the twin's draw — before any liquid depth exists. See WATER_DEPTH_SHADER_CODE in
## goldsrc_bsp.cpp. What that cost until it was fixed was every High-preset player looking at
## ww_golem's moat through the far wall of each water brush.
const PRIORITY_BEFORE := -1
## The twin stamps its depth this much farther from the camera than the surface it copies, as a
## proportion of view distance, so the prepass cannot reject the colour pass it exists to gate.
## Anything left of that band is a second liquid face drawn over the first — and since the band
## is a proportion, its size changes as you walk, so a moat's floor and back wall blink in and
## out of it. Never the surface: that is the nearest liquid and always wins.
##
## The push was needed when the depth func was GL_LESS. The RenderingDevice renderers draw
## reverse-Z at GEQUAL, where equal depth passes, so they need none: over a walk round
## ww_golem's moat both draw the identical count of liquid pixels with the push and without it,
## while doubled pixels fall from 2625 to nil. gl_compatibility still loses about 2600 liquid
## pixels over that walk without it, so it keeps the push.
const PUSH_PARAM := &"depth_push"
const PUSH_NONE := 1.0
const PUSH_COMPAT := 1.002
## Where an effect that is INSIDE the liquid sorts. Below the colour pass, so the water blends
## over it and it reads as being in the pool rather than on it — which is GoldSrc's back-to-front
## sort, done per object because Godot's queue is priority-major. Below PRIORITY_BEFORE too: a
## twin stamping there would depth-reject the effect outright instead of dimming it.
const PRIORITY_SUBMERGED := PRIORITY_BEFORE - 1


## Push `enabled` onto every liquid material under `map_root`. Returns how many surfaces were
## touched, so a caller can log it the way the detail pass does.
##
## Also pins the depth-prepass twins ahead of the colour pass and sets their depth push for this
## renderer. The converter already emits them at that priority, so the pinning is belt and braces
## for a .scn that predates it; the push is not — nothing else sets it.
##
## The twin is never HIDDEN, which is what it used to be here. With no liquid depth in the buffer
## at all, every later transparent draw survives over the water whatever its position: a fireball
## sunk in ww_hunt's harbour still rendered at full strength on top of it, because effect sprites
## sort at render_priority 2 and priority outranks depth in the transparent queue.
static func apply(map_root: Node, enabled: bool) -> int:
	if map_root == null:
		return 0
	var count := 0
	for mi in _collect(map_root):
		if mi.mesh == null:
			continue
		for surf_idx in mi.mesh.get_surface_count():
			var mat := mi.mesh.surface_get_material(surf_idx) as ShaderMaterial
			if mat:
				mat.set_shader_parameter(PARAM, enabled)
				count += 1
	var push := PUSH_COMPAT if RenderingServer.get_current_rendering_method() == "gl_compatibility" \
			else PUSH_NONE
	for twin in _collect_twins(map_root):
		twin.visible = true
		twin.material_override.render_priority = PRIORITY_BEFORE
		twin.material_override.set_shader_parameter(PUSH_PARAM, push)
	return count


## The converter names each twin after its surface with "_depth" appended, and it is the only
## liquid mesh carrying a material_override.
static func _collect_twins(node: Node, out: Array[MeshInstance3D] = []) -> Array[MeshInstance3D]:
	if node is MeshInstance3D and (node as MeshInstance3D).material_override != null \
			and String(node.name).ends_with("_depth"):
		out.append(node as MeshInstance3D)
	for child in node.get_children():
		_collect_twins(child, out)
	return out


static func _collect(node: Node, out: Array[MeshInstance3D] = []) -> Array[MeshInstance3D]:
	if node is MeshInstance3D and node.has_meta("is_water_surface") \
			and (node as MeshInstance3D).material_override == null:
		out.append(node as MeshInstance3D)
	for child in node.get_children():
		_collect(child, out)
	return out
