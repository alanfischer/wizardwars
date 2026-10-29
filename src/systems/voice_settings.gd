extends Object
## Voice chat preferences, in the [voice] section of settings.cfg — the same file the renderer,
## view and net settings live in, one section per owner. Written by /voice, and plain enough to
## edit by hand between sessions:
##
##     [voice]
##     enabled=true
##     volume=100
##
## Volume is a percentage rather than decibels because that is the number a player types at
## /voice; VoiceChat converts it on the way to the bus.
##
## No class_name — preloaded by its consumers; see README, "class_name and preload".

const SETTINGS_PATH := "user://settings.cfg"  # shared with LobbyUI, InputSettings, RenderQuality
const SECTION := "voice"

const DEFAULT_ENABLED := true
const DEFAULT_VOLUME := 100

## 0 is silence and 100 is the stream as it was encoded. Capped above 100 so a quiet talker can
## be lifted, but not far enough to clip the mix.
const VOLUME_MIN := 0
const VOLUME_MAX := 150


## Off means neither transmitting nor decoding: no microphone is opened and incoming packets are
## dropped, which is the setting for someone who wants nothing to do with voice at all.
static func load_enabled() -> bool:
	return bool(_load("enabled", DEFAULT_ENABLED))


static func save_enabled(enabled: bool) -> void:
	_store("enabled", enabled)


static func load_volume() -> int:
	return clamp_volume(int(_load("volume", DEFAULT_VOLUME)))


static func save_volume(percent: int) -> void:
	_store("volume", clamp_volume(percent))


static func clamp_volume(percent: int) -> int:
	return clampi(percent, VOLUME_MIN, VOLUME_MAX)


## Silence is -80 dB rather than linear_to_db(0)'s -INF, which an AudioStreamPlayer rejects.
static func volume_to_db(percent: int) -> float:
	var pct := clamp_volume(percent)
	return -80.0 if pct <= 0 else linear_to_db(pct / 100.0)


static func _load(key: String, default: Variant) -> Variant:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return default
	return cfg.get_value(SECTION, key, default)


static func _store(key: String, value: Variant) -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)  # load existing; OK if missing
	cfg.set_value(SECTION, key, value)
	cfg.save(SETTINGS_PATH)
