extends SceneTree
## ww_monoliths: hunt for the cap-point cover getting out of phase with the capture lockout.
##
## Invariant: the cover (func_door indicatorN) is up exactly while that point is locked out,
## i.e. while its capture goal (1N2 for blue, 2N2 for red) is ACTIVE. Plays a long game --
## every tick each team captures whatever its criteria currently allow, so the warpath runs
## back and forth through round wins -- and reports every violation that outlives a frame.
##
## Run: Godot --headless -s tools/probe_monolith_cover_sync.gd -- --server --map ww_monoliths

const POINTS := [2, 3, 4]
const CAP_GOALS := [122, 132, 142, 152, 212, 222, 232, 242]  # blue 1N2, red 2N2
const WIN_GOALS := [152, 212]  # each team's last capture
const GATE_HOLD := 20.0
const TOLERANCE := 0.35  # a mismatch shorter than this is just intra-frame ordering

var goals: Node
var map_root: Node
var doors := {}
var _bad_since := {}      # point -> time the current mismatch started
var _reported := {}
var _violations := 0
var _clock := 0.0


func _wait(sec: float) -> void:
	var t := 0.0
	while t < sec:
		await process_frame
		var d := get_root().get_process_delta_time()
		t += d
		_clock += d
		_check()


func _cover_up(n: int) -> bool:
	var d = doors["indicator%d" % n]
	var off: Vector3 = d.position - d._base_position
	return off.distance_to(d.position2) < off.distance_to(d.position1)


func _locked(n: int) -> bool:
	for gid in [100 + n * 10 + 2, 200 + n * 10 + 2]:
		var g = goals.get_goal(gid)
		if g and g.goal_state == 1:  # ACTIVE == mid-lockout
			return true
	return false


func _check() -> void:
	for n in POINTS:
		var mismatch := _cover_up(n) != _locked(n)
		if not mismatch:
			_bad_since.erase(n)
			_reported.erase(n)
			_reported.erase(str(n))
			continue
		if not _bad_since.has(n):
			_bad_since[n] = _clock
			continue
		var held: float = _clock - _bad_since[n]
		if held > TOLERANCE and not _reported.has(n):
			_reported[n] = true
			_violations += 1
			print("  !! t=%7.2f point %d out of phase: cover=%s lockout=%s" % [
				_clock, n, "UP" if _cover_up(n) else "down", _locked(n)])
		# A mismatch outliving the 5s toggle is not a window any pending fire will close.
		if held > 7.0 and not _reported.has(str(n)):
			_reported[str(n)] = true
			print("  !!!! t=%7.2f point %d STUCK out of phase for %.1fs" % [_clock, n, held])


## One capture per tick: a real player has to run to the next point, and each capture
## restores the next one's prerequisite, so grabbing them all in one tick is not a
## sequence the map can actually produce. Returns true on a round-winning capture.
func _try_captures() -> bool:
	for gid in CAP_GOALS:
		var g = goals.get_goal(gid)
		if g and g.goal_state == 0 and g.check_activation(null):
			print("  t=%7.2f capture goal %d" % [_clock, gid])
			g.goal_activate(null)
			return gid in WIN_GOALS
	return false


func _initialize() -> void:
	goals = get_root().get_node("GoalSystem")
	var main := (load("res://src/main.tscn") as PackedScene).instantiate()
	get_root().add_child(main)
	await _wait(3.0)
	map_root = main.get("_map_root")
	if map_root == null:
		print("map not loaded"); quit(1); return
	for n in map_root.find_children("*", "", true, false):
		var e: Dictionary = n.get_meta("entity", {}) if n.has_meta("entity") else {}
		var tn := String(e.get("targetname", ""))
		if tn.begins_with("indicator"):
			doors[tn] = n
	await _wait(8.0)

	print("=== playing; each tick both teams capture whatever they legally can ===")
	for i in 100:
		if _try_captures():
			# The spawn gates hold everyone in for gate_short_mm's 20s, and a non-thread
			# multi_manager ignores a win landing before that run ends, as GoldSrc does.
			await _wait(GATE_HOLD)
		await _wait(3.0)

	print("=== %d violation(s) ===" % _violations)
	quit()
