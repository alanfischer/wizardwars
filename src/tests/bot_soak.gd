extends Node
## Throwaway soak probe: boot the real dedicated server on a map with N bots, then watch what
## the bots actually do — distance covered, stuck episodes, deaths, and every scoring event.
##
##   godot --headless --path . res://src/tests/bot_soak.tscn -- --server --map ww_ravine --bots 4
##
## SOAK_SPEED runs the clock faster than real time. The server spends ~1.5ms of each 16.7ms tick
## doing work and the rest waiting, so there is room; everything here is measured in SIM seconds,
## and SceneTreeTimer (the sampler) scales with it. Treat a fast run as a screen, not a verdict —
## confirm anything you intend to act on at 1x. Two of these cannot run at once on one machine:
## the server's ENet port is fixed (NetworkManager.PORT), and the second one dies at boot.
##
## Env: SOAK_SECONDS (default 300), SOAK_STUCK_WINDOW (20), SOAK_STUCK_RADIUS (2.0 m).

var _main: Node
var _t := 0.0
var _hist := {}          # bot id -> Array[Vector3] ring of samples (one per second)
var _travel := {}        # bot id -> total horizontal metres walked
var _deaths := {}        # bot id -> deaths seen
var _was_dead := {}
var _stuck_open := {}    # bot id -> {t, pos}
var _stuck_log := []     # finished stuck episodes
var _score_log := []
var _scores := [0, 0, 0, 0, 0]
var _bot_teams := {}
var _bot_names := {}
var _flags := []         # ItemTFGoal nodes
var _flag_carrier := {}  # flag -> last carrier peer id
var _near_flag := {}     # bot id -> closest it ever came to an enemy flag
var _y_below := {}       # bot id -> samples taken below SOAK_Y_SPLIT (alive only)
var _y_total := {}       # bot id -> samples taken at all (alive only)
var _y_split := INF      # SOAK_Y_SPLIT: height that divides the levels worth comparing
## Map coverage: the distinct CELL cubes a bot's samples fall in, per bot and pooled. Travel alone
## says a bot is walking, not that it is going anywhere — six bots circling one room cover ground
## and see a fifth of the level. Coverage is what separates the two.
const BotBrain = preload("res://src/bot/bot_brain.gd")
var _aim_query := PhysicsRayQueryParameters3D.new()   # reused; the aim test runs per bot per tick
const CELL := 4.0
var _cells := {}         # bot id -> {Vector3i: true}
var _cells_all := {}     # the same, pooled over every bot

var _duration := 300.0
var _window := 20
var _radius := 2.0

