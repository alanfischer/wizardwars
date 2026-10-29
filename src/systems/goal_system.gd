extends Node
# GoalSystem — central registry for TFC goal entities (item_tfgoal, i_t_g, info_tfgoal).
# Keyed by goal_no and group_no. Tracks team scores.

signal kill_occurred(killer_peer: int, victim_peer: int)

# goal_no -> Node (must have tf_goal_base methods)
var _goals: Dictionary = {}

# group_no -> Array[Node]
var _groups: Dictionary = {}

# Every registered goal node, including those with no goal_no/group_no (e.g. detpack
# breach goals). _goals is keyed by goal_no and so silently omits goal_no==0 goals.
var _all_goals: Array = []

# Team scores indexed 0-4 (0=none, 1=blue, 2=red, 3=yellow, 4=green)
var team_scores: Array[int] = [0, 0, 0, 0, 0]

# Per-player kill/death tracking — keyed by peer_id
var player_kills: Dictionary = {}   # peer_id -> int
var player_deaths: Dictionary = {}  # peer_id -> int

# Team configuration (set by info_tfdetect / info_wwdetect)
var team_count: int = 0  # Explicit count from number_of_teams key (0 = not set)
var team_names: Array[String] = ["Blue", "Red", "", ""]
var team_max_players: Array[int] = [0, 0, 0, 0]  # 0 = unlimited
# Bitmask of teams explicitly declared via team names/lives/restrictions in detect entities
var _declared_teams: int = 0

# Team alliances: indexed 0-3 for teams 1-4. Each entry is a bitmask of allied teams.
# e.g. team_allies[0] = 2 means team 1 (Blue) is allied with team 2 (Red).
var team_allies: Array[int] = [0, 0, 0, 0]

# True when the map declares flag HUD status (info_tfdetect display_item_status* keys) —
# i.e. it's a CTF/flag map. Gates the "flag captured"/"enemy scores" score VOX, which is
# nonsensical on non-flag maps (ww_hunt's escape, ww_golem, etc. announce via HUD text).
var display_item_status: bool = false

# True when the map asks for combo chaos (info_wwdetect "combo_chaos"), which turns its leftover
# GoldSrc weapon/ammo pickups and its TFC resupply grenades into random combo spellbooks.
# See is_combo_chaos.
var map_combo_chaos: bool = false

# Class restriction bitmasks per team (indexed 0-3 for teams 1-4).
# Bit set = class BLOCKED. Uses TFC class bits mapped to WW elements.
var class_restrictions: Array[int] = [0, 0, 0, 0]

# TFC class bit -> WW Element mapping
const TFC_BIT_TO_ELEMENT := {
	1: GameConsts.Element.WIND,        # Scout
	2: GameConsts.Element.LIGHTNING,    # Sniper
	4: GameConsts.Element.FIRE,        # Soldier
	8: GameConsts.Element.EARTH,       # Demoman
	16: GameConsts.Element.LIFE,       # Medic
	32: GameConsts.Element.DEATH,      # HWGuy
	# 64: Pyro — unmapped
	# 128: Random — not a class
	256: GameConsts.Element.ICE,       # Spy
	512: GameConsts.Element.NATURE,    # Engineer
	# -1: Archmage (Civilian) — handled specially
}

# Reverse: WW Element -> TFC class bit
const ELEMENT_TO_TFC_BIT := {
	GameConsts.Element.WIND: 1,
	GameConsts.Element.LIGHTNING: 2,
	GameConsts.Element.FIRE: 4,
	GameConsts.Element.EARTH: 8,
	GameConsts.Element.LIFE: 16,
	GameConsts.Element.DEATH: 32,
	GameConsts.Element.ICE: 256,
	GameConsts.Element.NATURE: 512,
	GameConsts.Element.ARCHMAGE: -1,  # Civilian — only allowed if restriction == -1
}


func register(goal: Node, goal_no: int, group_no: int) -> void:
	if not _all_goals.has(goal):
		_all_goals.append(goal)
	if goal_no != 0:
		# Maps do ship duplicate goal_no's; TFC's Findgoal() returns the first match,
		# so the first entity to register wins here too (spawn order is BSP order).
		if _goals.has(goal_no):
			Log.debug("GoalSystem: goal_no %d already registered, keeping the first" % goal_no)
		else:
			_goals[goal_no] = goal
	if group_no != 0:
		if not _groups.has(group_no):
			_groups[group_no] = []
		_groups[group_no].append(goal)


