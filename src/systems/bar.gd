@tool
extends ColorRect
## One resource bar: a dark trough whose Fill grows left-to-right (HUD.BarWidget moves
## anchor_right), captioned by a centred Label. hud.tscn instances bar.tscn five times —
## health, mana, beanstalk, thornplant and the siege altar — so the look is set once.
##
## The per-bar colour and caption are exported here rather than written straight onto Fill
## and Label as instance overrides, because Godot's export-time text->binary conversion
## DROPS overrides on nodes internal to an instanced scene: it re-serializes from live
## nodes and keeps only what the outer scene owns. The shipped pck lost all five fill
## colours that way and every bar drew in Fill's own white. Properties on the instance
## root survive, so the colour has to arrive through one.

@export var fill_color := Color(1, 1, 1, 1):
	set(value):
		fill_color = value
		_apply()

@export var caption := "":
	set(value):
		caption = value
		_apply()

@export var caption_font_size := 12:
	set(value):
		caption_font_size = value
		_apply()


func _ready() -> void:
	_apply()


## Setters fire while the scene is still being built, before Fill and Label exist, so this
## is a no-op until the node is ready; _ready then applies whatever landed.
func _apply() -> void:
	if not is_node_ready():
		return
	var fill := get_node_or_null(^"Fill") as ColorRect
	if fill:
		fill.color = fill_color
	var label := get_node_or_null(^"Label") as Label
	if label:
		label.text = caption
		label.add_theme_font_size_override(&"font_size", caption_font_size)