## Per-physics-tick behaviour profile (SOAK_PROFILE=1). The 1 Hz sampler above says where a bot
## ended up; this says what it was doing to get there — which navigation mode drove the tick, how
## fast it was going, and how much of its life was spent in a recovery path rather than playing.
var _profile := false
var _pf := {}            # counter name -> ticks
var _pf_bot := {}        # bot id -> {counter -> ticks}
## Micro-stall: below MICRO_SPEED for MICRO_T continuous seconds while alive and trying to move.
## An order of magnitude shorter than the 1 Hz stuck test, which only sees a bot pinned for 20s.
const MICRO_SPEED := 0.6
const MICRO_T := 2.0
var _micro_t := {}       # bot id -> continuous seconds slow
var _micro_n := {}       # bot id -> completed micro-stall episodes
var _micro_time := {}    # bot id -> seconds spent inside one
## Recovery-event forensics: every rising edge of freeze recovery / bounce-lock, with the context
## the bot was in when it fired. A percentage says how often a recovery path runs; this says where
## and why, which is what separates "a spot on this map" from "the detector fires on normal play".
## The per-tick states _edge turns into located rising edges, and how each one reports itself.
const EDGE_REPORTS := {
	"freeze": "freeze recovery: %d trip(s)",
	"bounce": "bounce recovery: %d trip(s)",
	"fall": "Falls off the route: %d",
}
var _ev_cell := {}       # _edge signal name -> {Vector3i cell -> count}
var _ev_ctx := {}        # "<event>:<context>" -> count
var _ev_prev := {}       # bot id -> {event -> was active last tick}
## Actual displacement, not `velocity`. CharacterBody3D.velocity is what the bot ASKED for; a body
## leaning on a wall reports full speed and travels nothing, and telling those two apart is most of
## the question here.
var _last_pos := {}      # bot id -> position last tick
var _grind_cell := {}    # 4m cell -> ticks spent pushing hard and travelling nothing there
## Spinning: turning a lot while going nowhere. Distinct from orbiting (which covers ground) and
## from being pinned (which the 1 Hz ball test catches). Accumulated |yaw change| per second,
## and the share of alive time turning faster than SPIN_RATE while travelling under SPIN_SPEED.
const SPIN_RATE := deg_to_rad(120.0)
const SPIN_SPEED := 1.5
var _last_yaw := {}
var _yaw_sum := {}       # bot id -> total |yaw change| (radians)
var _spin_ticks := {}
## Where a bot's aim actually points versus where the target's body is. The brain aims at the
## enemy's ORIGIN (its feet) and fires from eye height, while target acquisition rays from the
## feet to the collision CENTRE — three different lines, and this measures the gap.
var _aim_n := 0
var _aim_pitch_err := 0.0   # signed degrees: negative = aiming below the target's centre
var _aim_ground := 0        # ticks where the aim ray hits the world before reaching the target
## ...and the same two while the target is actually VISIBLE, which is the only state the trigger
## can pull in. A blocked line on a merely REMEMBERED target is correct behaviour — the enemy
## went behind a wall and the bot is still facing where it was — so pooling the two overstates
## the problem, which is what the first measurement of this did.
var _aim_seen_n := 0
var _aim_seen_ground := 0


func _ready() -> void:
	if OS.has_environment("SOAK_SPEED"):
		# time_scale ALONE is a trap: it buys wall-clock speed by simulating fewer ticks per game
		# second (6x measured as 10 tps, down from 60), so the movement and the bot decisions stop
		# being the thing under test. Raise the tick rate by the same factor and the sim still runs
		# at 60 Hz of game time, just more of them per real second.
		var mult := maxf(float(OS.get_environment("SOAK_SPEED")), 0.1)
		Engine.time_scale = mult
		Engine.physics_ticks_per_second = int(round(60.0 * mult))
		Engine.max_fps = 0
		print("[Soak] %.1fx (physics %d Hz wall, 60 Hz sim)" % [mult, Engine.physics_ticks_per_second])
	_duration = float(OS.get_environment("SOAK_SECONDS")) if OS.has_environment("SOAK_SECONDS") else 300.0
	_window = int(OS.get_environment("SOAK_STUCK_WINDOW")) if OS.has_environment("SOAK_STUCK_WINDOW") else 20
	_radius = float(OS.get_environment("SOAK_STUCK_RADIUS")) if OS.has_environment("SOAK_STUCK_RADIUS") else 2.0
	# Which LEVEL the bots play on, not just how far they walk. A change that moves waypoints moves
	# routes, and the way that showed up last time was bots abandoning ww_ravine's lower level for
	# the contested middle deck — they navigated better and captured less. Travel and stuck counts
	# both missed it; the height split is what caught it.
	_y_split = float(OS.get_environment("SOAK_Y_SPLIT")) if OS.has_environment("SOAK_Y_SPLIT") else INF
	_profile = OS.has_environment("SOAK_PROFILE")
	BotBrain.diag = _profile
	_aim_query.collision_mask = GameConsts.MASK_WORLD | GameConsts.MASK_ENTITY
	_run.call_deferred()


