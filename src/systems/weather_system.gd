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
const BOLT_SEGMENTS := 16
const SOUND_SPEED := 340.0

var _player: Node3D
var _particles: GPUParticles3D
var _rain_audio: AudioStreamPlayer
var _thunder: AudioStream
## What the map asked for (PotatoC SetWeather). The `rain` server var overrides it while non-zero.
var _current_type: int = 0
var _current_intensity: int = 0
var _shown_intensity := 0
var _next_strike := 0.0
var _flash_t := -1.0
var _flash_dir := Vector3.UP
var _map_bounds := AABB()


func setup() -> void:
	# Repositioned every _process frame; physics interpolation would lag it behind the player.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF

	_particles = GPUParticles3D.new()
	_particles.emitting = false
	_particles.amount = 100
	_particles.lifetime = 2.0
	_particles.visibility_aabb = AABB(Vector3(-12, -15, -12), Vector3(24, 30, 24))

	var mat := ParticleProcessMaterial.new()
	mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	mat.emission_box_extents = Vector3(10.0, 0.05, 10.0)
	mat.direction = Vector3(0, -1, 0)
	mat.spread = 3.0
	mat.initial_velocity_min = 10.0
	mat.initial_velocity_max = 14.0
	mat.gravity = Vector3(0, -4, 0)
	_particles.process_material = mat

	var quad := QuadMesh.new()
	quad.size = Vector2(0.005, 0.15)
	var draw_mat := StandardMaterial3D.new()
	draw_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	draw_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	draw_mat.albedo_color = Color(0.7, 0.8, 1.0, 0.4)
	draw_mat.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	quad.material = draw_mat
	_particles.draw_pass_1 = quad

	add_child(_particles)

	_rain_audio = AudioStreamPlayer.new()
	_rain_audio.name = "RainAudio"
	_rain_audio.bus = SoundSystem.EFFECTS_BUS
	var rain_stream := load("sounds/weather/rain1.wav") as AudioStream
	if rain_stream:
		_rain_audio.stream = rain_stream
	_rain_audio.finished.connect(_on_rain_finished)
	add_child(_rain_audio)
	_thunder = load("sounds/ambience/thunder.wav") as AudioStream

	ServerVars.value_changed.connect(_on_server_var_changed)
	_refresh()


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
func rain_intensity() -> int:
	var forced := int(ServerVars.get_value("rain", 0))
	if forced > 0:
		return clampi(forced, 1, 9)
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
		_particles.emitting = false
		if _rain_audio.playing:
			_rain_audio.stop()
		return

	var t := (intensity - 1) / 8.0  # 0.0 at intensity 1, 1.0 at intensity 9

	_particles.amount = int(lerpf(200.0, 4000.0, t))

	var mat := _particles.process_material as ParticleProcessMaterial
	mat.initial_velocity_min = 10.0 + intensity * 2.0
	mat.initial_velocity_max = 14.0 + intensity * 2.0
	mat.gravity = Vector3(0, -4.0 - intensity * 2.0, 0)

	var quad := _particles.draw_pass_1 as QuadMesh
	quad.size = Vector2(0.005 + t * 0.005, lerpf(0.15, 0.35, t))
	var draw_mat := quad.material as StandardMaterial3D
	draw_mat.albedo_color = Color(0.7, 0.8, 1.0, lerpf(0.3, 0.7, t))

	_particles.emitting = true

	# Rain audio: volume scales with intensity (-20 dB at 1, -5 dB at 9)
	_rain_audio.volume_db = lerpf(-20.0, -5.0, t)
	if not _rain_audio.playing and _rain_audio.stream:
		_rain_audio.play()


## Join snapshot. Default weather is "none", which every peer already starts at, so a dry map
## sends nothing. The `rain` override is a server var and reaches the client with the rest of them.
func send_state_to(peer_id: int) -> void:
	if _current_type != 0 or _current_intensity != 0:
		set_weather.rpc_id(peer_id, _current_type, _current_intensity)


func _on_rain_finished() -> void:
	if _particles.emitting:
		_rain_audio.play()


func _strike_gap(intensity: int) -> float:
	var t := (intensity - 1) / 8.0
	return randf_range(lerpf(STRIKE_GAP_LIGHT.x, STRIKE_GAP_HEAVY.x, t),
		lerpf(STRIKE_GAP_LIGHT.y, STRIKE_GAP_HEAVY.y, t))


func _process(delta: float) -> void:
	if _player:
		global_position = Vector3(_player.global_position.x, _player.global_position.y + 12.0, _player.global_position.z)

	# The host times the strikes so every peer sees the same one; each draws it from the seed.
	var intensity := rain_intensity()
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
		NightMode.set_flash(FLASH * k)
		if Game.skybox:
			var sky_k := k * lerpf(SKY_FLASH_DAY, 1.0, NightMode.amount())
			Game.skybox.set_flash(SKY_FLASH * sky_k, _flash_dir)


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
	var box := AABB()
	var first := true
	for mi in (EntityRender.find_mesh_instances(root) if root else []):
		var b: AABB = mi.global_transform * mi.get_aabb()
		box = b if first else box.merge(b)
		first = false
	_map_bounds = box if not first else AABB(Vector3(-100, -20, -100), Vector3(200, 60, 200))
	return _map_bounds
