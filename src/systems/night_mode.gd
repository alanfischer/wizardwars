class_name NightMode
extends Object
## Night: the sky's light turned down to moonlight, the map's own lights left as they are.
##
## How much of each lightmap luxel the sky put there is baked at conversion (GoldSrcBSP's
## compute_sun_fractions: lm_sun on world materials, sun_slices in the light grid for models).
## This only says how far to turn that share down, and swaps the sky. A map with no
## light_environment has no share to turn, so night leaves it exactly as it was.

## Moonlight, as a multiplier on the sky's share of the (linear) light.
const TINT := Color(0.12, 0.14, 0.24)
## Unlit liquid has no lightmap to read, so it dims by a flat amount.
const LIQUID_DIM := Color(0.3, 0.33, 0.42)
## Skies that already read as night stay; any other gives way to this one.
const SKY := "fullmoon"
const NIGHT_SKIES := ["fullmoon", "night", "space", "space2"]


static func enabled() -> bool:
	return bool(ServerVars.get_value("night", false))


static func sky_for(sky_name: String) -> String:
	if sky_name.is_empty() or not enabled() or sky_name in NIGHT_SKIES:
		return sky_name
	return SKY


## Push the current setting onto a loaded map and every model the light grid lights. Safe to
## call again on a live map, which is how a mid-match /night takes hold.
static func apply(map_root: Node) -> void:
	var amount := 1.0 if enabled() else 0.0
	var tint := Vector3(TINT.r, TINT.g, TINT.b)
	var dim := LIQUID_DIM if enabled() else Color.WHITE
	if map_root:
		_apply_recursive(map_root, amount, tint, Vector3(dim.r, dim.g, dim.b))
	LightGrid.set_night(amount, tint)


## Descends into MeshInstance3Ds too: a BSP nests submodel meshes under their parent mesh.
static func _apply_recursive(node: Node, amount: float, tint: Vector3, dim: Vector3) -> void:
	for child in node.get_children():
		if child is MeshInstance3D:
			var mi := child as MeshInstance3D
			if mi.mesh:
				for i in mi.mesh.get_surface_count():
					_set_material(mi.mesh.surface_get_material(i), amount, tint, dim)
					_set_material(mi.get_surface_override_material(i), amount, tint, dim)
		_apply_recursive(child, amount, tint, dim)


static func _set_material(mat: Material, amount: float, tint: Vector3, dim: Vector3) -> void:
	if not mat is ShaderMaterial:
		return
	var smat := mat as ShaderMaterial
	if smat.get_shader_parameter("lm_sun") != null:
		smat.set_shader_parameter("night", amount)
		smat.set_shader_parameter("night_tint", tint)
	elif smat.get_shader_parameter("liquid_type") != null:
		smat.set_shader_parameter("night_dim", dim)