func _run() -> void:
	var tree := get_tree()
	_main = load("res://src/main.tscn").instantiate()
	tree.root.add_child(_main)
	tree.current_scene = _main   # BotSystem/entities resolve main through current_scene

	# Map conversion on a cold cache can take a while; wait for the game to actually start.
	var waited := 0.0
	while waited < 240.0 and not bool(_main.get("_game_active")):
		await tree.create_timer(1.0).timeout
		waited += 1.0
	if not bool(_main.get("_game_active")):
		print("[Soak] game never became active after %ds" % int(waited))
		tree.quit(1)
		return
	# --bots can't be used here: main spawns those inside add_child(), before current_scene is
	# set, and BotSystem resolves main through current_scene. Add them the /addbot way instead.
	var want := int(OS.get_environment("SOAK_BOTS")) if OS.has_environment("SOAK_BOTS") else 4
	while BotSystem._bots.size() < want:
		var want_team := int(OS.get_environment("SOAK_TEAM")) if OS.has_environment("SOAK_TEAM") else -1
		if BotSystem.add_bot(-1, want_team) == 0:
			break
	print("[Soak] game active after %.0fs; bots=%d" % [waited, BotSystem._bots.size()])

	for n in _main.get_tree().get_nodes_in_group("entities") + _root_walk():
		if n is ItemTFGoal and not _flags.has(n):
			_flags.append(n)
	print("[Soak] tracking %d flag(s)" % _flags.size())

	while _t < _duration:
		await tree.create_timer(1.0).timeout
		_t += 1.0
		_sample()
	_report()
	tree.quit(0)


