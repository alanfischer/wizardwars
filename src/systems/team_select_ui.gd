class_name TeamSelectUI
extends CanvasLayer

signal selection_made(team: int, element: int)

const BG_COLOR := Color(0.08, 0.08, 0.12, 0.92)
const TEXT_COLOR := Color(0.9, 0.9, 0.95)
const ACCENT := Color(0.4, 0.6, 1.0)

var _selected_team := GameConsts.Team.NONE
var _bg: ColorRect
var _title: Label
var _button_container: VBoxContainer
var _step := 0  # 0=hidden, 1=team, 2=class


func _ready() -> void:
	layer = 90
	visible = false

	_bg = ColorRect.new()
	_bg.color = BG_COLOR
	_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_bg)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_bg.add_child(center)

	var panel := VBoxContainer.new()
	panel.add_theme_constant_override("separation", 16)
	panel.custom_minimum_size = Vector2(300, 0)
	center.add_child(panel)

	_title = Label.new()
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_font_size_override("font_size", 28)
	_title.add_theme_color_override("font_color", ACCENT)
	panel.add_child(_title)

	_button_container = VBoxContainer.new()
	_button_container.add_theme_constant_override("separation", 8)
	panel.add_child(_button_container)


func show_ui() -> void:
	_show_step_1()
	visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


## Show class selection only (keeps current team).
func show_class_only(current_team: int) -> void:
	_selected_team = current_team as GameConsts.Team
	_show_step_2()
	visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func hide_ui() -> void:
	visible = false
	_step = 0
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _show_step_1() -> void:
	_step = 1
	_title.text = "Choose Team"
	_clear_buttons()
	for team_id in range(1, GoalSystem.get_team_count() + 1):
		var btn := Button.new()
		var team_name := GoalSystem.get_team_name(team_id)
		var limit: int = GoalSystem.team_max_players[team_id - 1]
		var count: int = GoalSystem.get_team_player_count(team_id)
		if limit > 0:
			btn.text = "%s (%d/%d)" % [team_name, count, limit]
		else:
			btn.text = team_name
		btn.custom_minimum_size.y = 40
		var full := GoalSystem.is_team_full(team_id)
		_style_button(btn, GameConsts.TEAM_COLORS.get(team_id, Color.GRAY))
		if full:
			btn.disabled = true
			btn.modulate.a = 0.5
		else:
			btn.pressed.connect(_on_team_picked.bind(team_id))
		_button_container.add_child(btn)


func _show_step_2() -> void:
	_step = 2
	_title.text = "Choose Class"
	_clear_buttons()
	var valid_classes := GoalSystem.valid_classes_for_team(_selected_team)
	for element_id in GameConsts.Element.values():
		if not valid_classes.has(element_id):
			continue
		var btn := Button.new()
		btn.text = GameConsts.ELEMENT_LABELS[element_id]
		btn.custom_minimum_size.y = 40
		_style_button(btn, GameConsts.ELEMENT_COLORS[element_id])
		btn.pressed.connect(_on_class_picked.bind(element_id))
		_button_container.add_child(btn)


func _on_team_picked(team: int) -> void:
	_selected_team = team as GameConsts.Team
	_show_step_2()


func _on_class_picked(element: int) -> void:
	hide_ui()
	selection_made.emit(_selected_team, element)


func _clear_buttons() -> void:
	for child in _button_container.get_children():
		child.queue_free()


func _style_button(btn: Button, color: Color) -> void:
	var font_color := Color.BLACK if color.get_luminance() > 0.5 else TEXT_COLOR

	var sb_normal := StyleBoxFlat.new()
	sb_normal.bg_color = color.darkened(0.3)
	sb_normal.set_corner_radius_all(4)
	sb_normal.set_content_margin_all(8)

	var sb_hover := StyleBoxFlat.new()
	sb_hover.bg_color = color.darkened(0.1)
	sb_hover.set_corner_radius_all(4)
	sb_hover.set_content_margin_all(8)

	var sb_pressed := StyleBoxFlat.new()
	sb_pressed.bg_color = color
	sb_pressed.set_corner_radius_all(4)
	sb_pressed.set_content_margin_all(8)

	btn.add_theme_stylebox_override("normal", sb_normal)
	btn.add_theme_stylebox_override("hover", sb_hover)
	btn.add_theme_stylebox_override("pressed", sb_pressed)
	btn.add_theme_stylebox_override("focus", sb_normal)

	btn.add_theme_color_override("font_color", font_color)
	btn.add_theme_color_override("font_hover_color", font_color)
	btn.add_theme_color_override("font_pressed_color", font_color)
	btn.add_theme_color_override("font_focus_color", font_color)
