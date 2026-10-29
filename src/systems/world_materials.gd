class_name WorldMaterials
extends Object
## Per-surface detail shading for BSP world geometry, chosen by texture name.
##
## The BSP loader groups world faces one MeshInstance3D per texture and names each node after the
## GoldSrc texture it draws (goldsrc_bsp.cpp, set_name on the mesh instance), so the map arrives
## already sorted into exactly the buckets a material system wants. This walks that tree, decides
## what each texture is made of, and hangs a detail pass off the material.
##
## It hangs it off as next_pass rather than replacing anything. The world's lightstyle shader —
## four lightmap layers, animated styles, gamma-space compositing — lives as a string literal
## inside the C++ extension; reimplementing it here to add one term would be a second copy of it
## that silently drifts out of step. next_pass adds a second draw over the untouched original, so
## none of that logic is duplicated and nothing in extern/ has to change.
##
## Costs one extra draw of world geometry, so it is gated on the "high" picture-quality preset.

const DETAIL_SHADER := "res://shaders/world_detail.gdshader"

## Per-class detail settings. Deliberately few classes: measured over the 30 shipped maps, rock,
## brick, dirt and wood are about 60% of all shaded wall area between them, while metal is 0.5%
## and glass is a rounding error — there is nothing to be gained by splitting this finer.
const CLASS_PARAMS := {
	"mineral": {"detail_scale": 120.0, "detail_strength": 0.35, "detail_aniso": 1.0},
	"wood": {"detail_scale": 90.0, "detail_strength": 0.30, "detail_aniso": 0.12},
	"ground": {"detail_scale": 150.0, "detail_strength": 0.45, "detail_aniso": 1.0},
}

## Names the keyword rules get wrong or have nothing to say about, taken from a look at the actual
## textures. Only the ones that matter: these plus the keywords below cover roughly three quarters
## of the wall area in the shipped maps, which is as far as hand-listing is worth taking.
const OVERRIDES := {
	# Wood the keywords would call stone, mostly because it is a roof or a wall made of it.
	"ww_rooftile1": "wood", "ww_roof3": "wood", "m_ceiling4": "wood", "hwall3_4": "wood",
	"crossover03": "wood", "fifties_dr1": "wood",
	# Masonry under names that say nothing at all.
	"rtex336": "mineral", "rtex033": "mineral", "ext004__3arena_": "mineral",
	"wiz_cross2": "mineral", "wiz_cross3": "mineral", "out_w5": "mineral",
	"mur191__tutoria": "mineral", "kl_demogr3c2": "mineral", "tel_roof-01": "mineral",
	"cloud_blu_ext": "mineral", "cloud_blu_1": "mineral",
	# Grass that spells itself creatively.
	"btgrazz1": "ground",
}

## Checked in order, so a name matching two classes takes the first. Wood leads because the wooden
## things in these maps are usually named for what they are part of — a roof, a wall, a floor —
## and would otherwise be swallowed by the masonry rules.
const KEYWORDS := [
	["wood", ["wood", "plank", "timber", "bark", "crate", "barrel", "keg", "fence", "beam",
			"board", "deck", "shingle", "oak"]],
	["mineral", ["rock", "rck", "_rk", "stone", "cliff", "granit", "marble", "marb", "boulder",
			"brick", "brk", "crete", "concr", "cinder", "cement", "block", "castle", "wall",
			"cave", "mine", "asphalt", "road", "street", "curb", "stair", "column", "pillar",
			"arch", "rubble", "cobble", "church", "tnnl", "tunnel", "floor", "flr", "tile"]],
	["ground", ["dirt", "mud", "sand", "snd", "grass", "grss", "ground", "gnd", "soil", "snow",
			"gravel", "path", "moss", "leaf"]],
]

static var _materials := {}  # class name -> shared ShaderMaterial


## The class a GoldSrc texture name belongs to, or "" for leave-alone.
static func classify(tex_name: String) -> String:
	var n := _normalize(tex_name)
	if n.is_empty():
		return ""
	if OVERRIDES.has(n):
		return OVERRIDES[n]
	for rule in KEYWORDS:
		for kw in rule[1]:
			if n.contains(kw):
				return rule[0]
	return ""


## GoldSrc encodes meaning in the first character or two. "{" is alpha-masked (fences, foliage),
## "!" is liquid and "~" is light-emitting — none of which wants surface grain, and the first two
## have their own shaders anyway. "+0".."+9"/"+A".. are animation frames and "-0".."-9" are random
## tiling variants: those are ordinary walls wearing a prefix, so it comes off before matching.
static func _normalize(tex_name: String) -> String:
	var n := tex_name.to_lower()
	if n.is_empty() or n[0] in ["{", "!", "~"] or n.begins_with("sky"):
		return ""
	if n.length() > 2 and n[0] in ["+", "-"]:
		n = n.substr(2)
	return n


## Hang (or strip) the detail pass across a loaded map. Returns how many surfaces were classified.
## Safe to call repeatedly — it is how a live quality change takes hold — and on a headless server,
## where there is nothing to draw and it does nothing.
static func apply(map_root: Node, enabled: bool) -> int:
	if map_root == null or DisplayServer.get_name() == "headless":
		return 0
	var count := 0
	for mi in _collect(map_root, []):
		var cls := classify(String(mi.name))
		if cls.is_empty():
			continue
		count += 1
		for i in mi.get_surface_override_material_count():
			var mat := mi.get_active_material(i)
			if mat:
				mat.next_pass = _material_for(cls) if enabled else null
	return count


static func _collect(node: Node, out: Array[MeshInstance3D]) -> Array[MeshInstance3D]:
	# Sky and water are the loader's own shaders on their own geometry, and it flags both.
	if node is MeshInstance3D and not node.has_meta("is_sky_surface") \
			and not node.has_meta("is_water_surface"):
		out.append(node as MeshInstance3D)
	for child in node.get_children():
		_collect(child, out)
	return out


## One material per class, shared by every surface of that class in every map.
static func _material_for(cls: String) -> ShaderMaterial:
	if not _materials.has(cls):
		var mat := ShaderMaterial.new()
		mat.shader = load(DETAIL_SHADER)
		# Which space the pass blends in, same question the lightmap shaders ask. The renderer
		# cannot change without a relaunch, so reading it once per material is enough.
		mat.set_shader_parameter("linear_output", EntityRender.renderer_is_linear())
		for param in CLASS_PARAMS[cls]:
			mat.set_shader_parameter(param, CLASS_PARAMS[cls][param])
		_materials[cls] = mat
	return _materials[cls]
