extends Node
## Self-contained AI bot module (autoload).
##
## A bot is a host-side RemotePlayer puppet with a ServerMovement queue, identical to a
## connected client's puppet, except its InputCommands come from a BotBrain each tick instead
## of the network. Everything downstream is reused unchanged.
##
## Bots use synthetic NEGATIVE peer ids, so is_peer_connected() is false for them and every
## per-peer RPC auto-skips them. Clients can't build a puppet for a non-ENet id on their own,
## so a roster RPC (below) tells them to create/free a client-side puppet keyed by bot id.

const RemotePlayerScene = preload("res://src/remote_player.tscn")
const BotBrain = preload("res://src/bot/bot_brain.gd")
const WaypointGraph = preload("res://src/bot/waypoint_graph.gd")

var _bots: Array = []                 # RemotePlayer bot puppets (host-only)
var _brains: Array = []               # parallel to _bots, avoids a per-tick get_node lookup
var _roster: Dictionary = {}          # bot id -> {name, element, team, pos, yaw} for late joiners
var _next_bot_id := -1                # next synthetic bot peer id (decrements)
var _waypoints: WaypointGraph = null  # per-map navigation graph (null if the map has no file)
var _waypoints_map := ""              # map name the graph was loaded for (staleness check)
var _control_points: PackedVector3Array = PackedVector3Array()  # sequential capture-point centres
									  # (ww_chasm PotatoC point1..N), empty off such maps


func _get_main() -> Node:
	return get_tree().current_scene


# --- Public API (host-only) -----------------------------------------------

## The bots in play, as the arguments that would recreate them. A map change frees every puppet
## (see reset), so main takes this before the unload and hands it back on the new map.
func roster_snapshot() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for id in _roster:
		# get() with a default, not a bare index: this runs on the map-change path, where a
		# missing key would take the whole roster down and lose every bot rather than one field.
		out.append({"element": int(_roster[id]["element"]), "team": int(_roster[id]["team"]),
				"skill": float(_roster[id].get("skill", -1.0))})
	return out


## Put a snapshot back after a map change. Returns how many made it onto the new map.
##
## A bot's old team may not fit where it's going — ww_hunt's civilian team is one slot wide, and a
## map can carry no spawn for a team at all — and keeping the bot matters more than keeping it
## where it was, so a refused team falls back to the same auto-balance a fresh /addbot gets.
func restore_roster(snapshot: Array[Dictionary]) -> int:
	var added := 0
	for bot in snapshot:
		var element := int(bot.get("element", -1))
		var skill := float(bot.get("skill", -1.0))
		if add_bot(element, int(bot.get("team", -1)), skill) != 0 \
				or add_bot(element, -1, skill) != 0:
			added += 1
	return added


## Add an AI bot. Returns its synthetic peer id (0 on failure).
## element < 0 → default fire; team < 0 → auto-balance onto the smallest playing team;
## skill < 0 → take the `bot_skill` server var, which itself defaults to a per-bot random roll.
func add_bot(element: int = -1, team: int = -1, skill: float = -1.0) -> int:
	if NetworkManager.is_online() and not NetworkManager.is_host():
		return 0
	var main := _get_main()
	if main == null or not Game.game_active:
		return 0
	if team < 1 or team > GoalSystem.get_team_count():
		team = _auto_balance_team()
	# Per-team player caps bind bots exactly as they bind humans (network_manager
	# ServerRequests.join_team). ww_hunt's civilian team is one slot wide, and it's
	# also the smallest team, so auto-balance would keep stacking Archmages onto it.
	if GoalSystem.is_team_full(team):
		push_warning("[Bot] Team %d is full" % team)
		return 0
	if element < 0:
		element = _random_class(team)
	# An explicit skill beats the var; the var's own default is negative, which BotBrain.setup
	# reads as "roll one", so the out-of-the-box mix of good and sloppy bots is unchanged.
	if skill < 0.0:
		skill = float(ServerVars.get_value("bot_skill", -1.0))
	# Some maps block elements per team; never let a bot spawn as an illegal class.
	if not GoalSystem.is_valid_class(team, element):
		var valid := GoalSystem.valid_classes_for_team(team)
		if not valid.is_empty():
			element = valid[0]
	var sp := SpawnSystem.get_spawn_for_team(team)
	if sp == null:
		push_warning("[Bot] No active spawn for team %d" % team)
		return 0

	_ensure_waypoints(main)

	var id := _next_bot_id
	_next_bot_id -= 1
	# Replicates via MultiplayerSpawner; clients build their own puppet from the replicated spawn.
	var bot: RemotePlayer = main._player_spawner.spawn({peer_id = id, node_name = "Bot_%d" % (-id)})
	bot.is_host_puppet = true
	# `spawned` doesn't fire on the authority, so register the puppet explicitly here.
	main._on_puppet_spawned(bot)
	bot.team = team
	bot.setup_server_movement()
	_bots.append(bot)
	var bot_name := "BOT %s" % GameConsts.ELEMENT_NAMES.get(element, "wizard")
	NetworkManager.set_player_name(id, bot_name)
	NetworkManager.set_player_team(id, team)

	bot.spawn_at(sp, element, true)
	var pos: Vector3 = sp.get_spawn_position()
	var yaw: float = sp.rotation.y
	_roster[id] = {name = bot_name, element = element, team = team, pos = pos, yaw = yaw,
			skill = skill}

	# Spawner replicates the body; broadcast team/element/name so it renders correctly for
	# already-connected clients (late joiners get this via request_player_states).
	NetworkManager.sync_team_for_peer.rpc(id, team, element, pos, yaw)
	NetworkManager.sync_player_name.rpc(id, bot_name)

	var brain := BotBrain.new()
	brain.name = "BotBrain"
	bot.add_child(brain)
	brain.setup(bot, main, _waypoints if (_waypoints != null and _waypoints.loaded) else null,
			_control_points, skill)
	_brains.append(brain)

	Log.info("[Bot] Added bot id=%d team=%d element=%d at %s" % [id, team, element, pos])
	return id


