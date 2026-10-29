## Detects whether OpenXR initialized at startup (project.godot auto-inits it; fails silently with no headset, leaving is_vr false).
extends Node

const SETTINGS_PATH := "user://settings.cfg"

var is_vr := false
var advanced_head_tracking := true
var vr_passthrough := false
var hand_tracking := false
var left_handed := false

func _ready() -> void:
	if RenderingServer.get_current_rendering_method() == "gl_compatibility":
		Log.info("XR: disabled (gl_compatibility renderer — desktop)")
		return
	var interface := XRServer.find_interface("OpenXR")
	is_vr = interface != null and interface.is_initialized()
	if is_vr:
		get_viewport().use_xr = true
		_load_settings()
	Log.info("XR: %s" % ("VR mode active" if is_vr else "desktop mode (no OpenXR)"))

func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) == OK:
		advanced_head_tracking = cfg.get_value("vr", "advanced_head_tracking", true)
		vr_passthrough = cfg.get_value("vr", "vr_passthrough", false)
		hand_tracking = cfg.get_value("vr", "hand_tracking", false)
		left_handed = cfg.get_value("vr", "left_handed", false)

func save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	cfg.set_value("vr", "advanced_head_tracking", advanced_head_tracking)
	cfg.set_value("vr", "vr_passthrough", vr_passthrough)
	cfg.set_value("vr", "hand_tracking", hand_tracking)
	cfg.set_value("vr", "left_handed", left_handed)
	cfg.save(SETTINGS_PATH)
