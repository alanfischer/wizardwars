extends Object
## Game sound preferences, in the [audio] section of settings.cfg. Voice chat keeps its own
## [voice] section (VoiceSettings); this is everything else the game plays.
##
##     [audio]
##     effects=100
##
## No class_name — preloaded by its consumers; see README, "class_name and preload".

const VoiceSettings = preload("res://src/systems/voice_settings.gd")

const SETTINGS_PATH := "user://settings.cfg"
const SECTION := "audio"

const DEFAULT_EFFECTS := 100

## Capped at 100, unlike voice: the effects are mixed at full scale already, so there is no quiet
## source to lift, only a mix to clip.
const EFFECTS_MIN := 0
const EFFECTS_MAX := 100


static func load_effects() -> int:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return DEFAULT_EFFECTS
	return clamp_effects(int(cfg.get_value(SECTION, "effects", DEFAULT_EFFECTS)))


static func save_effects(percent: int) -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)  # load existing; OK if missing
	cfg.set_value(SECTION, "effects", clamp_effects(percent))
	cfg.save(SETTINGS_PATH)


static func clamp_effects(percent: int) -> int:
	return clampi(percent, EFFECTS_MIN, EFFECTS_MAX)


static func effects_to_db(percent: int) -> float:
	return VoiceSettings.volume_to_db(clamp_effects(percent))
