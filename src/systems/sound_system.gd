extends Node
# SoundSystem — plays positional and global audio with automatic network sync.
#
# Use play_3d() to play a sound at a world position. When online, the host
# broadcasts the sound to all clients so everyone hears it.
# Use play_global() for non-positional sounds (e.g. PotatoC PlaySound).

const AudioSettings = preload("res://src/systems/audio_settings.gd")

static var _cache: Dictionary = {}  # path -> AudioStream

## Default audible radius for a one-shot 3D sound: ~320 GoldSrc units, i.e. within
## a room. unit_size (the full-volume radius, ~120 units) scales off this.
const DEFAULT_MAX_DIST := 8.0

## Every game sound lands on Effects, which carries the effects volume; voice chat is the one
## thing that skips it. World sounds route through their own bus on the way so env_sound can
## reverb them without also washing out the announcer and UI, which go straight to Effects.
const EFFECTS_BUS := &"Effects"
const WORLD_BUS := &"World"

## GoldSrc roomtype -> [room_size, damping, wet]. Roomtypes run in families of
## three (small/medium/large), so each entry below is the medium of its family
## and the outer two scale off it. Approximated: GoldSrc ships measured impulse
## presets, we only have Godot's parametric reverb.
const ROOM_FAMILIES := {
	1: [0.40, 0.50, 0.20],   # generic
	2: [0.30, 0.10, 0.35],   # metal — bright, barely damped
	5: [0.50, 0.30, 0.40],   # tunnel
	8: [0.50, 0.40, 0.30],   # chamber
	11: [0.40, 0.20, 0.30],  # bright
	14: [0.60, 0.70, 0.35],  # water — muffled
	17: [0.50, 0.50, 0.30],  # concrete
	20: [0.80, 0.40, 0.40],  # big
	23: [0.85, 0.35, 0.50],  # cavern
	26: [0.70, 0.20, 0.60],  # weirdo
}
const FAMILY_SIZE_SCALE := [0.8, 1.0, 1.2]  # small, medium, large

var _room_type := 0
var _room_owner: Node = null
var _effects := AudioSettings.DEFAULT_EFFECTS


func _ready() -> void:
	_ensure_effects_bus()
	_ensure_world_bus()
	set_effects_volume(AudioSettings.load_effects(), false)
	ClientCommandSystem.register("volume", _cmd_volume, "/volume [0-100]",
			"Sound effects volume. Voice chat has its own, on /voice.")


## Before World: a bus can only send to one with a lower index.
func _ensure_effects_bus() -> void:
	if AudioServer.get_bus_index(EFFECTS_BUS) != -1:
		return
	var idx := AudioServer.bus_count
	AudioServer.add_bus(idx)
	AudioServer.set_bus_name(idx, EFFECTS_BUS)
	AudioServer.set_bus_send(idx, &"Master")


## Create the World bus (routed to Effects) with a reverb sitting at fully dry,
## so it costs nothing until an env_sound turns it up.
func _ensure_world_bus() -> void:
	if AudioServer.get_bus_index(WORLD_BUS) != -1:
		return
	var idx := AudioServer.bus_count
	AudioServer.add_bus(idx)
	AudioServer.set_bus_name(idx, WORLD_BUS)
	AudioServer.set_bus_send(idx, EFFECTS_BUS)
	var reverb := AudioEffectReverb.new()
	reverb.wet = 0.0
	reverb.dry = 1.0
	AudioServer.add_bus_effect(idx, reverb)


func effects_volume() -> int:
	return _effects


func set_effects_volume(percent: int, save := true) -> void:
	_effects = AudioSettings.clamp_effects(percent)
	if save:
		AudioSettings.save_effects(_effects)
	var idx := AudioServer.get_bus_index(EFFECTS_BUS)
	if idx != -1:
		AudioServer.set_bus_volume_db(idx, AudioSettings.effects_to_db(_effects))


func _cmd_volume(args: String) -> void:
	args = args.strip_edges()
	if args.is_valid_int():
		set_effects_volume(int(args))
	elif not args.is_empty():
		ClientCommandSystem.reply_err("Usage: /volume [0-100]")
		return
	ClientCommandSystem.reply_ok("Effects volume %d%%." % _effects)


func _world_reverb() -> AudioEffectReverb:
	var idx := AudioServer.get_bus_index(WORLD_BUS)
	if idx == -1 or AudioServer.get_bus_effect_count(idx) == 0:
		return null
	return AudioServer.get_bus_effect(idx, 0) as AudioEffectReverb


## Claim the listener's room. Last claim wins, matching GoldSrc's overlapping
## env_sounds; `owner_node` is only used so a release can't clobber a newer claim.
func set_room_type(roomtype: int, owner_node: Node = null) -> void:
	_room_owner = owner_node
	if roomtype == _room_type:
		return
	_room_type = roomtype
	var reverb := _world_reverb()
	if reverb == null:
		return
	if roomtype <= 0:
		reverb.wet = 0.0
		return
	for base: int in ROOM_FAMILIES:
		if roomtype < base or roomtype > base + 2:
			continue
		var preset: Array = ROOM_FAMILIES[base]
		var scale: float = FAMILY_SIZE_SCALE[roomtype - base]
		reverb.room_size = clampf(float(preset[0]) * scale, 0.0, 1.0)
		reverb.damping = float(preset[1])
		reverb.wet = clampf(float(preset[2]) * scale, 0.0, 1.0)
		return
	reverb.wet = 0.0  # roomtype outside the known families — leave it dry


