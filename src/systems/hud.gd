class_name HUD
extends CanvasLayer
# The layout is hud.tscn; this script drives it and builds the parts that are made per-use
# (satchel icons, status icons, scoreboard rows, kill-feed and chat lines, weapon slots).
# Four text channels back the game_text entity: each shows one message at a time, and a new
# message replaces the old one.

const NUM_CHANNELS := 4
## A satchel is taller than a bar slot, so the row overhangs both ways. hud.tscn holds the
## resulting Satchels offsets, so changing this height means re-centring the row there.
const SATCHEL_ICON_SIZE := Vector2i(18, 28)
const FLAME_COLOR: Color = GameConsts.ELEMENT_COLORS[GameConsts.Element.FIRE]

const IntroGuide = preload("res://src/systems/intro_guide.gd")

## One resource bar, an instance of bar.tscn: a Fill whose anchor_right is the ratio, under a
## Label reading "<caption> <value>". The scene's starting colour and caption are kept because
## both get overwritten as the bar fills. `overheal` is the health bar's extra fill, null elsewhere.
class BarWidget:
	var root: Control
	var fill: ColorRect
	var label: Label
	var overheal: ColorRect
	var base_color: Color
	var caption: String

	func _init(node: Control) -> void:
		root = node
		fill = node.get_node("Fill")
		label = node.get_node("Label")
		overheal = node.get_node_or_null("Overheal")
		base_color = fill.color
		caption = label.text

	## Fills left-to-right, capped at full; `fallback` stands in when there is no max to divide
	## by. Returns the ratio, which a bar's colour and caption usually follow too.
	func set_ratio(value: float, max_value: float, fallback := 0.0) -> float:
		var ratio := clampf(value / max_value, 0.0, 1.0) if max_value > 0.0 else fallback
		fill.anchor_right = ratio
		return ratio


@onready var _labels: Array[Label] = [$Channel0, $Channel1, $Channel2, $Channel3]
var _tweens: Array[Tween] = []
@onready var _bar_container: HBoxContainer = $ResourceBars
@onready var _health := BarWidget.new($ResourceBars/HealthColumn/HealthBar)
@onready var _mana := BarWidget.new($ResourceBars/ManaColumn/ManaBar)
## While riding a dragon the mana bar becomes the dragon's flame meter — mana is
## unspendable up there, so the slot shows the resource the rider actually burns.
var _flame_mode := false
@onready var _satchel_container: HBoxContainer = $ResourceBars/SatchelColumn/Satchels
var _satchel_icons: Array[Control] = []
## The model inside each icon's SubViewport, held so _process can spin them.
var _satchel_models: Array[Node3D] = []
var _satchel_icon_elem := -1
var _satchel_count := 3  # remaining, so only the ones you still have tumble
@onready var _damage_overlay: ColorRect = $DamageOverlay
var _damage_tween: Tween
@onready var _hit_overlay: ColorRect = $HitOverlay
var _hit_tween: Tween
var _hit_sound: AudioStream
@onready var _crosshair: Control = $Crosshair
@onready var _center_label: Label = $CenterMessage
var _center_tween: Tween
## Who the crosshair is on, coloured by side. Ally green and enemy red carry the same thing the
## "(Friend)"/"(Foe)" words do, and the words stay for anyone the colours don't reach.
@onready var _target_id_label: Label = $TargetID
const TARGET_ID_FRIEND_COLOR := Color(0.5, 0.9, 0.55)
const TARGET_ID_FOE_COLOR := Color(1.0, 0.5, 0.45)
const TARGET_ID_NEUTRAL_COLOR := Color(0.9, 0.9, 0.9)
var _notify_sound: AudioStream
@onready var _scoreboard: PanelContainer = $Scoreboard
@onready var _score_table: VBoxContainer = $Scoreboard/ScoreTable
## Seconds between live rebuilds of the scoreboard while Tab is held.
const SCOREBOARD_REFRESH_INTERVAL := 0.5
var _scoreboard_refresh_timer := 0.0
## Match over: the scoreboard is pinned up until the next map loads, Tab or no Tab.
var _intermission := false
## Where hud.tscn anchors the centre message and the ballot for normal play, captured so
## _stack_banners_around_board can put them back after moving them for the intermission.
var _center_message_y: float
var _vote_y: float
## Gap left between the pinned board and the banners stacked above and below it.
const INTERMISSION_BANNER_GAP := 10.0
## Room kept above the board for the result banner: two lines at its font size, with headroom.
const RESULT_BANNER_HEIGHT := 96.0
## Match clock (top centre) and the intermission ballot under the result banner.
@onready var _match_label: Label = $MatchClock
@onready var _vote_label: Label = $MapVote
## Last whole second drawn, so the clock rebuilds its string once a second and not once a frame.
var _match_label_secs := -1
var _match_label_color := Color.TRANSPARENT  # never a real colour, so the first draw always applies
@onready var _siege_label: Label = $SiegeWave
@onready var _siege_bar := BarWidget.new($SiegeAltarBar)

const CLOCK_COLOR := Color(0.9, 0.9, 0.95)
const CLOCK_WARNING_COLOR := Color(1.0, 0.4, 0.4)
const CLOCK_INTERMISSION_COLOR := Color(1.0, 0.9, 0.4)
## Seconds left at which the match clock turns red.
const CLOCK_WARNING_SECONDS := 60
@onready var _kill_feed: VBoxContainer = $KillFeed
@onready var _fade_overlay: ColorRect = $FadeOverlay
var _fade_tween: Tween
@onready var _status_container: HBoxContainer = $StatusIcons
## kind ("beanstalk"/"thornplant") -> the indicator stacked above that kind's resource bar.
@onready var _plant_bars: Dictionary[String, BarWidget] = {
	"beanstalk": BarWidget.new($ResourceBars/HealthColumn/BeanstalkBar),
	"thornplant": BarWidget.new($ResourceBars/ManaColumn/ThornplantBar),
}
var _status_icons: Dictionary = {}  # StatusType or HELP_ICON_KEY -> TextureRect
var _status_textures: Dictionary = {}  # same key -> Array of textures
var _status_frame: Dictionary = {}  # same key -> int (current frame)
var _status_timer: float = 0.0
const STATUS_FPS := 10.0
@onready var _perf_label: Label = $PerfLabel
var _perf_label_color := Color.TRANSPARENT  # never a real colour, so the first draw applies
@onready var _render_debug_label: Label = $RenderDebugLabel
@onready var _pos_label: Label = $PosLabel
var _debug_player_ref: Node3D = null  # cached for the /pos readout
@onready var _weapon_row: VBoxContainer = $WeaponRow
var _weapon_slot_panels: Array[PanelContainer] = []
var _weapon_slot_labels: Array[Label] = []
var _weapon_row_style_normal: StyleBoxFlat
var _weapon_row_style_active: StyleBoxFlat

