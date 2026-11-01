class_name WeatherSystem
extends Node3D

## Lightning's light at the peak of a strike, added to the sky's share of the world's light
## (NightMode.set_flash): the open map lights up, a torch-lit room does not.
const FLASH := Vector3(2.0, 2.1, 2.6)
## And what it lights the sky itself with, brightest toward the bolt (Skybox.set_flash). A day sky
## is already bright, and the full flash would white it out and hide the bolt, so it takes
## SKY_FLASH_DAY of it, rising to all of it at full night.
const SKY_FLASH := Color(1.0, 1.05, 1.3)
const SKY_FLASH_DAY := 0.3
## The light of a strike over time: a stroke, a fainter return stroke, each dying away fast.
const STROKES := [[0.0, 1.0], [0.11, 0.75]]
const STROKE_DECAY := 0.07
const FLASH_LENGTH := 0.6
## Seconds between strikes at the lightest rain and the heaviest.
const STRIKE_GAP_LIGHT := Vector2(25.0, 45.0)
const STRIKE_GAP_HEAVY := Vector2(4.0, 10.0)
## How overcast the procedural sky goes at the lightest rain (it reaches 1 at the heaviest), and how
## fast it closes over or clears, per second.
const STORM_LIGHT := 0.55
const STORM_RATE := 0.2
## Rain sound by how much of the rain around the player is reachable: sampled off the rain floor in
## rings (metres) a few times a second. Deep indoors it is RAIN_INDOOR_GAIN of the open-air volume
## and low-passed to RAIN_INDOOR_CUTOFF.
const RAIN_RINGS := [2.0, 6.0, 12.0]
const RAIN_RING_POINTS := 8
const RAIN_INDOOR_GAIN := 0.25
const RAIN_INDOOR_CUTOFF := 600.0
const RAIN_OPEN_CUTOFF := 20000.0
const RAIN_SAMPLE_EVERY := 0.25
const RAIN_EASE := 1.5  # exposure per second
## Rain haze (shaders/rain_haze.gdshader): density per metre of rain-filled air at a full storm,
## scaled by storm² so light rain barely hazes; 0.04 loses ~70% of the view in 30 m of downpour.
## Its colour is the sky's at the horizon (Skybox.horizon_color), so distance fades into the sky
## behind it. Never darker than HAZE_FLOOR of HAZE_COLOR in the map's own sky light (NightMode),
## though: a night sky's art is near black, and the moonlight on the map is set brighter than it.
## Lit by lightning.
const HAZE_DENSITY := 0.04
const HAZE_COLOR := Color(0.4, 0.43, 0.48)
const HAZE_FLOOR := 0.25
const HAZE_FLASH := 0.35
## Gusts: how far the haze density swings either way, and how fast the curtains drift (m/s).
const GUST_AMOUNT := 0.6
const GUST_DRIFT := Vector3(2.5, -1.0, 0.9)
const GUST_CELL := 80.0  # metres to the noise texture's width, as the shader's
## Drops (shaders/rain.gdshader) fill a box this size (m) around the camera: this many at the lightest
## rain and at a downpour. DROP_LIGHT is how bright they read by day; lightning adds DROP_FLASH of its
## light and DROP_FLASH_OPACITY times their opacity.
const DROP_BOX := Vector3(36.0, 24.0, 36.0)
const DROPS_LIGHT := 3000.0
const DROPS_HEAVY := 40000.0
const DROP_LIGHT := 0.85
const DROP_FLASH := 1.5
const DROP_FLASH_OPACITY := 2.5
const DROP_COLOR := Color(0.75, 0.8, 0.9)
## Opacity of the far rain's streaks (shaders/rain_haze.gdshader) at a downpour.
const FAR_OPACITY := 0.6
## Wet ground (shaders/goldsrc_hook.gdshaderinc): per second, how fast the map soaks at a downpour
## (slower in light rain) and dries once it stops, and the same for puddles, which only a downpour
## fills completely.
const WET_RISE := 1.0 / 20.0
const WET_DRY := 1.0 / 120.0
const PUDDLE_RISE := 1.0 / 90.0
const PUDDLE_DRY := 1.0 / 240.0
## How readily each WorldMaterials class pools; anything it leaves unclassified takes the default.
const PUDDLE_BY_CLASS := {"ground": 1.0, "mineral": 0.6, "wood": 0.0}
const PUDDLE_DEFAULT := 0.5
const BOLT_SEGMENTS := 16
const TopDownFrame = preload("res://src/systems/top_down_frame.gd")
const SOUND_SPEED := 340.0

