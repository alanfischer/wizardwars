extends Node
## Boots the game with an ASCII renderer beside it. The renderer outlives this scene; the game
## becomes current_scene exactly as it would launched normally.

const MAIN_SCENE := "res://src/main.tscn"
const PLAY_WINDOW := Vector2i(160, 90)


func _ready() -> void:
	if OS.get_environment("ASCII_KEYS") != "" and DisplayServer.get_name() != "headless":
		_tuck_window_away()
	var renderer: Node = preload("ascii_renderer.gd").new()
	renderer.name = "AsciiRenderer"
	get_tree().root.add_child.call_deferred(renderer)
	get_tree().change_scene_to_file.call_deferred(MAIN_SCENE)


## Playing needs a real window: the game reads look and fire only with the mouse captured, which
## a headless display cannot do. It must still draw (the host waits on a drawn frame), but it
## never takes focus, so the captured mouse stays a mode and the terminal keeps the real cursor.
func _tuck_window_away() -> void:
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, true)
	DisplayServer.window_set_size(PLAY_WINDOW)
	var area := DisplayServer.screen_get_usable_rect()
	DisplayServer.window_set_position(area.position + area.size - PLAY_WINDOW)