# Map description (MOTD) panel — shown on map start / join, dismissed by any
# key/click or auto-hidden after a hold. Re-shown via the /motd command.
@onready var _motd_panel: PanelContainer = $MapInfo
@onready var _motd_title: Label = $MapInfo/Content/Title
## The body lives in a height-capped ScrollContainer so long descriptions scroll instead of
## running off the bottom of the screen. It's driven manually (see _unhandled_input) so it
## works even with the mouse captured.
@onready var _motd_scroll: ScrollContainer = $MapInfo/Content/BodyScroll
@onready var _motd_body: Label = $MapInfo/Content/BodyScroll/Body
var _motd_tween: Tween
var _motd_visible := false
## The mod's gfx/vgui/640_<world>.tga briefing sheet (per maps/<map>.ww), with the original
## blinking cross marking where in the world the level takes place. Hidden for maps with no sheet.
@onready var _motd_map: TextureRect = $MapInfo/Content/WorldMap
@onready var _motd_cross: TextureRect = $MapInfo/Content/WorldMap/Cross
@onready var _motd_cross_timer: Timer = $MapInfo/Content/WorldMap/CrossBlink
## Fired once the panel is gone, however it went — used to queue the map description behind the
## intro card so a first-time player reads one then the other instead of both at once.
var _motd_then := Callable()

@onready var _chat_log: VBoxContainer = $ChatLog
@onready var _chat_input_container: PanelContainer = $ChatInput
@onready var _chat_input_prefix: Label = $ChatInput/Row/Prefix
@onready var _chat_input: LineEdit = $ChatInput/Row/Input
var _chat_team_only := false

## Who is talking, above the chat log. Built in _ready rather than in hud.tscn: it is one line of
## text, and move_to_vr_panel has to be able to list it before voice chat has anything to say.
var _voice_label: Label = null

signal chat_submitted(message: String, team_only: bool)


## The layout lives in hud.tscn, so a HUD is instantiated, never `new`ed. Loaded by path
## rather than preloaded: the scene's own root carries this script.
static func create() -> HUD:
	return load("res://src/systems/hud.tscn").instantiate()


## hud.tscn carries the layout; this wires up what a scene can't hold.
func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)

	_tweens.resize(NUM_CHANNELS)
	_center_message_y = _center_label.anchor_top
	_vote_y = _vote_label.anchor_top

	_weapon_row_style_normal = _make_slot_style(Color(0.05, 0.05, 0.05, 0.65))
	_weapon_row_style_active = _make_slot_style(Color(0.25, 0.22, 0.04, 0.88),
			Color(0.9, 0.8, 0.2, 0.9))

	_build_satchel_icons(3, GameConsts.Element.FIRE)

	_notify_sound = load("sounds/vox/doop.wav")
	_hit_sound = _create_hit_sound()

	_voice_label = _make_label(14, Color(0.7, 0.95, 0.75))
	_voice_label.anchor_top = 1.0
	_voice_label.anchor_bottom = 1.0
	_voice_label.offset_left = 8.0
	_voice_label.offset_top = -152.0
	_voice_label.offset_right = 390.0
	_voice_label.offset_bottom = -132.0
	_voice_label.visible = false
	add_child(_voice_label)

	GoalSystem.kill_occurred.connect(_on_kill)


## Four ticks around a gap in the middle. Drawn rather than textured, so it stays one pixel
## crisp at any resolution. Connected from hud.tscn.
func _draw_crosshair() -> void:
	const WIDTH := 2.0
	const GAP := 4.0
	const LENGTH := 5.0
	const COL := Color(1, 1, 1, 0.7)
	_crosshair.draw_line(Vector2(0, -GAP), Vector2(0, -GAP - LENGTH), COL, WIDTH)
	_crosshair.draw_line(Vector2(0, GAP), Vector2(0, GAP + LENGTH), COL, WIDTH)
	_crosshair.draw_line(Vector2(-GAP, 0), Vector2(-GAP - LENGTH, 0), COL, WIDTH)
	_crosshair.draw_line(Vector2(GAP, 0), Vector2(GAP + LENGTH, 0), COL, WIDTH)


func _blink_motd_cross() -> void:
	_motd_cross.visible = not _motd_cross.visible


## Background for one weapon-wheel slot. A `border` with no alpha leaves the slot unbordered.
func _make_slot_style(bg: Color, border := Color(0, 0, 0, 0)) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	if border.a > 0.0:
		style.border_color = border
		style.set_border_width_all(1)
	style.set_corner_radius_all(3)
	style.set_content_margin_all(4)
	return style


func _process(delta: float) -> void:
	_update_match_label()
	_update_siege()
	_update_perf_label()
	_update_render_debug_label()
	_update_pos_label()
	var tab_held := Input.is_action_pressed("scoreboard")
	var want_board := tab_held or _intermission
	if want_board and not _scoreboard.visible:
		_update_scoreboard()
		_scoreboard_refresh_timer = 0.0
		_scoreboard.visible = true
	elif not want_board and _scoreboard.visible:
		_scoreboard.visible = false
	elif tab_held and _scoreboard.visible:
		# Keep ping/scores/quality live while Tab is held down, not frozen at the press. The
		# intermission board is exempt: scoring is frozen behind it, so there is nothing to redraw
		# and rebuilding every row twice a second for the whole intermission is pure churn.
		_scoreboard_refresh_timer += delta
		if _scoreboard_refresh_timer >= SCOREBOARD_REFRESH_INTERVAL:
			_scoreboard_refresh_timer -= SCOREBOARD_REFRESH_INTERVAL
			_update_scoreboard()
	_spin_satchel_icons(delta)
	# Animate status icons
	if not _status_textures.is_empty():
		_status_timer += delta
		if _status_timer >= 1.0 / STATUS_FPS:
			_status_timer -= 1.0 / STATUS_FPS
			for st in _status_textures:
				var textures: Array = _status_textures[st]
				if textures.size() <= 1:
					continue
				_status_frame[st] = (_status_frame[st] + 1) % textures.size()
				var icon: TextureRect = _status_icons.get(st)
				if icon and is_instance_valid(icon):
					icon.texture = textures[_status_frame[st]]


