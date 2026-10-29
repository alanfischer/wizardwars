class_name LightEntity
extends EntityBase
# GoldSrc "light" / "light_spot" entity — controls BSP lightmap brightness via
# lightstyle indices and creates a Godot OmniLight3D/SpotLight3D so that non-brush
# models (flags, items, players) receive dynamic lighting.
#
# Updates a shared 64×1 lightstyle texture directly from GDScript (shader path).
# Falls back to C++ set_lightstyle() if the texture isn't available.

# Standard Half-Life lightstyle patterns (a=dark, z=bright, m=normal)
const LIGHTSTYLE_PATTERNS := {
	0: "m",                                           # normal
	1: "mmnmmommommnonmmonqnmmo",                     # flicker 1
	2: "abcdefghijklmnopqrstuvwxyzyxwvutsrqponmlkjihgfedcba", # slow strong pulse
	3: "mmmmmaaaaammmmmaaaaaabcdefgabcdefg",           # candle 1
	4: "mamamamamama",                                 # fast strobe
	5: "jklmnopqrstuvwxyzyxwvutsrqponmlkj",           # gentle pulse
	6: "nmonqnmomnmomomno",                           # flicker 2
	7: "mmmaaaabcdefgmmmmaaaammmaamm",                 # candle 2
	8: "mmmaaammmaaammmabcdefaaaammmmabcdefmmmaaaa",   # candle 3
	9: "aaaaaaaazzzzzzzz",                             # slow strobe
	10: "mmamammmmammamamaaamammma",                   # fluorescent
	11: "abcdefghijklmnopqrrqponmlkjihgfedcba",       # slow pulse (not fading to black)
}

const SF_START_OFF := 1

var _style: int = 0
var _pattern: String = "m"
var _pattern_time: float = 0.0
var _is_on: bool = true
var _initial_is_on: bool = true
var _ls_image: Image = null
var _ls_texture: ImageTexture = null
var _bsp: Node = null  # fallback for legacy C++ path
var _light_node: Light3D = null
var _base_energy: float = 1.0


func _ready() -> void:
	super()
	_register_for_sync()
	_style = parse_int(ent, "style", 0)
	var spawnflags := parse_spawnflags(ent)
	var scene := get_tree().current_scene
	_ls_image = scene.get("lightstyle_image") if scene else null
	_ls_texture = scene.get("lightstyle_texture") if scene else null
	if not _ls_image:
		_bsp = scene.get("_bsp") if scene else null

	if LIGHTSTYLE_PATTERNS.has(_style):
		_pattern = LIGHTSTYLE_PATTERNS[_style]

	_create_light_node()

	if spawnflags & SF_START_OFF:
		_is_on = false
		_set_lightstyle(0.0)
		set_process(false)
	else:
		set_process(_pattern.length() > 1)  # animated styles need per-frame updates

	_initial_is_on = _is_on


func trigger(_activator: Node, type: TriggerSystem.Type) -> void:
	match type:
		TriggerSystem.Type.ON: _is_on = true
		TriggerSystem.Type.OFF: _is_on = false
		TriggerSystem.Type.TOGGLE: _is_on = not _is_on
	_set_lightstyle(1.0 if _is_on else 0.0)
	set_process(_is_on and _pattern.length() > 1)
	_sync_notify()


func _get_sync_state() -> Dictionary:
	var state := super._get_sync_state()
	if _state_dirty or _is_on != _initial_is_on:
		state["light_style"] = GoldSrcEntity.encode_lightstyle_on_off(_is_on)
	return state


func _apply_sync_state(state: Dictionary) -> void:
	super._apply_sync_state(state)
	if "light_style" in state:
		set_light_style(state["light_style"])


func set_light_style(style_char: String) -> void:
	if style_char.is_empty():
		return
	var intensity := GoldSrcEntity.decode_lightstyle_char(style_char)
	_is_on = intensity > 0.0
	_set_lightstyle(intensity)
	set_process(false)
	_sync_notify()


func _process(delta: float) -> void:
	_pattern_time += delta * 10.0  # ~10 chars per second (HL convention)
	var idx := int(_pattern_time) % _pattern.length()
	var char_val := GoldSrcEntity.decode_lightstyle_char(_pattern[idx])
	_set_lightstyle(char_val)


func _create_light_node() -> void:
	var classname: String = ent.get("classname", "light")

	# Parse _light property: "R G B [brightness]" (0-255)
	var light_color := Color.WHITE
	var brightness_gs := 200.0  # default GoldSrc brightness
	if ent.has("_light"):
		var parts := str(ent["_light"]).split(" ")
		if parts.size() >= 3:
			var r := float(parts[0]) / 255.0
			var g := float(parts[1]) / 255.0
			var b := float(parts[2]) / 255.0
			if parts.size() >= 4 and float(parts[3]) > 0.0:
				brightness_gs = float(parts[3])
			else:
				brightness_gs = 300.0
			light_color = Color(r, g, b)

	# Normalize color and extract peak for energy
	var peak := maxf(light_color.r, maxf(light_color.g, light_color.b))
	if peak > 0.0:
		light_color = Color(light_color.r / peak, light_color.g / peak, light_color.b / peak)

	# Range: GoldSrc brightness roughly equals effective range in GoldSrc units
	var range_godot: float = brightness_gs * GameConsts.SCALE_FACTOR

	if classname == "light_spot":
		var spot := SpotLight3D.new()
		spot.spot_range = range_godot
		spot.spot_angle = parse_float(ent, "_cone2", 45.0)
		spot.rotation = parse_angles(ent)
		_light_node = spot
	else:
		var omni := OmniLight3D.new()
		omni.omni_range = range_godot
		omni.omni_attenuation = 1.5
		_light_node = omni

	_light_node.light_color = light_color
	_base_energy = peak * (brightness_gs / 300.0)
	_light_node.light_energy = _base_energy
	_light_node.shadow_enabled = false
	_light_node.light_bake_mode = Light3D.BAKE_DISABLED
	# style=0 + start-off means no lightstyle channel: OmniLight3D is the only BSP effect
	# when toggled on, so hit the BSP geometry layer too (same as weapon lights).
	var no_baked_channel := _style == 0 and bool(parse_spawnflags(ent) & SF_START_OFF)
	_light_node.light_cull_mask = GameConsts.LIGHT_CULL_ALL if no_baked_channel else GameConsts.VISUAL_LAYER_DEFAULT
	add_child(_light_node)


func _set_lightstyle(brightness: float) -> void:
	if _light_node:
		_light_node.light_energy = _base_energy * brightness if _style > 0 else (
			_base_energy if brightness > 0.0 else 0.0)
	if _style <= 0:
		return
	if _ls_image and _ls_texture:
		# Shader path: update pixel in shared 64×1 brightness texture
		_ls_image.set_pixel(_style, 0, Color(brightness, 0, 0, 1))
		_ls_texture.update(_ls_image)
	elif _bsp:
		# Legacy C++ fallback
		_bsp.set_lightstyle(_style, brightness)