var _player: Node3D
var _drops: MultiMeshInstance3D
var _rain_audio: AudioStreamPlayer
var _thunder: AudioStream
## What the map asked for (PotatoC SetWeather). The `rain` server var overrides it while non-zero.
var _current_type: int = 0
var _current_intensity: int = 0
var _shown_intensity := 0.0
var _next_strike := 0.0
var _flash_t := -1.0
var _flash_dir := Vector3.UP
var _map_bounds := AABB()
var _drop_material: ShaderMaterial
var _floor: Image
var _floor_tex: ImageTexture
var _map_root: Node
var _linear_output := true
var _rain_filter: AudioEffectLowPassFilter
var _floor_origin := Vector3.ZERO
var _floor_size := Vector2.ONE
var _rain_db := 0.0
var _exposure := 1.0
var _exposure_target := 1.0
var _sample_in := 0.0
var _haze: MeshInstance3D
var _haze_material: ShaderMaterial
var _flash_k := 0.0
var _gust_offset := Vector3.ZERO
var _wet_mats: Array[ShaderMaterial] = []
var _wetness := 0.0
var _puddles := 0.0
var _wet_pushed := Vector4(-1, -1, -1, -1)  # wetness, puddles, sky luma, flash, as last pushed
var _storm := 0.0


func setup() -> void:
	# The shader places every drop itself (shaders/rain.gdshader); the instances carry no transforms.
	_drop_material = ShaderMaterial.new()
	_drop_material.shader = preload("res://shaders/rain.gdshader")
	_drop_material.set_shader_parameter("box", DROP_BOX)
	_drop_material.render_priority = Material.RENDER_PRIORITY_MAX
	_linear_output = EntityRender.renderer_is_linear()
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	quad.material = _drop_material
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = quad
	_drops = MultiMeshInstance3D.new()
	_drops.name = "RainDrops"
	_drops.multimesh = multimesh
	_drops.custom_aabb = AABB(Vector3(-1e5, -1e5, -1e5), Vector3(2e5, 2e5, 2e5))
	_drops.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_drops.visible = false
	add_child(_drops)

	_rain_audio = AudioStreamPlayer.new()
	_rain_audio.name = "RainAudio"
	_rain_audio.bus = SoundSystem.RAIN_BUS
	var rain_stream := load("sounds/weather/rain1.wav") as AudioStream
	if rain_stream:
		_rain_audio.stream = rain_stream
	_rain_audio.finished.connect(_on_rain_finished)
	add_child(_rain_audio)
	_thunder = load("sounds/ambience/thunder.wav") as AudioStream
	_rain_filter = SoundSystem.rain_filter()

	ServerVars.value_changed.connect(_on_server_var_changed)
	_refresh()


## The map's rain floor (MapConverter, GoldSrcBSP.bake_rain_floor), so no drop is drawn under a
## roof. A map converted before it existed has none, and rains everywhere as it always did.
func _ready() -> void:
	_map_root = get_tree().current_scene.get("_map_root") if get_tree().current_scene else null
	var data: Dictionary = _map_root.get_meta("rain_floor", {}) if _map_root else {}
	if data.is_empty():
		return
	_floor = data["image"]
	_floor_origin = data["origin"]
	_floor_size = data["size"]
	_floor_tex = ImageTexture.create_from_image(_floor)
	_set_floor(_drop_material)
	_drop_material.set_shader_parameter("has_floor", true)
	_refresh()
	# A map loaded into rain that is already falling starts soaked rather than drying out to it.
	if _shown_intensity > 0:
		_wetness = 1.0
		_puddles = _heaviness(_shown_intensity)


