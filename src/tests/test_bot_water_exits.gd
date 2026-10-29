extends "res://src/tests/test_base.gd"
## The baked climb-outs on ww_2fort, which is the map that pays for them: its water is the route
## into the enemy base, and the yard stands 1.60m over the moat — half a metre past what a swimmer
## can reach. The baker used to link every one of those yard lips anyway, and bots asked to perform
## them bobbed at the wall until the penned rescue took them back to spawn. Measured, dropping one
## bot into each of the seven water bodies: 1 of 7 got out inside 45s before, 7 of 7 after.
##
## Run against the shipped maps/waypoints/ww_2fort.gen_wpt, because the bake is what is being
## tested, and this regression is invisible in play: the map still works, the bots still swim, they
## just never come out.

const WaypointGraph = preload("res://src/bot/waypoint_graph.gd")
const MovementConfig = preload("res://addons/pmove/movement_config.gd")

const MAP := "ww_2fort"
## ww_2fort's func_water brushes (models *229..*235 of the .bsp), as world XZ footprint plus the
## surface the brush top sits at. The moat is the one under the bridge; the channels run from it to
## each base and end in a basin whose rim a body can actually climb.
const POOLS: Array = [
	{name = "moat", x = [-16.0, 14.4], z = [-12.8, 12.8], surf = -2.95},
	{name = "channel N", x = [-3.2, 1.6], z = [12.8, 38.4], surf = -3.2},
	{name = "channel S", x = [-3.2, 1.6], z = [-38.4, -12.8], surf = -3.2},
	{name = "basin N inner", x = [-3.2, 20.8], z = [38.4, 43.2], surf = -10.4},
	{name = "basin N outer", x = [20.8, 27.2], z = [38.4, 43.2], surf = -9.6},
	{name = "basin S inner", x = [-22.4, 1.6], z = [-43.2, -38.4], surf = -10.4},
	{name = "basin S outer", x = [-28.8, -22.4], z = [-43.2, -38.4], surf = -9.6},
]
## Somewhere in the middle of the moat, on its bed — where a bot that walks off the bridge ends up.
const MOAT_BED := Vector3(0.0, -7.0, 0.0)

## What a swimmer can actually climb, worked out from the movement rather than from the baker's
## own constant: the swim holds a body with its feet SWIM_FEET_DEPTH under the waterline, and
## PM_CheckWaterJump only launches while the lip is inside stand_height of those feet. Asserting
## against WaypointBaker.WATER_EXIT_RISE instead would pass for any value of it, including the
## 1.8 this test exists to stop anyone going back to.
static func swimmer_reach() -> float:
	return MovementConfig.new().stand_height - Player.SWIM_FEET_DEPTH


var _graph: WaypointGraph
var _exits: Array = []     # the climb-outs, collected once in _run_tests


func _run_tests() -> void:
	_graph = WaypointGraph.new()
	if not _graph.load_generated(MAP):
		_current_test = "load(%s)" % MAP
		assert_true(false, "no baked waypoint file")
		return
	# Every baked climb-out: an edge that starts under a waterline and ends above it.
	for e in _graph.edges():
		var a: Vector3 = _graph.position_of(e.x)
		var b: Vector3 = _graph.position_of(e.y)
		var pool := _pool_at(a)
		if pool.is_empty() or b.y <= float(pool.surf):
			continue
		_exits.append({pool = pool.name, rise = b.y - float(pool.surf), from = a, to = b})
	await super()


## The pool `p` is inside, with its waterline; empty when it is not in one.
func _pool_at(p: Vector3) -> Dictionary:
	for pool in POOLS:
		if p.x >= pool.x[0] and p.x <= pool.x[1] and p.z >= pool.z[0] and p.z <= pool.z[1] \
				and p.y <= pool.surf:
			return pool
	return {}


## Nothing in the graph asks a swimmer to climb higher than one can get.
func test_no_climb_out_asks_for_more_than_a_swimmer_has() -> void:
	var worst := {}
	for c in _exits:
		if float(c.rise) > float(worst.get("rise", -INF)):
			worst = c
	if worst.is_empty():
		assert_true(false, "no climb-out anywhere in the graph")
		return
	assert_true(float(worst.rise) <= swimmer_reach() + 0.01,
			"tallest climb-out is %.2fm out of the %s (a swimmer reaches %.2f) at %v" % [
				worst.rise, worst.pool, swimmer_reach(), worst.from])


## The moat's own rim is the yard at -1.35, which is 1.60m of sheer wall over the water. A bot aimed
## at it tops out 1.05m up and falls back, so there must be nothing there to aim at.
func test_the_moat_has_no_climb_out_at_all() -> void:
	var n := 0
	for c in _exits:
		if str(c.pool) == "moat":
			n += 1
	assert_eq(n, 0, "moat climb-outs")


## ...but the water as a whole has to be leavable, or falling in is a death sentence. Both basins
## end in a 0.27m lip, which is what the swim route into each base is for.
func test_the_basins_do_have_climb_outs() -> void:
	var per := {}
	for c in _exits:
		per[c.pool] = int(per.get(c.pool, 0)) + 1
	for side in ["basin N outer", "basin S outer"]:
		assert_true(int(per.get(side, 0)) > 0, "%s has %d climb-out(s)" % [side, per.get(side, 0)])


## The end-to-end claim: a bot on the moat bed can still get somewhere dry. The route is the long
## one now — down a channel and out at a basin — which is the way the map is built to be swum.
func test_the_moat_bed_can_still_route_to_dry_land() -> void:
	var dry := Vector3(-25.0, -6.3, -44.0)   # the south basin's bank, where the probe climbed out
	var route := _graph.path_ids(MOAT_BED, dry)
	assert_true(route.size() > 0, "no route from the moat bed to dry land")
	if route.is_empty():
		return
	var last: Vector3 = _graph.position_of(route[route.size() - 1])
	assert_true(_pool_at(last).is_empty(),
			"route from the moat ends at %v, still under water" % last)
