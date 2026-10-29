extends Node

## Server-side chat command dispatcher. Client routes "/foo args" through
## NetworkManager.send_request_command to dispatch() here; replies go back via
## NetworkManager.sync_command_reply into the same chat log under "Server".

enum Perm { PUBLIC, ADMIN }

const EntityRegistry = preload("res://src/entities/entity_registry.gd")
const REPLY_COLOR_OK := Color(0.55, 0.85, 1.0)
const REPLY_COLOR_ERR := Color(1.0, 0.5, 0.4)
const AUTH_THROTTLE_SEC := 1.0
## Furthest ahead of the eye /spawn will place something (metres; ~100 GoldSrc units).
const SPAWN_DISTANCE := 2.5
## How far down the aim ray to look for the point a spawned spell should fly at (metres).
const AIM_RANGE := 40.0
## Speed a spawned object is thrown at, matching a thrown satchel (m/s).
const SPAWN_THROW_SPEED := 12.0
## Names per line in /spawnlist output.
const LIST_CHUNK := 12
## What a kicked player is told when the admin gave no reason.
const DEFAULT_KICK_REASON := "Kicked by an admin."

var _admin_password := ""  # empty => /auth always fails
var _commands: Dictionary = {}  # name -> {callable, perm, usage, help}
var _authed: Dictionary = {}  # peer_id -> true
var _last_auth_attempt: Dictionary = {}  # peer_id -> Time.get_ticks_msec at last try
var _noclip_peers: Dictionary = {}  # peer_id -> true


func _ready() -> void:
	_register_builtins()
	NetworkManager.peer_disconnected.connect(_on_peer_disconnected)


func set_admin_password(pw: String) -> void:
	_admin_password = pw


## Listen-server host's own peer is auto-admin. Called from main.gd after host().
func grant_admin(peer_id: int) -> void:
	_authed[peer_id] = true


func is_admin(peer_id: int) -> bool:
	return _authed.get(peer_id, false)


func is_noclip(peer_id: int) -> bool:
	return _noclip_peers.get(peer_id, false)


## Server entry point. Parses `text` (with or without leading "/") and runs
## the matching command on behalf of `sender_id`. Replies go to the sender.
func dispatch(sender_id: int, text: String) -> void:
	text = text.strip_edges()
	if text.begins_with("/"):
		text = text.substr(1)
	if text.is_empty():
		_reply_err(sender_id, "Empty command. Try /help.")
		return
	var space := text.find(" ")
	var cmd_name := text if space < 0 else text.substr(0, space)
	var rest := "" if space < 0 else text.substr(space + 1).strip_edges()
	cmd_name = cmd_name.to_lower()
	var entry = _commands.get(cmd_name)
	if entry == null:
		_reply_err(sender_id, "Unknown command: /%s. Try /help." % cmd_name)
		return
	if entry["perm"] == Perm.ADMIN and not is_admin(sender_id):
		_reply_err(sender_id, "/%s requires admin. Use /auth <password>." % cmd_name)
		return
	var sender_label := _peer_label(sender_id)
	if cmd_name == "auth":
		Log.info("[Cmd] %s: /auth ***" % sender_label)
	else:
		Log.info("[Cmd] %s: /%s %s" % [sender_label, cmd_name, rest])
	entry["callable"].call(sender_id, rest)


func _reply(sender_id: int, msg: String, color: Color) -> void:
	if sender_id == multiplayer.get_unique_id():
		# Local host: drop straight into the HUD chat log.
		if Game.hud:
			Game.hud.add_chat_message("Server", msg, false, color)
		return
	# Bots and departed peers have no chat to reply into; the log is the only listener.
	if not NetworkManager.is_peer_connected(sender_id):
		Log.info("[Cmd] (no reply channel for %d) %s" % [sender_id, msg])
		return
	NetworkManager.sync_command_reply.rpc_id(sender_id, msg, color.r, color.g, color.b)


func _reply_ok(sender_id: int, msg: String) -> void:
	_reply(sender_id, msg, REPLY_COLOR_OK)


func _reply_err(sender_id: int, msg: String) -> void:
	_reply(sender_id, msg, REPLY_COLOR_ERR)