func unregister(node: Node) -> void:
	_all_goals.erase(node)
	for key in _goals.keys():
		if _goals[key] == node:
			_goals.erase(key)
	for key in _groups.keys():
		var arr: Array = _groups[key]
		arr.erase(node)
		if arr.is_empty():
			_groups.erase(key)


func get_goal(goal_no: int) -> Node:
	return _goals.get(goal_no, null)


func get_group(group_no: int) -> Array:
	return _groups.get(group_no, [])


func get_all_goals() -> Array:
	return _all_goals.filter(func(g): return is_instance_valid(g) and g.is_inside_tree())


## Is this goal a flag a player can pick up by walking into it? `is ItemTFGoal` is NOT the test:
## ww_golem's crystals are item_tfgoals too and nobody can carry those. _is_touch_grabbable is
## the same check the goal's own touch handler runs, which is what makes this the real answer.
func is_carriable_flag(g) -> bool:
	return _is_goal_prop(g) and g._is_touch_grabbable()


## A team's base fixture: the same thing standing in a base, except that it may not be picked up,
## which is what makes it the better landmark of the two. ww_golem's crystal is the only one in
## the shipped maps — the thing a golem is driven across the map to smash.
func is_base_fixture(g) -> bool:
	return _is_goal_prop(g) and not g._is_touch_grabbable()


## A goal standing in the world as a model on a pedestal rather than as a brush volume: the half
## of the test the two above share. Its origin is where it stands, so a caller may use the node's
## own position instead of measuring its mesh.
static func _is_goal_prop(g) -> bool:
	return g is ItemTFGoal and not g._is_brush and g._has_model


## Every carriable flag currently in the world. Static for the map's lifetime, so callers that
## want it per frame should resolve it once and re-validate rather than asking again.
func get_carriable_flags() -> Array:
	var out: Array = []
	for g in get_all_goals():
		if is_carriable_flag(g):
			out.append(g)
	return out


# Listener groups a scoring goal already speaks to itself, so the generic stinger
# would only repeat it. Set by the goal that scored (see tf_goal_base.speak_coverage).
const SPOKEN_FRIENDLY := 1
const SPOKEN_ENEMY := 2


## The board is frozen once the match is decided: it is up on everyone's screen for the whole
## intermission, and a goal still ticking over behind it must not move what people are reading.
## Every mutator below asks, so the freeze can't drift as more of them appear.
func _scoring_open() -> bool:
	return not MatchSystem.is_intermission()


func add_score(team: int, points: int, spoken: int = 0) -> void:
	if team < 0 or team > 4 or points == 0 or not _scoring_open():
		return
	team_scores[team] += points
	Log.info("Team %d score: %d (+%d)" % [team, team_scores[team], points], "tfgoal")
	if NetworkManager.is_online() and NetworkManager.is_host():
		sync_score.rpc(team, team_scores[team], true, spoken)
	announce_score(team, spoken)
	# Every scoring path in the game lands here — TF goals, PotatoC's GiveTeamPoints, a map's own
	# win logic — so this is the one place a score limit has to be checked.
	MatchSystem.note_team_score(team, team_scores[team])


## Client receive: the authority sends the absolute total, not the delta add_score applied, so
## this cannot be add_score re-sending itself. `announce` is false for the join snapshot, which
## must not retrigger the score stinger for points scored before the joiner arrived.
@rpc("authority", "call_remote", "reliable")
func sync_score(team: int, total: int, announce := true, spoken := 0) -> void:
	if team < 0 or team >= team_scores.size():
		return
	team_scores[team] = total
	if announce:
		announce_score(team, spoken)


## Most recent physics frame each phrase played. A single capture can award several
## teams at once (a goal with increase_team1 AND increase_team2, allied teams scoring
## together), so the listener would otherwise hear one stinger per scoring team. Keyed
## by phrase (friendly/enemy) so those collapse to one "flag captured", while a genuine
## friendly-and-enemy pair in the same frame still each play once.
var _last_announce_frame: Dictionary = {}