func _set_floor(mat: ShaderMaterial) -> void:
	mat.set_shader_parameter("rain_floor", _floor_tex)
	mat.set_shader_parameter("rain_floor_origin", _floor_origin)
	mat.set_shader_parameter("rain_floor_size", _floor_size)


## The haze and wet ground, the first time it rains: a map that stays dry never builds them.
func _ensure_rain_visuals() -> void:
	if _haze or _floor_tex == null or DisplayServer.get_name() == "headless":
		return
	_build_haze()
	_collect_wet()


## Every map material the shader hook gave rain to, handed the rain floor once.
func _collect_wet() -> void:
	var seen := {}
	for mi in WorldMaterials._collect(_map_root, []):
		# The loader names each world mesh after its texture.
		var pools: float = PUDDLE_BY_CLASS.get(WorldMaterials.classify(String(mi.name)), PUDDLE_DEFAULT)
		for i in (mi.mesh.get_surface_count() if mi.mesh else 0):
			for mat in [mi.mesh.surface_get_material(i), mi.get_surface_override_material(i)]:
				if mat is ShaderMaterial and not seen.has(mat) and _takes_rain(mat.shader):
					seen[mat] = true
					_set_floor(mat)
					mat.set_shader_parameter("puddle_scale", pools)
					_wet_mats.append(mat)


static var _rain_shaders := {}


static func _takes_rain(shader: Shader) -> bool:
	if shader == null:
		return false
	if not _rain_shaders.has(shader):
		_rain_shaders[shader] = shader.get_shader_uniform_list().any(
			func(u: Dictionary) -> bool: return u["name"] == "wetness")
	return _rain_shaders[shader]


func _build_haze() -> void:
	_haze_material = ShaderMaterial.new()
	_haze_material.shader = preload("res://shaders/rain_haze.gdshader")
	_haze_material.render_priority = Material.RENDER_PRIORITY_MAX - 1  # over all it hazes, under the drops
	_haze_material.set_shader_parameter("depth_remap", DecalSystem.depth_remap())
	_haze_material.set_shader_parameter("linear_output", _linear_output)
	_set_floor(_haze_material)
	_haze_material.set_shader_parameter("rain_top", float(_map_root.get_meta("rain_floor")["top"]))
	var noise := FastNoiseLite.new()
	noise.frequency = 1.0 / 16.0
	noise.fractal_octaves = 3
	var gusts := NoiseTexture3D.new()
	gusts.width = 64
	gusts.height = 64
	gusts.depth = 64
	gusts.seamless = true
	gusts.noise = noise
	_haze_material.set_shader_parameter("gust_noise", gusts)
	_haze_material.set_shader_parameter("gust_amount", GUST_AMOUNT)
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)  # clip space, see the shader's vertex()
	quad.material = _haze_material
	_haze = MeshInstance3D.new()
	_haze.name = "RainHaze"
	_haze.mesh = quad
	# Drawn over the whole screen whatever the camera sees, so never culled.
	_haze.custom_aabb = AABB(Vector3(-1e5, -1e5, -1e5), Vector3(2e5, 2e5, 2e5))
	_haze.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_haze.visible = false
	add_child(_haze)


## The node this follows. The map-load path builds the system before the local player exists, and
## a dedicated server never gets one — _process already tolerates null.
func attach_player(player: Node3D) -> void:
	_player = player


## Server-authoritative (a PotatoC entity drives it): applies locally and then re-sends itself to
## the clients, which take the same path with is_host() false and so do not re-broadcast.
@rpc("authority", "call_remote", "reliable")
func set_weather(type: int, intensity: int) -> void:
	Log.debug("  WeatherSystem -> set_weather(type=%d, intensity=%d)" % [type, intensity])
	_current_type = type
	_current_intensity = intensity
	if NetworkManager.is_online() and NetworkManager.is_host():
		set_weather.rpc(type, intensity)
	_refresh()