func _register_builtins() -> void:
	_register("auth", _cmd_auth, Perm.PUBLIC, "/auth <password>", "Authenticate as admin.")
	_register("help", _cmd_help, Perm.PUBLIC, "/help [command]", "List commands or describe one.")
	_register("map", _cmd_map, Perm.ADMIN, "/map <name>", "Change to the named map.")
	_register("maplist", _cmd_maplist, Perm.PUBLIC, "/maplist [filter]", "Show the map rotation.")
	_register("nextmap", _cmd_nextmap, Perm.PUBLIC, "/nextmap [map]", "What loads after this match (admin: set it, or 'clear' to hand it back to the rotation).")
	_register("vote", _cmd_vote, Perm.PUBLIC, "/vote <n>", "Vote for one of the maps offered between matches.")
	_register("timeleft", _cmd_timeleft, Perm.PUBLIC, "/timeleft", "How long is left on this match.")
	# All three are one int server var read and written the same way — see _cmd_limit_var.
	_register("timelimit", _cmd_limit_var.bind("timelimit", " min", " — no clock, this map stays up until someone changes it"),
		Perm.ADMIN, "/timelimit [minutes]", "Get or set the match length (0 = no clock).")
	_register("scorelimit", _cmd_limit_var.bind("scorelimit", " points", " (off)"),
		Perm.ADMIN, "/scorelimit [points]", "Get or set the team score that ends a match (0 = off).")
	_register("fraglimit", _cmd_limit_var.bind("fraglimit", " frags", " (off)"),
		Perm.ADMIN, "/fraglimit [frags]", "Get or set the frags one player needs to end a match (0 = off).")
	_register("hitscanrad", _cmd_hitscanrad, Perm.ADMIN, "/hitscanrad [value]", "Get or set hitscan sphere radius.")
	_register("noclip", _cmd_noclip, Perm.ADMIN, "/noclip", "Toggle noclip for yourself.")
	_register("debug_rewind", _cmd_debug_rewind, Perm.ADMIN, "/debug_rewind [0|1]", "Toggle drawing the hitbox rig where your shots rewound it.")
	_register("kick", _cmd_kick, Perm.ADMIN, "/kick <name|#id> [reason]", "Remove a player from the server. A bot is removed outright.")
	_register("addbot", _cmd_addbot, Perm.ADMIN, "/addbot [element] [team] [skill]", "Add an AI bot (auto-balances team by default).")
	_register("botskill", _cmd_botskill, Perm.ADMIN, "/botskill [0..1|random]", "Aim skill new bots are built with.")
	_register("killbots", _cmd_killbots, Perm.ADMIN, "/killbots", "Remove all AI bots.")
	_register("record", _cmd_record, Perm.ADMIN, "/record [seconds]",
			"Record everyone's movement for a top-down replay (tools/match_gif.py).")
	_register("stoprecord", _cmd_stoprecord, Perm.ADMIN, "/stoprecord", "Stop recording.")
	_register("topview", _cmd_topview, Perm.ADMIN, "/topview [seconds]",
			"Film the live game from above (real render, spells and all).")
	_register("stoptopview", _cmd_stoptopview, Perm.ADMIN, "/stoptopview", "Stop filming.")
	_register("spawn", _cmd_spawn, Perm.ADMIN, "/spawn <name> [key value ...]", "Spawn a map entity, a spell object, or a weapon (as a pickup) in front of you. combo_weapon = a random combo spell.")
	_register("spawnlist", _cmd_spawnlist, Perm.ADMIN, "/spawnlist [filter]", "List everything /spawn accepts.")
	_register("give", _cmd_give, Perm.ADMIN, "/give <weapon>", "Give yourself a weapon directly (e.g. /give comet_weapon), no pickup.")
	_register("golem_interp", _cmd_golem_interp, Perm.ADMIN, "/golem_interp [on|off]", "Toggle client-side golem limb reconstruction (off = old per-limb interp).")
	_register("bsp_hulls", _cmd_bsp_hulls, Perm.ADMIN, "/bsp_hulls [on|off]", "Toggle GoldSrc BSP hull collision (off = trimesh/convex colliders).")
	_register("combo_chaos", _cmd_combo_chaos, Perm.ADMIN, "/combo_chaos [auto|on|off]", "Trade a map's weapon/ammo pickups and resupply grenades for random combo spellbooks (auto = whatever the map asks for).")
	_register("allow_combos", _cmd_allow_combos, Perm.ADMIN, "/allow_combos [on|off]", "Whether two allied wizards can clash staves to earn a combo spell.")
	_register("siege", _cmd_siege, Perm.ADMIN, "/siege [on|off]", "Co-op: waves of monsters against an altar everyone defends together. Works on any map.")
	_register("siege_wave", _cmd_siege_wave, Perm.ADMIN, "/siege_wave [count]", "Send a wave at the altar now. Waves run themselves later; this is the hand crank.")
	_register("ragdolls", _cmd_ragdolls, Perm.ADMIN, "/ragdolls [off|box|capsule]", "Whether the dead fall as ragdolls, and what their bones are made of: the MDL hitbox itself, or a capsule fitted inside it (what Godot's own ragdolls use). Off is the old death clips.")
	_register("sv_updaterate", _cmd_sv_updaterate, Perm.ADMIN, "/sv_updaterate [hz]", "Get or set the server's broadcast rate for everyone.")
	_register("cl_updaterate", _cmd_cl_updaterate, Perm.PUBLIC, "/cl_updaterate [hz]", "Get or set the rate YOU are served at (capped by the server's).")
	_register("cl_cmdrate", _cmd_cl_cmdrate, Perm.PUBLIC, "/cl_cmdrate [packets per sec]", "Get or set how many input packets YOU send per second; 0 = automatic (the default), picked from how your uplink is keeping up.")
	_register("rate", _cmd_rate, Perm.PUBLIC, "/rate [bytes per sec]", "Get or set the most the server sends YOU per second; 0 = automatic (the default), picked from how your downlink is keeping up.")


## /spawn <name> [key value ...] — one flat namespace, one name per thing, all three halves
## derived rather than listed: a map entity by the classname the .bsp uses ("item_healthkit"),
## a world object by its script name ("comet" — the thing that flies and explodes), or a weapon
## by its script name ("comet_weapon"), which drops as a spellbook to pick up. "combo_weapon"
## drops an undecided spellbook: one of the combo spells, picked at random.
##
## Extra key/value pairs become entity keyvalues exactly as a .bsp would supply them. A brush
## entity needs "size <goldsrc units>" to be given geometry — /spawn func_door size 96.
func _cmd_spawn(sender_id: int, args: String) -> void:
	var parts := args.split(" ", false)
	if parts.is_empty():
		_reply_err(sender_id, "Usage: /spawn <entity|object|weapon> [key value ...] — see /spawnlist")
		return
	var typed := parts[0]
	var what := typed.to_lower()
	var keys := {}
	for i in range(1, parts.size() - 1, 2):
		keys[parts[i].to_lower()] = parts[i + 1]

	if Game.current_map_name.is_empty():
		_reply_err(sender_id, "No map loaded.")
		return
	var placement := _spawn_placement(sender_id)
	if placement.is_empty():
		_reply_err(sender_id, "No player body to spawn in front of.")
		return

	var node: Node = null
	if EntityRegistry.has(what):
		node = EntityRegistry.spawn(what, keys, placement["position"], placement["yaw"])
	elif SpawnRegistry.has_object(what):
		var parsed: Variant = _typed_keyvalues(keys)
		if parsed is String:
			_reply_err(sender_id, parsed)
			return
		node = _spawn_object(sender_id, what, parsed, placement)
	elif SpawnRegistry.has_weapon(what):
		# A weapon isn't a thing in the world — the book that carries it is.
		keys["weapon"] = what
		node = EntityRegistry.spawn("item_weapon", keys, placement["position"], placement["yaw"])
	else:
		_reply_err(sender_id, "Don't know how to spawn '%s'. Try /spawnlist." % typed)
		return

	if node == null:
		_reply_err(sender_id, "Failed to spawn %s." % what)
		return
	_reply_ok(sender_id, "Spawned %s." % what)
	Log.info("[Cmd] %s spawned %s at %s" % [_peer_label(sender_id), what, str(placement["position"])])


