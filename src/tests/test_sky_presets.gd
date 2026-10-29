extends "res://src/tests/test_base.gd"
## The procedural sky has to look like the cubemap it replaces, and every map's colours come out
## of SkyPreset rather than a hand-written table. These cover the two halves that can be checked
## without eyes on the screen: that measurement reads the shipped sky art in the right key, and
## that the sun ends up where the map's own light_environment put it.
##
## Scene-run only (needs the AssetLoader autoload): res://src/tests/run_tests.tscn.

const FACE_SUFFIXES := ["rt", "lf", "up", "dn", "bk", "ft"]


## The six faces of a shipped sky, in Skybox.setup's order and with the same two rotations
## applied — SkyPreset's face math only lines up after those.
func _faces(sky_name: String) -> Array[Image]:
	var images: Array[Image] = []
	for suffix in FACE_SUFFIXES:
		var img := AssetLoader.load_sky_image(sky_name, suffix)
		if img == null:
			var tex := load("sky/%s%s.tga" % [sky_name, suffix]) as Texture2D
			if tex == null:
				return []
			img = tex.get_image()
		images.append(img)
	images[2].rotate_90(COUNTERCLOCKWISE)
	images[3].rotate_90(CLOCKWISE)
	return images


func test_sun_direction_from_pitch_and_yaw() -> void:
	# pitch -90 is noon: light travels straight down, so the sun is straight up.
	var noon := SkyPreset.sun_dir_from_light_environment({"pitch": "-90"})
	assert_vec3_almost_eq(noon, Vector3.UP, 0.01, "pitch -90 puts the sun overhead")

	# ww_2fort, straight out of the .bsp. Yaw 144 with a -30 pitch: 30 degrees above the horizon.
	var fort := SkyPreset.sun_dir_from_light_environment({"pitch": "-30", "angles": "0 144 0"})
	assert_almost_eq(fort.y, 0.5, 0.02, "a -30 pitch sits the sun at sin(30) above the horizon")
	assert_almost_eq(fort.length(), 1.0, 0.001, "and the direction is normalised")

	# GoldSrc yaw runs anticlockwise about the up axis; two yaws a quarter turn apart must come
	# out a quarter turn apart, or the axis map has a sign flipped.
	var east := SkyPreset.sun_dir_from_light_environment({"pitch": "-45", "angle": "0"})
	var north := SkyPreset.sun_dir_from_light_environment({"pitch": "-45", "angle": "90"})
	assert_almost_eq(east.dot(north), 0.5, 0.02, "90 degrees of yaw at a 45 degree pitch")


## ww_varrock's sun points up (+90) and ww_chasm's sits on the horizon (-1). Neither is usable as
## written, but both maps still say which way and what colour, so the value is bent, not dropped.
func test_degenerate_suns_are_salvaged() -> void:
	var varrock := SkyPreset.sun_dir_from_light_environment({"pitch": "90", "angle": "0"})
	assert_gt(varrock.y, 0.0, "a sun below the horizon is mirrored back above it")

	var chasm := SkyPreset.sun_dir_from_light_environment({"pitch": "-1", "angle": "0"})
	assert_gt(chasm.y, 0.05, "a grazing sun is lifted clear of the horizon band")
	assert_lt(chasm.y, 0.3, "but not so far that the map's low sun becomes a high one")


func test_missing_pitch_is_refused_rather_than_guessed() -> void:
	# ww_leyline and ww_rage: a light_environment with a colour but no usable angle at all.
	assert_eq(SkyPreset.sun_dir_from_light_environment({"_light": "255 255 128 200",
		"angles": "0 0 0"}), Vector3.ZERO, "zeroed angles are not a sun direction")
	assert_eq(SkyPreset.sun_dir_from_light_environment({}), Vector3.ZERO,
		"and neither is a map with no light_environment at all")


func test_sun_colour_keeps_hue_drops_brightness() -> void:
	# ww_keep's sun. The 100 is a GoldSrc lightmap compile parameter, not a screen brightness.
	var keep := SkyPreset.sun_color_from_light_environment({"_light": "251 142 70 100"})
	assert_almost_eq(keep.r, 1.0, 0.001, "the brightest channel is normalised to 1")
	assert_gt(keep.r, keep.g, "and the orange survives normalising")
	assert_gt(keep.g, keep.b, "in both channels")
	assert_eq(SkyPreset.sun_color_from_light_environment({}), Color.WHITE,
		"no _light key leaves the sun white")


## The whole matching argument: a sky nobody wrote a preset for still comes out the right colour,
## because the colours are read off the art the map already ships.
func test_derives_colours_from_the_shipped_sky() -> void:
	var seascape := _faces("seascape")
	if seascape.is_empty():
		return  # sky art not present in this checkout
	var p := SkyPreset.build("seascape", seascape)
	var zenith: Color = p["zenith_color"]
	assert_gt(zenith.b, zenith.r, "seascape's zenith keeps its blue")
	assert_gt(zenith.b, zenith.g, "against both other channels")

	var firey := _faces("firey_")
	if not firey.is_empty():
		var fp := SkyPreset.build("firey_", firey)
		var fz: Color = fp["zenith_color"]
		assert_gt(fz.r, fz.b, "and firey_'s comes out warm, from the same code")


func test_starfields_get_stars_and_no_clouds() -> void:
	var space := _faces("space2")
	if space.is_empty():
		return
	var p := SkyPreset.build("space2", space)
	assert_eq(p["cloud_amount"], 0.0, "there is no weather in space")
	assert_gt(p["star_amount"], 0.5, "but there are stars")
	assert_eq(p["sun_energy"], 0.0, "and no sun disc — the bright pixel out there is a star")

	# Without a light_environment a starfield must not aim the sun at its brightest star.
	var no_sun := SkyPreset.build("space2", space)
	assert_gt(no_sun["sun_dir"].y, 0.0, "the fallback sun stays above the horizon")


func test_overrides_win_and_every_name_is_a_real_sky() -> void:
	var dark := _faces("dark")
	if not dark.is_empty():
		var p := SkyPreset.build("dark", dark)
		assert_eq(p["cloud_amount"], SkyPreset.OVERRIDES["dark"]["cloud_amount"],
			"an override beats the measured value")
		# ww_chasm, ww_matrox, ww_ravine2, ww_skytower and ww_storm all ride on this one being
		# overcast rather than night — it measures at 96 luminance with no black pixels at all.
		assert_eq(p["star_amount"], 0.0, "dark is an overcast sky, not a night one")

	# A preset for a sky that no longer ships is dead weight nobody would notice.
	for sky_name in SkyPreset.OVERRIDES:
		assert_false(_faces(sky_name).is_empty(), "OVERRIDES names a shipped sky: %s" % sky_name)


## build() returns a dict that is written straight onto the material as shader parameters, so a
## name that drifts from the shader silently does nothing at all.
func test_shader_takes_every_uniform_the_preset_sets() -> void:
	var shader: Shader = load("res://shaders/sky_procedural.gdshader")
	assert_ne(shader, null, "the sky shader loads")
	if shader == null:
		return
	var declared := {}
	for u in shader.get_shader_uniform_list():
		declared[u.name] = true

	var faces := _faces("wiz")
	if faces.is_empty():
		return
	for key in SkyPreset.build("wiz", faces):
		assert_true(declared.has(key), "sky_procedural declares a '%s' uniform" % key)
