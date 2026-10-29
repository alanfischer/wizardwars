class_name SkyPreset
extends RefCounted
## Uniform values for sky_procedural.gdshader, one set per map.
##
## The point is that the new sky has to look like the old one. Rather than hand-author fifteen
## palettes, the colours are measured off the cubemap the map already ships — zenith from its up
## face, ground from its down face, horizon from the band the side faces meet at. A sky nobody has
## ever seen (a downloaded map, or ww_library's "desert", which the repo doesn't have) therefore
## still lands in the right key.
##
## What measurement can't recover is character: whether a dark sky is dark because it's night or
## because it's overcast, whether a bright pixel is the sun or a star. OVERRIDES carries that per
## skyname, as a partial dict merged over the derived values — so it stays a handful of entries
## about weather, and the colour matching keeps working for everything not listed.

## Cubemap face order, matching Skybox.setup's `suffixes` and Godot's +X,-X,+Y,-Y,+Z,-Z.
const FACE_RT := 0
const FACE_LF := 1
const FACE_UP := 2
const FACE_DN := 3
const FACE_BK := 4
const FACE_FT := 5
const SIDE_FACES: Array[int] = [FACE_RT, FACE_LF, FACE_BK, FACE_FT]

## Faces are measured at this size. The statistics wanted here are all low-frequency — mean colour,
## how much the sky varies across itself — and 256x256x6 get_pixel calls in GDScript is a visible
## stall at map load for numbers that a downsample answers identically.
const SAMPLE_SIZE := 32

## Above this fraction of near-black pixels a sky is a starfield, not a lit one. space2 is 99.8%
## black, fullmoon 89%, night 51%, and the next sky down (avanti) is 72% — so the line sits above
## avanti's neighbours rather than between them, and OVERRIDES names the night skies explicitly.
const STARFIELD_DARK_FRACTION := 0.85
const DARK_PIXEL := 0.125  # 32/255

## Per-skyname character. Merged over the derived colours, so an entry only says what measurement
## cannot: how cloudy, whether there are stars, whether a sun is visible at all.
const OVERRIDES := {
	# Starfields. No atmosphere to gradient and no sun — the bright pixel a measurement would
	# find here is a star, and pointing a sun disc at it would put a second one in the sky.
	"space": {"cloud_amount": 0.0, "star_amount": 0.9, "sun_energy": 0.0,
		"sun_glow_energy": 0.0, "horizon_falloff": 3.0},
	"space2": {"cloud_amount": 0.0, "star_amount": 1.0, "sun_energy": 0.0,
		"sun_glow_energy": 0.0, "horizon_falloff": 3.0},
	# Night. The disc is the moon: small, cold, and dim enough not to read as daylight.
	"fullmoon": {"cloud_amount": 0.15, "star_amount": 0.75, "sun_size": 0.018,
		"sun_color": Color(0.82, 0.86, 1.0), "sun_energy": 1.5, "sun_glow_energy": 0.3},
	"night": {"cloud_amount": 0.22, "star_amount": 0.6, "sun_size": 0.02,
		"sun_color": Color(0.8, 0.85, 1.0), "sun_energy": 1.2, "sun_glow_energy": 0.25},
	"avanti": {"cloud_amount": 0.3, "star_amount": 0.45, "sun_energy": 0.6,
		"sun_glow_energy": 0.3},
	# Overcast. The sun is behind the cloud deck, so it contributes glow and no disc.
	"dark": {"cloud_amount": 0.85, "cloud_softness": 0.3, "sun_energy": 0.0,
		"sun_glow_energy": 0.2},
	"null_plainsky256_": {"cloud_amount": 0.0, "sun_energy": 0.0, "sun_glow_energy": 0.25,
		"horizon_falloff": 0.6},
	"nottingham": {"cloud_amount": 0.55, "sun_energy": 0.8},
	"wiz": {"cloud_amount": 0.5},
	"purple": {"cloud_amount": 0.45},
	# Clear-ish daylight.
	"seascape": {"cloud_amount": 0.28, "horizon_falloff": 1.4},
	"osaka": {"cloud_amount": 0.35},
	"forest256_": {"cloud_amount": 0.5},
	"firey_": {"cloud_amount": 0.6, "cloud_speed": 0.014},
}

## Used when a map has no usable light_environment — six of the thirty do, and a dropped-in map
## may too. Mid-morning and slightly off-axis, so the disc lands somewhere a sky brush can show it.
const DEFAULT_SUN_DIR := Vector3(0.45, 0.55, -0.70)


