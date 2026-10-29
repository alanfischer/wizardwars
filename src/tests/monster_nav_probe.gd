extends Node
## Throwaway probe for [MonsterNav]: can a monster hull actually walk a baked route across a real
## map, and does the shared query budget hold up with a crowd asking at once?
##
##   godot --headless --path . res://src/tests/monster_nav_probe.tscn -- --server --map ww_2fort
##
## Each trial drops a skeleton on one waypoint and gives it another, far away, as its goal. The
## skeleton's own script is switched off — this measures the nav, the hull and the world, not the
## monster's targeting, which has its own rules about who it chases and when.
##
## Env: NAV_TRIALS (default 8, run concurrently), NAV_SECONDS (90, per-trial budget),
##      NAV_MIN_SEP (40 m, how far apart the two ends must be).

const MonsterNavScript = preload("res://src/monsters/monster_nav.gd")
const SkeletonScript = preload("res://src/monsters/skeleton.gd")
const MonsterBodyScript = preload("res://src/monsters/monster_body.gd")

const ARRIVED := 2.5            # horizontal metres from the goal that counts as getting there
## No progress for this long and the trial is called off. Progress is measured along the ROUTE,
## not as crow-flies closing: a route that goes round a building moves away from the goal for
## tens of metres at a time, and the first cut of this probe scored that as stuck — it killed
## trials that had walked 135 m and were still going.
const STALL_WINDOW := 6.0

var _main: Node
var _trials: Array = []
var _limit := 90.0
var _min_sep := 40.0
## NAV_CONTROL=1 drives every trial straight at the goal with the nav switched off. The control for
## "is the route wrong" vs "is this body unable to walk the map at all" — the driving loop is
## Skeleton's own, and move_and_slide over a few metres at a visible target is not the same test as
## move_and_slide over a hundred metres of GoldSrc doorframes.
var _control := false
var _seed := 1234
## NAV_TRACE=<trial index> follows ONE crossing tick by tick instead of scoring ten. Four
## hypotheses about why monsters stall were each refuted by measurement; this stops guessing and
## reads what one of them actually does.
var _trace := -1
var _trace_t := 0.0


func _ready() -> void:
	_limit = float(OS.get_environment("NAV_SECONDS")) if OS.has_environment("NAV_SECONDS") else 90.0
	_min_sep = float(OS.get_environment("NAV_MIN_SEP")) if OS.has_environment("NAV_MIN_SEP") else 40.0
	_control = OS.has_environment("NAV_CONTROL")
	# Deterministic start/goal pairs. Without this every run draws different crossings and the
	# runs are not paired, so a change cannot be told from the draw — ww_2fort gave 3, 7 and 4
	# out of 10 on identical code. Seeded per map so each map keeps its own fixed set.
	_seed = int(OS.get_environment("NAV_SEED")) if OS.has_environment("NAV_SEED") else 1234
	_trace = int(OS.get_environment("NAV_TRACE")) if OS.has_environment("NAV_TRACE") else -1
	_run.call_deferred()


func _run() -> void:
	var tree := get_tree()
	_main = load("res://src/main.tscn").instantiate()
	tree.root.add_child(_main)
	tree.current_scene = _main

	var waited := 0.0
	while waited < 240.0 and not bool(_main.get("_game_active")):
		await tree.create_timer(1.0).timeout
		waited += 1.0
	if not bool(_main.get("_game_active")):
		print("[NavProbe] game never became active after %ds" % int(waited))
		tree.quit(1)
		return

	var g = MonsterNavScript.graph(_main)
	if g == null:
		print("[NavProbe] no waypoint graph for this map — nothing to probe")
		tree.quit(1)
		return
	seed(_seed + hash(str(_main.get("_current_map_name"))))
	print("[NavProbe] graph: %d nodes" % g.positions.size())

	var want := int(OS.get_environment("NAV_TRIALS")) if OS.has_environment("NAV_TRIALS") else 8
	for i in want:
		var pair := _pick_pair(g)
		if pair.is_empty():
			break
		_start_trial(pair[0], pair[1])
	if _trials.is_empty():
		print("[NavProbe] could not pick a single start/goal pair %.0fm apart" % _min_sep)
		tree.quit(1)
		return
	print("[NavProbe] %d trial(s) running, %.0fs each" % [_trials.size(), _limit])

	var elapsed := 0.0
	while elapsed < _limit and _trials.any(func(t): return t["state"] == "running"):
		await tree.create_timer(1.0).timeout
		elapsed += 1.0
	_report()
	tree.quit(0)


