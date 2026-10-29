extends "res://src/tests/test_base.gd"
## The baked lift bridges on ww_storm, which is the map that pays for them: both capture dropoffs
## sit on the upper level of a func_platrot shaft, and before the baker knew what a lift was the
## graph had nothing at all above y 1.62 and bots never scored.
##
## Run against the shipped maps/waypoints/ww_storm.gen_wpt, because what is being tested is the
## bake, and a bake that quietly stops bridging is exactly the regression worth catching: the map
## still plays, the bots still run about, and the scoreboard just never moves.

const WaypointGraph = preload("res://src/bot/waypoint_graph.gd")

const MAP := "ww_storm"
## The two func_platrot shafts, from the map's own entities: deck footprint (world XZ) and the deck
## surface at each stop. Both plats are freestanding, so both rest at the bottom.
const SHAFTS: Array = [
	{x = [-1.6, 2.8], z = [30.4, 34.8], bottom = -4.78, top = 2.60},
	{x = [-1.6, 2.8], z = [-34.8, -30.4], bottom = -4.78, top = 2.60},
]
## The capture dropoffs (the i_t_g brush centres), which is what the whole exercise is for.
const DROPOFFS: Array[Vector3] = [Vector3(-4.0, 2.9, 28.0), Vector3(-4.0, 2.9, -28.0)]

var _graph: WaypointGraph


func _run_tests() -> void:
	_graph = WaypointGraph.new()
	if not _graph.load_generated(MAP):
		_current_test = "load(%s)" % MAP
		assert_true(false, "no baked waypoint file")
		return
	for name in ["test_both_shafts_are_bridged", "test_the_ride_is_two_way",
			"test_boarding_a_deck_is_always_flagged", "test_nothing_else_stands_on_a_deck",
			"test_the_dropoffs_have_waypoints", "test_the_upper_level_routes_both_ways"]:
		_current_test = name
		call(name)


## Every FL_LIFT node in the graph, as ids.
func _lift_ids() -> PackedInt32Array:
	var out := PackedInt32Array()
	for i in _graph.positions.size():
		if _graph.node_flags[i] & WaypointGraph.FL_LIFT:
			out.append(i)
	return out


## The FL_LIFT node standing at `y` in this shaft's column, or -1.
func _deck_node(shaft: Dictionary, y: float) -> int:
	for i in _lift_ids():
		var p := _graph.positions[i]
		if p.x >= shaft.x[0] and p.x <= shaft.x[1] and p.z >= shaft.z[0] and p.z <= shaft.z[1] \
				and absf(p.y - y) < 0.3:
			return i
	return -1


func test_both_shafts_are_bridged() -> void:
	assert_eq(_lift_ids().size(), 4, "one deck waypoint per shaft per stop")
	for s in SHAFTS:
		assert_gt(_deck_node(s, s.bottom), -1, "no deck waypoint at the bottom of shaft %s" % [s.z])
		assert_gt(_deck_node(s, s.top), -1, "no deck waypoint at the top of shaft %s" % [s.z])


func test_the_ride_is_two_way() -> void:
	for s in SHAFTS:
		var lo := _deck_node(s, s.bottom)
		var hi := _deck_node(s, s.top)
		if lo < 0 or hi < 0:
			continue
		for pair in [[lo, hi], [hi, lo]]:
			assert_true(_graph.flags_of_edge(pair[0], pair[1]) & WaypointGraph.FL_LIFT != 0,
				"the ride %d -> %d is missing, or is not flagged as one" % [pair[0], pair[1]])


## Walking ONTO a deck has to be flagged too, not just the ride between the stops: the deck is only
## under that waypoint at one of the two stops, so a bot that takes the edge without first checking
## walks into an open shaft.
func test_boarding_a_deck_is_always_flagged() -> void:
	var lifts := {}
	for i in _lift_ids():
		lifts[i] = true
	for e in _graph._edges:
		if not lifts.has(e.y):
			continue
		assert_true(_graph.flags_of_edge(e.x, e.y) & WaypointGraph.FL_LIFT != 0,
			"edge %d -> %d walks onto a deck without waiting for it" % [e.x, e.y])


## The fill samples the resting deck as ordinary floor and it is not: a route that merely crosses
## one walks a bot into the shaft the moment the plat is called away, and a bot standing in the
## shaft is what the descending deck reverses on.
func test_nothing_else_stands_on_a_deck() -> void:
	for s in SHAFTS:
		for i in _graph.positions.size():
			var p := _graph.positions[i]
			if p.x < s.x[0] or p.x > s.x[1] or p.z < s.z[0] or p.z > s.z[1]:
				continue
			if absf(p.y - s.bottom) > 0.45:
				continue
			assert_true(_graph.node_flags[i] & WaypointGraph.FL_LIFT != 0,
				"waypoint %d at %v stands on a lift deck but is not one" % [i, p])


func test_the_dropoffs_have_waypoints() -> void:
	for d in DROPOFFS:
		var best := INF
		for p in _graph.positions:
			best = minf(best, d.distance_squared_to(p))
		assert_lt(sqrt(best), 3.0, "no waypoint within reach of the dropoff at %v" % d)


## The upper level is lift-only, so it is also the case the prune is most likely to delete: it
## survives exactly as long as the ride edges give it a way back down.
func test_the_upper_level_routes_both_ways() -> void:
	var ground := Vector3(0.0, -4.4, 37.0)   # shaft-bottom floor, outside the deck
	for d in DROPOFFS:
		assert_false(_graph.path_ids(ground, d).is_empty(), "no route up to the dropoff at %v" % d)
		assert_false(_graph.path_ids(d, ground).is_empty(), "no route back down from %v" % d)