## The satchels you still have tumble at the thrown pouch's own rate; a spent one freezes where
## it stopped until it comes back. Each icon is its own little SubViewport, so a still one is
## also parked at UPDATE_ONCE and costs nothing to keep on screen — but a SubViewportContainer
## forces UPDATE_ALWAYS on its viewport every time it becomes visible, so the mode set at build
## time does not survive being shown and has to be settled here instead. Skipped whole while the
## HUD is hidden: the container has already disabled those viewports, and re-arming one would
## draw an icon nobody is looking at.
func _spin_satchel_icons(delta: float) -> void:
	if _satchel_models.is_empty() or not visible:
		return
	var spin := deg_to_rad(Satchel.SPIN_SPEED) * delta
	for i in _satchel_models.size():
		var model := _satchel_models[i]
		var vp: SubViewport = model.get_parent()
		if i < _satchel_count:
			model.rotate_y(spin)
			if vp.render_target_update_mode != SubViewport.UPDATE_ALWAYS:
				vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		elif vp.render_target_update_mode == SubViewport.UPDATE_ALWAYS:
			# UPDATE_ONCE redraws the frozen pose once, then disables itself.
			vp.render_target_update_mode = SubViewport.UPDATE_ONCE


## Every label built at runtime goes through here: outlined black so it stays readable over any
## scene, and transparent to the mouse so it never eats a click. `font_color` of null leaves the
## theme default in place, for labels that are recoloured per-use (weapon slots).
func _make_label(font_size: int, font_color = null, outline := 2) -> Label:
	var label := Label.new()
	label.add_theme_font_size_override("font_size", font_size)
	if font_color != null:
		label.add_theme_color_override("font_color", font_color)
	if outline > 0:
		label.add_theme_constant_override("outline_size", outline)
		label.add_theme_color_override("font_outline_color", Color.BLACK)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


## Puts a banner's box at `anchor` (a fraction of screen height) between the two offsets. A
## zero-height box is the usual case: the label grows down from its top edge to fit its text.
##
## The bottom anchor moves first, and pushes: raising it can never invert the box, and lowering it
## brings the top down with it. Setting the top first inverts the box on the way up, and Control
## answers that by clamping the anchor back — which is how the ballot ended up 12px inside the
## board, anchored at 0.47 when it had been asked for 0.5.
func _place_banner(label: Label, anchor: float, off_top: float, off_bottom: float) -> void:
	label.set_anchor(SIDE_BOTTOM, anchor)
	label.set_anchor(SIDE_TOP, anchor)
	label.offset_top = off_top
	label.offset_bottom = off_bottom


func _build_satchel_icons(count: int, elem: int) -> void:
	for c in _satchel_container.get_children():
		_satchel_container.remove_child(c)
		c.queue_free()
	_satchel_icons.clear()
	_satchel_models.clear()
	_satchel_icon_elem = elem
	var caption := _make_label(12, Color.WHITE)
	caption.text = "Satchels:"
	caption.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	caption.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_satchel_container.add_child(caption)
	for i in count:
		var icon := _make_satchel_icon(elem)
		_satchel_container.add_child(icon)
		_satchel_icons.append(icon)


## One HUD satchel icon: the element's actual thrown-satchel model rendered in a
## tiny isolated SubViewport, so the icon always matches what leaves your hand.
## Built still — _spin_satchel_icons decides frame by frame which ones tumble and
## which stay parked. Spent/remaining is a `modulate` on the container either way,
## needing no re-render.
func _make_satchel_icon(elem: int) -> Control:
	var model_name: String = Satchel.ELEMENT_MODELS.get(elem, "fire")
	var model := AssetLoader.load_model("models/satchels/%s.mdl" % model_name)
	if not model:
		var rect := ColorRect.new()
		rect.custom_minimum_size = Vector2(14, 14)
		rect.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		rect.color = GameConsts.ELEMENT_COLORS.get(elem, Color.WHITE)
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		return rect

	var vp := SubViewport.new()
	vp.size = SATCHEL_ICON_SIZE
	vp.transparent_bg = true
	vp.own_world_3d = true
	vp.msaa_3d = Viewport.MSAA_DISABLED
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_CLEAR_COLOR
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color.WHITE
	e.ambient_light_energy = 0.6
	env.environment = e
	vp.add_child(env)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-35, -40, 0)
	light.light_energy = 1.2
	vp.add_child(light)
	vp.add_child(model)
	_satchel_models.append(model)

	# The pouch AABB is ~0.31 x 0.52, sitting on y = 0.05, so frame it about its
	# waist with a hair of margin rather than about the model origin.
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 0.62
	cam.position = Vector3(0, 0.31, 1)
	vp.add_child(cam)
	cam.current = true

	var holder := SubViewportContainer.new()
	holder.custom_minimum_size = Vector2(SATCHEL_ICON_SIZE)
	holder.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	holder.stretch = true
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(vp)
	return holder


func update_health(hp: float, max_hp: float) -> void:
	_health.label.text = "%s %d" % [_health.caption, roundi(hp)]
	_health.set_ratio(hp, max_hp)
	if hp > max_hp:
		# Gold overheal bar: 0 at max_hp, full at 2x max_hp
		var overheal_ratio := clampf((hp - max_hp) / max_hp, 0.0, 1.0) if max_hp > 0 else 0.0
		_health.overheal.anchor_left = 1.0 - overheal_ratio
		_health.overheal.visible = true
		_health.label.add_theme_color_override("font_color", Color(0.9, 0.8, 0.1))
	else:
		_health.overheal.visible = false
		if hp <= 30.0:
			_health.label.add_theme_color_override("font_color", Color.RED)
		else:
			_health.label.add_theme_color_override("font_color", Color.WHITE)


func update_mana(mp: float, max_mp: float) -> void:
	if _flame_mode:
		return
	_set_mana_bar("%s %d" % [_mana.caption, roundi(mp)], mp, max_mp, 10.0)


func set_flame_mode(active: bool) -> void:
	_flame_mode = active
	_mana.fill.color = FLAME_COLOR if active else _mana.base_color


func update_flame(flame: float, max_flame: float) -> void:
	if not _flame_mode:
		return
	_set_mana_bar("FIRE: %d" % roundi(flame), flame, max_flame, max_flame * 0.2)


func _set_mana_bar(text: String, value: float, max_value: float, low: float) -> void:
	_mana.label.text = text
	_mana.set_ratio(value, max_value)
	if value <= low:
		_mana.label.add_theme_color_override("font_color", Color(0.7, 0.3, 0.3))
	else:
		_mana.label.add_theme_color_override("font_color", Color.WHITE)


func update_satchels(count: int, elem: int = GameConsts.Element.FIRE) -> void:
	# Rebuild only on an element switch (new models) or an unexpected count change
	if _satchel_icons.size() != 3 or elem != _satchel_icon_elem:
		_build_satchel_icons(3, elem)
	_satchel_count = count
	for i in _satchel_icons.size():
		_satchel_icons[i].modulate = Color.WHITE if i < count else Color(0.3, 0.3, 0.3, 0.65)