## Two linked waypoints at least NAV_MIN_SEP apart, with a route between them — a pair the graph
## itself says is connected, so a failed trial is the follower's fault and not the bake's.
func _pick_pair(g) -> Array:
	for _attempt in 200:
		var a: int = randi() % int(g.positions.size())
		var b: int = randi() % int(g.positions.size())
		var pa: Vector3 = g.position_of(a)
		var pb: Vector3 = g.position_of(b)
		if pa.distance_to(pb) < _min_sep:
			continue
		if g.path_ids(pa, pb).is_empty():
			continue
		return [pa, pb]
	return []


func _start_trial(from_pos: Vector3, goal: Vector3) -> void:
	var body: Node = NetworkManager.spawn_dynamic_entity({
		"script_path": "res://src/monsters/skeleton.gd",
		"position": from_pos + Vector3.UP * 0.2,
		"team": GameConsts.Team.GREEN,
	})
	if body == null:
		return
	# Its own brain would chase whatever it can see; this trial is about the route.
	body.set_physics_process(false)
	var nav = MonsterNavScript.new()
	nav.setup(body)
	# The same locomotion the shipped monster uses, so the probe measures what plays.
	var walk = MonsterBodyScript.new()
	walk.setup(body, SkeletonScript.MOVE_SPEED, SkeletonScript.HEIGHT)
	_trials.append({
		"body": body, "nav": nav, "walk": walk, "goal": goal, "state": "running",
		"start": from_pos, "t": 0.0, "best": _horiz(goal - from_pos),
		"best_left": 1 << 30, "best_t": 0.0, "travel": 0.0, "prev": from_pos,
		# Why a trial ended, not just that it did: no route at all reads nothing like a route the
		# body could not walk, and crow-flies distance cannot tell them apart.
		"zero": 0, "ticks": 0, "route_max": 0, "route_end": 0,
		"floor": 0, "moving": 0, "crept": 0,
		# Falling, as distinct from jamming. A monster pressed into a wall and one dropping off a
		# ledge both stop making progress, and the blocked/on-floor pair tells them apart only
		# vaguely — these count the drops outright.
		"falls": 0, "fall_drop": 0.0, "fall_max": 0.0, "airborne": 0.0, "wet": 0,
		# Airborne EPISODES, bucketed by how far they dropped. Many tiny ones is bumpy ground or
		# floor detection flickering; a few deep ones is the monster leaving the map.
		"ep": 0, "ep_t": 0.0, "d_tiny": 0, "d_small": 0, "d_mid": 0, "d_big": 0, "air_from_t": 0.0,
		"was_floor": true, "fall_from": 0.0,
	})


func _physics_process(delta: float) -> void:
	for i in _trials.size():
		var t: Dictionary = _trials[i]
		if t["state"] != "running":
			continue
		var body: CharacterBody3D = t["body"]
		if not is_instance_valid(body):
			t["state"] = "lost"
			continue
		t["t"] += delta
		var here: Vector3 = body.global_position
		t["travel"] += Vector2(here.x - t["prev"].x, here.z - t["prev"].z).length()
		t["prev"] = here

		var left: float = _horiz(here - t["goal"])
		t["best"] = minf(t["best"], left)
		if left <= ARRIVED:
			t["state"] = "arrived"
			continue

		# The movement half of Skeleton._physics_process, with the nav in place of its chase.
		var pre_i: int = t["nav"]._route_i
		var pre_n: int = t["nav"]._route.size()
		var dir: Vector3 = Vector3.ZERO if _control else t["nav"].desired_dir(delta, t["goal"])
		if _trace >= 0 and i == _trace:
			_trace_tick(t, here, dir, pre_i, pre_n, body.is_on_floor())
		t["ticks"] += 1
		# A monster in water is the other way to be off the floor without falling — it is swimming
		# (MonsterBody._swim), not dropping.
		if SpatialQuery.is_point_in_water(body, here + Vector3(0.0, 0.9, 0.0)):
			t["wet"] += 1
		var grounded: bool = body.is_on_floor()
		if grounded:
			t["floor"] += 1
		else:
			t["airborne"] += delta
		if t["was_floor"] and not grounded:
			t["fall_from"] = here.y                      # left the ground
			t["air_from_t"] = t["t"]
		elif grounded and not t["was_floor"]:
			var drop: float = t["fall_from"] - here.y    # landed again
			t["ep"] += 1
			t["ep_t"] = maxf(t["ep_t"], t["t"] - t["air_from_t"])
			if drop < 0.3: t["d_tiny"] += 1
			elif drop < 1.0: t["d_small"] += 1
			elif drop < 5.0: t["d_mid"] += 1
			else: t["d_big"] += 1
			if drop > 1.0:                               # a step down is not a fall
				t["falls"] += 1
				t["fall_drop"] += drop
				t["fall_max"] = maxf(t["fall_max"], drop)
		t["was_floor"] = grounded
		var rl: int = maxi(t["nav"]._route.size() - t["nav"]._route_i, 0)
		t["route_end"] = rl
		t["route_max"] = maxi(t["route_max"], rl)
		# Consuming route nodes is the honest progress signal. A re-path can hand back a LONGER
		# route from a better place, so only an improvement resets the clock, never a regression.
		if _control:
			if left < t["best_left"]:
				t["best_left"] = left
				t["best_t"] = t["t"]
		elif rl > 0 and rl < t["best_left"]:
			t["best_left"] = rl
			t["best_t"] = t["t"]
		if t["t"] - t["best_t"] > STALL_WINDOW:
			t["state"] = "stalled"
			continue
		if dir == Vector3.ZERO:
			t["zero"] += 1
			var flat: Vector3 = t["goal"] - here
			flat.y = 0.0
			dir = flat.normalized() if flat.length_squared() > 0.0001 else Vector3.ZERO
		if dir != Vector3.ZERO:
			t["moving"] += 1
		var before := body.global_position
		t["walk"].walk(delta, dir, t["nav"].waypoint())
		# Asked to walk and went nowhere: the tick the hull spent pressed against geometry.
		if dir != Vector3.ZERO \
				and _horiz(body.global_position - before) < SkeletonScript.MOVE_SPEED * delta * 0.25:
			t["crept"] += 1


