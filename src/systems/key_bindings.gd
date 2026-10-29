extends Object
## Key bindings — the [binds] section of settings.cfg, alongside the renderer, picture quality,
## mouse and net settings, one section per owner:
##
##     [binds]
##     jump="Space"
##     slot1="Kp 1"
##     attack="Mouse 1"
##     callhelp=""
##
## Only *overrides* are written. The shipped defaults live in project.godot's [input] section,
## which is where a bind that nobody has touched still comes from, so deleting settings.cfg puts
## every control back to stock. An empty string is a deliberate unbind, which is why it is stored
## rather than simply left out.
##
## Keys are named by their PHYSICAL position — "W" means the key where W sits on a US keyboard,
## which on AZERTY is the one engraved Z. That is what the game has always bound (project.godot
## stores physical_keycode) and it keeps WASD a shape rather than four letters; display_for() is
## what turns a stored name into the letter actually printed on the player's keyboard. Two
## consequences worth knowing: the file reads in US names, and a name for a key whose OS label
## differs between platforms (macOS calls Alt "Option") will not carry to another machine — it
## falls back to the default rather than failing.
##
## No class_name — preloaded by its consumers; see README, "class_name and preload".

const SETTINGS_PATH := "user://settings.cfg"  # shared with LobbyUI, InputSettings, RenderQuality
const SECTION := "binds"

## Every rebindable control, grouped and ordered the way the menu lists them. The labels are what
## the player reads, so they describe the act ("Cast", "Call For Help"), not the action name.
##
## Deliberately not here: Escape, which is the way out of the menu and out of a capture, and the
## F-key developer toggles, which are not controls anyone plays with.
const GROUPS := [
	["Moving", [
		["move_forward", "Forward"],
		["move_back", "Back"],
		["move_left", "Strafe Left"],
		["move_right", "Strafe Right"],
		["jump", "Jump"],
		["crouch", "Duck"],
		["walk", "Walk Slowly"],
	]],
	["Casting", [
		["attack", "Cast"],
		["attack2", "Second Mode"],
		["satchel", "Satchel"],
		["weapon_prev", "Previous Spell"],
		["weapon_next", "Next Spell"],
		["lastweapon", "Last Spell"],
		["slot1", "Spell 1"],
		["slot2", "Spell 2"],
		["slot3", "Spell 3"],
		["slot4", "Spell 4"],
		["slot5", "Spell 5"],
		["slot6", "Spell 6"],
		["slot7", "Spell 7"],
		["slot8", "Spell 8"],
		["slot9", "Spell 9"],
	]],
	["Talking", [
		["use", "Use"],
		["callhelp", "Call For Help"],
		["scoreboard", "Scoreboard"],
		["chat", "Chat"],
		["chat_team", "Team Chat"],
		["voice_all", "Voice"],
		["voice_team", "Team Voice"],
		["console", "Command"],
		["team_menu", "Team Menu"],
		["class_menu", "Wizard Menu"],
	]],
]

## How many spell slots have a key of their own. The wheel and Last Spell reach the rest.
const SLOT_COUNT := 9

## Mouse buttons have no OS name, so they get these. Everything else is a key and is named by
## OS.get_keycode_string(), which round-trips through OS.find_keycode_from_string() and ignores
## case — so "wheel up" and "Wheel Up" both parse, and so does "mouse1" (spaces are squeezed out
## before the comparison, for typing one at the console).
const MOUSE_NAMES := {
	MOUSE_BUTTON_LEFT: "Mouse 1",
	MOUSE_BUTTON_RIGHT: "Mouse 2",
	MOUSE_BUTTON_MIDDLE: "Mouse 3",
	MOUSE_BUTTON_WHEEL_UP: "Wheel Up",
	MOUSE_BUTTON_WHEEL_DOWN: "Wheel Down",
	MOUSE_BUTTON_WHEEL_LEFT: "Wheel Left",
	MOUSE_BUTTON_WHEEL_RIGHT: "Wheel Right",
	MOUSE_BUTTON_XBUTTON1: "Mouse 4",
	MOUSE_BUTTON_XBUTTON2: "Mouse 5",
}