## The crosshair ID line. relation: 1 ally, -1 enemy, 0 neither (deathmatch, or something with
## no side); health_pct < 0 when this player may not read it. An empty label hides the line.
func set_target_id(label: String, relation: int, health_pct: int) -> void:
	if label.is_empty():
		_target_id_label.visible = false
		return
	var text := label
	if relation > 0:
		text = "(Friend) " + text
	elif relation < 0:
		text = "(Foe) " + text
	if health_pct >= 0:
		text += "  %d%%" % health_pct
	_target_id_label.text = text
	var color := TARGET_ID_NEUTRAL_COLOR
	if relation > 0:
		color = TARGET_ID_FRIEND_COLOR
	elif relation < 0:
		color = TARGET_ID_FOE_COLOR
	_target_id_label.add_theme_color_override("font_color", color)
	_target_id_label.visible = true


func update_weapon_row(weapons: Array[Weapon], active_idx: int) -> void:
	# Rebuild panels if the weapon count changed
	if _weapon_slot_panels.size() != weapons.size():
		for p in _weapon_slot_panels:
			p.queue_free()
		_weapon_slot_panels.clear()
		_weapon_slot_labels.clear()
		for i in weapons.size():
			var panel := PanelContainer.new()
			panel.custom_minimum_size = Vector2(145, 0)
			panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_weapon_row.add_child(panel)
			_weapon_slot_panels.append(panel)
			var lbl := _make_label(13)
			lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			panel.add_child(lbl)
			_weapon_slot_labels.append(lbl)

	for i in weapons.size():
		var lbl: Label = _weapon_slot_labels[i]
		var panel: PanelContainer = _weapon_slot_panels[i]
		lbl.text = "%d: %s" % [i + 1, weapons[i].get_display_name()]
		if i == active_idx:
			panel.add_theme_stylebox_override("panel", _weapon_row_style_active)
			lbl.add_theme_color_override("font_color", Color(1.0, 0.95, 0.5))
		else:
			panel.add_theme_stylebox_override("panel", _weapon_row_style_normal)
			lbl.add_theme_color_override("font_color", Color(0.72, 0.72, 0.72))


const STATUS_TINTS := {
	GameConsts.StatusType.FROSTED: Color(0.3, 0.6, 1.0),
}

## Key for the call-for-help icon. A String so it can never collide with the StatusType ints
## the status icons key by — neither kind can evict the other from the strip.
const HELP_ICON_KEY := "help_call"


func show_status(status_type: int) -> void:
	var sprite_path: String = StatusSystem.STATUS_SPRITES.get(status_type, "")
	_add_status_icon(status_type, sprite_path, STATUS_TINTS.get(status_type, Color.WHITE))


func hide_status(status_type: int) -> void:
	_remove_status_icon(status_type)


## A call for help is an event, not a status, but it belongs in the same strip: it's the caller's
## only confirmation that the call went out and the cooldown accepted it. Times itself out.
func show_help_call(sprite_path: String, duration: float) -> void:
	_remove_status_icon(HELP_ICON_KEY)  # a fresh call restarts the clock
	var icon := _add_status_icon(HELP_ICON_KEY, sprite_path)
	if icon == null:
		return
	# Identity-checked, so an earlier call's timer can never take a later call's icon down with it.
	get_tree().create_timer(duration).timeout.connect(
		func() -> void:
			if _status_icons.get(HELP_ICON_KEY) == icon:
				_remove_status_icon(HELP_ICON_KEY))


func hide_help_call() -> void:
	_remove_status_icon(HELP_ICON_KEY)


## One icon in the status strip, animated by the _process loop when its sprite has frames.
## Null if `key` is already showing or the sprite won't load.
func _add_status_icon(key: Variant, sprite_path: String, tint := Color.WHITE) -> TextureRect:
	if _status_icons.has(key) or sprite_path.is_empty():
		return null
	var spr_data := AssetLoader.load_sprite(sprite_path)
	if spr_data.is_empty():
		return null
	var textures: Array = spr_data.get("textures", [])
	if textures.is_empty():
		return null
	var icon := TextureRect.new()
	icon.texture = textures[0]
	icon.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.custom_minimum_size = Vector2(40, 40)
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Additive blending via shader with optional tint
	var shader := Shader.new()
	shader.code = "shader_type canvas_item;\nrender_mode blend_add;\nuniform vec3 tint = vec3(1.0);\nvoid fragment() {\n\tvec4 tex = texture(TEXTURE, UV);\n\tCOLOR = vec4(tex.rgb * tint, tex.a);\n}\n"
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("tint", Vector3(tint.r, tint.g, tint.b))
	icon.material = mat
	_status_container.add_child(icon)
	_status_icons[key] = icon
	_status_textures[key] = textures
	_status_frame[key] = 0
	return icon


func _remove_status_icon(key: Variant) -> void:
	if not _status_icons.has(key):
		return
	var icon: TextureRect = _status_icons[key]
	if is_instance_valid(icon):
		icon.queue_free()
	_status_icons.erase(key)
	_status_textures.erase(key)
	_status_frame.erase(key)


## Show/hide + fill the persistent-plant health bar for `kind`
## ("beanstalk"/"thornplant"). hp/max_hp come from the authoritative plant.
func set_plant_indicator(kind: String, active: bool, hp: float = 0.0, max_hp: float = 0.0) -> void:
	var bar: BarWidget = _plant_bars.get(kind)
	if bar == null:
		return
	bar.root.visible = active
	if not active:
		return
	var ratio := bar.set_ratio(hp, max_hp, 1.0)
	# Redden as it drops so a dying plant reads at a glance
	bar.fill.color = bar.base_color.lerp(Color(0.85, 0.15, 0.1), 1.0 - ratio)
	bar.fill.color.a = 0.85
	bar.label.text = "%s %d" % [bar.caption, roundi(hp)]


func flash_damage() -> void:
	if _damage_tween:
		_damage_tween.kill()
	_damage_overlay.color.a = 0.3
	_damage_tween = create_tween()
	_damage_tween.tween_property(_damage_overlay, "color:a", 0.0, 0.3)


func flash_hit(lethal := false) -> void:
	# Crosshair flash: white for a hit, red and longer for the killing blow
	if _hit_tween:
		_hit_tween.kill()
	_hit_overlay.color = Color(1.0, 0.25, 0.15, 0.8) if lethal else Color(1.0, 1.0, 1.0, 0.6)
	_hit_tween = create_tween()
	_hit_tween.tween_property(_hit_overlay, "color:a", 0.0, 0.3 if lethal else 0.15)
	# Ding sound; the kill confirm reuses it pitched down (~480Hz) and louder,
	# which also stretches it — reads as a heavier "thunk" with no extra asset.
	if _hit_sound:
		var player := AudioStreamPlayer.new()
		player.stream = _hit_sound
		player.bus = SoundSystem.EFFECTS_BUS
		player.volume_db = 0.0 if lethal else -6.0
		player.pitch_scale = 0.55 if lethal else 1.0
		add_child(player)
		player.play()
		player.finished.connect(player.queue_free)