## Per-physics-tick behaviour profile. Reads the live brain state each bot ACTED on this tick,
## which is the only place the mode it chose is visible — by the next 1 Hz sample it is gone.
func _physics_process(delta: float) -> void:
	if not _profile or _main == null or _t <= 0.0:
		return
	for i in BotSystem._bots.size():
		var bot = BotSystem._bots[i]
		if not is_instance_valid(bot) or i >= BotSystem._brains.size():
			continue
		var br = BotSystem._brains[i]
		if not is_instance_valid(br):
			continue
		var id: int = bot.peer_id
		if bool(bot.is_dead):
			_bump(id, "dead", 1.0)
			_micro_t[id] = 0.0
			continue
		var speed := Vector2(bot.velocity.x, bot.velocity.z).length()
		_bump(id, "alive", 1.0)
		_bump(id, "speed_sum", speed)
		# Speed histogram: what a spectator sees. Bots that only ever sprint read as bots.
		if speed < 0.5:
			_bump(id, "spd_still", 1.0)
		elif speed < 2.0:
			_bump(id, "spd_walk", 1.0)
		elif speed < 5.0:
			_bump(id, "spd_jog", 1.0)
		else:
			_bump(id, "spd_run", 1.0)
		# Which navigation mode drove the tick.
		if br._graph == null:
			_bump(id, "nav_nograph", 1.0)
		elif br._route.is_empty():
			_bump(id, "nav_noroute", 1.0)   # beeline: A* found nothing, or the route was dropped
		else:
			_bump(id, "nav_route", 1.0)
		if br._local_nav:
			_bump(id, "local_steer", 1.0)
		if br._wf_hand != 0:
			_bump(id, "wall_follow", 1.0)
		if br._riding:
			_bump(id, "riding", 1.0)
		if br._free_t > 0.0:
			_bump(id, "freeze_recovery", 1.0)
		if br._stuck_t > 0.0:
			_bump(id, "anti_stuck", 1.0)
		if br._bl_rest_t > 0.0:
			_bump(id, "bounce_locked", 1.0)
		if br._roaming:
			_bump(id, "roaming", 1.0)
		if br._known != null and is_instance_valid(br._known):
			_bump(id, "has_target", 1.0)
		if bot._move_ctx != null and bot._move_ctx.ladder_normal != Vector3.ZERO:
			_bump(id, "on_ladder", 1.0)
		if not bot.carried_items.is_empty():
			_bump(id, "carrying", 1.0)
		if bot.sync_firing:
			_bump(id, "beaming", 1.0)
		var p_now: Vector3 = bot.global_position
		var lp: Vector3 = _last_pos.get(id, p_now)
		var real := Vector2(p_now.x - lp.x, p_now.z - lp.z).length() / maxf(delta, 0.0001)
		_last_pos[id] = p_now
		if real < 20.0:                      # skip the respawn teleport
			_bump(id, "real_sum", real)
			_bump(id, "real_n", 1.0)
			if real < 0.5:
				_bump(id, "real_still", 1.0)
			if speed > 3.0 and real < 1.0:   # pushing hard, going nowhere: leaning on geometry
				_bump(id, "grinding", 1.0)
				# ...and WHERE, because "7% of ticks leaning on something" names no place to fix.
				var gc := _cell(p_now)
				_grind_cell[gc] = int(_grind_cell.get(gc, 0)) + 1
		# `get()` returns null on a target with no is_dead property (a non-player damageable), and
		# bool(null) throws — which kills the whole profiler frame, silently dropping its samples.
		if br._known != null and is_instance_valid(br._known) and br._known.get("is_dead") != true:
			var seen: bool = br._seen != null
			var eye := p_now + Vector3(0.0, 1.6, 0.0)
			var ctr: Vector3 = SpatialQuery.collision_center(br._known)
			var want := (ctr - eye).normalized()
			var cp := cos(br._face_pitch)
			var have := Vector3(-sin(br._face_yaw) * cp, sin(br._face_pitch), -cos(br._face_yaw) * cp)
			_aim_n += 1
			_aim_pitch_err += rad_to_deg(asin(clampf(have.y, -1.0, 1.0))
					- asin(clampf(want.y, -1.0, 1.0)))
			# Does the shot reach? Same origin the weapon uses, along the direction actually held.
			_aim_query.from = eye
			_aim_query.to = eye + have * eye.distance_to(ctr)
			_aim_query.exclude = [bot.get_rid()]
			var blocked: bool = not bot.get_world_3d().direct_space_state \
					.intersect_ray(_aim_query).is_empty()
			if blocked:
				_aim_ground += 1
			if seen:
				_aim_seen_n += 1
				if blocked:
					_aim_seen_ground += 1
		var yaw: float = bot.rotation.y
		var dyaw: float = absf(angle_difference(float(_last_yaw.get(id, yaw)), yaw))
		_last_yaw[id] = yaw
		if real < 20.0:
			_yaw_sum[id] = float(_yaw_sum.get(id, 0.0)) + dyaw
			if dyaw / maxf(delta, 0.0001) > SPIN_RATE and real < SPIN_SPEED:
				_spin_ticks[id] = int(_spin_ticks.get(id, 0)) + 1
		_edge(id, "freeze", br._free_t > 0.0, br, bot, speed)
		_edge(id, "bounce", br._bl_rest_t > 0.0, br, bot, speed)
		_edge(id, "fall", bool(br.fell_now), br, bot, speed)
		# Micro-stalls: slow while alive, for long enough that a watching player would notice.
		var slow: float = float(_micro_t.get(id, 0.0))
		if speed < MICRO_SPEED:
			slow += delta
			_micro_t[id] = slow
			if slow >= MICRO_T:
				_micro_time[id] = float(_micro_time.get(id, 0.0)) + delta
				if slow - delta < MICRO_T:
					_micro_n[id] = int(_micro_n.get(id, 0)) + 1
		else:
			_micro_t[id] = 0.0


## The 4m cube a position falls in. Shared by every place-keyed metric here — coverage, the
## recovery edges, grinding — so their reports can be compared with each other.
func _cell(p: Vector3) -> Vector3i:
	return Vector3i(floori(p.x / CELL), floori(p.y / CELL), floori(p.z / CELL))