## How hard it is raining, 0 for dry: the `rain` server var while set, the map's own otherwise.
func rain_intensity() -> float:
	var forced := float(ServerVars.get_value("rain", 0.0))
	if forced > 0.0:
		# Preserve the old 1–9 curve through 1.0, then let every weather effect scale beyond it.
		return 1.0 + forced * 8.0
	return _current_intensity if _current_type == 1 else 0


func _on_server_var_changed(key: String, _value: Variant) -> void:
	if key == "rain":
		_refresh()


func _refresh() -> void:
	var intensity := rain_intensity()
	if intensity != _shown_intensity:
		_shown_intensity = intensity
		_next_strike = _strike_gap(intensity) * 0.5
	if intensity <= 0:
		if _haze_material:
			_haze_material.set_shader_parameter("streak_opacity", 0.0)
		if _rain_audio.playing:
			_rain_audio.stop()
		return
	_ensure_rain_visuals()

	var t := _rain_t(intensity)
	var heavy := _heaviness(intensity)
	var count := int(lerpf(DROPS_LIGHT, DROPS_HEAVY, t))
	var multimesh := _drops.multimesh
	if multimesh.instance_count < count:
		multimesh.instance_count = maxi(count, int(DROPS_HEAVY))
	multimesh.visible_instance_count = count
	# Rain falls at its terminal speed, a few m/s for drizzle and ~9 for a downpour's big drops.
	var fall_speed := lerpf(6.0, 9.5, heavy)
	var streak_length := lerpf(0.3, 0.55, heavy)
	var streak_width := lerpf(0.004, 0.007, heavy)
	_drop_material.set_shader_parameter("velocity", Vector3(0.0, -fall_speed, 0.0))
	_drop_material.set_shader_parameter("streak_length", streak_length)
	_drop_material.set_shader_parameter("width", streak_width)
	_drop_material.set_shader_parameter("opacity", lerpf(0.3, 0.45, heavy))
	if _haze_material:
		# The far rain thins out with the rain, and past a downpour fills in as the box does.
		_haze_material.set_shader_parameter("presence", clampf(count / DROPS_HEAVY, 0.15, 1.0))
		_haze_material.set_shader_parameter("streak_opacity", FAR_OPACITY * maxf(count / DROPS_HEAVY, 1.0))
		_haze_material.set_shader_parameter("fall_speed", fall_speed)
		_haze_material.set_shader_parameter("streak_length", streak_length)
		_haze_material.set_shader_parameter("streak_width", streak_width)

	# Rain audio: volume scales with intensity (-20 dB at 1, -5 dB at 9), and with how much of it
	# is in reach (_update_rain_sound)
	_rain_db = lerpf(-20.0, -5.0, t)
	_apply_rain_volume()
	if not _rain_audio.playing and _rain_audio.stream:
		_rain_audio.play()


## 0 at the lightest rain, 1 at a downpour, and beyond it as the `rain` var goes past 1.
static func _rain_t(intensity: float) -> float:
	return (intensity - 1.0) / 8.0


## _rain_t held to 0..1, and 0 when dry: what looks and sounds heavier stops at a downpour.
static func _heaviness(intensity: float) -> float:
	return clampf(_rain_t(intensity), 0.0, 1.0) if intensity > 0 else 0.0


## Join snapshot. Default weather is "none", which every peer already starts at, so a dry map
## sends nothing. The `rain` override is a server var and reaches the client with the rest of them.
func send_state_to(peer_id: int) -> void:
	if _current_type != 0 or _current_intensity != 0:
		set_weather.rpc_id(peer_id, _current_type, _current_intensity)


func _on_rain_finished() -> void:
	if _drops.visible:
		_rain_audio.play()