## VOX announcer for a score event, phrased for the local listener ("flag captured"
## when our side scores, "enemy scores" otherwise). Runs on the authority from
## add_score and on clients from the sync_score receive — the wording depends on
## the listener's team, so each peer announces locally instead of syncing audio.
## `spoken` names the listener groups the scoring goal already speaks to (TFC
## AP_speak/team_speak/non_team_speak); those hear the map's own line instead.
func announce_score(team: int, spoken: int = 0) -> void:
	var main := get_tree().current_scene
	if not main:
		return
	var lp = Game.local_player
	if lp == null:  # dedicated server — nobody listening
		return
	if not display_item_status:
		return  # non-flag map (ww_hunt, etc.) — the goal's HUD broadcast carries the news
	# Allied teams can score together — an ally's points are still "our" score, not "enemy".
	var friendly: bool = lp.team == team or Teams.teams_friendly(lp.team, team)
	if spoken & (SPOKEN_FRIENDLY if friendly else SPOKEN_ENEMY):
		return
	var frame := Engine.get_physics_frames()
	if _last_announce_frame.get(friendly) == frame:
		return  # already played this phrase this frame — don't double it
	_last_announce_frame[friendly] = frame
	if friendly:
		SentenceSystem.play_words(["vox/flag.wav", "vox/captured.wav"])
	else:
		SentenceSystem.play_words(["vox/enemy.wav", "vox/scores.wav"])


## The map's own name for a team, then the stock colour, then a number. Four places grew their own
## copy of this ladder before it lived anywhere.
func get_team_name(team: int) -> String:
	var team_name := ""
	if team >= 1 and team <= team_names.size():
		team_name = team_names[team - 1]
	if team_name.is_empty():
		team_name = GameConsts.TEAM_NAMES.get(team, "Team %d" % team)
	return team_name


func get_score(team: int) -> int:
	if team < 0 or team > 4:
		return 0
	return team_scores[team]


## The playing teams grouped by alliance — each group in ascending team order, groups ordered by
## their lowest team. Allied teams are one side and belong on one score line: ww_chasm's
## dragonrider teams 3 and 4 ride with blue and red, so its board reads two sides, not four.
## A map that declares no alliances gets a group per team, i.e. today's behaviour.
func get_team_groups() -> Array:
	var count := get_team_count()
	var groups: Array = []
	var placed := {}
	for t in range(1, count + 1):
		if placed.has(t):
			continue
		var group: Array[int] = [t]
		placed[t] = true
		# Walk the group as it grows so an ally's allies land on the same side even when the map
		# never names that pair directly.
		var i := 0
		while i < group.size():
			for other in range(1, count + 1):
				if not placed.has(other) and _teams_allied(group[i], other):
					group.append(other)
					placed[other] = true
			i += 1
		group.sort()
		groups.append(group)
	return groups


## Alliances are mutual, however the map spelled them. ww_chasm names both directions, ww_feudal
## only names 3->4 and 4->3 — but a map naming one side alone still means one side.
func _teams_allied(a: int, b: int) -> bool:
	if a < 1 or a > 4 or b < 1 or b > 4:
		return false
	return team_allies[a - 1] & (1 << (b - 1)) != 0 or team_allies[b - 1] & (1 << (a - 1)) != 0


## One alliance's score. Allied teams score in mirror — ww_hunt's escape goal carries
## increase_team1 AND increase_team2 for the same escape — so the side's score is its highest
## member, not the sum, which would double every shared award and drift from the score limit
## MatchSystem checks against per-team totals.
func get_group_score(group: Array) -> int:
	var best := 0
	for t in group:
		best = maxi(best, get_score(t))
	return best


## Effective team count — mirrors C++ NumTeams/ValidTeams logic.
## Priority: explicit team_count > declared teams bitmask > spawn-derived teams.
## Only number_of_teams and a teamN_name declare a team; the other per-team detect
## keys are settings, not declarations (see info_tfdetect).
func get_team_count() -> int:
	if team_count > 0:
		return team_count
	var bits := _declared_teams | SpawnSystem.global_teams
	var count := 0
	for i in range(4):
		if bits & (1 << i):
			count = i + 1  # Highest team seen determines count
	return max(count, 2)  # Fallback to 2


func is_valid_class(team: int, element: int) -> bool:
	if team < 1 or team > 4:
		return true
	var restrictions := class_restrictions[team - 1]
	var bit: int = ELEMENT_TO_TFC_BIT.get(element, 0)
	if bit == -1:
		# Archmage (Civilian): only allowed when restrictions == -1 (civilian-only team)
		return restrictions == -1
	if restrictions == 0:
		return true  # No restrictions
	if bit == 0:
		return true  # Unmapped element, allow
	return (restrictions & bit) == 0  # Bit set = BLOCKED


## Returns the number of players occupying a slot on a team.
func get_team_player_count(team: int) -> int:
	var count := 0
	var teams := _team_by_peer()
	for peer_id in teams:
		if teams[peer_id] == team:
			count += 1
	return count