static func _create_hit_sound() -> AudioStream:
	var sample_rate := 22050
	var duration := 0.1
	var freq := 880.0
	var num_samples := int(sample_rate * duration)
	var audio := AudioStreamWAV.new()
	audio.format = AudioStreamWAV.FORMAT_16_BITS
	audio.mix_rate = sample_rate
	var data := PackedByteArray()
	data.resize(num_samples * 2)
	for i in num_samples:
		var t := float(i) / sample_rate
		var envelope := 1.0 - (t / duration)
		var sample := sin(t * freq * TAU) * envelope * 0.5
		var s16 := int(clampf(sample, -1.0, 1.0) * 32767)
		data[i * 2] = s16 & 0xFF
		data[i * 2 + 1] = (s16 >> 8) & 0xFF
	audio.data = data
	return audio


func show_message(text: String, channel: int, x: float, y: float,
		color: Color, fadein: float, fadeout: float, holdtime: float,
		_effect: int = 0) -> void:
	channel = clampi(channel, 0, NUM_CHANNELS - 1)
	var label := _labels[channel]

	if _tweens[channel]:
		_tweens[channel].kill()

	label.text = text
	label.self_modulate = color
	label.modulate.a = 0.0
	label.visible = true

	# Position: -1 = center, 0-1 = normalized screen position
	var vp_size := get_viewport().get_visible_rect().size
	if x < 0:
		label.position.x = 0
		label.size.x = vp_size.x
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	else:
		label.position.x = x * vp_size.x
		label.size.x = vp_size.x - label.position.x
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT

	if y < 0:
		label.position.y = vp_size.y * 0.35
		label.size.y = vp_size.y * 0.3
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	else:
		label.position.y = y * vp_size.y
		label.size.y = vp_size.y - label.position.y
		label.vertical_alignment = VERTICAL_ALIGNMENT_TOP

	# Animate: fade in → hold → fade out
	var tween := create_tween()
	if fadein > 0:
		tween.tween_property(label, "modulate:a", 1.0, fadein)
	else:
		label.modulate.a = 1.0
	tween.tween_interval(holdtime)
	if fadeout > 0:
		tween.tween_property(label, "modulate:a", 0.0, fadeout)
	else:
		tween.tween_callback(func(): label.modulate.a = 0.0)
	tween.tween_callback(func(): label.visible = false)
	_tweens[channel] = tween


## Show the newcomer's controls card. It's the same panel as the map description — one card at a
## time, the same key to move past it — with `then` (the map description) queued behind it.
func show_intro(body: String, then: Callable = Callable()) -> void:
	show_map_info(IntroGuide.TITLE, body, null, Vector2(-1, -1), IntroGuide.HOLD, then)


## Show the map's title + description. `title` is the map name; `body` is the
## raw text of maps/<map>.txt. `world_map` is the world briefing image from
## maps/<map>.ww (null if the map has none) and `marker` is the normalized
## 0..1 "you are here" position on it (negative = no marker). Auto-hides after
## `hold` seconds; a key/click also dismisses it (see _unhandled_input).
func show_map_info(title: String, body: String, world_map: Texture2D = null,
		marker: Vector2 = Vector2(-1, -1), hold: float = 12.0, then: Callable = Callable()) -> void:
	if _motd_then.is_valid():
		# A second card replacing this one still owes whatever was queued behind it.
		var pending := _motd_then
		_motd_then = Callable()
		pending.call()
	_motd_then = then
	_motd_title.text = title
	_motd_body.text = body
	_motd_scroll.scroll_vertical = 0
	_update_motd_world_map(world_map, marker)
	_motd_panel.visible = true
	_motd_panel.modulate.a = 0.0
	_motd_visible = true
	_apply_motd_cap(0.0)   # immediate estimate-based cap (before layout)
	_fit_motd_height()     # refine once the wrapped label has measured
	if _motd_tween:
		_motd_tween.kill()
	_motd_tween = create_tween()
	_motd_tween.tween_property(_motd_panel, "modulate:a", 1.0, 0.3)
	_motd_tween.tween_interval(hold)
	_motd_tween.tween_property(_motd_panel, "modulate:a", 0.0, 0.6)
	_motd_tween.tween_callback(_finish_motd)


## Configure the world-map strip of the MOTD panel: sized to the screen, with
## the cross centered on `marker` (normalized) and blinking at the original
## mod's 0.4s cadence.
func _update_motd_world_map(world_map: Texture2D, marker: Vector2) -> void:
	_motd_cross_timer.stop()
	if world_map == null:
		_motd_map.visible = false
		return
	var w := minf(get_viewport().get_visible_rect().size.y * 0.4, 560.0)
	var h := w * float(world_map.get_height()) / maxf(float(world_map.get_width()), 1.0)
	_motd_map.texture = world_map
	_motd_map.custom_minimum_size = Vector2(w, h)
	_motd_map.visible = true
	if marker.x >= 0.0 and marker.y >= 0.0 and _motd_cross.texture != null:
		var cross_size := maxf(roundf(w / 16.0), 16.0)
		_motd_cross.size = Vector2(cross_size, cross_size)
		_motd_cross.position = marker * Vector2(w, h) - _motd_cross.size * 0.5
		_motd_cross.visible = true
		_motd_cross_timer.start()
	else:
		_motd_cross.visible = false


## Cap the scroll area so the whole panel — world map included — ends by ~94%
## of the screen; tall descriptions scroll rather than overflow. `measured` is
## the laid-out label height (0 before layout); it's floored with a per-line
## estimate so a not-yet-wrapped label never collapses the scroll area to a
## single line.
func _apply_motd_cap(measured: float) -> void:
	if not is_instance_valid(_motd_scroll):
		return
	var vh := get_viewport().get_visible_rect().size.y
	# Fixed panel chrome around the scroll area: title, hint, separations,
	# and the stylebox content margins.
	var chrome := 120.0
	var max_h := vh * (0.94 - _motd_panel.anchor_top) - chrome
	if _motd_map.visible:
		max_h -= _motd_map.custom_minimum_size.y
	var line_h := _motd_body.get_theme_font_size("font_size") * 1.4
	max_h = maxf(max_h, line_h * 6.0)
	var est := float(_motd_body.text.count("\n") + 1) * line_h
	_motd_scroll.custom_minimum_size.y = minf(maxf(measured, est), max_h)


## Refine the cap with the true wrapped height once the label has laid out.
func _fit_motd_height() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	if is_instance_valid(_motd_scroll):
		_apply_motd_cap(_motd_body.size.y)


func hide_map_info() -> void:
	if not _motd_visible:
		return
	_motd_visible = false  # immediately, so keys during the fade don't restart it
	if _motd_tween:
		_motd_tween.kill()
	_motd_tween = create_tween()
	_motd_tween.tween_property(_motd_panel, "modulate:a", 0.0, 0.25)
	_motd_tween.tween_callback(_finish_motd)


