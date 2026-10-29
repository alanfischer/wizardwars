class_name WeatherSystem
extends Node3D

var _player: Node3D
var _particles: GPUParticles3D
var _rain_audio: AudioStreamPlayer
var _current_type: int = 0
var _current_intensity: int = 0


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

	if type != 1 or intensity <= 0:
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
## sends nothing.
func send_state_to(peer_id: int) -> void:
	if _current_type != 0 or _current_intensity != 0:
		set_weather.rpc_id(peer_id, _current_type, _current_intensity)


func _on_rain_finished() -> void:
	if _particles.emitting:
		_rain_audio.play()


func _process(_delta: float) -> void:
	if _player:
		global_position = Vector3(_player.global_position.x, _player.global_position.y + 12.0, _player.global_position.z)