## One rising edge of a per-tick state, tagged with what the bot was doing. Contexts are ordered
## most-specific first and only one is recorded, so the counts partition the events.
func _edge(id: int, ev: String, active: bool, br, bot, speed: float) -> void:
	if not _ev_prev.has(id):
		_ev_prev[id] = {}
	var prev: Dictionary = _ev_prev[id]
	var was: bool = bool(prev.get(ev, false))
	prev[ev] = active
	if not active or was:
		return
	var p: Vector3 = bot.global_position
	if not _ev_cell.has(ev):
		_ev_cell[ev] = {}
	var cells: Dictionary = _ev_cell[ev]
	var cell := _cell(p)
	cells[cell] = int(cells.get(cell, 0)) + 1
	var ctx := "other"
	var obj_d: float = INF if br._route_obj == Vector3.INF else Vector2(
			br._route_obj.x - p.x, br._route_obj.z - p.z).length()
	var sm = bot.get_server_movement()
	if bot._move_ctx != null and bot._move_ctx.check_water():
		ctx = "in_water"
	elif bot._move_ctx != null and bot._move_ctx.ladder_normal != Vector3.ZERO:
		ctx = "on_ladder"
	elif sm != null and not sm.state.on_floor:
		ctx = "airborne"
	elif obj_d < 2.0:
		ctx = "AT objective"       # holding station on the thing it came for
	elif br._known != null and is_instance_valid(br._known):
		ctx = "fighting"
	elif speed > 2.0:
		ctx = "wish>2m/s"          # asking to move; the world is not letting it
	var ck := "%s:%s" % [ev, ctx]
	_ev_ctx[ck] = int(_ev_ctx.get(ck, 0)) + 1


## A place-keyed count, biggest cell first. `title` carries one %d for the total. Returns that
## total, which the recovery reports divide their context breakdown by.
func _report_cells(title: String, cells: Dictionary, top: int) -> int:
	var total := 0
	for k in cells:
		total += int(cells[k])
	if total == 0:
		return 0
	print("\n%s in %d distinct %.0fm cell(s)" % [title % total, cells.size(), CELL])
	var keys: Array = cells.keys()
	keys.sort_custom(func(x, y): return int(cells[x]) > int(cells[y]))
	for k in keys.slice(0, top):
		print("    %5d at cell %v  (~%v)" % [int(cells[k]), k, Vector3(k) * CELL])
	return total


## Sum one of the brains' counter dictionaries across every live bot.
func _pool(field: String) -> Dictionary:
	var out := {}
	for br in BotSystem._brains:
		if not is_instance_valid(br):
			continue
		var d = br.get(field)
		if d == null:
			continue
		for k in d:
			out[k] = int(out.get(k, 0)) + int(d[k])
	return out


func _bump(id: int, key: String, by: float) -> void:
	_pf[key] = float(_pf.get(key, 0.0)) + by
	if not _pf_bot.has(id):
		_pf_bot[id] = {}
	var m: Dictionary = _pf_bot[id]
	m[key] = float(m.get(key, 0.0)) + by


func _root_walk() -> Array:
	var out: Array = []
	var stack: Array = [_main]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		out.append(n)
		for c in n.get_children():
			stack.append(c)
	return out


