extends Node
## Every liquid surface a map converts to: which brush carries it, and which liquid the
## converter decided it was. Exists because two separate bugs each made water silently vanish
## and neither was visible from outside the converter:
##   - liquid was detected from the texture NAME alone ('!' or '*'), which missed water4b and
##     scrollwater1/2, so ww_2fort, ww_ravine2 and ww_countryside got no liquid shader;
##   - the parser's water seam cull let two coincident water brushes delete each other, which
##     erased every one of ww_osaka's rivers (a func_water laid over a func_conveyor).
## Run after touching the liquid path in goldsrc_bsp.cpp or the seam cull in bsp_parser.cpp.
##
## Runs as a SCENE, not with -s: MapConverter needs the Log autoload, which the bare
## SceneTree runner never registers.
##
##   godot --headless --path . res://tools/verify_water_surfaces.tscn

const KINDS := ["water", "slime", "lava"]  # the brush's CONTENTS_*, as the shader sees it

## The maps the prefix test used to miss, the one whose water the seam cull ate (ww_osaka),
## one the prefix test always caught (regression control), and ww_skytower, whose liquid is all
## ice-textured but water by contents — the case that would go wrong again if anything ever
## started reading the texture name instead of the brush.
const MAPS := ["ww_2fort", "ww_osaka", "ww_ravine2", "ww_countryside", "ww_leyline",
	"ww_skytower", "ww_golem", "ww_matrox", "ww_volcano", "ww_keep"]


func _ready() -> void:
	if not ClassDB.class_exists(&"GoldSrcBSP"):
		printerr("GoldSrcBSP plugin not available")
		get_tree().quit(1)
		return
	var converter := MapConverter.new()
	add_child(converter)

	var failed := 0
	for map_name in MAPS:
		if not converter.convert(map_name):
			printerr("%s: conversion FAILED" % map_name)
			failed += 1
			continue
		var scn := ResourceLoader.load(
				"user://resources/maps/%s.scn" % map_name, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
		if scn == null:
			printerr("%s: no cached .scn after convert" % map_name)
			failed += 1
			continue
		var map_root: Node3D = scn.instantiate()
		var by_owner: Dictionary = {}  # "<classname> <kind>" -> surface count
		_collect(map_root, map_root, by_owner)
		if by_owner.is_empty():
			printerr("%s: NO liquid surfaces" % map_name)
			failed += 1
		else:
			var keys := by_owner.keys()
			keys.sort()
			var parts: PackedStringArray = []
			for k in keys:
				parts.append("%s x%d" % [k, by_owner[k]])
			print("%-16s %s" % [map_name, ", ".join(parts)])
		map_root.free()

	converter.queue_free()
	get_tree().quit(1 if failed > 0 else 0)


## Depth twins share the mesh and carry the same meta, so they are counted by their
## material_override instead of being double-counted as liquid surfaces.
func _collect(node: Node, map_root: Node3D, out: Dictionary) -> void:
	if node is MeshInstance3D and node.has_meta("is_water_surface"):
		var mi := node as MeshInstance3D
		if mi.material_override == null and mi.mesh:
			var mat := mi.mesh.surface_get_material(0) as ShaderMaterial
			var kind := -1
			if mat:
				var raw = mat.get_shader_parameter("liquid_type")
				kind = int(raw) if raw != null else 0
			var kind_name: String = KINDS[kind] if kind >= 0 and kind < KINDS.size() else "NO-SHADER"
			var owner_name := _owning_entity(mi, map_root)
			var key := "%s/%s" % [owner_name, kind_name]
			out[key] = int(out.get(key, 0)) + 1
	for child in node.get_children():
		_collect(child, map_root, out)


## Which brush this surface belongs to — the map-root child it sits under is the model node,
## and its name is "<classname>_<targetname>_<index>" (or "worldspawn").
func _owning_entity(node: Node, map_root: Node3D) -> String:
	var n := node
	while n != null and n.get_parent() != map_root:
		n = n.get_parent()
	if n == null:
		return "?"
	var ent_name := String(n.name)
	return "worldspawn" if ent_name == "worldspawn" else ent_name.split("_")[0] + "_" + ent_name.split("_")[1]