## How much of the rain around the player reaches them, 0 under a roof with no open sky in reach to
## 1 in the open. Each sample point counts where rain lands below the player's head there; the
## near ring counts most. Walls between are not seen: rain past one reads as rain through it.
func _rain_exposure() -> float:
	if _floor == null or _player == null:
		return 1.0
	var head := _player.global_position.y + 1.5
	var p := _player.global_position
	var hit := 0.0
	var total := 0.0
	for i in RAIN_RINGS.size() + 1:
		var r: float = 0.0 if i == 0 else RAIN_RINGS[i - 1]
		var weight := 1.0 / (1.0 + r * 0.25)
		for k in (1 if i == 0 else RAIN_RING_POINTS):
			var a := TAU * k / RAIN_RING_POINTS
			var q := p + Vector3(cos(a), 0.0, sin(a)) * r
			total += weight
			if _floor_at(q) < head:
				hit += weight
	return hit / total


## Where rain stops at world XZ `q`; above any head when off the map, where no rain falls.
func _floor_at(q: Vector3) -> float:
	var u := (_floor_origin.x - q.x) / _floor_size.x
	var v := (q.z - _floor_origin.z) / _floor_size.y
	if u < 0.0 or v < 0.0 or u >= 1.0 or v >= 1.0:
		return INF
	return _floor.get_pixel(int(u * _floor.get_width()), int(v * _floor.get_height())).r


func _update_rain_sound(delta: float) -> void:
	_sample_in -= delta
	if _sample_in <= 0.0:
		_sample_in = RAIN_SAMPLE_EVERY
		_exposure_target = _rain_exposure()
	if _exposure != _exposure_target:
		_exposure = move_toward(_exposure, _exposure_target, RAIN_EASE * delta)
		_apply_rain_volume()


func _apply_rain_volume() -> void:
	_rain_audio.volume_db = _rain_db + linear_to_db(lerpf(RAIN_INDOOR_GAIN, 1.0, _exposure))
	if _rain_filter:
		_rain_filter.cutoff_hz = RAIN_INDOOR_CUTOFF * pow(RAIN_OPEN_CUTOFF / RAIN_INDOOR_CUTOFF, _exposure)


func _update_haze(delta: float, underwater: bool, sky: Color, drop_light: Color) -> void:
	if _haze == null:
		return
	var density := HAZE_DENSITY * _storm * _storm
	_haze.visible = (density > 0.0005 or _shown_intensity > 0) and not underwater
	if not _haze.visible:
		return
	# Kept in [0, 1) rather than driven off TIME, which loses precision as it grows.
	_gust_offset = (_gust_offset + GUST_DRIFT * delta / GUST_CELL).posmod(1.0)
	_haze_material.set_shader_parameter("gust_offset", _gust_offset)
	_haze_material.set_shader_parameter("density", density)
	_drop_material.set_shader_parameter("haze_density", density)
	_haze_material.set_shader_parameter("haze_color", Vector3(sky.r, sky.g, sky.b))
	var streak := DROP_COLOR * drop_light
	_haze_material.set_shader_parameter("streak_color", Vector3(streak.r, streak.g, streak.b))
	_haze_material.set_shader_parameter("flash", _flash_k * DROP_FLASH_OPACITY)


## What the haze fades to before lightning: the sky at the horizon, or lit haze where there is none.
func _haze_base() -> Color:
	var sky := Game.skybox.horizon_color() if Game.skybox else Color.BLACK
	var lit := HAZE_COLOR * _sky_light()
	var floor := lit * HAZE_FLOOR
	return lit if sky == Color.BLACK else \
		Color(maxf(sky.r, floor.r), maxf(sky.g, floor.g), maxf(sky.b, floor.b))


## Soaks and dries the map, and hands its wet surfaces the sky they reflect, lightning included.
## Pushed only when the state moves by a step the screen can show.
func _update_wet(delta: float, sky: Color) -> void:
	if _wet_mats.is_empty():
		return
	var wet_target := 1.0 if _shown_intensity > 0 else 0.0
	var puddle_target := _heaviness(_shown_intensity)
	_wetness = move_toward(_wetness, wet_target,
		(WET_RISE * lerpf(0.35, 1.0, puddle_target) if wet_target > _wetness else WET_DRY) * delta)
	_puddles = move_toward(_puddles, puddle_target,
		(PUDDLE_RISE if puddle_target > _puddles else PUDDLE_DRY) * delta)
	var state := Vector4(_wetness, _puddles, sky.get_luminance(), _flash_k).snapped(Vector4.ONE / 255.0)
	if state == _wet_pushed:
		return
	_wet_pushed = state
	var reflected := sky.linear_to_srgb()  # the hook composites in sRGB
	for mat in _wet_mats:
		mat.set_shader_parameter("wetness", _wetness)
		mat.set_shader_parameter("puddles", _puddles)
		mat.set_shader_parameter("rain_sky", Vector3(reflected.r, reflected.g, reflected.b))


