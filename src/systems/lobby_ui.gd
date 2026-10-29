class_name LobbyUI
extends CanvasLayer

signal host_pressed(map_name: String)
signal join_pressed(ip: String, map_name: String)
signal renderer_restart_requested(renderer: String)
## Emitted with the new level whenever the quality dropdown changes. Unlike the renderer, this
## one lands live, so the listener just applies it.
signal quality_changed(level: String)

const ACCENT := Color(0.4, 0.6, 1.0)
const BG_COLOR := Color(0.0, 0.0, 0.0, 1.0)
const PAUSE_TINT := Color(0.0, 0.0, 0.0, 0.6)  # the match stays readable behind the panel
const TEXT_COLOR := Color(0.9, 0.9, 0.95)
const PANEL_COLOR := Color(0.12, 0.12, 0.18)
const BUTTON_COLOR := Color(0.2, 0.3, 0.5)
const BUTTON_HOVER := Color(0.25, 0.38, 0.6)

const InputSettings = preload("res://src/systems/input_settings.gd")
const KeyBindings = preload("res://src/systems/key_bindings.gd")
const GameVersion = preload("res://src/systems/game_version.gd")
const IntroGuide = preload("res://src/systems/intro_guide.gd")
const AudioSettings = preload("res://src/systems/audio_settings.gd")
const VoiceSettings = preload("res://src/systems/voice_settings.gd")
const NetProfiles = preload("res://src/systems/net_profiles.gd")

const SETTINGS_PATH := "user://settings.cfg"
## Every settings row is label + control on one line; a shared label width keeps the controls in a
## column instead of stepping in and out with the length of each word.
const ROW_LABEL_WIDTH := 120
## The key button on each Controls row. Sized for the longest name rather than the row.
const BIND_BUTTON_WIDTH := 170

var _map_dropdown: OptionButton
var _renderer_dropdown: OptionButton
var _renderer_index := 0  # the choice currently in force, restored when a restart is cancelled
var _quality_dropdown: OptionButton
## Quality levels in the order RenderQuality lists them, so a dropdown index maps to a setting.
var _quality_values: Array[String] = []
## Built into the Controls panel, so these are null whenever it is closed.
var _sensitivity_slider: HSlider
var _sensitivity_value: Label
var _invert_check: CheckBox
var _controls_btn: Button  # null in VR, which has no keyboard to bind and no mouse to tune
var _third_person_check: CheckBox  # null in VR, where the view is the headset's
var _intro_check: CheckBox
var _effects_slider: HSlider
var _voice_slider: HSlider  # null when this build has no voice chat
## Set while the Controls screen is waiting for a key. _input() swallows everything until one
## arrives, which is also what stops the button that started the capture from eating the press.
var _capture_action := ""
var _bind_buttons: Dictionary = {}  # action -> Button, so a steal can redraw the loser's row too
var _bind_note: Label
var _controls_overlay: ColorRect  # held so hide_menu() can take an armed capture down with it

## setting value -> label. "" means "leave the project default alone", which is what almost every
## machine should stay on; the rest exist because one renderer can be dramatically faster than
## another on a given GPU and only the machine itself can settle which.
const RENDERER_CHOICES := [
	["", "Automatic (recommended)"],
	["gl_compatibility", "Compatibility — OpenGL, widest support"],
	["mobile", "Mobile — Vulkan/Metal, faster if supported"],
	["forward_plus", "Forward+ — Vulkan/Metal, full features"],
]
var _server_list: ItemList
var _ip_edit: LineEdit
var _name_edit: LineEdit
var _status_label: Label
var _host_btn: Button
var _join_btn: Button
var _netsim_btn: MenuButton
var _servers: Array[Dictionary] = []  # [{ip: String, map: String}]
var _controls_disabled := false

## Escape during a match opens this same panel over the game. While it is up, LocalPlayer takes
## no movement, fire or chat input, so it is static rather than per-instance.
static var pause_open := false
var _in_game := false  # set when a match starts, cleared when the menu comes back
var _bg: ColorRect
var _pause_row: HBoxContainer  # the Resume button, shown only over a match
var _lobby_only: Array[Control] = []  # what the pause panel sets aside: the logo, the join rows
var _mouse_before := Input.MOUSE_MODE_VISIBLE

