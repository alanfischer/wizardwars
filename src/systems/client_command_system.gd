## Client-side command dispatcher. Commands here run entirely locally — nothing reaches
## the server. Other nodes may call register()/unregister() to add commands tied to
## their own lifetime.
extends Node

const REPLY_COLOR_OK  := Color(0.55, 0.85, 1.0)
const REPLY_COLOR_ERR := Color(1.0, 0.5, 0.4)

const KeyBindings = preload("res://src/systems/key_bindings.gd")

var _commands: Dictionary = {}  # name -> {callable, usage, help}


func _ready() -> void:
	_register("help",        _cmd_help,        "/help",                                       "List client commands. Also shows server commands if online.")
	_register("sim_latency", _cmd_sim_latency, "/sim_latency <min,max | fixed_ms | 0>",       "Set simulated per-leg send latency in ms on this endpoint. 0 disables.")
	_register("sim_loss",    _cmd_sim_loss,    "/sim_loss <0-100>",                           "Set simulated packet loss % (unreliable sends) on this endpoint.")
	_register("sim_spike",   _cmd_sim_spike,   "/sim_spike <ms[,interval_s[,duration_s]] | 0>", "Configure WiFi spike simulation. 0 disables.")
	_register("motd",        _cmd_motd,        "/motd",                                       "Re-show the current map's description.")
	_register("mapinfo",     _cmd_motd,        "/mapinfo",                                    "Re-show the current map's description.")
	_register("intro",       _cmd_intro,       "/intro",                                      "Re-show the controls card for new players.")
	_register("interp_diag", _cmd_interp_diag, "/interp_diag [on|off|dump]",                  "Measure how well the entity snapshot stream feeds interpolation. Reports to the client log.")
	_register("bind",       _cmd_bind,       "/bind <key> <control>",                        "Put a control on a key. /bind with no argument lists the controls.")
	_register("unbind",     _cmd_unbind,     "/unbind <control>",                            "Leave a control with no key at all.")
	_register("binds",      _cmd_binds,      "/binds",                                       "List every control and the key it is on.")
	_register("resetbinds", _cmd_resetbinds, "/resetbinds",                                  "Put every control back to the key the game ships with.")
	_register("connect",    _cmd_connect,    "/connect [address]",                           "Leave this server and join another. No address reconnects to the last one.")
	_register("quit",       _cmd_quit,       "/quit",                                        "Leave the game and close Wizard Wars.")
	_register("exit",       _cmd_quit,       "/exit",                                        "Leave the game and close Wizard Wars.")


## Register a dynamic command tied to a caller's lifetime.
## Call unregister() in _exit_tree to avoid dangling callables.
func register(cmd_name: String, callable: Callable, usage: String = "", help: String = "") -> void:
	_commands[cmd_name.to_lower()] = {"callable": callable, "usage": usage, "help": help}


func unregister(cmd_name: String) -> void:
	_commands.erase(cmd_name.to_lower())


func _register(cmd_name: String, callable: Callable, usage: String = "", help: String = "") -> void:
	_commands[cmd_name] = {"callable": callable, "usage": usage, "help": help}


## Parse `text` (with or without leading "/") and dispatch to a local handler.
## Returns true if the command was handled, false if unknown (caller may forward
## to the server).
func dispatch(text: String) -> bool:
	text = text.strip_edges()
	if text.begins_with("/"):
		text = text.substr(1)
	if text.is_empty():
		return false
	var space := text.find(" ")
	var cmd_name: String = (text if space < 0 else text.substr(0, space)).to_lower()
	var args: String = "" if space < 0 else text.substr(space + 1).strip_edges()
	var entry = _commands.get(cmd_name)
	if entry == null:
		return false
	entry["callable"].call(args)
	return true


func reply_ok(msg: String) -> void:
	_reply(msg, REPLY_COLOR_OK)


func reply_err(msg: String) -> void:
	_reply(msg, REPLY_COLOR_ERR)


func _reply(msg: String, color: Color) -> void:
	var hud = Game.hud
	if hud:
		hud.add_chat_message("Client", msg, false, color)


func _cmd_help(_args: String) -> void:
	var names: Array = []
	for cmd_name in _commands.keys():
		names.append("/" + cmd_name)
	names.sort()
	reply_ok("Client commands: " + ", ".join(names))
	if NetworkManager.is_online():
		NetworkManager.send_request_command("/help")


