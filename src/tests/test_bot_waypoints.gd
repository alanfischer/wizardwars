extends "res://src/tests/test_base.gd"
## Tests for WaypointGraph route perturbation (bot route variety), run against the real shipped
## waypoint files since these properties only mean anything on the hand-authored graphs.

const WaypointGraph = preload("res://src/bot/waypoint_graph.gd")

var _graph: WaypointGraph
var _from := Vector3.ZERO
var _to := Vector3.ZERO


func _run_tests() -> void:
	for map_name in ["ww_2fort", "ww_memnate", "ww_ravine2"]:
		_graph = WaypointGraph.new()
		if not _graph.load_map(map_name):
			_current_test = "load(%s)" % map_name
			assert_true(false, "could not load waypoint file")
			continue
		_pick_far_endpoints()
		_current_test = "%s: baseline_deterministic" % map_name
		test_baseline_deterministic()
		_current_test = "%s: weights_reset_after_perturbed_query" % map_name
		test_weights_reset_after_perturbed_query()
		_current_test = "%s: same_salt_same_route" % map_name
		test_same_salt_same_route()
		_current_test = "%s: interleaved_salts_stay_correct" % map_name
		test_interleaved_salts_stay_correct()
		_current_test = "%s: avoid_set_invalidates_weights" % map_name
		test_avoid_set_invalidates_weights()
		_current_test = "%s: perturbed_routes_valid" % map_name
		test_perturbed_routes_valid()
		_current_test = "%s: salts_give_route_variety" % map_name
		test_salts_give_route_variety()
		_current_test = "%s: tombstones_excluded" % map_name
		test_tombstones_excluded()
		_current_test = "%s: waypoints_sit_at_floor_level" % map_name
		test_waypoints_sit_at_floor_level(map_name)
	_graph = WaypointGraph.new()
	_graph.load_map("ww_2fort")
	_current_test = "ww_2fort: objectives_mutually_reachable"
	test_objectives_mutually_reachable()


## Roughly base-to-base: the farthest-apart pair from a sampled subset of waypoints.
func _pick_far_endpoints() -> void:
	var n := _graph.positions.size()
	var best := -1.0
	for i in range(0, n, 7):
		for j in range(0, n, 7):
			var d: float = _graph.positions[i].distance_squared_to(_graph.positions[j])
			if d > best:
				best = d
				_from = _graph.positions[i]
				_to = _graph.positions[j]


func test_baseline_deterministic() -> void:
	var a := _graph.path_ids(_from, _to)
	assert_false(a.is_empty(), "no baseline route")
	assert_eq(a, _graph.path_ids(_from, _to), "unperturbed path changed between queries")


func test_weights_reset_after_perturbed_query() -> void:
	var base := _graph.path_ids(_from, _to)
	_graph.path_ids(_from, _to, 0.5, 12345)
	assert_eq(_graph.path_ids(_from, _to), base, "perturbed weights leaked into perturb=0 query")


func test_same_salt_same_route() -> void:
	for salt in [0, 7, 991]:
		var a := _graph.path_ids(_from, _to, 0.5, salt)
		assert_eq(a, _graph.path_ids(_from, _to, 0.5, salt), "salt %d unstable" % salt)


## The weight-restamp memo must invalidate on salt change, or one bot's route comes back
## computed against another bot's weights.
func test_interleaved_salts_stay_correct() -> void:
	var a := _graph.path_ids(_from, _to, 0.5, 11)
	var b := _graph.path_ids(_from, _to, 0.5, 22)
	assert_eq(_graph.path_ids(_from, _to, 0.5, 22), b, "salt 22 route changed after salt 11 queried")
	assert_eq(_graph.path_ids(_from, _to, 0.5, 11), a, "salt 11 route changed after salt 22 queried")


## The avoid set changes weights without changing perturb/salt, so the memo must key on it too.
func test_avoid_set_invalidates_weights() -> void:
	var base := _graph.path_ids(_from, _to, 0.5, 5)
	assert_false(base.is_empty(), "no baseline route to avoid")
	var avoid := {}
	for id in base:
		avoid[id] = 50.0
	var away := _graph.path_ids(_from, _to, 0.5, 5, avoid)
	assert_false(away.is_empty(), "avoid set left no route at all")
	assert_true(away != base, "avoid set ignored — weight memo did not invalidate")
	assert_eq(_graph.path_ids(_from, _to, 0.5, 5), base, "avoid penalties leaked into a later query")