## Shown where a control has no key at all.
const UNBOUND := "—"

## The project defaults, read out of the InputMap before the first override touches it. Static, so
## every preload of this script shares one copy; populated once by ensure_applied().
static var _defaults: Dictionary = {}  # action -> Array[InputEvent]
static var _applied := false


## Put the saved overrides into the InputMap. Safe to call from anywhere and at any depth — the
## first call does the work, and it is the first call that snapshots the defaults, so nothing can
## capture an InputMap that has already been overridden.
static func ensure_applied() -> void:
	if _applied:
		return
	_applied = true
	for action in actions():
		if InputMap.has_action(action):
			_defaults[action] = InputMap.action_get_events(action).duplicate()
		else:
			push_warning("KeyBindings: no such input action '%s'" % action)
	for action in actions():
		_apply(action)


## Every bindable action, flattened out of GROUPS in menu order.
static func actions() -> Array[String]:
	var out: Array[String] = []
	for group in GROUPS:
		for entry in group[1]:
			out.append(entry[0])
	return out


## The player-facing name of a control, or the raw action for one not in GROUPS.
static func label_for(action: String) -> String:
	for group in GROUPS:
		for entry in group[1]:
			if entry[0] == action:
				return entry[1]
	return action


## The keys currently bound to a control, in stored (US-physical) names.
static func names_for(action: String) -> PackedStringArray:
	ensure_applied()
	var out := PackedStringArray()
	if not InputMap.has_action(action):
		return out
	for event in InputMap.action_get_events(action):
		var nm := event_to_name(event)
		if not nm.is_empty():
			out.append(nm)
	return out


## What to print for a control: the keys as engraved on this player's keyboard, or UNBOUND.
static func display_for(action: String) -> String:
	var parts := PackedStringArray()
	for nm in names_for(action):
		parts.append(display_name(nm))
	return " / ".join(parts) if parts.size() > 0 else UNBOUND


## Bind `event` to `action`, replacing whatever was there, and save it. A key already spoken for
## is taken from its previous owner rather than refused — a menu that can only reject leaves no
## way to swap two controls around — and the actions it was taken from are returned so the caller
## can say so. Returns an empty array when nothing was displaced; see is_bindable() for the events
## this will not accept.
static func set_binding(action: String, event: InputEvent) -> PackedStringArray:
	ensure_applied()
	var stolen := PackedStringArray()
	var name := event_to_name(event)
	if name.is_empty() or not InputMap.has_action(action):
		return stolen
	for other in actions():
		if other == action:
			continue
		if names_for(other).has(name):
			stolen.append(other)
			_store(other, PackedStringArray())
	_store(action, PackedStringArray([name]))
	return stolen


## Leave a control with no key at all. Reachable from the menu with Delete and from /unbind; the
## unbind is stored, so it survives rather than reverting to the default on the next run.
static func clear_binding(action: String) -> void:
	ensure_applied()
	if InputMap.has_action(action):
		_store(action, PackedStringArray())


## Put one control back to what the game shipped with, dropping its override.
static func reset(action: String) -> void:
	ensure_applied()
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	if cfg.has_section_key(SECTION, action):
		cfg.erase_section_key(SECTION, action)
		cfg.save(SETTINGS_PATH)
	_apply(action)


## Put every control back, leaving the rest of settings.cfg alone.
static func reset_all() -> void:
	ensure_applied()
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	if cfg.has_section(SECTION):
		cfg.erase_section(SECTION)
		cfg.save(SETTINGS_PATH)
	for action in actions():
		_apply(action)


## Whether a control has been moved off its shipped key.
static func is_overridden(action: String) -> bool:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return false
	return cfg.has_section_key(SECTION, action)