## Switching servers mid-game. A listen host's own session goes down with it and its players are
## dropped — the same thing they'd see if the host closed the game.
func _cmd_connect(args: String) -> void:
	var ip := args.strip_edges()
	if ip.is_empty():
		ip = NetworkManager.last_join_address
		if ip.is_empty():
			reply_err("Usage: /connect <address>")
			return
	var main_scene = get_tree().current_scene
	if main_scene == null or not main_scene.has_method("connect_to_server"):
		reply_err("connect: no game running.")
		return
	reply_ok("Connecting to %s..." % ip)
	main_scene.connect_to_server(ip)


## Leaving is a clean disconnect first: the server drops the player from its roster now instead of
## waiting out the connection timeout, and a listen host tears its own session down before the
## window goes away.
func _cmd_quit(_args: String) -> void:
	reply_ok("Quitting...")
	if NetworkManager.is_online():
		NetworkManager.disconnect_from_game()
	get_tree().quit()


func _cmd_intro(_args: String) -> void:
	var main_scene = get_tree().current_scene
	if main_scene and main_scene.has_method("show_intro"):
		main_scene.show_intro()
	else:
		reply_err("No map loaded.")


func _cmd_motd(_args: String) -> void:
	var main_scene = get_tree().current_scene
	if main_scene and main_scene.has_method("show_motd"):
		main_scene.show_motd()
	else:
		reply_err("No map loaded.")


# Sim commands only affect THIS endpoint's outgoing packets (goldnet transport, send-side);
# configure the opposite leg on its own endpoint (e.g. GOLDNET_LATENCY on a headless server).
func _sim_ready() -> bool:
	if not NetworkManager.transport.is_goldnet:
		reply_err("network simulation requires the goldnet transport")
		return false
	return true


## goldnet's sim_config REPLACES the whole config on write (so `= {}` is its off switch), which
## makes changing one knob a read-modify-write. Safe because every goldnet setter is idempotent —
## writing the other six back unchanged disturbs nothing, the seed included.
##
## Returns the config as goldnet STORED it, not what we asked for: the transport clamps (loss to
## 0-100, latency and spike to >= 0), so the reply has to quote what took effect. That is also what
## keeps these three commands honest if goldnet's clamping ever changes.
func _sim_apply(changes: Dictionary) -> Dictionary:
	var cfg: Dictionary = multiplayer.sim_config
	cfg.merge(changes, true)
	multiplayer.sim_config = cfg
	return multiplayer.sim_config


func _cmd_sim_latency(args: String) -> void:
	if not _sim_ready():
		return
	if args.is_empty() or args == "0":
		_sim_apply({"latency_min_ms": 0, "latency_max_ms": 0})
		reply_ok("sim_latency: disabled")
		return
	var parts := args.split(",")
	var lo: int
	var hi: int
	if parts.size() == 2 and parts[0].is_valid_int() and parts[1].is_valid_int():
		lo = int(parts[0])
		hi = int(parts[1])
		# goldnet clamps each bound to >= 0 but never checks their order, so this is ours to catch.
		if lo > hi:
			reply_err("min must be <= max")
			return
	elif parts[0].is_valid_int():
		lo = int(parts[0])
		hi = lo
	else:
		reply_err("Usage: /sim_latency <min,max | fixed_ms | 0>")
		return
	var cfg := _sim_apply({"latency_min_ms": lo, "latency_max_ms": hi})
	reply_ok("sim_latency: %d-%dms (this endpoint's send leg)"
			% [cfg["latency_min_ms"], cfg["latency_max_ms"]])


func _cmd_sim_loss(args: String) -> void:
	if not _sim_ready():
		return
	if not args.is_valid_int():
		reply_err("Usage: /sim_loss <0-100>")
		return
	# No clamp here: goldnet's set_loss_percent owns the 0-100 range, and the read-back reports it.
	var cfg := _sim_apply({"loss_percent": int(args)})
	reply_ok("sim_loss: %d%% (drops unreliable sends on this endpoint's leg)" % cfg["loss_percent"])


func _cmd_sim_spike(args: String) -> void:
	if not _sim_ready():
		return
	if args.is_empty() or args == "0":
		_sim_apply({"spike_ms": 0})
		reply_ok("sim_spike: disabled")
		return
	var parts := args.split(",")
	if not parts[0].is_valid_int():
		reply_err("Usage: /sim_spike <ms[,interval_s[,duration_s]] | 0>")
		return
	var changes := {"spike_ms": int(parts[0])}
	if parts.size() >= 2 and parts[1].is_valid_float():
		changes["spike_interval_s"] = float(parts[1])
	if parts.size() >= 3 and parts[2].is_valid_float():
		changes["spike_duration_s"] = float(parts[2])
	var cfg := _sim_apply(changes)
	reply_ok("sim_spike: %dms every %.1fs for %.2fs"
			% [cfg["spike_ms"], cfg["spike_interval_s"], cfg["spike_duration_s"]])