## Remove all bots and tell clients to free their client-side puppets. Returns the count.
func remove_all_bots() -> int:
	var n := _bots.size()
	for bot in _bots:
		if is_instance_valid(bot):
			_teardown_bot(bot)
	_bots.clear()
	_brains.clear()
	_roster.clear()
	Log.info("[Bot] Removed %d bot(s)" % n)
	return n


## Remove one bot by its synthetic peer id — what /kick calls when the name it was
## given belongs to a bot, which has no connection to close. False if no such bot.
func remove_bot(id: int) -> bool:
	var idx := -1
	for i in _bots.size():
		if is_instance_valid(_bots[i]) and _bots[i].peer_id == id:
			idx = i
			break
	if idx == -1:
		return false
	_teardown_bot(_bots[idx])
	_bots.remove_at(idx)
	_brains.remove_at(idx)  # parallel to _bots — both only ever grow together in add_bot
	_roster.erase(id)
	Log.info("[Bot] Removed bot id=%d" % id)
	return true


## Put a bot back at one of its team's spawns. Last resort for a bot wedged in world geometry —
## velocity but no displacement, which no amount of re-pathing can fix (see BotBrain.WEDGE_T).
## Mirrors what main.respawn_all_players does per player, so clients see the same move.
func free_wedged(bot) -> bool:
	if bot == null or not is_instance_valid(bot) or bot.team == GameConsts.Team.NONE:
		return false
	var sp := SpawnSystem.get_spawn_for_team(bot.team)
	if sp == null:
		return false
	bot.spawn_at(sp, bot.element, true, false)
	bot.sync_spawn_to_network(sp)
	bot._apply_spawn_point_effects(sp)
	return true


## Everything a bot leaving takes with it. The caller owns _bots/_brains/_roster, which
## differ between removing one and removing them all.
func _teardown_bot(bot) -> void:
	var id: int = bot.peer_id
	NetworkManager.drop_peer_state(id)
	# Full disconnect teardown, not just a free: drop_peer_state leaves the player registry alone,
	# and a bot raises neither peer_disconnected nor a host-side `despawned`. Freeing the puppet
	# while the registry still holds it is the /killbots crash — see test_killbots_despawn.gd.
	# drop_peer_state has to run first and leave the body alone, since despawn_player needs it.
	if not NetworkManager.despawn_player(id):
		bot.cleanup_for_class_change()  # not in the registry — free it here, don't leak it
		bot.queue_free()


## Host-only: drive every bot's AI one physics tick. Called from main._physics_process
## before _process_player_movements() so each enqueued command is consumed the same tick.
func tick(delta: float) -> void:
	for brain in _brains:
		if is_instance_valid(brain):
			brain.tick(delta)