## The single way the panel goes away, so whatever was queued behind it runs exactly once
## whether the player dismissed it or the hold ran out.
func _finish_motd() -> void:
	_motd_panel.visible = false
	_motd_visible = false
	_motd_cross_timer.stop()
	var then := _motd_then
	_motd_then = Callable()
	if then.is_valid():
		then.call()


func _unhandled_input(event: InputEvent) -> void:
	# While the map-info panel is up: wheel / arrow / page keys scroll it (and
	# cancel the auto-hide so it stays while reading); any other key or click
	# dismisses it. Dismiss doesn't consume the event, so the same press still
	# acts in-game (e.g. starting to move closes it).
	if not _motd_visible:
		return
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_motd_scroll_by(-60)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_motd_scroll_by(60)
		else:
			hide_map_info()
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_UP or event.keycode == KEY_PAGEUP:
			_motd_scroll_by(-80)
		elif event.keycode == KEY_DOWN or event.keycode == KEY_PAGEDOWN:
			_motd_scroll_by(80)
		else:
			hide_map_info()


func _motd_scroll_by(delta: int) -> void:
	# Keep the panel fully visible while the player is reading/scrolling.
	if _motd_tween:
		_motd_tween.kill()
		_motd_tween = null
	_motd_panel.modulate.a = 1.0
	_motd_scroll.scroll_vertical += delta
	get_viewport().set_input_as_handled()


## Pins the scoreboard up for the intermission. _process's Tab handling does the rest, so releasing
## Tab can't dismiss it and holding Tab doesn't fight it.
func set_intermission(active: bool) -> void:
	_intermission = active
	_stack_banners_around_board(active)
	if not active:
		set_vote(PackedStringArray(), PackedInt32Array())


## The pinned board owns the middle of the screen for the whole intermission, and it is built last
## so it draws over anything sharing that space. Both banners live there in normal play, so for the
## intermission they move out from under it — the result above, the ballot below. Their boxes hang
## off the board's own offsets, so the gaps hold if it is ever resized.
##
func _stack_banners_around_board(stacked: bool) -> void:
	if stacked:
		# The result gets a fixed box ending just above the board and sits at the bottom of it, so
		# a one-line result ("Draw") and a two-line one ("Blue wins! / Next map: …") both hang off
		# the board's top edge. The ballot grows down from just under it.
		var result_bottom: float = _scoreboard.offset_top - INTERMISSION_BANNER_GAP
		_place_banner(_center_label, 0.5, result_bottom - RESULT_BANNER_HEIGHT, result_bottom)
		_center_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
		var ballot_top: float = _scoreboard.offset_bottom + INTERMISSION_BANNER_GAP
		_place_banner(_vote_label, 0.5, ballot_top, ballot_top)
	else:
		_place_banner(_center_label, _center_message_y, 0.0, 0.0)
		_center_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
		_place_banner(_vote_label, _vote_y, 0.0, 0.0)


## The intermission ballot. Empty candidates take it down — a forced next map, or no rotation to
## choose from.
func set_vote(candidates: PackedStringArray, tallies: PackedInt32Array) -> void:
	if candidates.is_empty():
		_vote_label.visible = false
		return
	var lines: Array[String] = ["Vote for the next map — type /vote 1-%d" % candidates.size()]
	for i in candidates.size():
		var votes: int = tallies[i] if i < tallies.size() else 0
		lines.append("%d)  %s   %s" % [i + 1, candidates[i],
			"" if votes == 0 else ("1 vote" if votes == 1 else "%d votes" % votes)])
	_vote_label.text = "\n".join(lines)
	_vote_label.visible = true


## Time left in the match, or until the next map during an intermission. Hidden when neither is
## counting down — a server with no time limit shows no clock.
func _update_match_label() -> void:
	var left := MatchSystem.time_left()
	if left < 0.0:
		_match_label.visible = false
		_match_label_secs = -1
		return
	var secs := int(left)
	if secs == _match_label_secs and _match_label.visible:
		return
	_match_label_secs = secs
	var clock := MatchSystem.time_left_text()
	var color := CLOCK_COLOR
	if MatchSystem.is_intermission():
		_match_label.text = "Next map in %s" % clock
		color = CLOCK_INTERMISSION_COLOR
	else:
		_match_label.text = clock
		if secs <= CLOCK_WARNING_SECONDS:
			color = CLOCK_WARNING_COLOR  # the last minute goes red, like every clock that matters
	# Each override re-resolves the label's theme and re-shapes its text, so only on a real change.
	if color != _match_label_color:
		_match_label_color = color
		_match_label.add_theme_color_override("font_color", color)
	_match_label.visible = true


func show_center_message(text: String, color: Color = Color.WHITE, hold: float = 3.0, sound: bool = true) -> void:
	if _center_tween:
		_center_tween.kill()
	_center_label.text = text
	_center_label.add_theme_color_override("font_color", color)
	_center_label.visible = true
	_center_label.modulate.a = 0.0
	_center_tween = create_tween()
	_center_tween.tween_property(_center_label, "modulate:a", 1.0, 0.2)
	_center_tween.tween_interval(hold)
	_center_tween.tween_property(_center_label, "modulate:a", 0.0, 0.5)
	_center_tween.tween_callback(func(): _center_label.visible = false)
	if sound and _notify_sound:
		var player := AudioStreamPlayer.new()
		player.stream = _notify_sound
		player.bus = SoundSystem.EFFECTS_BUS
		player.volume_db = -3.0
		add_child(player)
		player.play()
		player.finished.connect(player.queue_free)


const TEAM_COLORS := {
	GameConsts.Team.BLUE: Color(0.2, 0.4, 0.9),
	GameConsts.Team.RED: Color(0.9, 0.2, 0.2),
	GameConsts.Team.YELLOW: Color(0.9, 0.8, 0.1),
	GameConsts.Team.GREEN: Color(0.2, 0.8, 0.3),
}

## Column stretch ratios: Team, Player, K, D, Ping
const _COL_RATIOS := [1.5, 3.0, 0.8, 0.8, 1.2, 0.6]

func _sb_label(text: String, color: Color, bold := false, align := HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var lbl := _make_label(17 if bold else 16, color)
	lbl.text = text
	lbl.horizontal_alignment = align
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return lbl


func _sb_row(cols: Array, colors: Array, bold := false) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 4)
	for i in cols.size():
		var align := HORIZONTAL_ALIGNMENT_LEFT if i <= 1 else HORIZONTAL_ALIGNMENT_RIGHT
		var lbl := _sb_label(str(cols[i]), colors[i], bold, align)
		lbl.size_flags_stretch_ratio = _COL_RATIOS[i]
		row.add_child(lbl)
	return row