## A live projectile/plant/effect, cast as if the caller had cast it: their team, their aim, and
## themselves excluded from their own blast. Homing spells read target_pos, straight ones read
## direction, and each script takes what it understands from the payload.
func _spawn_object(sender_id: int, what: String, keys: Dictionary, placement: Dictionary) -> Node:
	var player := NetworkManager.get_player(sender_id)
	var data := {
		"position": placement["position"],
		"direction": placement["aim_dir"],
		"target_pos": placement["aim_point"],
		# Thrown things (a satchel) read a velocity rather than a direction, so give them the
		# throw they'd have got from the hand that cast them.
		"velocity": placement["aim_dir"] * SPAWN_THROW_SPEED,
		"team": player.team,
	}
	# The casting weapons ask for a network id for anything whose death burst or growth is a
	# one-shot push (see raise_dead_weapon), and without one every such push is silently dropped —
	# a /spawn'd skeleton died gibless on a dedicated server. Asked of the script, not listed here.
	if SpawnRegistry.object_syncs_state(what):
		data["sync_state"] = true
	data.merge(keys, true)
	return NetworkManager.spawn_projectile(SpawnRegistry.object_script_path(what), data,
		player, player.get_rid())


## Command-line keyvalues arrive as strings, but a spawned object assigns them straight into typed
## fields, so they're converted here. "element" also takes a name — spelled the way /addbot spells
## it, since nobody remembers that ice is 5. Returns an error message instead of a Dictionary when
## a value doesn't parse.
func _typed_keyvalues(keys: Dictionary) -> Variant:
	var out := {}
	for key in keys:
		var value: String = keys[key]
		if key == "element" and not value.is_valid_int():
			var element := GameConsts.element_from_name(value)
			if element < 0:
				return "Unknown element '%s'. Try: %s" % [value,
					", ".join(GameConsts.ELEMENT_NAMES.values())]
			out[key] = element
		elif value.is_valid_int():
			out[key] = value.to_int()
		elif value.is_valid_float():
			out[key] = value.to_float()
		else:
			out[key] = value
	return out


## Where the caster is looking: `position` is a short way down their aim ray, stopped short of
## whatever it hits so nothing lands inside a wall; `aim_point` is where that ray ends up, which
## is what a homing spell should chase.
func _spawn_placement(sender_id: int) -> Dictionary:
	var player := NetworkManager.get_player(sender_id)
	if player == null:
		return {}
	var aim: Dictionary = Combat.get_aim(player)
	var from: Vector3 = aim["from"]
	var dir: Vector3 = aim["aim_dir"]
	var space := player.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, from + dir * AIM_RANGE)
	query.collision_mask = GameConsts.MASK_WORLD
	query.exclude = [player.get_rid()]
	var hit := space.intersect_ray(query)
	var reach: float = from.distance_to(hit["position"]) if hit else AIM_RANGE
	return {
		"position": from + dir * clampf(reach - 0.5, 0.5, SPAWN_DISTANCE),
		"aim_point": from + dir * reach,
		"aim_dir": dir,
		# Face the spawn back at whoever asked for it.
		"yaw": player.rotation.y + PI,
	}


func _cmd_spawnlist(sender_id: int, args: String) -> void:
	var filter := args.strip_edges().to_lower()
	var entities: Array = EntityRegistry.classnames()
	var groups := {
		"Entities": entities,
		"Objects": SpawnRegistry.object_names(),
		"Weapons": SpawnRegistry.weapon_names(),
	}
	var found := false
	for label in groups:
		var names := []
		for n in groups[label]:
			if filter.is_empty() or filter in n:
				names.append(n)
		if names.is_empty():
			continue
		found = true
		_reply_list(sender_id, label, names)
	if not found:
		_reply_err(sender_id, "Nothing matches '%s'." % filter)


## One chat line per dozen names — the full list runs to 180-odd entries and a single line of
## that is unreadable in the chat log.
func _reply_list(sender_id: int, label: String, names: Array) -> void:
	_reply_ok(sender_id, "%s (%d):" % [label, names.size()])
	for i in range(0, names.size(), LIST_CHUNK):
		_reply_ok(sender_id, "  " + ", ".join(names.slice(i, i + LIST_CHUNK)))


func _cmd_give(sender_id: int, args: String) -> void:
	var key := args.strip_edges().to_lower()
	if key.is_empty():
		_reply_err(sender_id, "Usage: /give <weapon>")
		return
	if not SpawnRegistry.has_weapon(key):
		_reply_err(sender_id, "Unknown weapon '%s'. Try /spawnlist." % key)
		return
	var player := NetworkManager.get_player(sender_id)
	if player == null:
		_reply_err(sender_id, "No player body to give to.")
		return
	if not player.grant_weapon(key):
		_reply_err(sender_id, "You already have %s." % key)
		return
	_reply_ok(sender_id, "Gave %s." % key)


## Server-side game code (item_weapon pickups) telling one player something, through the same
## chat channel command replies use.
func notify_peer(peer_id: int, msg: String) -> void:
	# Bots (negative ids) and unowned bodies have nobody to tell.
	if peer_id <= 0:
		return
	_reply_ok(peer_id, msg)


func _register(cmd_name: String, callable: Callable, perm: int, usage: String, help: String) -> void:
	_commands[cmd_name] = {
		"callable": callable,
		"perm": perm,
		"usage": usage,
		"help": help,
	}


