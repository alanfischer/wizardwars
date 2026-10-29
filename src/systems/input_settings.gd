extends Object
## View and mouse-look preferences, in the [input] section of settings.cfg — the same file the renderer,
## picture quality and net settings live in, one section per owner. Written by the lobby and by
## /sensitivity, /invertmouse and /thirdperson, and plain enough to edit by hand between sessions:
##
##     [input]
##     invert_mouse=true
##     sensitivity=1.5
##     third_person=false
##
## No class_name — preloaded by its consumers; see README, "class_name and preload".

const SETTINGS_PATH := "user://settings.cfg"  # shared with LobbyUI, RenderQuality, NetworkManager
const SECTION := "input"

const DEFAULT_INVERT := false

## First person is the game as designed; third person is opt-in per player.
const DEFAULT_THIRD_PERSON := false

## A multiplier on LocalPlayer.MOUSE_SENSITIVITY rather than a raw radians-per-pixel figure, so the
## number in the file means something to whoever is editing it: 1.0 is the stock feel, 2.0 twice it.
const DEFAULT_SENSITIVITY := 1.0
const SENSITIVITY_MIN := 0.25
const SENSITIVITY_MAX := 4.0


static func load_invert_mouse() -> bool:
	return bool(_load("invert_mouse", DEFAULT_INVERT))


static func save_invert_mouse(invert: bool) -> void:
	_store("invert_mouse", invert)


## Clamped on the way in as well as on the way out: a hand-edited 0 would freeze the view outright
## and a hand-edited 100 would leave the game unplayable, with the file the only way back.
static func load_sensitivity() -> float:
	return clamp_sensitivity(float(_load("sensitivity", DEFAULT_SENSITIVITY)))


static func save_sensitivity(value: float) -> void:
	_store("sensitivity", clamp_sensitivity(value))


static func clamp_sensitivity(value: float) -> float:
	return clampf(value, SENSITIVITY_MIN, SENSITIVITY_MAX)


## Third-person view. Persisted rather than session-only because a map change rebuilds the
## LocalPlayer, and a view setting that silently reverted every map would read as a bug.
static func load_third_person() -> bool:
	return bool(_load("third_person", DEFAULT_THIRD_PERSON))


static func save_third_person(enabled: bool) -> void:
	_store("third_person", enabled)


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