func _sb_separator() -> HSeparator:
	var sep := HSeparator.new()
	sep.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sep.modulate = Color(1, 1, 1, 0.25)
	return sep


func _update_scoreboard() -> void:
	for child in _score_table.get_children():
		child.queue_free()

	# Team scores header row — one line per SIDE, not per team: ww_chasm's dragonrider teams are
	# allied with blue and red and have no score of their own to read.
	var header_row := HBoxContainer.new()
	header_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header_row.add_theme_constant_override("separation", 16)
	for group in GoalSystem.get_team_groups():
		var lead: int = group[0]
		var tc: Color = TEAM_COLORS.get(lead, Color.WHITE)
		var lbl := _sb_label("%s: %d" % [GoalSystem.get_team_name(lead),
			GoalSystem.get_group_score(group)], tc, true)
		lbl.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		header_row.add_child(lbl)
	_score_table.add_child(header_row)
	_score_table.add_child(_sb_separator())

	# Column headers
	var white := Color.WHITE
	_score_table.add_child(_sb_row(["Team", "Player", "K", "D", "Ping", "Q"],
		[white, white, white, white, white, white], true))
	_score_table.add_child(_sb_separator())

	# The scoreboard must list every player/bot regardless of PVS, so build from the PVS-independent
	# roster (the per-peer records), not just the puppet bodies in the local PVS — a client's bots
	# outside PVS have no body but must still show. Live bodies win for the team value (freshest).
	var peer_teams := {}  # pid -> team
	for pid: int in NetworkManager.peer_names():
		peer_teams[pid] = NetworkManager.get_player_team(pid)
	var roster := NetworkManager.player_roster()
	for pid in roster:
		var remote = roster[pid]
		peer_teams[pid] = remote.team if "team" in remote else 0
	if Game.local_player:
		peer_teams[Game.local_player.peer_id] = Game.local_player.team
	var peers: Array = []
	for pid in peer_teams:
		peers.append([pid, peer_teams[pid]])
	peers.sort_custom(func(a, b): return a[1] * 100000 + a[0] < b[1] * 100000 + b[0])

	# Player rows
	for p in peers:
		var pid: int = p[0]
		var t: int = p[1]
		# pid == 0 is invalid; negative ids are bots (no ENet peer) and SHOULD be listed.
		if pid == 0:
			continue
		# Skip the dedicated-server peer-1 puppet (no body, no name registered); a listen-server
		# host also occupies peer 1 but DOES register a name, which is the discriminator.
		if pid == 1 and not NetworkManager.has_player_name(1):
			continue
		# Team NONE (hasn't picked yet, or a deathmatch map) is its own state, not a team: plain
		# white and no team name, never a team colour someone could read as a membership they
		# don't have.
		var tc: Color = TEAM_COLORS.get(t, Color.WHITE)
		var tname := "—"
		if t >= 1 and t <= 4:
			tname = GoalSystem.get_team_name(t)
		var ping := NetworkManager.get_peer_ping(pid)
		var ping_str := "%dms" % ping if ping >= 0 else "—"
		var ping_color := Color(0.0, 0.8, 0.27) if ping <= 50 else (Color(0.87, 0.87, 0.0) if ping <= 100 else Color(1.0, 0.27, 0.27))
		if ping < 0:
			ping_color = Color(0.6, 0.6, 0.6)
		var qdepth := NetworkManager.get_peer_queue_depth(pid)
		var q_str := str(qdepth) if qdepth >= 0 else "—"
		var q_color: Color
		if qdepth < 0:
			q_color = Color(0.6, 0.6, 0.6)
		elif qdepth <= 3:
			q_color = Color(0.0, 0.8, 0.27)
		elif qdepth <= 15:
			q_color = Color(0.87, 0.87, 0.0)
		else:
			q_color = Color(1.0, 0.27, 0.27)
		_score_table.add_child(_sb_row(
			[tname, _peer_name(pid), GoalSystem.get_kills(pid), GoalSystem.get_deaths(pid), ping_str, q_str],
			[tc, tc, Color.WHITE, Color.WHITE, ping_color, q_color]))

	# PVS culling stats — only meaningful on a remote client
	if not multiplayer.is_server():
		_score_table.add_child(_sb_separator())
		var vis_count := NetworkManager.pvs_visible
		var total := NetworkManager.pvs_total
		var pct := int(100.0 * vis_count / total) if total > 0 else 0
		var pvs_color := Color(0.4, 1.0, 0.4) if pct < 60 else Color(1.0, 0.87, 0.4)
		_score_table.add_child(_sb_label(
			"Network PVS: %d / %d entities (%d%% culled)" % [vis_count, total, 100 - pct],
			pvs_color))
		var vis_info: String = VisibilitySystem.get_debug_info()
		var vis_color := Color(0.4, 1.0, 0.4) if vis_info.begins_with("Client PVS: leaf=") else Color(1.0, 0.5, 0.3)
		_score_table.add_child(_sb_label(vis_info, vis_color))


func _peer_name(pid: int) -> String:
	if pid == multiplayer.get_unique_id():
		return "You"
	return NetworkManager.display_name(pid)


func _on_kill(killer_peer: int, victim_peer: int) -> void:
	var text: String
	# peer 0 is the world/environment (fall/lava). Bots use negative peer ids and DO get
	# credit, so gate on != 0, not > 0 (matches GoalSystem.record_kill).
	if killer_peer != 0 and killer_peer != victim_peer:
		text = "%s killed %s" % [_peer_name(killer_peer), _peer_name(victim_peer)]
	else:
		text = "%s died" % _peer_name(victim_peer)

	var entry := _make_label(16, Color(1, 0.85, 0.85))
	entry.text = text
	entry.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_kill_feed.add_child(entry)

	# Fade out and remove after 5 seconds
	var tween := create_tween()
	tween.tween_interval(4.0)
	tween.tween_property(entry, "modulate:a", 0.0, 1.0)
	tween.tween_callback(entry.queue_free)

	# Cap visible entries
	while _kill_feed.get_child_count() > 6:
		var oldest := _kill_feed.get_child(0)
		_kill_feed.remove_child(oldest)
		oldest.queue_free()


func show_fade(color: Color, duration: float, holdtime: float, reverse: bool) -> void:
	if _fade_tween:
		_fade_tween.kill()
	_fade_overlay.color = Color(color.r, color.g, color.b, 0.0 if not reverse else color.a)
	_fade_overlay.visible = true
	_fade_tween = create_tween()
	if reverse:
		# Start at full color, hold, then fade out
		_fade_tween.tween_interval(holdtime)
		_fade_tween.tween_property(_fade_overlay, "color:a", 0.0, duration)
	else:
		# Fade in to full color, hold, then fade out
		_fade_tween.tween_property(_fade_overlay, "color:a", color.a, duration)
		_fade_tween.tween_interval(holdtime)
		_fade_tween.tween_property(_fade_overlay, "color:a", 0.0, duration)
	_fade_tween.tween_callback(func(): _fade_overlay.visible = false)