func _report() -> void:
	var arrived := 0
	print("\n[NavProbe] ---- results ----")
	for i in _trials.size():
		var t: Dictionary = _trials[i]
		var direct: float = _horiz(t["goal"] - t["start"])
		if t["state"] == "arrived":
			arrived += 1
		var body = t["body"]
		var at: Vector3 = body.global_position if is_instance_valid(body) else Vector3.ZERO
		print("  %2d  %-8s  direct %5.1fm  walked %6.1fm  closed to %5.1fm  in %5.1fs"
				% [i, t["state"], direct, t["travel"], t["best"], t["t"]])
		var ticks := maxf(float(t["ticks"]), 1.0)
		print("      route %d left of %d   no-route %d%%   on-floor %d%%   walking %d%%   blocked %d%% of walking   ended at %.0f,%.0f,%.0f"
				% [t["route_end"], t["route_max"],
				int(100.0 * float(t["zero"]) / ticks),
				int(100.0 * float(t["floor"]) / ticks),
				int(100.0 * float(t["moving"]) / ticks),
				int(100.0 * float(t["crept"]) / maxf(float(t["moving"]), 1.0)),
				at.x, at.y, at.z])
		print("      falls %d  dropped %.0fm total / %.0fm worst  airborne %.0f%%  in water %d%%"
				% [t["falls"], t["fall_drop"], t["fall_max"],
				100.0 * float(t["airborne"]) / maxf(float(t["t"]), 0.01),
				int(100.0 * float(t["wet"]) / maxf(float(t["ticks"]), 1.0))])
		print("      air episodes %d (longest %.1fs)  drops <0.3m:%d  0.3-1m:%d  1-5m:%d  >5m:%d"
				% [t["ep"], t["ep_t"], t["d_tiny"], t["d_small"], t["d_mid"], t["d_big"]])
	print("[NavProbe] %sarrived %d/%d" % ["CONTROL (no nav): " if _control else "", arrived, _trials.size()])


static func _horiz(v: Vector3) -> float:
	return Vector2(v.x, v.z).length()


## One line every TRACE_EVERY seconds for the traced trial: where it is, what the nav told it, and
## what the nav's own route cursor did. A route index that keeps resetting is re-pathing; one that
## climbs and never finishes is a route it cannot walk; a dir that flips is oscillation.
const TRACE_EVERY := 0.5

func _trace_tick(t: Dictionary, here: Vector3, dir: Vector3, pre_i: int, pre_n: int,
		grounded: bool) -> void:
	if t["t"] < _trace_t:
		return
	_trace_t = t["t"] + TRACE_EVERY
	var nav = t["nav"]
	var wp := Vector3.ZERO
	var have_wp := false
	if nav._route.size() > 0 and nav._route_i < nav._route.size():
		wp = MonsterNavScript.graph(_main).position_of(nav._route[nav._route_i])
		have_wp = true
	var mode := "route"
	if nav._unwedge_t > 0.0:
		mode = "UNWEDGE"
	elif dir == Vector3.ZERO:
		mode = "no-dir"
	print("  t=%5.1f  at %6.1f,%6.1f,%6.1f  %s  node %d/%d (was %d/%d)  wp %s  d=%4.1fm  dir %5.2f,%5.2f  %s  goal %5.1fm"
			% [t["t"], here.x, here.y, here.z, "grnd" if grounded else "AIR ",
			nav._route_i, nav._route.size(), pre_i, pre_n,
			("%6.1f,%6.1f,%6.1f" % [wp.x, wp.y, wp.z]) if have_wp else "        none       ",
			here.distance_to(wp) if have_wp else -1.0,
			dir.x, dir.z, mode, _horiz(here - t["goal"])])