func _cmd_auth(sender_id: int, args: String) -> void:
	var now := Time.get_ticks_msec()
	var last: int = _last_auth_attempt.get(sender_id, 0)
	if now - last < int(AUTH_THROTTLE_SEC * 1000.0):
		_reply_err(sender_id, "Slow down.")
		return
	_last_auth_attempt[sender_id] = now
	if _admin_password.is_empty():
		_reply_err(sender_id, "Authentication failed.")
		Log.info("[Cmd] %s: /auth refused (no admin password set)" % _peer_label(sender_id))
		return
	if args == _admin_password:
		_authed[sender_id] = true
		_reply_ok(sender_id, "Authenticated.")
		Log.info("[Cmd] %s: /auth granted" % _peer_label(sender_id))
	else:
		_reply_err(sender_id, "Authentication failed.")
		Log.info("[Cmd] %s: /auth denied" % _peer_label(sender_id))


func _cmd_debug_rewind(sender_id: int, args: String) -> void:
	var enable: bool
	if args.is_empty():
		enable = not LagCompensation.debug_ghosts
	elif args == "1" or args == "on":
		enable = true
	elif args == "0" or args == "off":
		enable = false
	else:
		_reply_err(sender_id, "Usage: /debug_rewind [0|1]")
		return
	LagCompensation.debug_ghosts = enable
	_reply_ok(sender_id, "debug_rewind: %s" % ("on" if enable else "off"))


## The server-wide broadcast rate. Raising it lowers everyone's snapshot age (and their interp
## floor, which is two intervals); lowering it trades that back for bandwidth.
func _cmd_sv_updaterate(sender_id: int, args: String) -> void:
	if args.is_empty():
		_reply_ok(sender_id, "sv_updaterate = %.0f" % NetworkManager.NET_TICKRATE)
		return
	if not args.is_valid_float():
		_reply_err(sender_id, "Usage: /sv_updaterate [%.0f-%.0f]"
			% [NetworkManager.UPDATERATE_MIN, NetworkManager.UPDATERATE_MAX])
		return
	NetworkManager.apply_sv_updaterate(args.to_float())
	_reply_ok(sender_id, "sv_updaterate = %.0f (clamped to %.0f-%.0f)"
		% [NetworkManager.NET_TICKRATE, NetworkManager.UPDATERATE_MIN, NetworkManager.UPDATERATE_MAX])
	Log.info("[Cmd] %s: sv_updaterate -> %.0f" % [_peer_label(sender_id), NetworkManager.NET_TICKRATE])


## Per-client rate. Runs server-side like every command; the value is
## pushed back to the asking client to persist and ask for, and goldnet grants it.
func _cmd_cl_updaterate(sender_id: int, args: String) -> void:
	if sender_id == multiplayer.get_unique_id():
		_reply_err(sender_id, "The host renders its own world live — cl_updaterate does nothing here.")
		return
	if args.is_empty():
		var served: float = NetworkManager.transport.link_stats(sender_id).get("update_rate", 0)
		_reply_ok(sender_id, "served at %.0f" % (served if served > 0 else NetworkManager.NET_TICKRATE))
		return
	if not args.is_valid_float():
		_reply_err(sender_id, "Usage: /cl_updaterate [%.0f-%.0f]"
			% [NetworkManager.UPDATERATE_MIN, NetworkManager.UPDATERATE_MAX])
		return
	var rate := args.to_float()
	# The client adopts + persists it, then asks; the grant that follows is the real answer.
	NetworkManager.sync_set_cl_updaterate.rpc_id(sender_id, rate)
	_reply_ok(sender_id, "cl_updaterate = %s" % ("server rate" if rate <= 0.0
		else "%.0f" % clampf(rate, NetworkManager.UPDATERATE_MIN, NetworkManager.UPDATERATE_MAX)))


func _cmd_cl_cmdrate(sender_id: int, args: String) -> void:
	if sender_id == multiplayer.get_unique_id():
		_reply_err(sender_id, "The host sends itself no input packets — cl_cmdrate does nothing here.")
		return
	if args.is_empty():
		_reply_ok(sender_id, "Usage: /cl_cmdrate [0 | %.0f+] (0 = automatic)" % NetworkManager.CMDRATE_MIN)
		return
	if not args.is_valid_float():
		_reply_err(sender_id, "Usage: /cl_cmdrate [0 | %.0f+]" % NetworkManager.CMDRATE_MIN)
		return
	var rate := args.to_float()
	NetworkManager.sync_set_cl_cmdrate.rpc_id(sender_id, rate)
	_reply_ok(sender_id, "cl_cmdrate = %s" % ("automatic" if rate <= 0.0 else "%.0f" % maxf(rate, NetworkManager.CMDRATE_MIN)))


func _cmd_rate(sender_id: int, args: String) -> void:
	if sender_id == multiplayer.get_unique_id():
		_reply_err(sender_id, "The host has no link to itself — rate does nothing here.")
		return
	if args.is_empty():
		var current: int = NetworkManager.transport.link_stats(sender_id).get("rate", 0)
		_reply_ok(sender_id, "rate = %s" % ("automatic, currently no limit" if current <= 0 else "%d bytes/sec" % current))
		return
	if not args.is_valid_int():
		_reply_err(sender_id, "Usage: /rate [0 | %d-%d]" % [NetworkManager.RATE_MIN, NetworkManager.RATE_MAX])
		return
	var rate := args.to_int()
	NetworkManager.sync_set_cl_rate.rpc_id(sender_id, rate)
	var granted := clampi(rate, NetworkManager.RATE_MIN, NetworkManager.RATE_MAX) if rate > 0 else 0
	_reply_ok(sender_id, "rate = %s" % ("automatic" if granted <= 0 else "%d bytes/sec" % granted))


func _cmd_hitscanrad(sender_id: int, args: String) -> void:
	if args.is_empty():
		_reply_ok(sender_id, "hitscanrad = %s" % str(ServerVars.get_value("hitscan_radius")))
		return
	var result: Dictionary = ServerVars.set_from_string("hitscan_radius", args)
	if result["ok"]:
		_reply_ok(sender_id, "hitscanrad = %s" % str(result["value"]))
	else:
		_reply_err(sender_id, str(result["error"]))


