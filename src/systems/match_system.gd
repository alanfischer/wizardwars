extends Node
## What ends a map, and what comes next.
##
## Host-authoritative: only the authority runs the clock, decides a winner and picks the next map.
## Clients are told the state once per transition and render the countdown against the server clock,
## so a running match costs no traffic at all.

enum State { PLAYING, INTERMISSION }

## How long the final scoreboard stays up before the next map loads.
const INTERMISSION_SECONDS := 12.0

## Looked for in order when no --mapcycle was given. The user:// copy lets a server operator edit
## the rotation without touching the shipped one.
const USER_CYCLE_PATH := "user://mapcycle.txt"
const RES_CYCLE_PATH := "res://maps/mapcycle.txt"

## How many maps the intermission puts to a vote.
const VOTE_CANDIDATES := 3

signal state_changed(state: int)

var state: State = State.PLAYING
## 0 while playing, and after a match that ended level.
var winner_team := 0
## Set when one player won it outright (a frag limit); empty when the result is a team's.
var winner_name := ""
## "time", "score", "frags", or "" while playing.
var end_reason := ""
var next_map := ""
var current_map := ""
## Server time (ms) the time limit expires at; 0 = playing without one.
var match_end_ms := 0
## Server time (ms) the next map loads at; 0 = not in an intermission.
var intermission_end_ms := 0

## The maps this intermission is voting between, in the order they're offered. Empty when there's
## nothing to vote on — a one-map cycle, or an admin who already named the next map.
var vote_candidates: PackedStringArray = PackedStringArray()

## --mapcycle <path>. Empty = look in the usual places.
var cycle_path := ""

var _cycle: Array[String] = []
var _cycle_source := ""
var _cursor := -1
var _forced_next := ""  # /nextmap <map>, cleared once it has been served
var _votes: Dictionary = {}  # peer_id -> index into vote_candidates


func _ready() -> void:
	# Nothing to count down to until a map goes live, and a client never counts anything down —
	# _tick_while_counting_down puts the 60Hz callback back to sleep whenever both deadlines are 0.
	set_physics_process(false)
	ServerVars.value_changed.connect(_on_server_var_changed)
	# A voter who leaves takes their vote with them, or a map wins on the say-so of someone who
	# isn't there to play it.
	NetworkManager.peer_disconnected.connect(_on_peer_disconnected)


## The authority owns the clock; a client reads the estimate it is fed. Offline there is no session
## feeding the estimator, so the local clock is the only one there is.
func _now_ms() -> int:
	if NetworkManager.is_authority():
		return Time.get_ticks_msec()
	return int(NetworkManager.get_estimated_server_time() * 1000.0)


# --- The match ------------------------------------------------------------

## A map is up and playable. Restarts the clock, and remembers where in the cycle we are so the
## rotation continues from a map an admin picked by hand.
func begin_map(map_name: String) -> void:
	if not NetworkManager.is_authority():
		return
	_ensure_cycle()
	_clear_match_state(map_name)
	_sync_cursor_to(map_name)
	_restart_clock()
	# Playing on the same map rebuilds no HUD, so the final scoreboard needs taking down here —
	# a client gets the same in apply_remote.
	_dismiss()
	state_changed.emit(state)
	_broadcast()


## Back to a match nobody has won yet. Shared with reset() so a new piece of match state can only
## be forgotten in one place instead of two.
func _clear_match_state(map_name := "") -> void:
	state = State.PLAYING
	winner_team = 0
	winner_name = ""
	end_reason = ""
	next_map = ""
	current_map = map_name
	match_end_ms = 0
	intermission_end_ms = 0
	_clear_vote()


## Recompute the deadline from the current timelimit. Also how a mid-match /timelimit takes hold.
func _restart_clock() -> void:
	var minutes := int(ServerVars.get_value("timelimit", 0))
	match_end_ms = 0 if minutes <= 0 else _now_ms() + minutes * 60 * 1000
	_tick_while_counting_down()


## The tick exists to notice a deadline pass, so it only runs while there is one. A server with no
## time limit, and every client, spend nothing on it.
func _tick_while_counting_down() -> void:
	set_physics_process(NetworkManager.is_authority()
		and (match_end_ms > 0 or intermission_end_ms > 0))


func _on_server_var_changed(key: String, _value: Variant) -> void:
	if key == "timelimit" and NetworkManager.is_authority() and state == State.PLAYING:
		_restart_clock()
		_broadcast()


