extends Node
## Boots the game with an ASCII renderer beside it. The renderer outlives this scene; the game
## becomes current_scene exactly as it would launched normally.

const MAIN_SCENE := "res://src/main.tscn"


func _ready() -> void:
	var renderer: Node = preload("ascii_renderer.gd").new()
	renderer.name = "AsciiRenderer"
	get_tree().root.add_child.call_deferred(renderer)
	get_tree().change_scene_to_file.call_deferred(MAIN_SCENE)