## Drop back to dry, unless someone else has claimed the listener since.
func release_room_type(owner_node: Node = null) -> void:
	if _room_owner != owner_node:
		return
	set_room_type(0, null)


## Warm the cache for a sound so the first play has no hitch.
func precache(sound_path: String) -> void:
	_get_or_load(sound_path)


## Resolve a sound path (full res:// or relative) and return a cached AudioStream.
func _get_or_load(sound_path: String) -> AudioStream:
	if _cache.has(sound_path):
		return _cache[sound_path]
	var stream: AudioStream
	if sound_path.begins_with("res://") or sound_path.begins_with("user://"):
		if ResourceLoader.exists(sound_path):
			stream = load(sound_path)
	else:
		stream = AssetLoader.load_sound(sound_path)
	if stream:
		_cache[sound_path] = stream
	return stream


## Play a 3D sound at the given world position, synced to all peers.
## volume_db / max_dist default to the room-scale one-shot profile; raise both for
## big world events (a golem clap) that should carry beyond the room they happen in.
func play_3d(sound_path: String, pos: Vector3, pitch := 1.0, volume_db := 0.0, max_dist := DEFAULT_MAX_DIST) -> void:
	play_3d_local(sound_path, pos, pitch, volume_db, max_dist)
	if NetworkManager.is_online() and NetworkManager.is_host():
		_sync_sound_3d.rpc(sound_path, pos, pitch, volume_db, max_dist)


## Play a 3D sound on this peer only — for events that already carry their own RPC, where
## play_3d would sync the sound a second time.
func play_3d_local(sound_path: String, pos: Vector3, pitch := 1.0, volume_db := 0.0, max_dist := DEFAULT_MAX_DIST) -> void:
	_play_local(sound_path, pos, pitch, volume_db, max_dist)


@rpc("authority", "call_remote", "unreliable_ordered")
func _sync_sound_3d(sound_path: String, pos: Vector3, pitch := 1.0, volume_db := 0.0, max_dist := DEFAULT_MAX_DIST) -> void:
	_play_local(sound_path, pos, pitch, volume_db, max_dist)


func _play_local(sound_path: String, pos: Vector3, pitch := 1.0, volume_db := 0.0, max_dist := DEFAULT_MAX_DIST) -> void:
	var stream := _get_or_load(sound_path)
	if not stream:
		return
	var player := AudioStreamPlayer3D.new()
	player.stream = stream
	player.pitch_scale = pitch
	player.volume_db = volume_db
	player.max_distance = max_dist
	# Scale the full-volume radius with the audible radius so a long-range sound
	# isn't already fading at the distance a room-scale one would still be loud.
	player.unit_size = 3.0 * (max_dist / DEFAULT_MAX_DIST)
	player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	player.bus = WORLD_BUS
	get_tree().current_scene.add_child(player)
	player.global_position = pos
	player.play()
	player.finished.connect(player.queue_free)


## Spawn a 3D sound attached to a parent node (local only, no network sync).
## For looping sounds, use loop=true and node_name to find/stop it later.
## One-shot sounds auto-free on finish.
## The parent must be visible: an AudioStreamPlayer3D under a hidden node is silent, and player
## puppets are hidden (the listen host's own body always, anyone's when PVS drops them). Sound
## that must be heard regardless of what is drawn belongs on play_3d_local instead.
func spawn_on(parent: Node3D, sound_path: String, loop := false, max_dist := 20.0, node_name := "") -> AudioStreamPlayer3D:
	if not node_name.is_empty() and parent.get_node_or_null(node_name):
		return null  # already playing
	var stream := _get_or_load(sound_path)
	if not stream:
		return null
	var player := AudioStreamPlayer3D.new()
	if not node_name.is_empty():
		player.name = node_name
	player.stream = stream
	player.max_distance = max_dist
	player.bus = WORLD_BUS
	parent.add_child(player)
	player.play()
	if loop:
		player.finished.connect(player.play)
	else:
		player.finished.connect(player.queue_free)
	return player


# VOX announcer word stingers ("flag captured", etc.) live on SentenceSystem.play_words,
# not here — they're local-only since wording is listener-dependent.


## Play a non-positional sound, synced to all peers.
func play_global(sound_path: String) -> void:
	_play_local_global(sound_path)
	if NetworkManager.is_online() and NetworkManager.is_host():
		_sync_sound_global.rpc(sound_path)


@rpc("authority", "call_remote", "unreliable_ordered")
func _sync_sound_global(sound_path: String) -> void:
	_play_local_global(sound_path)


func _play_local_global(sound_path: String) -> void:
	var stream := _get_or_load(sound_path)
	if not stream:
		return
	_spawn_global_player(stream)


## Create, attach, and start a non-positional player for a loaded stream.
## Frees itself on finish.
func _spawn_global_player(stream: AudioStream) -> AudioStreamPlayer:
	var player := AudioStreamPlayer.new()
	player.stream = stream
	player.bus = EFFECTS_BUS
	get_tree().current_scene.add_child(player)
	player.play()
	player.finished.connect(player.queue_free)
	return player