func _physics_process(_delta: float) -> void:
	if state == State.INTERMISSION:
		if intermission_end_ms > 0 and _now_ms() >= intermission_end_ms:
			_advance_map()
		return
	if match_end_ms > 0 and _now_ms() >= match_end_ms:
		end_match("time")


## Every scoring path in the game funnels through GoalSystem.add_score, so one call from there
## covers TF goals, PotatoC's GiveTeamPoints and a map's own win logic alike.
func note_team_score(_team: int, total: int) -> void:
	if not NetworkManager.is_authority() or state != State.PLAYING:
		return
	var limit := int(ServerVars.get_value("scorelimit", 0))
	if limit > 0 and total >= limit:
		end_match("score")


## A player's own tally — frags plus the objective points that fold into them (GoalSystem
## record_kill and add_player_points). Ends the match on the player, not their team, so a
## deathmatch map with no teams still has a winner to name.
func note_player_frags(peer_id: int, total: int) -> void:
	if not NetworkManager.is_authority() or state != State.PLAYING or peer_id == 0:
		return
	var limit := int(ServerVars.get_value("fraglimit", 0))
	if limit > 0 and total >= limit:
		end_match("frags", peer_id)


## True while the match is over but the next map has not loaded. Damage and scoring are off.
func is_intermission() -> bool:
	return state == State.INTERMISSION


## Seconds left on the clock (playing) or on the intermission. -1.0 when nothing is counting down.
func time_left() -> float:
	var deadline := intermission_end_ms if state == State.INTERMISSION else match_end_ms
	if deadline <= 0:
		return -1.0
	return maxf(0.0, (deadline - _now_ms()) / 1000.0)


## `winner_peer` names the player who ended it (a frag limit); otherwise the leading team wins.
## The countdown as m:ss — whichever of the two clocks is running. "" when neither is.
func time_left_text() -> String:
	var left := time_left()
	if left < 0.0:
		return ""
	var total := int(left)
	# Truncation is the point: total / 60 is the minute the clock is showing.
	@warning_ignore("integer_division")
	return "%d:%02d" % [total / 60, total % 60]


func end_match(reason: String, winner_peer: int = 0) -> void:
	if not NetworkManager.is_authority() or state == State.INTERMISSION:
		return
	state = State.INTERMISSION
	end_reason = reason
	winner_name = ""
	if winner_peer != 0:
		winner_name = NetworkManager.display_name(winner_peer)
		var body = NetworkManager.get_player(winner_peer)
		winner_team = int(body.team) if body != null else 0
	else:
		winner_team = _leading_team()
	match_end_ms = 0
	intermission_end_ms = _now_ms() + int(INTERMISSION_SECONDS * 1000.0)
	_tick_while_counting_down()
	next_map = peek_next_map()
	_open_vote()
	Log.info("[Match] Over on %s — %s, next map %s%s" % [
		reason,
		winner_name if not winner_name.is_empty() else ("draw" if winner_team == 0 else "team %d wins" % winner_team),
		next_map,
		" (%d up for a vote)" % vote_candidates.size() if not vote_candidates.is_empty() else ""])
	state_changed.emit(state)
	_present()
	_broadcast()
	_broadcast_vote()


## The single highest-scoring team, or 0 if nobody leads outright.
func _leading_team() -> int:
	var best := 0
	var best_score := 0
	var tied := false
	for t in range(1, GoalSystem.get_team_count() + 1):
		var s := GoalSystem.get_score(t)
		if best == 0 or s > best_score:
			best = t
			best_score = s
			tied = false
		elif s == best_score:
			tied = true
	return 0 if tied else best


func _advance_map() -> void:
	intermission_end_ms = 0
	var target := next_map
	# Same channel /map uses (command_system._cmd_map), so there is one route into a level change
	# rather than a private one for the rotation.
	var listeners := not NetworkManager.map_change_server_request.get_connections().is_empty()
	if target.is_empty() or not listeners:
		# Nothing to change to (a one-map cycle, or no server listening): just play on.
		begin_map(current_map)
		return
	if target == _forced_next:
		_forced_next = ""
	NetworkManager.map_change_server_request.emit(target)


# --- The vote --------------------------------------------------------------