func _sample() -> void:
	for f in _flags:
		if not is_instance_valid(f):
			continue
		var c: int = f._carrier_peer_id
		if c != int(_flag_carrier.get(f, 0)):
			_score_log.append("t=%4.0fs  flag %s carrier %d -> %d" % [
					f.name, _flag_carrier.get(f, 0), c] if false else "t=%4.0fs  flag(owner %s) carrier %s -> %d" % [
					_t, str(f.get("owned_by")), str(_flag_carrier.get(f, 0)), c])
			_flag_carrier[f] = c

	for team in range(1, 5):
		if GoalSystem.team_scores[team] != _scores[team]:
			_score_log.append("t=%4.0fs  team %d: %d -> %d" % [
				_t, team, _scores[team], GoalSystem.team_scores[team]])
			_scores[team] = GoalSystem.team_scores[team]

	var bi := -1
	for bot in BotSystem._bots:
		bi += 1
		if not is_instance_valid(bot):
			continue
		var id: int = bot.peer_id
		if OS.has_environment("SOAK_TRACE") and bi < BotSystem._brains.size():
			var br = BotSystem._brains[bi]
			var route: PackedInt64Array = br._route
			var tgt := Vector3.INF
			var endp := Vector3.INF
			if br._graph != null and not route.is_empty():
				if br._route_i < route.size():
					tgt = br._graph.position_of(route[br._route_i])
				endp = br._graph.position_of(route[route.size() - 1])
			print("  T %4.0fs %s pos %v vel %.1f  route %d/%d  next %v (%.1fm)  end %v" % [
					_t, bot.name, bot.global_position,
					Vector2(bot.velocity.x, bot.velocity.z).length(),
					br._route_i, route.size(), tgt,
					INF if tgt == Vector3.INF else bot.global_position.distance_to(tgt), endp])
		var pos: Vector3 = bot.global_position
		_bot_teams[id] = bot.team
		_bot_names[id] = str(bot.name)
		var dead: bool = bool(bot.is_dead)
		if dead and not _was_dead.get(id, false):
			_deaths[id] = int(_deaths.get(id, 0)) + 1
		_was_dead[id] = dead

		for f in _flags:
			if not is_instance_valid(f):
				continue
			if int(f.get("owned_by")) == bot.team:
				continue   # own flag; only the enemy one matters for capturing
			var d: float = pos.distance_to(f.global_position)
			if d < float(_near_flag.get(id, INF)):
				_near_flag[id] = d

		if _y_split != INF and not dead:
			_y_total[id] = int(_y_total.get(id, 0)) + 1
			if pos.y < _y_split:
				_y_below[id] = int(_y_below.get(id, 0)) + 1

		if not dead:
			var cell := _cell(pos)
			var mine: Dictionary = _cells.get(id, {})
			mine[cell] = true
			_cells[id] = mine
			_cells_all[cell] = true

		var h: Array = _hist.get(id, [])
		if not h.is_empty():
			var d: float = Vector2(pos.x - h[-1].x, pos.z - h[-1].z).length()
			if d < 20.0:   # ignore respawn/teleport jumps
				_travel[id] = float(_travel.get(id, 0.0)) + d
		h.append(pos)
		while h.size() > _window:
			h.pop_front()
		_hist[id] = h

		# Stuck = alive, and every sample in the window sits inside a small ball.
		var stuck := false
		if not dead and h.size() >= _window:
			stuck = true
			for p in h:
				if p.distance_to(pos) > _radius:
					stuck = false
					break
		if stuck and not _stuck_open.has(id):
			_stuck_open[id] = {"t": _t - _window, "pos": pos}
		elif not stuck and _stuck_open.has(id):
			var s: Dictionary = _stuck_open[id]
			_stuck_log.append({"id": id, "start": s["t"], "end": _t, "pos": s["pos"],
					"freed": "respawn" if dead else "moved"})
			_stuck_open.erase(id)


