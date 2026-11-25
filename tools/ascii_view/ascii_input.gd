extends Node
## Terminal keys as game input. The wrapper appends raw tty bytes to a file; this turns them into
## the InputEventActions and mouse motion the game already reads.
##
## A terminal sends no key-up, only the OS key repeat, so a key is "held" while its bytes keep
## coming: through the repeat delay after the first one, then through a couple of repeat
## intervals after each later one. Only the last key pressed repeats, so movement keys can latch
## to make running and turning at once possible.

var keys_path := ""
var repeat_delay := 0.375
var repeat_interval := 0.09

var _bindings := {}
var _look_speed := 1000.0
var _look_nudge := 40.0
var _offset := 0
var _pending := PackedByteArray()
var _clock := 0.0
var _held := {}
var _latched := {}


func setup(play: Dictionary) -> void:
	_bindings = play.get("keys", {})
	_look_speed = play.get("look_speed", _look_speed)
	_look_nudge = play.get("look_nudge", _look_nudge)


## Short labels for what is held or latched, for the status line.
func status() -> String:
	var out := PackedStringArray()
	for key: String in _latched:
		out.append(key.to_upper() + "*")
	for key: String in _held:
		if not _latched.has(key):
			out.append(key.to_upper() if key.length() == 1 else key)
	return " ".join(out)


func _process(delta: float) -> void:
	_clock += delta
	for key in _read_keys():
		_on_key(key)
	var look := Vector2.ZERO
	for key: String in _held.keys():
		var h: Dictionary = _held[key]
		var window := repeat_delay + 0.12 if h.count == 1 else repeat_interval * 2.0 + 0.04
		if _clock - h.at > window:
			_held.erase(key)
			if not _latched.has(key):
				_release(key)
			continue
		var b: Variant = _bindings.get(key)
		if b is Dictionary and b.has("look") and h.count > 1:
			look += Vector2(b.look[0], b.look[1]) * _look_speed * delta
	if look != Vector2.ZERO:
		_move_mouse(look)


func _on_key(key: String) -> void:
	if key == "\u0003":
		get_tree().quit()
		return
	key = key.to_lower() if key.length() == 1 else key
	var b: Variant = _bindings.get(key)
	if b == null:
		return
	var fresh := not _held.has(key)
	_held[key] = {"at": _clock, "count": 1 if fresh else _held[key].count + 1}
	if not fresh:
		return
	if b is Dictionary and b.has("look"):
		_move_mouse(Vector2(b.look[0], b.look[1]) * _look_nudge)
		return
	if b is Dictionary and b.get("latch", false):
		if _latched.has(key):
			_latched.erase(key)
			_release(key)
			return
		for other: String in _latched.keys():
			if _action_of(other) == b.get("opposite", ""):
				_latched.erase(other)
				_release(other)
		_latched[key] = true
	_send(_action_of(key), true)


func _release(key: String) -> void:
	_send(_action_of(key), false)


func _action_of(key: String) -> String:
	var b: Variant = _bindings.get(key)
	if b is Dictionary:
		return b.get("action", "")
	return b if b is String else ""


func _send(action: String, pressed: bool) -> void:
	if action == "" or not InputMap.has_action(action):
		return
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = pressed
	ev.strength = 1.0 if pressed else 0.0
	Input.parse_input_event(ev)


func _move_mouse(relative: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	ev.relative = relative
	ev.screen_relative = relative
	Input.parse_input_event(ev)


## New keys since the last frame: single characters, or UP/DOWN/LEFT/RIGHT for the arrows.
func _read_keys() -> PackedStringArray:
	var out := PackedStringArray()
	var f := FileAccess.open(keys_path, FileAccess.READ)
	if f == null:
		return out
	var size := f.get_length()
	if size > _offset:
		f.seek(_offset)
		_pending.append_array(f.get_buffer(size - _offset))
		_offset = size
	var i := 0
	while i < _pending.size():
		var c := _pending[i]
		if c == 0x1b:
			if i + 2 >= _pending.size():
				break
			if _pending[i + 1] == 0x5b:
				var arrow := {0x41: "UP", 0x42: "DOWN", 0x43: "RIGHT", 0x44: "LEFT"}
				if arrow.has(_pending[i + 2]):
					out.append(arrow[_pending[i + 2]])
				i += 3
				continue
			i += 1
			continue
		out.append(char(c))
		i += 1
	_pending = _pending.slice(i)
	return out
