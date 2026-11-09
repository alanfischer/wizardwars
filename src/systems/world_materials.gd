class_name WorldMaterials
extends Object
## What a BSP world surface is made of, by its GoldSrc texture name: mineral, wood or ground. The
## loader names each world mesh after its texture (goldsrc_bsp.cpp), and the weather reads the class
## to say how readily it pools (WeatherSystem.PUDDLE_BY_CLASS).

## Names the keyword rules get wrong or have nothing to say about, taken from a look at the actual
## textures. Only the ones that matter: these plus the keywords below cover roughly three quarters
## of the wall area in the shipped maps, which is as far as hand-listing is worth taking.
const OVERRIDES := {
	# Wood the keywords would call stone, mostly because it is a roof or a wall made of it.
	"ww_rooftile1": "wood", "ww_roof3": "wood", "m_ceiling4": "wood", "hwall3_4": "wood",
	"crossover03": "wood", "fifties_dr1": "wood", "out_wd": "wood",
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
## "!" is liquid and "~" is light-emitting — none of which is ground, and the first two have
## their own shaders anyway. "+0".."+9"/"+A".. are animation frames and "-0".."-9" are random
## tiling variants: those are ordinary walls wearing a prefix, so it comes off before matching.
static func _normalize(tex_name: String) -> String:
	var n := tex_name.to_lower()
	if n.is_empty() or n[0] in ["{", "!", "~"] or n.begins_with("sky"):
		return ""
	if n.length() > 2 and n[0] in ["+", "-"]:
		n = n.substr(2)
	return n