## The full uniform set for one map. `faces` is the six cubemap Images in Skybox's order and
## orientation; `sun_dir` / `sun_color` come from the map's light_environment and are optional —
## pass Vector3.ZERO to have the sky pick for itself.
static func build(sky_name: String, faces: Array[Image], sun_dir := Vector3.ZERO,
		sun_color := Color.WHITE) -> Dictionary:
	var stats := _measure(faces)
	var params := _derive(stats)

	if sun_dir.length_squared() > 0.0001:
		params["sun_dir"] = sun_dir.normalized()
		params["sun_color"] = sun_color
	else:
		# No sun in the entity list: the brightest thing in the sky is the best guess left, and
		# on a starfield it is a star, so fall back to a plausible angle instead.
		params["sun_dir"] = (DEFAULT_SUN_DIR.normalized() if stats["is_starfield"]
			else stats["brightest_dir"])

	for key in OVERRIDES.get(sky_name, {}):
		params[key] = OVERRIDES[sky_name][key]
	return params


## Mean colour, spread, darkness and brightest direction, read off downsampled copies of the six
## faces. Everything build() decides comes from here.
static func _measure(faces: Array[Image]) -> Dictionary:
	var small: Array[Image] = []
	for face in faces:
		var copy := face.duplicate() as Image
		copy.resize(SAMPLE_SIZE, SAMPLE_SIZE, Image.INTERPOLATE_BILINEAR)
		small.append(copy)

	var dark_count := 0
	var total := 0
	var best_lum := -1.0
	var best_dir := DEFAULT_SUN_DIR.normalized()
	var lum_sum := 0.0
	var lum_sq := 0.0
	for face_idx in small.size():
		for y in SAMPLE_SIZE:
			for x in SAMPLE_SIZE:
				var c := small[face_idx].get_pixel(x, y)
				var lum := (c.r + c.g + c.b) / 3.0
				total += 1
				lum_sum += lum
				lum_sq += lum * lum
				if lum < DARK_PIXEL:
					dark_count += 1
				if lum > best_lum:
					best_lum = lum
					best_dir = _face_dir(face_idx,
						(x + 0.5) / SAMPLE_SIZE, (y + 0.5) / SAMPLE_SIZE)

	var mean_lum: float = lum_sum / maxf(total, 1)
	var variance: float = maxf(lum_sq / maxf(total, 1) - mean_lum * mean_lum, 0.0)
	return {
		"zenith": _face_mean(small[FACE_UP]),
		"ground": _face_mean(small[FACE_DN]),
		"horizon": _horizon_mean(small),
		"mean_lum": mean_lum,
		"spread": sqrt(variance),
		"dark_fraction": float(dark_count) / maxf(total, 1),
		"is_starfield": float(dark_count) / maxf(total, 1) > STARFIELD_DARK_FRACTION,
		"brightest_dir": best_dir,
	}


static func _derive(stats: Dictionary) -> Dictionary:
	# Contrast relative to overall brightness, not absolute: a bright sky and a dim one with the
	# same cloud pattern should come out equally cloudy.
	var relative_spread: float = stats["spread"] / maxf(stats["mean_lum"], 0.02)
	var cloud_amount := clampf(inverse_lerp(0.08, 0.55, relative_spread), 0.0, 0.85)
	if stats["is_starfield"]:
		cloud_amount = 0.0
	var star_amount := clampf(inverse_lerp(0.5, 0.95, stats["dark_fraction"]), 0.0, 1.0)

	var horizon: Color = stats["horizon"]
	return {
		"zenith_color": stats["zenith"],
		"horizon_color": horizon,
		"ground_color": stats["ground"],
		"horizon_falloff": 1.1,
		"sun_color": Color.WHITE,
		"sun_size": 0.035,
		"sun_energy": 2.2,
		"sun_glow_exp": 48.0,
		"sun_glow_energy": 0.5,
		"cloud_amount": cloud_amount,
		# Cloud lit/shadow sides bracket the horizon colour, which keeps a cloud deck in the same
		# family as the sky it sits in however that sky was coloured.
		"cloud_color": horizon.lightened(0.45),
		"cloud_shadow_color": horizon.darkened(0.35),
		"cloud_scale": 2.2,
		"cloud_speed": 0.008,
		"cloud_softness": 0.22,
		"star_amount": star_amount,
		"star_color": Color.WHITE,
		"cubemap_blend": 0.0,
	}


static func _face_mean(img: Image) -> Color:
	var r := 0.0
	var g := 0.0
	var b := 0.0
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			r += c.r
			g += c.g
			b += c.b
	var n := float(maxi(img.get_width() * img.get_height(), 1))
	return Color(r / n, g / n, b / n)