func _ready() -> void:
	layer = 100

	_bg = ColorRect.new()
	_bg.color = BG_COLOR
	_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_bg)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var margin_px := 20 if XRManager.is_vr else 40
	margin.add_theme_constant_override("margin_top", margin_px)
	margin.add_theme_constant_override("margin_bottom", margin_px)
	margin.add_theme_constant_override("margin_left", margin_px)
	margin.add_theme_constant_override("margin_right", margin_px)
	_bg.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 10)
	margin.add_child(vbox)

	_pause_row = HBoxContainer.new()
	_pause_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_pause_row.add_child(_make_button("Resume", _close_pause))
	_pause_row.visible = false
	vbox.add_child(_pause_row)

	# Title logo
	var logo_tex := load("res://ww_header.jpg") as Texture2D
	if logo_tex:
		var logo := TextureRect.new()
		logo.texture = logo_tex
		logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		logo.custom_minimum_size.y = 140
		vbox.add_child(logo)
		_lobby_only.append(logo)
	else:
		var title := Label.new()
		title.text = "WIZARD WARS"
		title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		title.add_theme_font_size_override("font_size", 36)
		title.add_theme_color_override("font_color", ACCENT)
		vbox.add_child(title)
		_lobby_only.append(title)

	# Player name
	var name_row := _add_row(vbox, "Name")
	_lobby_only.append(name_row)
	_name_edit = LineEdit.new()
	_name_edit.text = _load_setting("player", "name", "Wizard")
	_name_edit.placeholder_text = "Enter your name"
	_name_edit.max_length = 24
	_style_line_edit(_name_edit)
	name_row.add_child(_name_edit)

	_build_display_rows(vbox)
	_build_audio_rows(vbox)
	_build_input_rows(vbox)
	_build_vr_rows(vbox)

	vbox.add_child(HSeparator.new())

	_build_game_rows(vbox)

	_status_label = _make_note("Scanning for LAN games...")
	vbox.add_child(_status_label)
	_lobby_only.append(_status_label)
	var ip_note := _make_note("Your IP: %s" % _get_local_ip())
	vbox.add_child(ip_note)
	_lobby_only.append(ip_note)
	# Last line on the menu, and the only screen that always shows it: a bug report is worth
	# little without the build it came from, and the launcher updates in place with nothing on
	# screen to say what it landed on.
	vbox.add_child(_make_note("Version %s" % GameVersion.display()))


## Renderer and quality. The renderer is chosen at engine startup so picking one only records
## a preference and asks main.gd to relaunch; quality is a viewport property and takes hold live.
func _build_display_rows(vbox: VBoxContainer) -> void:
	# Graphics — the rendering method is chosen at engine startup and cannot be swapped live, so
	# picking one here asks main.gd to start the game again on it, once the player agrees to that.
	# What is running stacks under the label rather than taking a line of its own: the choice is
	# only a preference until a renderer actually starts, and the two disagree whenever one falls
	# back, so both belong in front of the dropdown.
	vbox.add_child(HSeparator.new())
	var gfx_row := HBoxContainer.new()
	gfx_row.add_theme_constant_override("separation", 8)
	vbox.add_child(gfx_row)

	var gfx_col := VBoxContainer.new()
	gfx_col.add_theme_constant_override("separation", 0)
	gfx_col.custom_minimum_size.x = ROW_LABEL_WIDTH
	gfx_col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	gfx_row.add_child(gfx_col)

	var gfx_label := Label.new()
	gfx_label.text = "Renderer"
	gfx_label.add_theme_color_override("font_color", TEXT_COLOR)
	gfx_col.add_child(gfx_label)

	gfx_col.add_child(_make_note("(%s)" % RenderingServer.get_current_rendering_method(), 11, false))

	_renderer_dropdown = _make_dropdown()
	for entry in RENDERER_CHOICES:
		_renderer_dropdown.add_item(entry[1])
	var saved := _load_setting("graphics", "renderer", "")
	for i in RENDERER_CHOICES.size():
		if RENDERER_CHOICES[i][0] == saved:
			_renderer_dropdown.selected = i
			_renderer_index = i
			break
	_renderer_dropdown.item_selected.connect(_on_renderer_selected)
	gfx_row.add_child(_renderer_dropdown)

	# Quality, by contrast, is live: every level is a viewport property, so the choice takes hold
	# on the next frame and needs neither a restart nor a prompt.
	var quality_row := _add_row(vbox, "Quality")
	_quality_dropdown = _make_dropdown()
	var saved_quality := RenderQuality.load_level()
	for level in RenderQuality.LEVELS:
		_quality_values.append(level)
		_quality_dropdown.add_item(RenderQuality.LEVELS[level][0])
		if level == saved_quality:
			_quality_dropdown.selected = _quality_values.size() - 1
	_quality_dropdown.item_selected.connect(_on_quality_selected)
	quality_row.add_child(_quality_dropdown)


## Effects and voice chat share a line. Both take hold live — they are bus volumes — so the
## handle is the preview; /volume and /voice set the same two numbers mid-match.
func _build_audio_rows(vbox: VBoxContainer) -> void:
	var row := _add_row(vbox, "Volume")
	_effects_slider = _add_volume_slider(row, "Effects", SoundSystem.effects_volume(),
		AudioSettings.EFFECTS_MAX, func(v: int) -> void: SoundSystem.set_effects_volume(v))
	if VoiceChat.available:
		_voice_slider = _add_volume_slider(row, "Voice", VoiceChat.volume(),
			VoiceSettings.VOLUME_MAX, func(v: int) -> void: VoiceChat.set_volume(v))


