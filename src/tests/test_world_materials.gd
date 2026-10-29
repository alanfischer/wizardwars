extends "res://src/tests/test_base.gd"
## Texture-name classification for the world detail pass. The pass itself is pixels and cannot be
## checked headless; what is testable is the part that actually decides anything — which GoldSrc
## texture name lands in which material class.
##
## The named textures below are real, taken from the shipped maps by surface area.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.


func test_keywords_classify_the_common_cases() -> void:
	for name in ["cloud_rock1", "BIG_BRICK1B", "osaka_cliff3", "ww_graybrick", "crete3_flr05b",
			"K_castle5b", "wall_stone_sm", "GRANITE2", "canyonsasphalt"]:
		assert_eq(WorldMaterials.classify(name), "mineral", name)
	for name in ["WOOD4A", "55wood09", "wiz_wood2", "fp-bark4", "wood_tiled2"]:
		assert_eq(WorldMaterials.classify(name), "wood", name)
	for name in ["DIRT1", "GRASS_B", "out_ground4", "osaka_dirt", "out_snd1", "blade_grass"]:
		assert_eq(WorldMaterials.classify(name), "ground", name)


## Wood is matched before masonry on purpose: these are all named for the thing they are part of.
func test_wood_wins_over_masonry_words() -> void:
	assert_eq(WorldMaterials.classify("wood_tiled2"), "wood", "wood beats 'tile'")
	assert_eq(WorldMaterials.classify("ww_rooftile1"), "wood", "wooden shingles, despite 'tile'")
	assert_eq(WorldMaterials.classify("HWALL3_4"), "wood", "timber framing, despite 'wall'")
	assert_eq(WorldMaterials.classify("m_ceiling4"), "wood", "planks under a name saying neither")


## Rock is rock whether or not it is also mossy, sandy or snowed on.
func test_mineral_wins_over_ground_words() -> void:
	assert_eq(WorldMaterials.classify("cloud_rockmoss"), "mineral")
	assert_eq(WorldMaterials.classify("osaka_sandyrock"), "mineral")
	assert_eq(WorldMaterials.classify("snow_rock"), "mineral")
	assert_eq(WorldMaterials.classify("KX_snow3b"), "ground", "snow with no rock in it")


## GoldSrc prefixes: "-N" random tiling and "+N" animation frames are ordinary walls wearing two
## extra characters, and must classify as the wall they are.
func test_tiling_and_animation_prefixes_are_stripped() -> void:
	assert_eq(WorldMaterials.classify("-0out_rk3"), "mineral")
	assert_eq(WorldMaterials.classify("-3out_rk3"), "mineral")
	assert_eq(WorldMaterials.classify("-2tnnl_rck1"), "mineral")
	assert_eq(WorldMaterials.classify("-0ww_bfj7rock1"), "mineral")
	assert_eq(WorldMaterials.classify("+0ww_graybrick"), "mineral")


## "{" is alpha-masked, "!" is liquid, "~" is light-emitting, sky is sky. None of them wants grain,
## and the first two are on their own shaders already.
func test_special_prefixes_are_left_alone() -> void:
	for name in ["{forest1", "{blue", "{ladder1", "!water3", "~light1", "sky", "skybk"]:
		assert_eq(WorldMaterials.classify(name), "", name)


func test_unknown_names_are_left_alone() -> void:
	for name in ["aaatrigger", "clip", "origin", "HINT", "444yhalo1", ""]:
		assert_eq(WorldMaterials.classify(name), "", name)


## Every class the tables can produce must have detail settings, or apply() would fault on a name
## somebody adds to OVERRIDES without adding the class.
func test_every_class_has_parameters() -> void:
	var classes := {}
	for rule in WorldMaterials.KEYWORDS:
		classes[rule[0]] = true
	for name in WorldMaterials.OVERRIDES:
		classes[WorldMaterials.OVERRIDES[name]] = true
	for cls in classes:
		assert_true(WorldMaterials.CLASS_PARAMS.has(cls), "no detail params for class '%s'" % cls)


## Overrides are matched against the normalized (lowercased) name, so an entry typed with capitals
## would silently never fire.
func test_overrides_are_stored_normalized() -> void:
	for name in WorldMaterials.OVERRIDES:
		assert_eq(String(name), String(name).to_lower(), "override key must be lowercase")
		assert_eq(WorldMaterials.classify(name), WorldMaterials.OVERRIDES[name], name)