func _report() -> void:
	print("\n===== SOAK REPORT (%s, %.0fs) =====" % [_main.get("_current_map_name"), _t])
	print("Scores: ", GoalSystem.team_scores)
	if _score_log.is_empty():
		print("  NO scoring events")
	for line in _score_log:
		print("  ", line)
	print("\nBots:")
	for id in _hist:
		print("  %s (id %d, team %d): travelled %.0fm, %d death(s), last pos %v" % [
				_bot_names.get(id, "?"), id, _bot_teams.get(id, 0),
				_travel.get(id, 0.0), _deaths.get(id, 0), _hist[id][-1]])
		print("      closest approach to an enemy flag: %.1fm" % float(_near_flag.get(id, INF)))
		print("      covered %d cell(s) of %.0fm" % [_cells.get(id, {}).size(), CELL])
		if _y_split != INF:
			var tot: int = int(_y_total.get(id, 0))
			print("      time below y%.0f: %.0f%% (%d/%d samples)" % [
				_y_split, 100.0 * float(_y_below.get(id, 0)) / maxf(1.0, float(tot)),
				int(_y_below.get(id, 0)), tot])
	print("\nCoverage: %d distinct %.0fm cells visited by all bots together" % [
			_cells_all.size(), CELL])

	for id in _stuck_open:
		var s: Dictionary = _stuck_open[id]
		_stuck_log.append({"id": id, "start": s["t"], "end": _t, "pos": s["pos"], "freed": "STILL STUCK"})
	if _profile:
		_report_profile()
	print("\nStuck episodes (>%ds inside a %.1fm ball, alive):" % [_window, _radius])
	if _stuck_log.is_empty():
		print("  none")
	for s in _stuck_log:
		print("  %s  t=%.0f-%.0fs (%ds) at %v  [%s]" % [
				_bot_names.get(s["id"], "?"), s["start"], s["end"],
				int(s["end"] - s["start"]), s["pos"], s["freed"]])