func _add_volume_slider(row: HBoxContainer, caption: String, value: int, max_value: int,
		on_changed: Callable) -> HSlider:
	var label := Label.new()
	label.text = caption
	label.add_theme_color_override("font_color", TEXT_COLOR)
	label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(label)

	var slider := HSlider.new()
	slider.min_value = 0
	slider.max_value = max_value
	slider.step = 5
	slider.value = value
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(slider)

	var readout := Label.new()
	readout.text = "%d%%" % value
	readout.custom_minimum_size.x = 40
	readout.add_theme_color_override("font_color", TEXT_COLOR)
	readout.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(readout)
	# Connected after seeding so opening the menu doesn't write the file.
	slider.value_changed.connect(func(v: float) -> void:
		readout.text = "%d%%" % int(v)
		on_changed.call(int(v)))
	return slider


## One row, and a screen behind it. Mouse feel and every key live in the Controls panel rather
## than on the front menu, which has no room for thirty rows; what stays here are the two ticks
## that are not controls at all.
func _build_input_rows(vbox: VBoxContainer) -> void:
	# VR has no keyboard to bind and no mouse to tune — LocalPlayer reads neither setting off a
	# headset — so all that is left of this section there is the guide tick.
	if XRManager.is_vr:
		var vr_row := _add_row(vbox, "Guide")
		_intro_check = _make_check("Show Guide", IntroGuide.should_show(),
			func(pressed: bool) -> void: IntroGuide.set_show(pressed))
		vr_row.add_child(_intro_check)
		return

	var row := _add_row(vbox, "Controls")
	_controls_btn = _make_button("Controls...", _show_controls_popup)
	row.add_child(_controls_btn)

	# Not offered in VR, where the view is the headset's and /thirdperson refuses for the same
	# reason. Saved only — LocalPlayer reads it when it spawns, which is after this menu closes.
	_third_person_check = _make_check("Third Person", InputSettings.load_third_person(),
		func(pressed: bool) -> void: InputSettings.save_third_person(pressed))
	row.add_child(_third_person_check)

	# Rides this row rather than taking a line of its own: the controls card clears this tick the
	# first time it shows, so for most players it's already off by the time they come looking. It
	# stays for the second person on the machine, and for anyone wanting another read.
	_intro_check = _make_check("Show Guide", IntroGuide.should_show(),
		func(pressed: bool) -> void: IntroGuide.set_show(pressed))
	row.add_child(_intro_check)

	row.add_child(_make_note("Mouse speed, look direction, and what every key does.", 12, false))


## Head tracking, passthrough, and which hand holds the wand. Nothing here draws off a headset.
func _build_vr_rows(vbox: VBoxContainer) -> void:
	# VR Settings — only shown when a headset is active
	if XRManager.is_vr:
		vbox.add_child(HSeparator.new())
		var vr_section := Label.new()
		vr_section.text = "VR Settings"
		vr_section.add_theme_color_override("font_color", ACCENT)
		vbox.add_child(vr_section)

		var vr_options_row := HBoxContainer.new()
		vr_options_row.add_theme_constant_override("separation", 12)
		vbox.add_child(vr_options_row)

		var head_track_check := _make_check("Adv Head Track", XRManager.advanced_head_tracking,
			func(pressed: bool) -> void:
				XRManager.advanced_head_tracking = pressed
				XRManager.save_settings())
		head_track_check.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vr_options_row.add_child(head_track_check)

		var passthrough_check := _make_check("Passthrough", XRManager.vr_passthrough,
			func(pressed: bool) -> void:
				XRManager.vr_passthrough = pressed
				XRManager.save_settings()
				var main_node := get_tree().get_root().get_node_or_null("Main")
				if main_node and main_node.has_method("apply_vr_passthrough"):
					main_node.apply_vr_passthrough(pressed))
		passthrough_check.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vr_options_row.add_child(passthrough_check)

		var hand_label := Label.new()
		hand_label.text = "Hands"
		hand_label.add_theme_color_override("font_color", TEXT_COLOR)
		hand_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		vr_options_row.add_child(hand_label)

		var hand_opts := [
			{"label": "L", "tracking": true, "left_handed": true},
			{"label": "R", "tracking": true, "left_handed": false},
			{"label": "—", "tracking": false, "left_handed": false},
		]
		var hand_btns: Array[Button] = []
		for opt in hand_opts:
			var btn := Button.new()
			btn.text = opt["label"]
			btn.custom_minimum_size = Vector2(36, 0)
			btn.toggle_mode = true
			btn.button_pressed = (XRManager.hand_tracking == (opt["tracking"] as bool)
				and XRManager.left_handed == (opt["left_handed"] as bool))
			_style_button(btn)
			hand_btns.append(btn)
			vr_options_row.add_child(btn)

		for i in hand_btns.size():
			var idx := i
			var opt = hand_opts[i]
			hand_btns[idx].toggled.connect(func(pressed: bool) -> void:
				if not pressed:
					hand_btns[idx].set_pressed_no_signal(true)
					return
				XRManager.hand_tracking = opt["tracking"]
				XRManager.left_handed = opt["left_handed"]
				XRManager.save_settings()
				for j in hand_btns.size():
					hand_btns[j].set_pressed_no_signal(j == idx)
			)