## Which events the menu will take. Escape is the only key held back, and for a practical reason
## rather than a stylistic one: it closes the menu, cancels a capture and frees the mouse, so a
## player who bound it to Jump would have no way to reach this screen and undo it. Mouse motion,
## controller and touch events are not keys and cannot be stored.
static func is_bindable(event: InputEvent) -> bool:
	if event is InputEventKey:
		return _key_code(event as InputEventKey) != KEY_ESCAPE
	if event is InputEventMouseButton:
		return MOUSE_NAMES.has((event as InputEventMouseButton).button_index)
	return false


## The stored name of an event, or "" for one that cannot be bound.
static func event_to_name(event: InputEvent) -> String:
	if event is InputEventMouseButton:
		return MOUSE_NAMES.get((event as InputEventMouseButton).button_index, "")
	if event is InputEventKey:
		var code := _key_code(event as InputEventKey)
		return OS.get_keycode_string(code) if code != KEY_NONE else ""
	return ""


## The event a stored name refers to, or null if it names nothing this build knows. Case and
## spacing are ignored, so a hand-edited "wheelup" and a menu-written "Wheel Up" are one key.
static func name_to_event(name: String) -> InputEvent:
	var wanted := _squash(name)
	if wanted.is_empty():
		return null
	for button_index in MOUSE_NAMES:
		if _squash(MOUSE_NAMES[button_index]) == wanted:
			var mb := InputEventMouseButton.new()
			mb.button_index = button_index
			return mb
	var code := OS.find_keycode_from_string(name.strip_edges())
	if code == KEY_NONE:
		return null
	var key := InputEventKey.new()
	key.physical_keycode = code
	return key


## A stored name as it reads on this player's keyboard: "W" stays "W" on QWERTY and becomes "Z"
## on AZERTY, because the binding is a position. Mouse names and anything the display server
## cannot translate are passed through unchanged.
static func display_name(name: String) -> String:
	var code := OS.find_keycode_from_string(name.strip_edges())
	if code == KEY_NONE:
		return name
	# Unsupported on the headless server the test suites and the dedicated server run on, where
	# there is no keyboard to ask and the physical name is the only one there is.
	if DisplayServer.get_name() == "headless":
		return name
	var local := DisplayServer.keyboard_get_keycode_from_physical(code)
	return OS.get_keycode_string(local) if local != KEY_NONE else name


## Write one control's binding and push it into the InputMap. The default is stored as an absence
## so that a later change to what the game ships with reaches players who never touched that key.
static func _store(action: String, names: PackedStringArray) -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)  # load existing; OK if missing
	if _is_default(action, names):
		if cfg.has_section_key(SECTION, action):
			cfg.erase_section_key(SECTION, action)
	else:
		cfg.set_value(SECTION, action, ", ".join(names))
	cfg.save(SETTINGS_PATH)
	_apply(action)


static func _is_default(action: String, names: PackedStringArray) -> bool:
	var default := PackedStringArray()
	for event in _defaults.get(action, []):
		var nm := event_to_name(event)
		if not nm.is_empty():
			default.append(nm)
	return default == names


static func _apply(action: String) -> void:
	if not InputMap.has_action(action):
		return
	var stored: Variant = _load_raw(action)
	InputMap.action_erase_events(action)
	if stored == null:
		for event in _defaults.get(action, []):
			InputMap.action_add_event(action, event)
		return
	for name in String(stored).split(",", false):
		var event := name_to_event(name)
		if event:
			InputMap.action_add_event(action, event)


## The stored override, or null for a control nobody has rebound. An empty string is a real
## value — the player unbound it — so this cannot collapse the two into one default.
static func _load_raw(action: String) -> Variant:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return null
	if not cfg.has_section_key(SECTION, action):
		return null
	return cfg.get_value(SECTION, action)


static func _key_code(event: InputEventKey) -> int:
	# physical_keycode is what the project binds and what a captured event carries; keycode is the
	# fallback for the odd device that reports no scancode at all.
	return event.physical_keycode if event.physical_keycode != KEY_NONE else event.keycode


static func _squash(text: String) -> String:
	return text.strip_edges().to_lower().replace(" ", "")