## The behaviour profile, as percentages of ALIVE bot-ticks. Modes are not exclusive (a bot can be
## route-following and dodging and shooting at once), so these do not sum to 100.
func _report_profile() -> void:
	var alive: float = float(_pf.get("alive", 0.0))
	if alive <= 0.0:
		return
	print("\nBehaviour profile (%d alive bot-ticks, %.0f%% of all ticks):" % [
			int(alive), 100.0 * alive / maxf(1.0, alive + float(_pf.get("dead", 0.0)))])
	print("  mean speed %.2f m/s" % (float(_pf.get("speed_sum", 0.0)) / alive))
	var rn: float = maxf(1.0, float(_pf.get("real_n", 0.0)))
	print("  mean TRAVELLED speed %.2f m/s (still %.1f%% of ticks, grinding %.1f%%)" % [
			float(_pf.get("real_sum", 0.0)) / rn,
			100.0 * float(_pf.get("real_still", 0.0)) / rn,
			100.0 * float(_pf.get("grinding", 0.0)) / rn])
	var order := ["spd_still", "spd_walk", "spd_jog", "spd_run", "nav_route", "nav_noroute",
			"nav_nograph", "local_steer", "wall_follow", "riding", "on_ladder", "roaming",
			"has_target", "beaming", "carrying", "anti_stuck", "freeze_recovery", "bounce_locked"]
	for k in order:
		print("  %-16s %5.1f%%" % [k, 100.0 * float(_pf.get(k, 0.0)) / alive])
	if _aim_n > 0:
		print("\nAim, while a target is in mind (%d tick(s)):" % _aim_n)
		print("  mean pitch error vs the target's CENTRE: %+.1f deg (negative = aiming low)"
				% (_aim_pitch_err / float(_aim_n)))
		print("  aim line blocked before reaching the target: %.1f%% of those ticks"
				% (100.0 * float(_aim_ground) / float(_aim_n)))
		if _aim_seen_n > 0:
			print("  ...of the %d tick(s) the target was VISIBLE (trigger live): %.1f%% blocked"
					% [_aim_seen_n, 100.0 * float(_aim_seen_ground) / float(_aim_seen_n)])
		var tl := _pool("steer_tally")
		var held: float = float(tl.get("shot_blocked", 0))
		var clear: float = float(tl.get("shot_clear", 0))
		if held + clear > 0.0:
			print("  fire-line gate: held fire on %d of %d engaging tick(s) (%.1f%%)"
					% [int(held), int(held + clear), 100.0 * held / (held + clear)])
	for ev in EDGE_REPORTS:
		var cells: Dictionary = _ev_cell.get(ev, {})
		# Falls go deeper than the recovery lists: the count is only useful split by PLACE, and
		# six cells cannot tell "the ramps improved" from "the ramps fell off the list".
		var total := _report_cells(EDGE_REPORTS[ev], cells, 30 if ev == "fall" else 6)
		var ctxs: Array = []
		for key in _ev_ctx:
			if str(key).begins_with(ev + ":"):
				ctxs.append(key)
		ctxs.sort_custom(func(x, y): return int(_ev_ctx[x]) > int(_ev_ctx[y]))
		for key in ctxs:
			print("    %5.1f%%  %s" % [100.0 * float(_ev_ctx[key]) / maxf(1.0, float(total)),
					str(key).substr(ev.length() + 1)])
	var g = BotSystem._waypoints
	if g != null and g.loaded and g.get("resnap_dest") != null:
		print("\nPath re-snaps: %d destination, %d source, %.0fm moved in total" % [
				g.resnap_dest, g.resnap_src, g.resnap_dist])
	_report_cells("Grinding (wish >3 m/s, travelled <1): %d tick(s)", _grind_cell, 10)
	var ot := _pool("obj_tally")
	if not ot.is_empty():
		var t: float = 0.0
		for k in ot: t += float(ot[k])
		print("\nobjective branches:")
		var ks: Array = ot.keys(); ks.sort()
		for k in ks:
			print("  %-14s %7d  %5.1f%%" % [k, int(ot[k]), 100.0 * float(ot[k]) / maxf(1.0, t)])
	var tally := _pool("steer_tally")
	if not tally.is_empty():
		var calls: float = maxf(1.0, float(tally.get("calls", 0)))
		print("\n_steer paths (%d calls):" % int(calls))
		for k in ["climb", "topout", "free", "rescue", "dodge", "precise",
				"dodge_blocked", "contact_nav",
				"L_aboard", "L_board", "L_backout", "L_toband", "L_wait",
				"L_settled", "L_moving", "L_deck_away"]:
			print("  %-14s %6d  %5.1f%%" % [k, int(tally.get(k, 0)),
					100.0 * float(tally.get(k, 0)) / calls])
	if not _yaw_sum.is_empty():
		print("\nSpin (turning >%.0f deg/s while travelling <%.1f m/s):" % [
				rad_to_deg(SPIN_RATE), SPIN_SPEED])
		var tot_spin := 0
		var tot_alive := 0
		for id in _yaw_sum:
			var ba: int = int(float((_pf_bot.get(id, {}) as Dictionary).get("alive", 1.0)))
			var sp: int = int(_spin_ticks.get(id, 0))
			tot_spin += sp
			tot_alive += ba
			print("  %-8s %6.0f deg/s mean turn rate, spinning %5.1f%% of its life" % [
					_bot_names.get(id, "?"),
					rad_to_deg(float(_yaw_sum[id])) / maxf(1.0, float(ba) / 60.0),
					100.0 * float(sp) / maxf(1.0, float(ba))])
		print("  ALL BOTS: spinning %.1f%% of alive time" % [
				100.0 * float(tot_spin) / maxf(1.0, float(tot_alive))])
	print("\nMicro-stalls (>%.0fs under %.1f m/s while alive):" % [MICRO_T, MICRO_SPEED])
	var tot_n := 0
	var tot_s := 0.0
	for id in _micro_n:
		var secs: float = float(_micro_time.get(id, 0.0))
		tot_n += int(_micro_n[id])
		tot_s += secs
		var ba: float = float((_pf_bot.get(id, {}) as Dictionary).get("alive", 1.0))
		print("  %s: %d episode(s), %.0fs (%.1f%% of its life)" % [
				_bot_names.get(id, "?"), int(_micro_n[id]), secs, 100.0 * secs / maxf(1.0, ba)])
	print("  total %d episode(s), %.0fs across all bots" % [tot_n, tot_s])