## Hosting a map, the LAN list, and joining an address: one decision made three ways, so they
## sit together with no rule between them.
func _build_game_rows(vbox: VBoxContainer) -> void:
	# Map selection — the map only matters to the button beside it, so they share a line, the same
	# shape as the address and Join further down. It sits here, under the settings and directly above
	# the server list, because picking a map is the last thing before starting a game: hosting and
	# joining are the same decision made two ways, so they belong next to each other.
	var map_row := _add_row(vbox, "Map")
	_lobby_only.append(map_row)
	_map_dropdown = _make_dropdown()
	_populate_maps()
	map_row.add_child(_map_dropdown)

	_host_btn = _make_button("Host Game", _on_host_pressed)
	map_row.add_child(_host_btn)

	# No rule between the map and the server list: hosting one and joining one are the same
	# decision, so they read as a single block bounded by the separators above and below.
	# Server list. Its title is a row label like every other control's, not a heading stacked above
	# it: the heading cost a whole line and sat outside the column the other labels line up in.
	var servers_row := _add_row(vbox, "LAN Servers")
	_lobby_only.append(servers_row)
	servers_row.size_flags_vertical = Control.SIZE_EXPAND_FILL  # the list is what grows on this row

	_server_list = ItemList.new()
	_server_list.custom_minimum_size.y = 60 if XRManager.is_vr else 80
	_server_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_server_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_server_list.add_theme_color_override("font_color", TEXT_COLOR)
	var list_bg := StyleBoxFlat.new()
	list_bg.bg_color = PANEL_COLOR
	list_bg.set_corner_radius_all(4)
	_server_list.add_theme_stylebox_override("panel", list_bg)
	_server_list.item_selected.connect(_on_server_selected)
	_server_list.item_activated.connect(_on_server_activated)
	servers_row.add_child(_server_list)

	# Manual join — no rule above it either: typing an address is joining a game the scan did not
	# find, so it belongs to the block above rather than standing apart from it.
	var join_row := _add_row(vbox, "Address")
	_lobby_only.append(join_row)
	_ip_edit = LineEdit.new()
	_ip_edit.text = GameVersion.default_server()
	_ip_edit.placeholder_text = "host or IP"
	_style_line_edit(_ip_edit)
	join_row.add_child(_ip_edit)

	_join_btn = _make_button("Join", _on_join_pressed)
	join_row.add_child(_join_btn)

	# Beside Join because it is about joining: the connection to play this server through.
	_netsim_btn = MenuButton.new()
	_netsim_btn.flat = false
	_netsim_btn.tooltip_text = "Simulate a slower connection on this client, for any server you join."
	_style_button(_netsim_btn)
	var menu := _netsim_btn.get_popup()
	var ids: Array = NetProfiles.PROFILES.keys()
	for i in ids.size():
		var p: Dictionary = NetProfiles.PROFILES[ids[i]]
		menu.add_radio_check_item(p["name"], i)
		menu.set_item_tooltip(i, p["info"])
	menu.id_pressed.connect(func(i: int) -> void:
		NetworkManager.set_net_profile(ids[i])
		_refresh_netsim_btn())
	join_row.add_child(_netsim_btn)
	_refresh_netsim_btn()


func _refresh_netsim_btn() -> void:
	_netsim_btn.text = "Netsim: %s" % NetProfiles.display_name(NetworkManager.net_profile)
	var menu := _netsim_btn.get_popup()
	var ids: Array = NetProfiles.PROFILES.keys()
	for i in ids.size():
		menu.set_item_checked(i, ids[i] == NetworkManager.net_profile)


func show_menu() -> void:
	_in_game = false
	_reset_pause()
	visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if not ServerBrowser.server_found.is_connected(_on_server_found):
		ServerBrowser.server_found.connect(_on_server_found)
	if not ServerBrowser.server_lost.is_connected(_on_server_lost):
		ServerBrowser.server_lost.connect(_on_server_lost)
	ServerBrowser.start_listening()
	_server_list.clear()
	_servers.clear()
	_status_label.text = "Scanning for LAN games..."
	_set_controls_disabled(false)


func hide_menu() -> void:
	# A capture is armed by a field on this node, not by the panel, and _input() runs whether or
	# not a CanvasLayer is visible — left behind, it would swallow the first key of the match.
	_close_controls_popup()
	_in_game = true  # the match is starting; main.gd sets the mouse itself
	_reset_pause()
	visible = false
	ServerBrowser.stop_listening()
	if ServerBrowser.server_found.is_connected(_on_server_found):
		ServerBrowser.server_found.disconnect(_on_server_found)
	if ServerBrowser.server_lost.is_connected(_on_server_lost):
		ServerBrowser.server_lost.disconnect(_on_server_lost)


