extends SceneTree
## ww_monoliths: do the five command points reset to their starting colours after a win?
## Boots the real dedicated server, plays three rounds (red, blue, red) by activating the
## capture goals in sequence, and dumps each point's beam colour, lights and goal state.
## Every "-> reset" line must match the "after init" line exactly.
##
## Run: Godot --headless -s tools/probe_monolith_reset.gd -- --server --map ww_monoliths

var goals: Node
var map_root: Node
var _beam_nodes := {}
var _light_nodes := {}


func _scan() -> void:
	for n in map_root.find_children("*", "", true, false):
		var e: Dictionary = n.get_meta("entity", {}) if n.has_meta("entity") else {}
		var tn := String(e.get("targetname", ""))
		if tn.is_empty():
			continue
		if tn.begins_with("beam") and not tn.contains("_"):
			_beam_nodes[tn] = n
		elif tn.begins_with("blight") or tn.begins_with("rlight"):
			_light_nodes[tn] = n


func _colname(c: Color) -> String:
	if c.r > 0.5 and c.b < 0.5: return "RED"
	if c.b > 0.5 and c.r < 0.5: return "BLU"
	return "WHT"


func _dump(label: String) -> void:
	var line := ""
	for k in ["beam1", "beam2", "beam3", "beam4", "beam5"]:
		var b = _beam_nodes.get(k)
		line += "%s=%s " % [k, _colname(b._color) if b else "??"]
	var l := ""
	for k in ["blight1", "rlight1", "blight5", "rlight5"]:
		var n = _light_nodes.get(k)
		l += "%s=%s " % [k, ("ON " if n and n._is_on else "off")]
	var gl := ""
	for g in [111, 121, 131, 141, 151, 211, 221, 231, 241, 251]:
		var go = goals.get_goal(g)
		gl += "%d:%s " % [g, (["inact", "ACTIVE", "REMOVED"][go.goal_state] if go else "?")]
	print("[%s]\n   beams  %s\n   lights %s\n   goals  %s" % [label, line, l, gl])


func _wait(sec: float) -> void:
	var t := 0.0
	while t < sec:
		await process_frame
		t += get_root().get_process_delta_time()


func _initialize() -> void:
	goals = get_root().get_node("GoalSystem")
	var main := (load("res://src/main.tscn") as PackedScene).instantiate()
	get_root().add_child(main)
	await _wait(3.0)
	map_root = main.get("_map_root")
	if map_root == null:
		print("map not loaded"); quit(1); return
	_scan()
	print("beams: %s" % [_beam_nodes.keys()])

	Engine.time_scale = 4.0
	await _wait(6.0)
	_dump("after init (cap1/cap5 fired at t=3)")

	# Alternate red and blue wins so a stale toggle would show up on round 2+.
	var rounds := [[242, 232, 222, 212], [122, 132, 142, 152], [242, 232, 222, 212]]
	for r in rounds.size():
		var chain: Array = rounds[r]
		var winner := "red" if chain[0] == 242 else "blue"
		for i in chain.size():
			var g = goals.get_goal(chain[i])
			if not g:
				print("round %d: goal %d MISSING" % [r, chain[i]])
				continue
			g.goal_activate(null)
			if i == chain.size() - 1:
				# Before the delay-2 reset batch: the winning point should read the
				# winner's colour, so the capture still registers on screen.
				await _wait(0.8)
				_dump("round %d %s capture flash" % [r, winner])
				await _wait(2.2)
			else:
				await _wait(3.0)
		await _wait(8.0)
		_dump("round %d won by %s -> reset" % [r, winner])
	quit()