func set_render_debug_visible(enabled: bool) -> void:
	_render_debug_label.visible = enabled


func _update_render_debug_label() -> void:
	if not _render_debug_label.visible:
		return
	var objects := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME)
	var primitives := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
	var draw_calls := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
	_render_debug_label.text = "objects: %d\nprimitives: %d\ndraw calls: %d" % [objects, primitives, draw_calls]


func set_pos_visible(enabled: bool) -> void:
	_pos_label.visible = enabled


## Live position readout (/pos). GoldSrc units are the useful half: entity "origin" keys
## in the .bsp/.map are in that space, so the number can be compared straight to map data.
func _update_pos_label() -> void:
	if not _pos_label.visible:
		return
	var player := _debug_local_player()
	if not player:
		_pos_label.text = "pos: —"
		return
	var p := player.global_position
	var g := GoldSrcEntity.to_goldsrc(p)
	_pos_label.text = "pos: %.1f %.1f %.1f\ngoldsrc: %.0f %.0f %.0f" % [p.x, p.y, p.z, g.x, g.y, g.z]


## Local player node, cached. Only walked while a debug readout is up.
func _debug_local_player() -> Node3D:
	if is_instance_valid(_debug_player_ref):
		return _debug_player_ref
	_debug_player_ref = Game.local_player
	return _debug_player_ref


func _update_perf_label() -> void:
	var fps := Engine.get_frames_per_second()
	var color := Color(0.8, 0.8, 0.8)
	if NetworkManager.is_online():
		var ping := NetworkManager.net_ping_ms
		if ping > 100:
			color = Color(1.0, 0.35, 0.35)
		elif ping > 50:
			color = Color(1.0, 1.0, 0.35)
		else:
			color = Color(0.35, 1.0, 0.35)
		_perf_label.text = "%d fps  %dms" % [fps, ping]
	else:
		_perf_label.text = "%d fps" % fps
	# Each override re-resolves the theme and re-shapes the text, so only on a real change.
	if color != _perf_label_color:
		_perf_label_color = color
		_perf_label.add_theme_color_override("font_color", color)


func is_chat_open() -> bool:
	return _chat_input_container.visible


func open_chat_input(team_only: bool, prefill: String = "") -> void:
	if _chat_input_container.visible:
		return
	_chat_team_only = team_only
	_chat_input_prefix.text = "(Team) Say:" if team_only else "Say:"
	_chat_input.text = prefill
	_chat_input_container.visible = true
	_chat_input.grab_focus()
	_chat_input.set_caret_column(_chat_input.text.length())
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _close_chat_input() -> void:
	_chat_input_container.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _on_chat_text_submitted(text: String) -> void:
	_close_chat_input()
	text = text.strip_edges()
	if not text.is_empty():
		chat_submitted.emit(text, _chat_team_only)


func _on_chat_input_gui_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_close_chat_input()
		get_viewport().set_input_as_handled()


func add_chat_message(sender_name: String, message: String, is_team: bool, team_color: Color) -> void:
	var entry := _make_label(14, team_color)
	var prefix := "(Team) " if is_team else ""
	entry.text = "%s%s: %s" % [prefix, sender_name, message]
	entry.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_chat_log.add_child(entry)

	# Fade out after 8 seconds
	var tween := create_tween()
	tween.tween_interval(6.0)
	tween.tween_property(entry, "modulate:a", 0.0, 2.0)
	tween.tween_callback(entry.queue_free)

	# Cap at 6 visible entries
	while _chat_log.get_child_count() > 6:
		var oldest := _chat_log.get_child(0)
		_chat_log.remove_child(oldest)
		oldest.queue_free()


## Who is talking, just above the chat log. `transmitting` is the channel this player's key has
## open ("" when silent), which is what makes a microphone that never opened visible rather than
## mysterious; `talkers` is everyone currently being heard.
func set_voice_status(transmitting: String, talkers: PackedStringArray) -> void:
	if _voice_label == null:
		return
	var parts := PackedStringArray()
	if not transmitting.is_empty():
		parts.append("MIC: %s" % transmitting)
	if not talkers.is_empty():
		parts.append(", ".join(talkers))
	_voice_label.visible = not parts.is_empty()
	if _voice_label.visible:
		_voice_label.text = "   ".join(parts)


## Reparent the in-world widgets into a SubViewport for display on a 3D VR panel; the rest
## (perf label, scoreboard, crosshair, overlays, center message, net alert) stay on this
## CanvasLayer. update_*/flash_* calls keep working since they act on the same Control instances.
func move_to_vr_panel(viewport: SubViewport) -> void:
	for ctrl in [_bar_container, _weapon_row, _status_container,
			_damage_overlay, _kill_feed, _voice_label, _chat_log, _chat_input_container]:
		ctrl.get_parent().remove_child(ctrl)
		viewport.add_child(ctrl)


## Polled from _process: the siege has no HUD push of its own, and the altar's health arrives on
## the entity snapshot rather than as a message, so reading both once a frame is the simple path.
func _update_siege() -> void:
	if not SiegeSystem.active:
		if _siege_label.visible:
			set_siege_status(false, 0, 0, 0.0, 0.0, -1.0)
		return
	var a := SiegeSystem.altar_node()
	var hp := float(a.get("health")) if a else 0.0
	var max_hp := float(a.get("max_health")) if a else 1.0
	set_siege_status(true, SiegeSystem.wave, SiegeSystem.WAVE_COUNT, hp, max_hp,
			SiegeSystem.build_time_left())


## Siege status: which wave, and how the altar is holding. `wave` 0 during the opening break.
## Call with active=false to put both away — every other mode never sees them.
func set_siege_status(active: bool, wave: int, total: int, hp: float, max_hp: float,
		break_left: float) -> void:
	_siege_label.visible = active
	_siege_bar.root.visible = active
	if not active:
		return
	if break_left >= 0.0:
		_siege_label.text = ("Wave %d in %ds" % [wave + 1, int(ceil(break_left))]) if wave < total \
				else "Holding"
	else:
		_siege_label.text = "Wave %d / %d" % [wave, total]
	var frac := _siege_bar.set_ratio(hp, maxf(max_hp, 1.0))
	# Blue while healthy, red as it goes — the bar should be readable without reading the number.
	_siege_bar.fill.color = _siege_bar.base_color.lerp(Color(0.95, 0.3, 0.25), 1.0 - frac)
	_siege_bar.label.text = "%s  %d%%" % [_siege_bar.caption, int(round(frac * 100.0))]