## The horizon is where the side faces meet the ground, i.e. their middle row — not their mean,
## which would drag the sky's colour down into whatever terrain is painted along the bottom.
static func _horizon_mean(small: Array[Image]) -> Color:
	var lo := int(SAMPLE_SIZE * 0.42)
	var hi := int(SAMPLE_SIZE * 0.58)
	var r := 0.0
	var g := 0.0
	var b := 0.0
	var n := 0
	for face_idx in SIDE_FACES:
		for y in range(lo, maxi(hi, lo + 1)):
			for x in SAMPLE_SIZE:
				var c := small[face_idx].get_pixel(x, y)
				r += c.r
				g += c.g
				b += c.b
				n += 1
	if n == 0:
		return Color(0.5, 0.5, 0.5)
	return Color(r / n, g / n, b / n)


## World-space direction for a point on a cubemap face. The face->vector half is the standard
## OpenGL cubemap layout; the final flip undoes the one the sky shader applies when it samples
## (`vec3(-eye_dir.x, eye_dir.y, eye_dir.z)`), so the result is back in world space.
static func _face_dir(face: int, u: float, v: float) -> Vector3:
	var a := 2.0 * u - 1.0
	var b := 2.0 * v - 1.0
	var c := Vector3.ZERO
	match face:
		FACE_RT: c = Vector3(1.0, -b, -a)
		FACE_LF: c = Vector3(-1.0, -b, a)
		FACE_UP: c = Vector3(a, 1.0, b)
		FACE_DN: c = Vector3(a, -1.0, -b)
		FACE_BK: c = Vector3(a, -b, 1.0)
		FACE_FT: c = Vector3(-a, -b, -1.0)
	return Vector3(-c.x, c.y, c.z).normalized()


## Direction TO the sun, in world space, from a light_environment's keys. GoldSrc gives the
## direction the light TRAVELS (pitch -90 is noon, straight down), so this negates before
## converting on the same (x, y, z) -> (-x, z, y) axis map EntityBase.parse_vector3 uses.
## Returns Vector3.ZERO when the entity has nothing usable, which is build()'s cue to guess.
static func sun_dir_from_light_environment(ent: Dictionary) -> Vector3:
	if ent.is_empty():
		return Vector3.ZERO
	var pitch_deg := 0.0
	var has_pitch := false
	if ent.has("pitch"):
		pitch_deg = float(str(ent["pitch"]))
		has_pitch = true
	elif ent.has("angles"):
		var parts: PackedStringArray = str(ent["angles"]).split(" ")
		if parts.size() >= 1 and float(parts[0]) != 0.0:
			pitch_deg = float(parts[0])
			has_pitch = true
	# Five maps carry a light_environment with no pitch and zeroed angles (ww_leyline, ww_rage,
	# ww_golem, ww_feudal, ww_countryside). A flat 0 would put the sun exactly on the horizon and
	# smear its glow across the whole sky, so treat "no pitch" as unusable rather than as noon.
	if not has_pitch:
		return Vector3.ZERO
	# A sun below the horizon lights nothing and shows nothing; ww_varrock's +90 is the case.
	# Mirror it up rather than dropping the entity's yaw and colour along with it.
	if pitch_deg > 0.0:
		pitch_deg = -pitch_deg
	# Only the grazing end needs a guard: ww_chasm's -1 and ww_ravine's 0 would sit the disc in
	# the horizon band, where the gradient is flattest and a sun reads as a smear. Straight down
	# is left alone — -90 is just noon.
	pitch_deg = clampf(pitch_deg, -90.0, -6.0)

	var yaw_deg := 0.0
	if ent.has("angles"):
		var parts: PackedStringArray = str(ent["angles"]).split(" ")
		if parts.size() >= 2:
			yaw_deg = float(parts[1])
	elif ent.has("angle"):
		yaw_deg = float(str(ent["angle"]))
	var yaw := deg_to_rad(yaw_deg)
	var pitch := deg_to_rad(pitch_deg)
	# GoldSrc direction of travel, then reversed to point at the sun.
	var gs := -Vector3(cos(yaw) * cos(pitch), sin(yaw) * cos(pitch), sin(pitch))
	return Vector3(-gs.x, gs.z, gs.y).normalized()


## "R G B [brightness]" from a light entity, normalised to a hue. Brightness is deliberately
## dropped: it is a lightmap compile parameter in GoldSrc units, and the sky's own sun_energy is
## what decides how bright the disc reads on screen.
static func sun_color_from_light_environment(ent: Dictionary) -> Color:
	if not ent.has("_light"):
		return Color.WHITE
	var parts: PackedStringArray = str(ent["_light"]).split(" ", false)
	if parts.size() < 3:
		return Color.WHITE
	var c := Color(float(parts[0]) / 255.0, float(parts[1]) / 255.0, float(parts[2]) / 255.0)
	var peak := maxf(c.r, maxf(c.g, c.b))
	if peak <= 0.0:
		return Color.WHITE
	return Color(c.r / peak, c.g / peak, c.b / peak)