func test_perturbed_routes_valid() -> void:
	var base := _graph.path_ids(_from, _to)
	for salt in 20:
		var p := _graph.path_ids(_from, _to, 0.5, salt)
		assert_false(p.is_empty(), "salt %d: empty route" % salt)
		if p.is_empty():
			continue
		assert_eq(p[0], base[0], "salt %d: wrong start node" % salt)
		assert_eq(p[-1], base[-1], "salt %d: wrong goal node" % salt)
		var all_edges := true
		for k in p.size() - 1:
			# HPB edges are directed; every hop must be a real one-way graph edge.
			if not _graph._astar.are_points_connected(p[k], p[k + 1], false):
				all_edges = false
		assert_true(all_edges, "salt %d: route uses a non-edge" % salt)


func test_salts_give_route_variety() -> void:
	var distinct := {}
	distinct[str(Array(_graph.path_ids(_from, _to)))] = true
	for salt in 40:
		distinct[str(Array(_graph.path_ids(_from, _to, 0.5, salt)))] = true
	assert_gt(distinct.size(), 1, "40 salts all produced the identical route")


## The editor tombstones a deleted waypoint in place (flag bit 31, origin zeroed) instead of
## renumbering the file. Those must never be graph nodes: the pile of them sits at the world
## origin, which is mid-map on most of these, and would swallow get_closest_point for anyone
## standing nearby — handing the bot a route of one isolated node and no way out.
func test_tombstones_excluded() -> void:
	var tombs := 0
	for i in _graph.positions.size():
		if _graph.node_flags[i] & WaypointGraph.FL_DELETED:
			tombs += 1
			assert_false(_graph._astar.has_point(i), "tombstoned waypoint %d became a node" % i)
	assert_gt(tombs, 0, "no tombstones in this file — test is not exercising anything")


## An HPB origin is the centre of the 72-unit standing hull; the graph (and the bot's own
## global_position) is floor-level. Without the half-hull drop every node reads as chest-high, and
## a bot walking up a ramp counts as having fallen off it and re-routes instead of climbing.
func test_waypoints_sit_at_floor_level(map_name: String) -> void:
	var f := FileAccess.open("res://maps/waypoints/%s.HPB_wpt" % map_name, FileAccess.READ)
	assert_true(f != null, "could not reopen waypoint file")
	if f == null:
		return
	f.big_endian = false
	f.get_buffer(8)
	f.get_32()
	f.get_32()
	var n := f.get_32()
	f.get_buffer(32)
	var checked := 0
	for i in n:
		f.get_32()
		var x := f.get_float()
		var y := f.get_float()
		var z := f.get_float()
		if not _graph._astar.has_point(i):
			continue
		var want := Vector3(-x, z, y) * WaypointGraph.SCALE - Vector3(0.0, WaypointGraph.HULL_HALF, 0.0)
		assert_true(_graph.positions[i].distance_to(want) < 0.001,
				"waypoint %d at %v, expected floor-level %v" % [i, _graph.positions[i], want])
		checked += 1
	f.close()
	assert_gt(checked, 0, "no live waypoints checked")


## ww_2fort ships one unpaired edge that made team 2's own spawn room enterable by nobody: bots
## could leave it and never route home, so that team could not score however well it played. Every
## objective must reach every other, in both directions.
func test_objectives_mutually_reachable() -> void:
	var places := {
		"team 1 grail": Vector3(25.2, -15.1, 90.8),
		"team 2 grail": Vector3(-26.8, -14.8, -90.8),
		"team 1 dropoff": Vector3(-27.2, 4.7, 38.4),
		"team 2 dropoff": Vector3(25.6, 4.7, -38.4),
		"team 1 spawn": Vector3(-35.9, 5.2, 40.7),
		"team 2 spawn": Vector3(34.3, 5.2, -40.7),
	}
	for a in places:
		for b in places:
			if a == b:
				continue
			assert_false(_graph.path_ids(places[a], places[b]).is_empty(),
					"no route from %s to %s" % [a, b])