## The falling-corpse artifact needs a measurement taken on a real connection, not localhost: how far
## apart entity samples actually land, and how much of the motion the client had to dead-reckon.
## Each entity reports when it despawns; /interp_diag dump reads out the ones still alive.
func _cmd_interp_diag(args: String) -> void:
	if args == "dump":
		if NetworkManager.interp_diag == null:
			reply_err("interp_diag is off")
			return
		var lines := NetworkManager.interp_diag.dump_live()
		if lines.is_empty():
			reply_ok("interp_diag: nothing being interpolated right now")
		for line in lines:
			Log.info("[InterpDiag] " + line)
		reply_ok("interp_diag: %d live entities written to the log" % lines.size())
		return
	var enable: bool
	if args.is_empty():
		enable = NetworkManager.interp_diag == null
	elif args == "1" or args == "on":
		enable = true
	elif args == "0" or args == "off":
		enable = false
	else:
		reply_err("Usage: /interp_diag [on|off|dump]")
		return
	if not enable:
		NetworkManager.interp_diag = null
		reply_ok("interp_diag: off")
		return
	if NetworkManager.is_authority():
		reply_err("interp_diag measures a CLIENT's interpolation — the host has none.")
		return
	NetworkManager.interp_diag = InterpDiag.new()
	var where := Log.get_file_path()
	reply_ok("interp_diag: on — each entity reports as it despawns%s"
		% ((", log: " + where) if where != "" else ""))


## /bind, in the GoldSrc order: the key first, then what it does. Key names are the ones /binds
## prints, and both halves ignore case and spacing so "mouse1" and "Mouse 1" are the same key.
func _cmd_bind(args: String) -> void:
	if args.is_empty():
		_cmd_binds("")
		return
	# Either half can be more than one word — "Wheel Up", "Team Chat" — so neither the first space
	# nor the last is the split. Every split point is tried, and the first that names both a real
	# key and a real control is the reading meant.
	var words := args.split(" ", false)
	var key_name := ""
	var action := ""
	for cut in range(1, words.size()):
		var left := " ".join(words.slice(0, cut))
		var right := _resolve_action(" ".join(words.slice(cut)))
		if not right.is_empty() and KeyBindings.name_to_event(left) != null:
			key_name = left
			action = right
			break
	if action.is_empty():
		# Nothing parsed. Blame whichever half is wrong under the plain one-word-key reading,
		# which is what all but a handful of keys are.
		if words.size() < 2:
			reply_err("Usage: /bind <key> <control>")
		elif KeyBindings.name_to_event(words[0]) == null:
			reply_err("No such key: '%s'. /binds prints the names." % words[0])
		else:
			reply_err("No such control: '%s'. /binds lists them." % " ".join(words.slice(1)))
		return
	var event := KeyBindings.name_to_event(key_name)
	if not KeyBindings.is_bindable(event):
		reply_err("Escape is how you get out of the menu and out of a capture — it stays put.")
		return
	var stolen := KeyBindings.set_binding(action, event)
	var msg := "%s: %s" % [KeyBindings.label_for(action), KeyBindings.display_for(action)]
	if stolen.size() > 0:
		var names := PackedStringArray()
		for other in stolen:
			names.append(KeyBindings.label_for(other))
		msg += " (taken from %s, now unbound)" % ", ".join(names)
	reply_ok(msg)


func _cmd_unbind(args: String) -> void:
	var action := _resolve_action(args)
	if action.is_empty():
		reply_err("Usage: /unbind <control>. /binds lists them.")
		return
	KeyBindings.clear_binding(action)
	reply_ok("%s: unbound" % KeyBindings.label_for(action))


func _cmd_binds(_args: String) -> void:
	for group in KeyBindings.GROUPS:
		var parts := PackedStringArray()
		for entry in group[1]:
			parts.append("%s %s" % [entry[0], KeyBindings.display_for(entry[0])])
		reply_ok("%s — %s" % [group[0], ", ".join(parts)])


func _cmd_resetbinds(_args: String) -> void:
	KeyBindings.reset_all()
	reply_ok("Controls back to defaults.")


## A control by its action name ("chat_team") or by the label the menu shows ("Team Chat"),
## either way ignoring case and spacing. "" when it is neither.
func _resolve_action(text: String) -> String:
	var wanted := text.strip_edges().to_lower().replace(" ", "")
	if wanted.is_empty():
		return ""
	for action in KeyBindings.actions():
		if action.to_lower() == wanted:
			return action
		if KeyBindings.label_for(action).to_lower().replace(" ", "") == wanted:
			return action
	return ""