## Escape over a match. Not in VR, which has no keyboard, and not while a text field has focus,
## since chat and the name box take Escape to close themselves.
func _toggle_pause() -> void:
	if pause_open:
		_close_pause()
		return
	_mouse_before = Input.mouse_mode
	pause_open = true
	_set_pause_layout(true)
	visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _close_pause() -> void:
	_close_controls_popup()
	pause_open = false
	_set_pause_layout(false)
	visible = false
	Input.mouse_mode = _mouse_before


## Drops the pause without touching the mouse: the caller is about to set it, or the menu is.
func _reset_pause() -> void:
	pause_open = false
	_set_pause_layout(false)


func _set_pause_layout(paused: bool) -> void:
	for node in _lobby_only:
		node.visible = not paused
	_pause_row.visible = paused
	_bg.color = PAUSE_TINT if paused else BG_COLOR


func _text_field_has_focus() -> bool:
	var focus := get_viewport().gui_get_focus_owner()
	return focus is LineEdit or focus is TextEdit


func get_player_name() -> String:
	var n := _name_edit.text.strip_edges()
	if n.is_empty():
		return "Wizard"
	_save_setting("player", "name", n)
	return n


func set_status(text: String) -> void:
	_status_label.text = text


## Modal overlay, panel, title and message. Built out of Controls rather than a Window because the
## lobby is also drawn into a VR viewport, where a real Window would never appear. Returns the
## overlay (free it to dismiss) and the vbox the caller appends its buttons to.
func _build_modal(title_text: String, title_color: Color, message: String,
		panel_width := 380) -> Array:
	var overlay := ColorRect.new()
	overlay.color = Color(0, 0, 0, 0.7)
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(overlay)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(panel_width, 0)
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = PANEL_COLOR
	panel_style.set_corner_radius_all(8)
	panel_style.set_content_margin_all(28)
	panel.add_theme_stylebox_override("panel", panel_style)
	center.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 16)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = title_text
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", title_color)
	vbox.add_child(title)

	vbox.add_child(HSeparator.new())

	var msg := Label.new()
	msg.text = message
	msg.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	msg.custom_minimum_size.x = 320
	msg.add_theme_color_override("font_color", TEXT_COLOR)
	vbox.add_child(msg)
	return [overlay, vbox]


func show_disconnect_popup(reason: String) -> void:
	show_error_popup("Disconnected", reason)


## The disconnect modal under a caller-supplied heading, for a join refused before it starts.
func show_error_popup(title: String, message: String) -> void:
	var modal := _build_modal(title, Color(1.0, 0.4, 0.4), message)
	var overlay: ColorRect = modal[0]
	var ok_btn := Button.new()
	ok_btn.text = "OK"
	_style_button(ok_btn)
	ok_btn.pressed.connect(overlay.queue_free)
	(modal[1] as VBoxContainer).add_child(ok_btn)


## A settings line: the label in the left-hand column, and whatever the caller adds after it
## sharing the width that's left.
func _add_row(parent: Control, label_text: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)
	row.add_child(_row_label(label_text))
	return row


## The dark rounded field the text inputs share.
func _style_line_edit(edit: LineEdit) -> void:
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.add_theme_color_override("font_color", TEXT_COLOR)
	edit.add_theme_color_override("font_placeholder_color", Color(0.5, 0.5, 0.6))
	var box := StyleBoxFlat.new()
	box.bg_color = PANEL_COLOR
	box.set_corner_radius_all(4)
	box.set_content_margin_all(6)
	edit.add_theme_stylebox_override("normal", box)


## A labelled tick box, wired to what it toggles.
func _make_check(text: String, pressed: bool, on_toggled: Callable) -> CheckBox:
	var check := CheckBox.new()
	check.text = text
	check.button_pressed = pressed
	check.add_theme_color_override("font_color", TEXT_COLOR)
	check.toggled.connect(on_toggled)
	return check


## Small grey caption text — what is running, what was found, which address to hand out.
func _make_note(text: String, font_size := 12, centred := true) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
	label.add_theme_font_size_override("font_size", font_size)
	if centred:
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return label


## A styled push button, already wired.
func _make_button(text: String, on_pressed: Callable) -> Button:
	var btn := Button.new()
	btn.text = text
	_style_button(btn)
	btn.pressed.connect(on_pressed)
	return btn


## A styled dropdown that takes the rest of its row.
func _make_dropdown() -> OptionButton:
	var opt := OptionButton.new()
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_button(opt)
	return opt


func _row_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.custom_minimum_size.x = ROW_LABEL_WIDTH
	label.add_theme_color_override("font_color", TEXT_COLOR)
	label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return label


func _set_controls_disabled(disabled: bool) -> void:
	_controls_disabled = disabled
	_host_btn.disabled = disabled
	_join_btn.disabled = disabled
	_map_dropdown.disabled = disabled
	_renderer_dropdown.disabled = disabled
	_quality_dropdown.disabled = disabled
	if _controls_btn:
		_controls_btn.disabled = disabled
	if _third_person_check:
		_third_person_check.disabled = disabled
	_intro_check.disabled = disabled
	_ip_edit.editable = not disabled