## /kick <name|#id> [reason] — take a player off the server. The kicked client is told why,
## in a popup and in its log, and everyone else is told in chat, so a kick nobody can see the
## reason for reads as the server dropping people at random.
##
## A bot has no connection to close, so kicking one removes the bot — /kick names whoever is on
## the scoreboard, and every name on it can be typed here.
func _cmd_kick(sender_id: int, args: String) -> void:
	var split := _split_target(args)
	var target: String = split[0]
	var reason: String = split[1]
	if target.is_empty():
		_reply_err(sender_id, "Usage: /kick <name|#id> [reason]")
		return
	var found := resolve_player(target)
	var peer_id: int = found["id"]
	if peer_id == 0:
		_reply_err(sender_id, str(found["error"]))
		return
	if peer_id == sender_id:
		_reply_err(sender_id, "You can't kick yourself.")
		return
	if peer_id == multiplayer.get_unique_id():
		# kick_peer refuses this silently (the host owns the session), so catch it here rather
		# than announce a kick that never happens.
		_reply_err(sender_id, "You can't kick the server.")
		return
	var who := NetworkManager.display_name(peer_id)
	if peer_id < 0:
		if not BotSystem.remove_bot(peer_id):
			_reply_err(sender_id, "%s is already gone." % who)
			return
		_reply_ok(sender_id, "Removed %s." % who)
		Log.info("[Cmd] %s kicked bot %s (#%d)" % [_peer_label(sender_id), who, peer_id])
		return
	if not NetworkManager.is_peer_connected(peer_id):
		# On the roster but with no connection behind it — a peer that dropped between the
		# scoreboard the admin read and the command they typed.
		_reply_err(sender_id, "%s is not connected." % who)
		return
	if reason.is_empty():
		reason = DEFAULT_KICK_REASON
	Log.info("[Cmd] %s kicked %s: %s" % [_peer_label(sender_id), _peer_label(peer_id), reason])
	# Announced before the kick, not after: kick_peer waits a tenth of a second for the reason
	# to land before it closes the connection, which is long enough for this to arrive too — so
	# the one being kicked reads it in chat as well as in the popup.
	_announce("%s was kicked (%s)" % [who, reason])
	NetworkManager.kick_peer(peer_id, reason)


## Resolve a player the way an admin would name one: "#<peer id>" is exact (bots hold negative
## ids, so "#-3" is a bot), and anything else is a name — matched whole first, then as a unique
## substring, both case-insensitively, so "/kick al" finds Alan. Returns {id, error}: id 0 means
## no single player, and error is what to tell the admin, including who a name matched twice.
## Names are not unique, which is why the id form exists.
func resolve_player(query: String) -> Dictionary:
	query = query.strip_edges()
	if query.is_empty():
		return {"id": 0, "error": "Name somebody."}
	if query.begins_with("#"):
		var wanted := query.substr(1).strip_edges()
		var peer_id := wanted.to_int()
		if not wanted.is_valid_int() or not NetworkManager.has_player_name(peer_id):
			return {"id": 0, "error": "Nobody here has id %s." % wanted}
		return {"id": peer_id, "error": ""}
	var lower := query.to_lower()
	var exact: Array[int] = []
	var partial: Array[int] = []
	var names := NetworkManager.peer_names()
	for peer_id: int in names:
		var player_name := str(names[peer_id]).to_lower()
		if player_name == lower:
			exact.append(peer_id)
		elif player_name.contains(lower):
			partial.append(peer_id)
	var hits := exact if not exact.is_empty() else partial
	if hits.is_empty():
		return {"id": 0, "error": "Nobody here is called '%s'." % query}
	if hits.size() > 1:
		var labels := []
		for peer_id in hits:
			labels.append("%s (#%d)" % [NetworkManager.display_name(peer_id), peer_id])
		return {"id": 0, "error": "'%s' matches %s — name one by id." % [query, ", ".join(labels)]}
	return {"id": hits[0], "error": ""}


## Split "<target> [rest]" for a command whose first argument is a player. A name with spaces in
## it goes in quotes — /kick "Big Al" idle — since the rest of the line is free text.
func _split_target(args: String) -> Array:
	var text := args.strip_edges()
	if text.begins_with("\""):
		var close := text.find("\"", 1)
		if close > 0:
			return [text.substr(1, close - 1), text.substr(close + 1).strip_edges()]
	var space := text.find(" ")
	if space < 0:
		return [text, ""]
	return [text.substr(0, space), text.substr(space + 1).strip_edges()]


## A line in the Server voice that every player sees, where a reply goes to one. Same path as
## _reply: remote peers over the RPC, the listen host straight into its own chat log.
func _announce(msg: String) -> void:
	if NetworkManager.is_online():
		NetworkManager.sync_command_reply.rpc(msg, REPLY_COLOR_OK.r, REPLY_COLOR_OK.g, REPLY_COLOR_OK.b)
	if Game.hud:
		Game.hud.add_chat_message("Server", msg, false, REPLY_COLOR_OK)


func _cmd_addbot(sender_id: int, args: String) -> void:
	var parts := args.strip_edges().split(" ", false)
	var element := -1
	var team := -1
	if parts.size() >= 1 and parts[0] != "":
		element = GameConsts.element_from_name(parts[0])
		if element < 0:
			_reply_err(sender_id, "Unknown element '%s'." % parts[0])
			return
	if parts.size() >= 2:
		team = parts[1].to_int()
	# Skill applies to this bot only; /botskill sets it for every bot added afterwards.
	var skill := -1.0
	if parts.size() >= 3:
		if not parts[2].is_valid_float():
			_reply_err(sender_id, "Skill must be a number from 0 (sloppy) to 1 (crack shot).")
			return
		skill = clampf(parts[2].to_float(), 0.0, 1.0)
	var id: int = BotSystem.add_bot(element, team, skill)
	if id == 0:
		_reply_err(sender_id, "Failed to add bot (game not active, team full, or no spawn for team).")
	else:
		_reply_ok(sender_id, "Added bot #%d." % (-id))