## peer id -> team, built the same way the scoreboard builds its rows: the PVS-independent roster
## first, then any live body on top (freshest, and the only place a pending class change shows).
## Counting bodies alone showed a client only the players inside its own PVS, so a spectator at the
## team menu saw an empty team the host then refused them from.
func _team_by_peer() -> Dictionary:
	var teams := NetworkManager.peer_teams()
	var roster := NetworkManager.player_roster()
	for peer_id in roster:
		teams[peer_id] = _counted_team(roster[peer_id])
	return teams


## A player switching class/team reserves a slot on their destination team for the
## whole respawn delay, even though `team` only updates when they actually respawn
## (see remote_player.die_for_class_change). Count them against the pending team so
## a limited team can't be over-filled during that window. Falls back to `team`
## otherwise — only test stand-ins lack the pending field; every real Player has it.
func _counted_team(node) -> int:
	var pending = node.get("class_change_pending_team")
	if pending != null and pending >= 0:
		return pending
	return node.get("team")


func is_team_full(team: int) -> bool:
	if team < 1 or team > 4:
		return false
	var limit: int = team_max_players[team - 1]
	if limit <= 0:
		return false  # unlimited
	return get_team_player_count(team) >= limit


func valid_classes_for_team(team: int) -> Array[int]:
	var result: Array[int] = []
	for element_id in GameConsts.Element.values():
		if is_valid_class(team, element_id):
			result.append(element_id)
	return result


func record_kill(killer_peer: int, victim_peer: int) -> void:
	# The tallies freeze with the rest of the board, but the event still fires: a death RPC that
	# lands just after the whistle is a kill that happened during play, and the feed should say so.
	if _scoring_open():
		# peer 0 is the world/environment (fall/lava); skip it. Bots use negative peer ids
		# and ARE scored, so gate on != 0, not > 0.
		if killer_peer != 0 and killer_peer != victim_peer:
			player_kills[killer_peer] = player_kills.get(killer_peer, 0) + 1
			MatchSystem.note_player_frags(killer_peer, player_kills[killer_peer])
		if victim_peer != 0:
			player_deaths[victim_peer] = player_deaths.get(victim_peer, 0) + 1
	kill_occurred.emit(killer_peer, victim_peer)


## Award objective points (PotatoC GivePoints/GivePlayerPoints) to a player,
## folded into their frag count. Server-authoritative: applies locally and
## then re-sends itself to the clients, which take the same path with is_host()
## false and so do not re-broadcast.
@rpc("authority", "call_remote", "reliable")
func add_player_points(peer_id: int, points: int) -> void:
	# peer 0 = world/no player. Bots (negative peer ids) DO earn objective points,
	# like record_kill — gate on != 0, not > 0.
	if peer_id == 0 or points == 0 or not _scoring_open():
		return
	player_kills[peer_id] = player_kills.get(peer_id, 0) + points
	# Objective points sit in the same column as frags, so they count toward a frag limit too.
	MatchSystem.note_player_frags(peer_id, player_kills[peer_id])
	if NetworkManager.is_online() and NetworkManager.is_host():
		add_player_points.rpc(peer_id, points)


## The join snapshot's per-player tallies; the live ones ride the kill and point paths.
@rpc("authority", "call_remote", "reliable")
func sync_player_stats(peer_id: int, kills: int, deaths: int) -> void:
	player_kills[peer_id] = kills
	player_deaths[peer_id] = deaths


func get_kills(peer_id: int) -> int:
	return player_kills.get(peer_id, 0)


func get_deaths(peer_id: int) -> int:
	return player_deaths.get(peer_id, 0)


## Is combo chaos on right now? The map declares it and the server gets the last word:
## /combo_chaos auto (default, follow the map), on (force everywhere), off (force nowhere).
func is_combo_chaos() -> bool:
	match str(ServerVars.get_value("combo_chaos", "auto")).to_lower():
		"on", "1", "true": return true
		"off", "0", "false": return false
		_: return map_combo_chaos


func reset() -> void:
	_goals.clear()
	_groups.clear()
	_all_goals.clear()
	team_scores = [0, 0, 0, 0, 0]
	player_kills.clear()
	player_deaths.clear()
	team_count = 0
	_declared_teams = 0
	team_names = ["Blue", "Red", "", ""]
	team_max_players = [0, 0, 0, 0]
	class_restrictions = [0, 0, 0, 0]
	team_allies = [0, 0, 0, 0]
	display_item_status = false
	map_combo_chaos = false