func _populate_maps() -> void:
	_populate_map_dropdown(_map_dropdown)


func _populate_map_dropdown(dropdown: OptionButton) -> void:
	dropdown.clear()
	for n in MapConverter.list_maps():
		dropdown.add_item(n)
	if dropdown.item_count > 0:
		dropdown.selected = 0


func _style_button(btn: BaseButton) -> void:
	var normal := StyleBoxFlat.new()
	normal.bg_color = BUTTON_COLOR
	normal.set_corner_radius_all(4)
	normal.set_content_margin_all(8)
	btn.add_theme_stylebox_override("normal", normal)

	var hover := StyleBoxFlat.new()
	hover.bg_color = BUTTON_HOVER
	hover.set_corner_radius_all(4)
	hover.set_content_margin_all(8)
	btn.add_theme_stylebox_override("hover", hover)

	var pressed := StyleBoxFlat.new()
	pressed.bg_color = ACCENT
	pressed.set_corner_radius_all(4)
	pressed.set_content_margin_all(8)
	btn.add_theme_stylebox_override("pressed", pressed)

	btn.add_theme_color_override("font_color", TEXT_COLOR)
	btn.add_theme_color_override("font_hover_color", Color.WHITE)


func _on_host_pressed() -> void:
	if _map_dropdown.item_count == 0 or _controls_disabled:
		return
	var map_name: String = _map_dropdown.get_item_text(_map_dropdown.selected)
	_set_controls_disabled(true)
	set_status("Converting %s..." % map_name)
	host_pressed.emit(map_name)


func _on_join_pressed() -> void:
	if _controls_disabled:
		return
	# Prefer selected server, fall back to IP text field
	var selected := _server_list.get_selected_items()
	if selected.size() > 0 and selected[0] < _servers.size():
		_join_server(selected[0])
		return
	var ip := _ip_edit.text.strip_edges()
	if ip.is_empty():
		return
	_set_controls_disabled(true)
	set_status("Connecting to %s..." % ip)
	join_pressed.emit(ip, "")


func _on_server_selected(index: int) -> void:
	if index >= 0 and index < _servers.size():
		_ip_edit.text = _servers[index].ip


func _on_server_activated(index: int) -> void:
	if not _controls_disabled:
		_join_server(index)


func _join_server(index: int) -> void:
	if index < 0 or index >= _servers.size():
		return
	var ip: String = _servers[index].ip
	var map_name: String = _servers[index].map
	_set_controls_disabled(true)
	set_status("Connecting to %s..." % ip)
	join_pressed.emit(ip, map_name)


func _on_server_found(ip: String, info: Dictionary) -> void:
	var map_name: String = info.get("map", "")
	var players: int = info.get("players", 0)
	var max_players: int = info.get("max", 0)
	var text := "%s (%d/%d) -- %s" % [map_name, players, max_players, ip]

	# Update existing or add new
	var idx := _find_server_index(ip)
	if idx >= 0:
		_server_list.set_item_text(idx, text)
		_servers[idx].map = map_name
	else:
		_server_list.add_item(text)
		_servers.append({"ip": ip, "map": map_name})

	if not _controls_disabled:
		_status_label.text = "%d server(s) found" % _servers.size()


func _on_server_lost(ip: String) -> void:
	var idx := _find_server_index(ip)
	if idx >= 0:
		_server_list.remove_item(idx)
		_servers.remove_at(idx)

	if not _controls_disabled:
		if _servers.is_empty():
			_status_label.text = "Scanning for LAN games..."
		else:
			_status_label.text = "%d server(s) found" % _servers.size()


func _find_server_index(ip: String) -> int:
	for i in _servers.size():
		if _servers[i].ip == ip:
			return i
	return -1


func _get_local_ip() -> String:
	for addr in IP.get_local_addresses():
		# Pick the first private IPv4 address (192.168.x.x, 10.x.x.x, 172.16-31.x.x)
		if ":" in addr:
			continue  # skip IPv6
		if addr.begins_with("192.168.") or addr.begins_with("10.") or addr.begins_with("172."):
			return addr
	return "unknown"


func _on_renderer_selected(index: int) -> void:
	if index == _renderer_index:
		return
	var value: String = RENDERER_CHOICES[index][0]
	# "Automatic" is not necessarily what came up: a renderer the GPU cannot start falls back to
	# gl_compatibility, so compare against the project setting rather than against the empty string.
	var target := value
	if target.is_empty():
		target = str(ProjectSettings.get_setting_with_override(
				&"rendering/renderer/rendering_method"))
	if target == RenderingServer.get_current_rendering_method():
		_renderer_index = index
		_save_setting("graphics", "renderer", value)
		set_status("Already running %s." % target)
		return
	_show_renderer_restart_popup(index, value, target)


func _sensitivity_text(value: float) -> String:
	return "%.2fx" % value