## The sky's light on the rain: full by day, darkened at night the way the sky's light is (NightMode).
func _sky_light() -> Color:
	var n := NightMode.night_light()
	var g := NightMode.LIGHTMAP_GAMMA
	return Color(pow(n.x, g), pow(n.y, g), pow(n.z, g))


## Drops are only seen by the light on them: dim under a storm sky, dimmer at night, and lit up all
## at once by lightning. Their colour goes to the shader in its output space.
func _update_drops(light: Color) -> void:
	if not _drops.visible:
		return
	var color := DROP_COLOR * light
	if not _linear_output:
		color = color.linear_to_srgb()
	_drop_material.set_shader_parameter("color", Vector3(color.r, color.g, color.b))
	_drop_material.set_shader_parameter("flash", _flash_k * DROP_FLASH_OPACITY)


func _drop_light() -> Color:
	return _sky_light() * DROP_LIGHT + SKY_FLASH * _flash_k * DROP_FLASH


func _strike_gap(intensity: float) -> float:
	var t := _rain_t(intensity)
	return randf_range(lerpf(STRIKE_GAP_LIGHT.x, STRIKE_GAP_HEAVY.x, t),
		lerpf(STRIKE_GAP_LIGHT.y, STRIKE_GAP_HEAVY.y, t))


func _process(delta: float) -> void:
	var intensity := _shown_intensity
	# GoldSrc drew no rain with the view underwater (v_waterlevel 3); the sound carries on.
	var underwater: bool = _player != null and _player.has_method("head_underwater") and _player.head_underwater()
	_drops.visible = intensity > 0 and not underwater
	if _rain_audio.playing:
		_update_rain_sound(delta)

	# The host times the strikes so every peer sees the same one; each draws it from the seed.
	var storm_target := 0.0 if intensity <= 0 else lerpf(STORM_LIGHT, 1.0, _rain_t(intensity))
	_storm = move_toward(_storm, storm_target, STORM_RATE * delta)
	# Compared every frame rather than pushed on change: night rebuilds the skybox, and a new one
	# starts clear.
	if Game.skybox and Game.skybox.storm != _storm:
		Game.skybox.set_storm(_storm)
	if intensity > 0 and bool(ServerVars.get_value("lightning", true)) and \
			(not NetworkManager.is_online() or NetworkManager.is_host()):
		_next_strike -= delta
		if _next_strike <= 0.0:
			_next_strike = _strike_gap(intensity)
			strike(randi())

	if _flash_t >= 0.0:
		_flash_t += delta
		var k := 0.0
		for s in STROKES:
			if _flash_t >= s[0]:
				k = maxf(k, s[1] * exp(-(_flash_t - s[0]) / STROKE_DECAY))
		if _flash_t >= FLASH_LENGTH:
			k = 0.0
			_flash_t = -1.0
		_flash_k = k
		NightMode.set_flash(FLASH * k)
		if Game.skybox:
			var sky_k := k * lerpf(SKY_FLASH_DAY, 1.0, NightMode.amount())
			Game.skybox.set_flash(SKY_FLASH * sky_k, _flash_dir)
	var drop_light := _drop_light()
	_update_drops(drop_light)
	if _haze:
		var sky := _haze_base() + SKY_FLASH * _flash_k * HAZE_FLASH
		_update_haze(delta, underwater, sky, drop_light)
		_update_wet(delta, sky)