const MatchRecorder = preload("res://src/systems/match_recorder.gd")
const TopViewRecorder = preload("res://src/systems/top_view_recorder.gd")
var _recorder: Node = null
var _topview: Node = null


## Get (or make) a recorder node. Both recorders live on the RUNNING SCENE rather than as an
## autoload, so they die with the map and can never outlive the players they are sampling.
func _recorder_on_map(main: Node, script: GDScript, node_name: String, held: Node) -> Node:
	if held != null and is_instance_valid(held):
		return held
	var n: Node = script.new()
	n.name = node_name
	main.add_child(n)
	return n


## Unlike /record, this one needs a real renderer — it is a second camera on the live scene, so
## it only works in a client or listen host, never on a headless dedicated server.
func _cmd_topview(sender_id: int, args: String) -> void:
	var main := get_tree().current_scene
	if main == null or not Game.game_active:
		_reply_err(sender_id, "No active map.")
		return
	if DisplayServer.get_name() == "headless":
		_reply_err(sender_id, "Headless server: nothing is rendered, so there is nothing to film.")
		return
	_topview = _recorder_on_map(main, TopViewRecorder, "TopViewRecorder", _topview)
	var secs := 0.0
	var cut := INF
	var parts := args.strip_edges().split(" ", false)
	if parts.size() >= 1 and parts[0] != "":
		secs = maxf(parts[0].to_float(), 0.0)
	if parts.size() >= 2:
		cut = parts[1].to_float()      # override the roof cut for a multi-level map
	var out: String = _topview.start(Game.current_map_name, secs, cut)
	if out.is_empty():
		_reply_err(sender_id, "Could not start (no map geometry?).")
		return
	_reply_ok(sender_id, "Filming to %s%s" % [out, "" if secs <= 0.0 else " (%.0fs)" % secs])


func _cmd_stoptopview(sender_id: int, _args: String) -> void:
	if _topview == null or not is_instance_valid(_topview) or not _topview.is_recording():
		_reply_err(sender_id, "Not filming.")
		return
	var n: int = _topview.frames()
	var out: String = _topview.dir
	_topview.stop()
	_reply_ok(sender_id, "Stopped, %d frames. %s" % [n, ProjectSettings.globalize_path(out)])


func _cmd_record(sender_id: int, args: String) -> void:
	var main := get_tree().current_scene
	if main == null or not Game.game_active:
		_reply_err(sender_id, "No active map.")
		return
	_recorder = _recorder_on_map(main, MatchRecorder, "MatchRecorder", _recorder)
	var secs := 0.0
	if not args.strip_edges().is_empty():
		secs = maxf(args.strip_edges().to_float(), 0.0)
	var out: String = _recorder.start(Game.current_map_name, secs)
	if out.is_empty():
		_reply_err(sender_id, "Could not open a replay file.")
		return
	_reply_ok(sender_id, "Recording to %s%s" % [
			out, "" if secs <= 0.0 else " (%.0fs)" % secs])


func _cmd_stoprecord(sender_id: int, _args: String) -> void:
	if _recorder == null or not is_instance_valid(_recorder) or not _recorder.is_recording():
		_reply_err(sender_id, "Not recording.")
		return
	var out: String = _recorder.path
	_recorder.stop()
	_reply_ok(sender_id, "Stopped. %s" % ProjectSettings.globalize_path(out))


## /botskill [0..1|random] — the aim skill bots are BUILT with, so it takes effect on the next
## /addbot rather than retuning the bots already playing (a bot's skill is rolled into its
## reaction, turn rate, aim wobble and lead once, at setup).
func _cmd_botskill(sender_id: int, args: String) -> void:
	var arg := args.strip_edges()
	if arg.is_empty():
		var cur := float(ServerVars.get_value("bot_skill", -1.0))
		_reply_ok(sender_id, "botskill = random (0.35-0.9 per bot)" if cur < 0.0
				else "botskill = %.2f" % cur)
		return
	var value := -1.0
	if arg == "random" or arg == "-1":
		value = -1.0
	elif arg.is_valid_float():
		value = clampf(arg.to_float(), 0.0, 1.0)
	else:
		_reply_err(sender_id, "Usage: /botskill [0..1|random]")
		return
	var result: Dictionary = ServerVars.set_from_string("bot_skill", str(value))
	if not result["ok"]:
		_reply_err(sender_id, str(result["error"]))
		return
	if value < 0.0:
		_reply_ok(sender_id, "botskill = random (0.35-0.9 per bot) — applies to bots added from now on.")
	else:
		_reply_ok(sender_id, "botskill = %.2f — applies to bots added from now on." % value)


func _cmd_killbots(sender_id: int, _args: String) -> void:
	var n: int = BotSystem.remove_all_bots()
	_reply_ok(sender_id, "Removed %d bot(s)." % n)


## Shared body for "/<name> [on|off]" bool server-var toggles (empty arg flips the
## current value). Returns the new value, or null if it didn't parse (usage already sent).
func _set_bool_var(sender_id: int, key: String, args: String, usage: String):
	var arg := args.strip_edges()
	if arg.is_empty():  # no arg → flip
		arg = "off" if ServerVars.get_value(key, true) else "on"
	var result: Dictionary = ServerVars.set_from_string(key, arg)
	if not result["ok"]:
		_reply_err(sender_id, "Usage: %s" % usage)
		return null
	return result["value"]


## The same for vars that take one of a fixed set of words rather than on/off (empty arg
## reports rather than flips: there is no obvious next value to flip to). Returns the word
## that was set, or null if it wasn't one of `choices` — the handler formats its own reply,
## which is the half that differs between them.
func _set_choice_var(sender_id: int, key: String, args: String, choices: Array, usage: String):
	var arg := args.strip_edges().to_lower()
	if not arg in choices:
		_reply_err(sender_id, "Usage: %s" % usage)
		return null
	var result: Dictionary = ServerVars.set_from_string(key, arg)
	if not result["ok"]:
		_reply_err(sender_id, str(result["error"]))
		return null
	return arg