## Saves as the handle moves rather than on release: settings.cfg is a couple of hundred bytes, and
## the slider is how someone finds the speed they want — the value under the handle at any moment is
## the one they mean.
func _on_sensitivity_changed(value: float) -> void:
	_sensitivity_value.text = _sensitivity_text(value)
	InputSettings.save_sensitivity(value)


func _on_quality_selected(index: int) -> void:
	var level := _quality_values[index]
	RenderQuality.save_level(level)
	quality_changed.emit(level)


## The rendering method is fixed when the engine starts, so honouring a new choice means starting
## the game again. Ask first, and leave the dropdown and the saved setting alone if the answer is no.
func _show_renderer_restart_popup(index: int, value: String, target: String) -> void:
	var modal := _build_modal("Restart required", ACCENT,
			"The %s renderer can only be chosen as the game starts.\n\nRestart Wizard Wars now?" % target)
	var overlay: ColorRect = modal[0]

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	(modal[1] as VBoxContainer).add_child(row)

	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_button(cancel_btn)
	cancel_btn.pressed.connect(func() -> void:
		_renderer_dropdown.selected = _renderer_index
		overlay.queue_free())
	row.add_child(cancel_btn)

	var restart_btn := Button.new()
	restart_btn.text = "Restart now"
	restart_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_button(restart_btn)
	restart_btn.pressed.connect(func() -> void:
		_renderer_index = index
		_save_setting("graphics", "renderer", value)
		set_status("Restarting on %s..." % target)
		overlay.queue_free()
		renderer_restart_requested.emit(value))
	row.add_child(restart_btn)


## The Controls screen: how the mouse feels, then every rebindable control with its key on a
## button beside it. Clicking one of those arms a capture, and the next key or mouse button
## pressed becomes that control's — see _input().
func _show_controls_popup() -> void:
	_close_controls_popup()  # never two at once; the second would leave the first's rows stale
	var modal := _build_modal("Controls", ACCENT,
			"Click a control, then press the key or button you want on it.\n"
			+ "Escape cancels, Delete leaves it unbound.", 560)
	_controls_overlay = modal[0]
	var vbox: VBoxContainer = modal[1]

	_bind_buttons.clear()
	# The list is far taller than any window, so it scrolls inside the panel while the heading and
	# the buttons underneath stay put.
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.y = 360
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)

	# The scrollbar is drawn over the right-hand edge of whatever is under it, so the rows are
	# inset far enough to clear it — without this the Invert Y tick sits half behind the bar.
	var inset := MarginContainer.new()
	inset.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inset.add_theme_constant_override("margin_right", 16)
	scroll.add_child(inset)

	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 4)
	inset.add_child(list)

	_build_mouse_rows(list)
	for group in KeyBindings.GROUPS:
		list.add_child(_group_heading(str(group[0])))
		for entry in group[1]:
			_add_bind_row(list, str(entry[0]))
		list.add_child(HSeparator.new())

	# Says what just happened — which key landed, and what it was taken off. Sized up front so
	# filling it in does not shove the buttons down the panel.
	_bind_note = _make_note("", 12)
	_bind_note.custom_minimum_size.y = 18
	vbox.add_child(_bind_note)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	vbox.add_child(row)

	var reset_btn := _make_button("Reset to defaults", func() -> void:
		KeyBindings.reset_all()
		_refresh_bind_buttons()
		_set_bind_note("Every control is back on the key the game ships with."))
	reset_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(reset_btn)

	var done_btn := _make_button("Done", _close_controls_popup)
	done_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(done_btn)


## Takes the panel down and disarms whatever it left running. An armed capture outlives the panel
## otherwise, and would swallow the next key pressed anywhere in the game.
func _close_controls_popup() -> void:
	_capture_action = ""
	_bind_buttons.clear()
	_bind_note = null
	_sensitivity_slider = null
	_sensitivity_value = null
	_invert_check = null
	if is_instance_valid(_controls_overlay):
		_controls_overlay.queue_free()
	_controls_overlay = null


## Mouse speed and look direction, at the top of the same list as the keys — they are the same
## question the rest of the screen answers, and nothing about them needs a restart or a live push:
## LocalPlayer re-reads the [input] section when it spawns, which is after any trip through here,
## and /sensitivity and /invertmouse cover changing your mind mid-match.
func _build_mouse_rows(list: VBoxContainer) -> void:
	list.add_child(_group_heading("Mouse"))

	# Speed and direction share a line: they are the same decision being made twice.
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	list.add_child(row)
	row.add_child(_row_label("  Sensitivity"))

	_sensitivity_slider = HSlider.new()
	_sensitivity_slider.min_value = InputSettings.SENSITIVITY_MIN
	_sensitivity_slider.max_value = InputSettings.SENSITIVITY_MAX
	_sensitivity_slider.step = 0.05
	_sensitivity_slider.value = InputSettings.load_sensitivity()
	# The only control on the row that grows: the readout and the tick want their natural width
	# and the slider wants every pixel left over, so the handle has somewhere to travel.
	_sensitivity_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sensitivity_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	# The list under it scrolls, and a slider that answers the wheel would change the setting —
	# and write the file — whenever someone scrolled past it on the way to the keys.
	_sensitivity_slider.scrollable = false
	row.add_child(_sensitivity_slider)

	_sensitivity_value = Label.new()
	_sensitivity_value.text = _sensitivity_text(_sensitivity_slider.value)
	_sensitivity_value.custom_minimum_size.x = 44
	_sensitivity_value.add_theme_color_override("font_color", TEXT_COLOR)
	_sensitivity_value.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_sensitivity_value)
	# Connected after the label is seeded so opening the panel doesn't write the file.
	_sensitivity_slider.value_changed.connect(_on_sensitivity_changed)

	_invert_check = _make_check("Invert Y", InputSettings.load_invert_mouse(),
		func(pressed: bool) -> void: InputSettings.save_invert_mouse(pressed))
	_invert_check.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_invert_check)

	list.add_child(HSeparator.new())