## One lightning strike, in the sky over the map: above its sky brushes, which draw no depth, so
## the bolt shows wherever the sky does — overhead from the bottom of a canyon, too.
## Everything about it comes from `seed`, so the bolt, its flash and its thunder agree everywhere.
@rpc("authority", "call_remote", "reliable")
func strike(seed: int) -> void:
	if NetworkManager.is_online() and NetworkManager.is_host():
		strike.rpc(seed)
	if DisplayServer.get_name() == "headless":
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var bounds := _bounds()
	var centre := bounds.get_center()
	var radius := maxf(bounds.size.x, bounds.size.z) * 0.5
	var angle := rng.randf() * TAU
	var out := Vector3(cos(angle), 0.0, sin(angle))
	var ground := centre + out * radius * rng.randf_range(0.2, 1.1)
	ground.y = bounds.end.y + 2.0
	var top := Vector3(ground.x, ground.y + rng.randf_range(110.0, 170.0), ground.z) \
		+ out * rng.randf_range(-25.0, 25.0)

	var parent := get_tree().current_scene
	_bolt(parent, ground, top, 1.0, rng)
	for i in rng.randi_range(1, 2):
		var from := ground.lerp(top, rng.randf_range(0.35, 0.75))
		var side := out.cross(Vector3.UP) * rng.randf_range(-1.0, 1.0)
		var to := from + (side + out * 0.4 + Vector3.DOWN).normalized() * rng.randf_range(15.0, 35.0)
		_bolt(parent, to, from, 0.5, rng)

	var eye := _player.global_position if _player else centre
	_flash_dir = (ground.lerp(top, 0.6) - eye).normalized()
	_flash_t = 0.0

	if _thunder:
		var dist := eye.distance_to(ground)
		var thunder := AudioStreamPlayer.new()
		thunder.stream = _thunder
		thunder.bus = SoundSystem.EFFECTS_BUS
		thunder.volume_db = lerpf(-2.0, -12.0, clampf(dist / 250.0, 0.0, 1.0))
		thunder.pitch_scale = rng.randf_range(0.85, 1.1)
		add_child(thunder)
		thunder.finished.connect(thunder.queue_free)
		get_tree().create_timer(dist / SOUND_SPEED).timeout.connect(func() -> void:
			if is_instance_valid(thunder):
				thunder.play())


## A jagged beam from `from` to `to`: each segment wanders off the one before, which is what makes
## it read as lightning and not a wobbly line.
func _bolt(parent: Node, from: Vector3, to: Vector3, width_scale: float, rng: RandomNumberGenerator) -> void:
	var offsets: Array[Vector3] = []
	var walk := Vector3.ZERO
	var jitter := from.distance_to(to) / BOLT_SEGMENTS * 0.6
	for i in BOLT_SEGMENTS + 1:
		offsets.append(walk)
		walk += Vector3(rng.randf_range(-jitter, jitter), 0.0, rng.randf_range(-jitter, jitter))
		walk *= 0.85
	offsets[BOLT_SEGMENTS] = Vector3.ZERO
	var noise := func(t: float) -> Vector3:
		return offsets[clampi(roundi(t * BOLT_SEGMENTS), 0, BOLT_SEGMENTS)]
	for stroke in STROKES:
		get_tree().create_timer(stroke[0]).timeout.connect(func() -> void:
			if is_instance_valid(parent):
				BeamSystem.create_oneshot(parent, from, to, {
					"color": Color(0.85, 0.9, 1.0, stroke[1]),
					"width": 2.2 * width_scale,
					"segments": BOLT_SEGMENTS,
					"noise_fn": noise,
					"fade_time": 0.25,
				}))


## The map's extent, once per map: where "past the edge" is.
func _bounds() -> AABB:
	if _map_bounds.size != Vector3.ZERO:
		return _map_bounds
	var root: Node = get_tree().current_scene.get("_map_root")
	var box := TopDownFrame.world_aabb(root) if root else AABB()
	_map_bounds = box if box.size != Vector3.ZERO else AABB(Vector3(-100, -20, -100), Vector3(200, 60, 200))
	return _map_bounds