## Offer the next few maps in the rotation. Nothing is offered when an admin has already named the
## next map, or when the cycle is too short for the choice to mean anything — a vote with one
## answer is just a delay.
func _open_vote() -> void:
	_votes.clear()
	vote_candidates = PackedStringArray()
	if not _forced_next.is_empty() or _cycle.size() < 2:
		return
	var start := _cursor + 1 if _cursor >= 0 else 0
	for i in _cycle.size():
		var candidate: String = _cycle[(start + i) % _cycle.size()]
		if candidate == current_map or candidate in vote_candidates:
			continue
		vote_candidates.append(candidate)
		if vote_candidates.size() >= VOTE_CANDIDATES:
			break
	# The map just played is never a candidate, so a two-map cycle gets down to here with a single
	# answer — the delay the guard above meant to skip.
	if vote_candidates.size() < 2:
		vote_candidates = PackedStringArray()
		return
	next_map = vote_candidates[0]


func _clear_vote() -> void:
	_votes.clear()
	vote_candidates = PackedStringArray()


## One vote each, changeable while the intermission lasts. Returns the map voted for, or "" if the
## vote was refused (not voting right now, or no such option).
func cast_vote(peer_id: int, choice: int) -> String:
	if state != State.INTERMISSION or vote_candidates.is_empty():
		return ""
	if choice < 1 or choice > vote_candidates.size():
		return ""
	_votes[peer_id] = choice - 1
	_publish_vote()
	return vote_candidates[choice - 1]


## Settle who is winning and tell everyone — the one path out of any change to the ballot.
func _publish_vote() -> void:
	next_map = _leading_candidate()
	_broadcast_vote()
	_present_vote()


func vote_tallies() -> PackedInt32Array:
	var tallies := PackedInt32Array()
	tallies.resize(vote_candidates.size())
	for peer_id in _votes:
		var idx: int = _votes[peer_id]
		if idx >= 0 and idx < tallies.size():
			tallies[idx] += 1
	return tallies


## Most votes wins; a tie goes to the earliest option, which is the map the rotation was going to
## play anyway — so an intermission nobody votes in changes nothing.
func _leading_candidate() -> String:
	if vote_candidates.is_empty():
		return peek_next_map()
	var tallies := vote_tallies()
	var best := 0
	for i in range(1, vote_candidates.size()):
		if tallies[i] > tallies[best]:
			best = i
	return vote_candidates[best]


func _on_peer_disconnected(peer_id: int) -> void:
	if not _votes.has(peer_id):
		return
	_votes.erase(peer_id)
	if NetworkManager.is_authority() and state == State.INTERMISSION:
		_publish_vote()


# --- The rotation ---------------------------------------------------------

## Reads a mapcycle file: one map name per line, "#" starts a comment. Names that aren't installed
## are dropped with a warning rather than wedging the rotation on a map nobody can load. With no
## usable file at all the cycle is every installed map, alphabetically.
func load_cycle(path := "") -> int:
	var candidates: Array[String] = []
	if not path.is_empty():
		candidates.append(path)
	else:
		candidates.append_array([USER_CYCLE_PATH, RES_CYCLE_PATH])

	_cycle.clear()
	_cycle_source = ""
	for candidate in candidates:
		if not FileAccess.file_exists(candidate):
			continue
		var f := FileAccess.open(candidate, FileAccess.READ)
		if f == null:
			continue
		var missing: Array[String] = []
		while not f.eof_reached():
			var line := f.get_line()
			var hash_pos := line.find("#")
			if hash_pos >= 0:
				line = line.substr(0, hash_pos)
			line = line.strip_edges()
			if line.is_empty() or _cycle.has(line):
				continue
			if MapConverter.map_exists(line):
				_cycle.append(line)
			else:
				missing.append(line)
		f.close()
		_cycle_source = candidate
		if not missing.is_empty():
			Log.warn("[Match] mapcycle %s skips %d map(s) not installed: %s" % [
				candidate, missing.size(), ", ".join(missing)])
		break

	if _cycle.is_empty():
		_cycle.assign(MapConverter.list_maps())
		_cycle_source = "installed maps" if _cycle_source.is_empty() else _cycle_source + " (empty)"
	Log.info("[Match] Map cycle: %d map(s) from %s" % [_cycle.size(), _cycle_source])
	return _cycle.size()


## Read the cycle once per session, the first time a map goes live.
func _ensure_cycle() -> void:
	if _cycle_source.is_empty():
		load_cycle(cycle_path)


func cycle() -> Array[String]:
	_ensure_cycle()
	return _cycle.duplicate()


func cycle_source() -> String:
	return _cycle_source