func _cmd_golem_interp(sender_id: int, args: String) -> void:
	var value = _set_bool_var(sender_id, "golem_interp", args, "/golem_interp [on|off]")
	if value == null:
		return
	_reply_ok(sender_id, "golem_interp: %s (%s)" % [
		"on" if value else "off",
		"client reconstruct" if value else "per-limb interp"])


func _cmd_allow_combos(sender_id: int, args: String) -> void:
	var value = _set_bool_var(sender_id, "allow_combos", args, "/allow_combos [on|off]")
	if value == null:
		return
	_reply_ok(sender_id, "allow_combos: %s" % ("on" if value else "off"))


## Turning it on stands the arena up on whatever map is loaded — SiegeSystem works out where the
## altar goes and where the attackers come in. The refusal, when there is one, says what the map
## could not supply, so report it rather than a bare "failed".
func _cmd_siege(sender_id: int, args: String) -> void:
	var arg := args.strip_edges().to_lower()
	if arg.is_empty():
		_reply_ok(sender_id, "siege: %s" % ("on" if SiegeSystem.active else "off"))
		return
	var value = _set_bool_var(sender_id, "siege", args, "/siege [on|off]")
	if value == null:
		return
	# The var is the switch; SiegeSystem acts on value_changed and may refuse. Report what it did,
	# not what was asked for, and put the var back if the map could not host it.
	if bool(value) and not SiegeSystem.active:
		ServerVars.set_from_string("siege", "off")
		_reply_err(sender_id, "Siege could not start on this map.")
		return
	_reply_ok(sender_id, "siege: %s" % ("on" if SiegeSystem.active else "off"))


func _cmd_siege_wave(sender_id: int, args: String) -> void:
	if not SiegeSystem.active:
		_reply_err(sender_id, "No siege running — /siege on first.")
		return
	var arg := args.strip_edges()
	var count := int(arg) if arg.is_valid_int() else 8
	var made := SiegeSystem.spawn_wave(clampi(count, 1, 40))
	if made == 0:
		_reply_err(sender_id, "Nothing spawned — the arena has no usable entry point.")
		return
	_reply_ok(sender_id, "%d on the way." % made)


## off is no ragdoll at all, box and capsule are what its bones are made of. A ragdoll's
## bodies are made once, when the corpse spawns, so this only changes what the NEXT one is
## built out of — kill something to see it. "on" is taken as "box" so the obvious thing to
## type works.
func _cmd_ragdolls(sender_id: int, args: String) -> void:
	var arg := args.strip_edges().to_lower()
	if arg.is_empty():
		_reply_ok(sender_id, "ragdolls = %s" % RagdollBuilder.mode())
		return
	if arg == "on":
		arg = RagdollBuilder.DEFAULT_MODE
	var value = _set_choice_var(sender_id, "ragdolls", arg, RagdollBuilder.MODES, "/ragdolls [off|box|capsule]")
	if value == null:
		return
	_reply_ok(sender_id, "ragdolls = %s%s" % [value, "" if value == "off" else " (the next corpse onwards)"])


## "auto" hands the decision back to the map's info_wwdetect key, on/off overrule it either way.
func _cmd_combo_chaos(sender_id: int, args: String) -> void:
	var arg := args.strip_edges().to_lower()
	if arg.is_empty():
		_reply_ok(sender_id, "combo_chaos = %s (%s here)" % [
			str(ServerVars.get_value("combo_chaos", "auto")),
			"on" if GoalSystem.is_combo_chaos() else "off"])
		return
	var value = _set_choice_var(sender_id, "combo_chaos", arg, ["auto", "on", "off"], "/combo_chaos [auto|on|off]")
	if value == null:
		return
	_reply_ok(sender_id, "combo_chaos = %s (%s here)" % [
		value, "on" if GoalSystem.is_combo_chaos() else "off"])


func _cmd_bsp_hulls(sender_id: int, args: String) -> void:
	var value = _set_bool_var(sender_id, "bsp_hulls", args, "/bsp_hulls [on|off]")
	if value == null:
		return
	# Only Hop can trace a hull, so under default Godot physics this flag is inert.
	var main := get_tree().current_scene
	var active: bool = main != null and main.has_method("bsp_hulls_active") and main.bsp_hulls_active()
	var note := "BSP clip hulls" if active else "trimesh/convex colliders"
	if value and not active:
		note = "trimesh/convex colliders — physics engine is not Hop, flag is inert"
	_reply_ok(sender_id, "bsp_hulls: %s (%s)" % ["on" if value else "off", note])


func _cmd_noclip(sender_id: int, _args: String) -> void:
	var enabled : bool = not _noclip_peers.get(sender_id, false)
	if enabled:
		_noclip_peers[sender_id] = true
	else:
		_noclip_peers.erase(sender_id)
	_reply_ok(sender_id, "noclip: %s" % ("on" if enabled else "off"))
	_sync_noclip_to_peer(sender_id, enabled)


## A map change rebuilds every client's LocalPlayer with noclip off, so the server has to drop
## its grants too — otherwise it keeps flying a client that thinks it's walking.
func clear_noclip() -> void:
	_noclip_peers.clear()


func _sync_noclip_to_peer(peer_id: int, enabled: bool) -> void:
	if peer_id == multiplayer.get_unique_id():
		if Game.local_player:
			Game.local_player.noclip = enabled
		return
	if NetworkManager.is_peer_connected(peer_id):
		NetworkManager.sync_noclip.rpc_id(peer_id, enabled)