## Load the navigation graph for the current map (once): the hand-authored HPB file if present,
## else a baked .gen_wpt from tools/bake_waypoints.sh. Maps with neither fall back to the
## reactive local steer (whiskers/wall-follow) in bot_brain.
func _ensure_waypoints(main: Node) -> void:
	var map_name := Game.current_map_name
	if _waypoints != null and _waypoints_map == map_name:
		return
	_waypoints = WaypointGraph.new()
	_waypoints_map = map_name
	_detect_control_points(main)
	# Baked graph first. The hand files came from a human who walked every link, which is why they
	# used to win — but they are coarse and fragmented next to a bake (a few hundred nodes at 5-10m
	# spacing, most of them tombstoned, against tens of thousands at 1m), and the one thing they
	# knew that a sampler could not, a lift shaft, the baker now finds for itself. A hand file is
	# the fallback for a map with no bake at all.
	if _waypoints.load_generated(map_name):
		return
	if _waypoints.load_map(map_name):
		return
	Log.info("[Bot] No waypoint file for '%s' — bots will steer locally (whiskers)" % map_name)


## Sequential control-point maps (ww_chasm's PotatoC) name their capture triggers point1code..pointNcode.
## Record each cap volume's centre, ordered by N (see BotBrain._sequential_cap_target). Empty off
## such maps.
func _detect_control_points(main: Node) -> void:
	_control_points = PackedVector3Array()
	var by_index := {}
	for node in main.find_children("*", "", true, false):
		if not node is TriggerMultiple:
			continue
		var tgt: String = node.ent.get("target", "")
		if not (tgt.begins_with("point") and tgt.ends_with("code")):
			continue
		var mid := tgt.substr(5, tgt.length() - 9)  # "point" <N> "code"
		if mid.is_valid_int():
			by_index[int(mid)] = _brush_center(node)
	if by_index.is_empty():
		return
	var indices := by_index.keys()
	indices.sort()
	for i in indices:
		_control_points.append(by_index[i])
	Log.info("[Bot] '%s': %d sequential control point(s)" % [_waypoints_map, _control_points.size()])


## World-space centre of a brush entity's volume — the cap's middle. Brush entities carry no `origin`
## (node sits at world 0), so the real spot is the collision/mesh AABB. Trigger volumes are collision-
## only (nodraw texture, no render mesh), so try the CollisionShape3D first, mesh as a fallback.
func _brush_center(node: Node3D) -> Vector3:
	var out := AABB()
	var have := false
	for c in node.find_children("*", "CollisionShape3D", true, false):
		var cs := c as CollisionShape3D
		if cs.shape == null:
			continue
		var w := cs.global_transform * cs.shape.get_debug_mesh().get_aabb()
		out = w if not have else out.merge(w)
		have = true
	if not have:
		for m in node.find_children("*", "MeshInstance3D", true, false):
			var mi := m as MeshInstance3D
			if mi.mesh == null:
				continue
			var w := mi.global_transform * mi.mesh.get_aabb()
			out = w if not have else out.merge(w)
			have = true
	return out.get_center() if have else node.global_position


## Map unload: drop all bot state. Puppets are freed by main._unload_map, but bots have no ENet
## peer, so nothing fires peer_disconnected to clear their scoreboard roster entry — erase it here
## (as remove_all_bots does) or removed bots linger in the Tab view after a map change.
func reset() -> void:
	for bot in _bots:
		if not is_instance_valid(bot):
			continue
		NetworkManager.drop_peer_state(bot.peer_id)
	_bots.clear()
	_brains.clear()
	_roster.clear()
	_next_bot_id = -1
	_waypoints = null
	_waypoints_map = ""
	_control_points = PackedVector3Array()


# --- Auto team balance ----------------------------------------------------

func _auto_balance_team() -> int:
	# Only the map's playing teams (get_team_count — the same set the human team menu offers).
	# A map can carry spawn points for teams it doesn't use (ww_ravine2 has yellow/green spawns
	# but is a 2-team map), so spawn existence alone is not a valid team filter.
	var best_team := -1
	var best_count := 0x7fffffff
	for t in range(1, GoalSystem.get_team_count() + 1):
		if SpawnSystem.get_spawn_for_team(t) == null:
			continue
		# Skip dragonrider-only teams (ww_chasm 3/4): they're mount-a-dragon slots
		# allied to a foot team, not something a bot can play on foot.
		if SpawnSystem.team_is_dragonrider_only(t):
			continue
		if GoalSystem.is_team_full(t):
			continue
		var c := GoalSystem.get_team_player_count(t)
		if c < best_count:
			best_count = c
			best_team = t
	return best_team if best_team >= 0 else GameConsts.Team.BLUE


## A random wizard class legal for the given team (respects per-team class restrictions the
## same way the human class menu does). Falls back to fire if nothing is available.
func _random_class(team: int) -> int:
	var valid := GoalSystem.valid_classes_for_team(team)
	if valid.is_empty():
		return GameConsts.Element.FIRE
	return valid[randi() % valid.size()]