func _group_heading(text: String) -> Label:
	var heading := Label.new()
	heading.text = text
	heading.add_theme_color_override("font_color", ACCENT)
	return heading


func _add_bind_row(list: VBoxContainer, action: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	list.add_child(row)
	row.add_child(_row_label("  " + KeyBindings.label_for(action)))

	# Wide enough for the longest key name ("Wheel Down", "Ctrl / Option") and no wider: stretched
	# across the panel, a button holding the single letter W reads as the loudest thing on screen.
	var btn := Button.new()
	btn.custom_minimum_size.x = BIND_BUTTON_WIDTH
	_style_button(btn)
	btn.pressed.connect(func() -> void: _begin_capture(action))
	row.add_child(btn)
	_bind_buttons[action] = btn
	_refresh_bind_button(action)


func _begin_capture(action: String) -> void:
	# Arming a second row while one is already waiting would leave the first one reading "Press a
	# key..." forever, so the old one goes back to showing its binding first.
	var previous := _capture_action
	_capture_action = action
	if not previous.is_empty():
		_refresh_bind_button(previous)
	var btn: Button = _bind_buttons.get(action)
	if btn:
		btn.text = "Press a key..."
		# Tinted as well as relabelled: at a glance the row otherwise reads as a control bound to
		# a key that happens to be called "Press a key...".
		btn.modulate = ACCENT
	_set_bind_note("")


## Runs ahead of the GUI while a capture is armed, which is the point: the key has to be caught
## before the focused button treats Space or Enter as a click on itself.
func _input(event: InputEvent) -> void:
	if _capture_action.is_empty():
		if _in_game and not XRManager.is_vr and event.is_action_pressed("ui_cancel") \
				and not _text_field_has_focus():
			get_viewport().set_input_as_handled()
			_toggle_pause()
		return
	var key := event as InputEventKey
	var button := event as InputEventMouseButton
	if key == null and button == null:
		return  # mouse motion still moves the cursor; only presses are ours
	get_viewport().set_input_as_handled()
	if key and (not key.pressed or key.is_echo()):
		return  # the matching release, swallowed so it cannot click the button underneath
	if button and not button.pressed:
		return
	_finish_capture(event)


func _finish_capture(event: InputEvent) -> void:
	var action := _capture_action
	_capture_action = ""
	var key := event as InputEventKey
	if key and key.physical_keycode == KEY_ESCAPE:
		_refresh_bind_button(action)
		return
	if key and (key.physical_keycode == KEY_DELETE or key.physical_keycode == KEY_BACKSPACE):
		KeyBindings.clear_binding(action)
		_refresh_bind_button(action)
		_set_bind_note("%s is now unbound." % KeyBindings.label_for(action))
		return
	if not KeyBindings.is_bindable(event):
		_refresh_bind_button(action)
		_set_bind_note("That one cannot be bound.")
		return
	var stolen := KeyBindings.set_binding(action, event)
	# A steal empties another row, so every button is redrawn rather than just this one.
	_refresh_bind_buttons()
	var msg := "%s is now %s." % [KeyBindings.label_for(action), KeyBindings.display_for(action)]
	if stolen.size() > 0:
		var names := PackedStringArray()
		for other in stolen:
			names.append(KeyBindings.label_for(other))
		msg += " %s left unbound." % " and ".join(names)
	_set_bind_note(msg)


func _refresh_bind_button(action: String) -> void:
	var btn: Button = _bind_buttons.get(action)
	if btn:
		btn.text = KeyBindings.display_for(action)
		btn.modulate = Color.WHITE  # drops the armed tint, whether or not this row was the armed one


func _refresh_bind_buttons() -> void:
	for action in _bind_buttons:
		_refresh_bind_button(action)


func _set_bind_note(text: String) -> void:
	if _bind_note:
		_bind_note.text = text


func _load_setting(section: String, key: String, default_val: String) -> String:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return default_val
	return cfg.get_value(section, key, default_val)


func _save_setting(section: String, key: String, value: String) -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)  # load existing; OK if missing
	cfg.set_value(section, key, value)
	cfg.save(SETTINGS_PATH)