## What loads when this match ends: an admin's pick, else the next entry in the cycle.
func peek_next_map() -> String:
	_ensure_cycle()
	if not _forced_next.is_empty():
		return _forced_next
	if _cycle.is_empty():
		return ""
	if _cursor < 0:
		return _cycle[0]
	return _cycle[(_cursor + 1) % _cycle.size()]


## /nextmap <map>. An empty name clears the override and hands the cycle back its turn.
func set_next_map(map_name: String) -> bool:
	if map_name.is_empty():
		_forced_next = ""
		if state == State.INTERMISSION:
			_open_vote()  # an admin standing down hands the choice back to the room
			_publish_vote()
			_broadcast()
		return true
	if not MapConverter.map_exists(map_name):
		return false
	_forced_next = map_name
	if state == State.INTERMISSION:
		# An admin naming the map settles it: the ballot comes down rather than counting votes
		# toward something that can no longer win. _leading_candidate falls through to the forced
		# map once the candidates are gone.
		_clear_vote()
		_publish_vote()
		_broadcast()
	return true


func forced_next_map() -> String:
	return _forced_next


func _sync_cursor_to(map_name: String) -> void:
	var idx := _cycle.find(map_name)
	if idx >= 0:
		_cursor = idx
	# A map that isn't in the cycle (an admin's /map) leaves the cursor alone, so the rotation
	# resumes where it left off instead of restarting.


# --- Telling everyone -----------------------------------------------------

func _broadcast() -> void:
	if NetworkManager.is_online() and NetworkManager.is_host():
		apply_remote.rpc(int(state), match_end_ms, intermission_end_ms,
			winner_team, winner_name, end_reason, next_map)


## The vote is its own message: it changes on every ballot, while the match state around it does
## not, and it only exists for the length of an intermission.
func _broadcast_vote() -> void:
	if NetworkManager.is_online() and NetworkManager.is_host():
		apply_remote_vote.rpc(vote_candidates, vote_tallies(), next_map)


## Client receive, and the late-joiner snapshot. Sent once per transition: the deadlines are
## absolute server times, so clients count down against their own server-clock estimate instead
## of being told the remaining seconds every tick.
@rpc("authority", "call_remote", "reliable")
func apply_remote(p_state: int, p_match_end_ms: int, p_intermission_end_ms: int,
		p_winner_team: int, p_winner_name: String, p_reason: String, p_next_map: String) -> void:
	var was := state
	state = p_state as State
	match_end_ms = p_match_end_ms
	intermission_end_ms = p_intermission_end_ms
	winner_team = p_winner_team
	winner_name = p_winner_name
	end_reason = p_reason
	next_map = p_next_map
	state_changed.emit(state)
	if state == State.INTERMISSION and was != State.INTERMISSION:
		_present()
	elif state == State.PLAYING and was == State.INTERMISSION:
		_clear_vote()
		_dismiss()


## The intermission ballot, resent on every vote. Only ever in flight during an intermission.
@rpc("authority", "call_remote", "reliable")
func apply_remote_vote(p_candidates: PackedStringArray, p_tallies: PackedInt32Array,
		p_leader: String) -> void:
	vote_candidates = p_candidates
	next_map = p_leader
	_present_vote(p_tallies)


## "Blue wins!" / "Time — draw", with what's coming next.
func result_text() -> String:
	var head := "Draw"
	if not winner_name.is_empty():
		head = "%s wins!" % winner_name
	elif winner_team > 0:
		head = "%s wins!" % GoalSystem.get_team_name(winner_team)
	if end_reason == "time":
		head = "Time — " + head
	if next_map.is_empty():
		return head
	return "%s\nNext map: %s" % [head, next_map]


func _present() -> void:
	var hud := Game.hud
	if hud == null:
		return
	hud.show_center_message(result_text(), Color(1.0, 0.9, 0.4), INTERMISSION_SECONDS)
	hud.set_intermission(true)
	_present_vote()


## Draws the ballot. Tallies are passed in on a client (they arrive with the message); the
## authority counts its own.
func _present_vote(tallies := PackedInt32Array()) -> void:
	var hud := Game.hud
	if hud == null:
		return
	if tallies.is_empty() and not vote_candidates.is_empty():
		tallies = vote_tallies()
	hud.set_vote(vote_candidates, tallies)


func _dismiss() -> void:
	var hud := Game.hud
	if hud:
		hud.set_intermission(false)


## Map unload: the next map's begin_map decides everything again.
func reset() -> void:
	_clear_match_state()
	_tick_while_counting_down()  # no deadlines left, so this puts the tick to sleep
	_dismiss()
