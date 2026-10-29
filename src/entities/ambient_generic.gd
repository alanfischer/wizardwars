class_name AmbientGeneric
extends EntityBase
# ambient_generic — looping or one-shot ambient sound entity, positional or play-everywhere.

const SF_PLAY_EVERYWHERE := 1
const SF_SMALL_RADIUS := 2
const SF_MEDIUM_RADIUS := 4
const SF_LARGE_RADIUS := 8
const SF_START_SILENT := 16
const SF_NOT_TOGGLED := 32

var _player_3d: AudioStreamPlayer3D
var _player_global: AudioStreamPlayer
var _is_everywhere: bool
var _is_playing := false
var _initial_playing := false
var _spawnflags: int
var _stream: AudioStream
var _sentence := ""            # sentences.txt name when message is "!NAME"
var _sentence_pb: RefCounted   # in-flight SentenceSystem.Playback
var _volume_db := 0.0
var _pitch_scale := 1.0
var _max_dist := 0.0
var _unit_size := 0.0


func _ready() -> void:
	super()
	_register_for_sync()
	var sound_path: String = ent.get("message", "")
	_spawnflags = parse_spawnflags(ent)
	var volume := parse_int(ent, "health", 10)
	var pitch := parse_int(ent, "pitchstart", 100)
	if pitch == 100:
		pitch = parse_int(ent, "pitch", 100)

	if sound_path.is_empty():
		return

	_is_everywhere = bool(_spawnflags & SF_PLAY_EVERYWHERE)
	_volume_db = linear_to_db(clampf(volume / 10.0, 0.0, 1.0))
	_pitch_scale = clampf(pitch / 100.0, 0.01, 2.55)

	# Radius from spawnflags (GoldSrc units * scale factor)
	if _spawnflags & SF_SMALL_RADIUS:
		_max_dist = 512.0 * GameConsts.SCALE_FACTOR
		_unit_size = 256.0 * GameConsts.SCALE_FACTOR
	elif _spawnflags & SF_MEDIUM_RADIUS:
		_max_dist = 768.0 * GameConsts.SCALE_FACTOR
		_unit_size = 384.0 * GameConsts.SCALE_FACTOR
	else:
		# LARGE_RADIUS and default
		_max_dist = 1280.0 * GameConsts.SCALE_FACTOR
		_unit_size = 640.0 * GameConsts.SCALE_FACTOR

	# "!NAME" — a sentences.txt reference, spoken word-by-word by SentenceSystem
	# instead of a single looping stream.
	if sound_path.begins_with("!"):
		_sentence = sound_path.substr(1)
		if not SentenceSystem.has_sentence(_sentence):
			Log.warn("ambient_generic: unknown sentence '%s'" % sound_path)
			_sentence = ""
			return
		SentenceSystem.precache(_sentence)
		if not (_spawnflags & SF_START_SILENT):
			_play()
		_initial_playing = _is_playing
		return

	_stream = AssetLoader.load_sound(sound_path)
	if not _stream:
		return

	if _is_everywhere:
		_player_global = AudioStreamPlayer.new()
		_player_global.name = "AmbientSound"
		_player_global.stream = _stream
		_player_global.volume_db = _volume_db
		_player_global.pitch_scale = _pitch_scale
		_player_global.bus = SoundSystem.EFFECTS_BUS
		add_child(_player_global)
		_player_global.finished.connect(_on_finished)
	else:
		_player_3d = AudioStreamPlayer3D.new()
		_player_3d.name = "AmbientSound"
		_player_3d.stream = _stream
		_player_3d.volume_db = _volume_db
		_player_3d.pitch_scale = _pitch_scale
		_player_3d.attenuation_model = AudioStreamPlayer3D.ATTENUATION_LOGARITHMIC
		_player_3d.max_distance = _max_dist
		_player_3d.unit_size = _unit_size
		_player_3d.bus = SoundSystem.EFFECTS_BUS
		add_child(_player_3d)
		_player_3d.finished.connect(_on_finished)

	if not (_spawnflags & SF_START_SILENT):
		_play()

	_initial_playing = _is_playing


func set_playing(on: bool) -> void:
	if on: _play()
	else: _stop()


func trigger(_activator: Node, type: TriggerSystem.Type) -> void:
	if _spawnflags & SF_NOT_TOGGLED:
		_play()
	else:
		match type:
			TriggerSystem.Type.ON: _play()
			TriggerSystem.Type.OFF: _stop()
			TriggerSystem.Type.TOGGLE:
				if _is_playing: _stop()
				else: _play()
	_sync_notify()


func _get_sync_state() -> Dictionary:
	var state := super._get_sync_state()
	if _state_dirty:
		state["playing"] = _is_playing
	return state


func _apply_sync_state(state: Dictionary) -> void:
	super._apply_sync_state(state)
	if "playing" in state:
		set_playing(state["playing"])


func _play() -> void:
	_is_playing = true
	if _sentence != "":
		# One-shot speech: retriggering restarts the sentence from the top.
		if _sentence_pb:
			_sentence_pb.cancel()
		if _is_everywhere:
			_sentence_pb = SentenceSystem.play_global(_sentence, _volume_db, _pitch_scale)
		else:
			_sentence_pb = SentenceSystem.play_on(self, _sentence, _volume_db, _pitch_scale,
					_max_dist, _unit_size)
	elif _is_everywhere and _player_global:
		_player_global.play()
	elif _player_3d:
		_player_3d.play()


func _stop() -> void:
	_is_playing = false
	if _sentence_pb:
		_sentence_pb.cancel()
		_sentence_pb = null
	if _is_everywhere and _player_global:
		_player_global.stop()
	elif _player_3d:
		_player_3d.stop()




func _on_finished() -> void:
	if _is_playing and not (_spawnflags & SF_NOT_TOGGLED):
		_play()