func _cmd_help(sender_id: int, args: String) -> void:
	var allowed_only := not is_admin(sender_id)
	if args.is_empty():
		var names := []
		for cmd_name in _commands.keys():
			var cmd_entry = _commands[cmd_name]
			if allowed_only and cmd_entry["perm"] == Perm.ADMIN:
				continue
			names.append("/" + cmd_name)
		names.sort()
		_reply_ok(sender_id, "Commands: " + ", ".join(names))
		return
	var requested := args.strip_edges().to_lower()
	if requested.begins_with("/"):
		requested = requested.substr(1)
	var entry = _commands.get(requested)
	if entry == null:
		_reply_err(sender_id, "Unknown command: /%s" % requested)
		return
	if allowed_only and entry["perm"] == Perm.ADMIN:
		_reply_err(sender_id, "Unknown command: /%s" % requested)
		return
	_reply_ok(sender_id, "%s — %s" % [entry["usage"], entry["help"]])


func _cmd_map(sender_id: int, args: String) -> void:
	var map_name := args.strip_edges()
	if map_name.is_empty():
		_reply_err(sender_id, "Usage: /map <name>")
		return
	if not MapConverter.map_exists(map_name):
		_reply_err(sender_id, "Map not found: %s" % map_name)
		return
	NetworkManager.map_change_server_request.emit(map_name)
	_reply_ok(sender_id, "Changing map to %s..." % map_name)


func _cmd_maplist(sender_id: int, args: String) -> void:
	var filter := args.strip_edges().to_lower()
	var current := MatchSystem.current_map
	var next_map := MatchSystem.peek_next_map()
	var rows: Array = []
	for map_name in MatchSystem.cycle():
		if not filter.is_empty() and not filter in map_name.to_lower():
			continue
		var mark := ""
		if map_name == current:
			mark = " (playing)"
		elif map_name == next_map:
			mark = " (next)"
		rows.append(map_name + mark)
	if rows.is_empty():
		_reply_err(sender_id, "Nothing in the rotation matches '%s'." % filter)
		return
	_reply_list(sender_id, "Map rotation — %s" % MatchSystem.cycle_source(), rows)


func _cmd_nextmap(sender_id: int, args: String) -> void:
	var arg := args.strip_edges()
	if arg.is_empty():
		var next_map := MatchSystem.peek_next_map()
		if next_map.is_empty():
			_reply_ok(sender_id, "No rotation — this map stays up.")
			return
		var how := "forced" if not MatchSystem.forced_next_map().is_empty() else "from the rotation"
		_reply_ok(sender_id, "Next map: %s (%s)" % [next_map, how])
		return
	if not is_admin(sender_id):
		_reply_err(sender_id, "Setting the next map requires admin. Use /auth <password>.")
		return
	if arg.to_lower() in ["clear", "none", "off"]:
		MatchSystem.set_next_map("")
		_reply_ok(sender_id, "Next map back to the rotation: %s" % MatchSystem.peek_next_map())
		return
	if not MatchSystem.set_next_map(arg):
		_reply_err(sender_id, "Map not found: %s" % arg)
		return
	_reply_ok(sender_id, "Next map: %s" % arg)


## The ballot the intermission puts up. Public, one vote each, changeable while it's open.
func _cmd_vote(sender_id: int, args: String) -> void:
	var candidates := MatchSystem.vote_candidates
	if candidates.is_empty():
		_reply_err(sender_id, "Nothing to vote on right now.")
		return
	var arg := args.strip_edges()
	if arg.is_empty():
		_reply_ok(sender_id, "Next map vote — %s" % _vote_options(candidates))
		return
	# cast_vote is the one place the range is judged; "abc".to_int() is 0, which it refuses.
	var picked := MatchSystem.cast_vote(sender_id, arg.to_int())
	if picked.is_empty():
		_reply_err(sender_id, "Usage: /vote <1-%d> — %s" % [candidates.size(), _vote_options(candidates)])
		return
	_reply_ok(sender_id, "Voted for %s. Leading: %s" % [picked, MatchSystem.next_map])


## "1) ww_hunt 2 · 2) ww_chasm 0 · 3) ww_roc2 1"
func _vote_options(candidates: PackedStringArray) -> String:
	var tallies := MatchSystem.vote_tallies()
	var parts: Array[String] = []
	for i in candidates.size():
		parts.append("%d) %s %d" % [i + 1, candidates[i], tallies[i] if i < tallies.size() else 0])
	return " · ".join(parts)


func _cmd_timeleft(sender_id: int, _args: String) -> void:
	if MatchSystem.is_intermission():
		_reply_ok(sender_id, "Match over — %s loads in %s." % [
			MatchSystem.next_map if not MatchSystem.next_map.is_empty() else "the same map",
			MatchSystem.time_left_text()])
		return
	var left := MatchSystem.time_left_text()
	if left.is_empty():
		_reply_ok(sender_id, "No time limit on this match.")
		return
	_reply_ok(sender_id, "Time left: %s" % left)


## Shared body for the "/<name> [number]" match limits, which are all one int server var reported
## the same way: an empty arg reports, a number sets, 0 reads as off. Bound per command the way
## _set_bool_var serves the on/off ones.
func _cmd_limit_var(sender_id: int, args: String, key: String, unit: String, off_text: String) -> void:
	if args.is_empty():
		var current := int(ServerVars.get_value(key, 0))
		_reply_ok(sender_id, "%s = %d%s" % [key, current, off_text if current <= 0 else unit])
		return
	var result: Dictionary = ServerVars.set_from_string(key, args)
	if not result["ok"]:
		_reply_err(sender_id, str(result["error"]))
		return
	var value := int(result["value"])
	if value <= 0:
		_reply_ok(sender_id, "%s = 0%s" % [key, off_text])
		return
	# A limit set mid-match takes hold from now — the clock restarts rather than ending a match
	# retroactively (MatchSystem._restart_clock).
	_reply_ok(sender_id, "%s = %d%s" % [key, value, unit])


func _on_peer_disconnected(id: int) -> void:
	_authed.erase(id)
	_last_auth_attempt.erase(id)
	_noclip_peers.erase(id)


func _peer_label(peer_id: int) -> String:
	if not NetworkManager.has_player_name(peer_id):
		return "peer %d" % peer_id
	return "%s (peer %d)" % [NetworkManager.display_name(peer_id), peer_id]
