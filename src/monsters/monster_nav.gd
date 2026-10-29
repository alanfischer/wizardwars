class_name MonsterNav
extends RefCounted

## Waypoint path following for monsters — the thing that lets one cross a map instead of walking
## into the wall between it and its target.
##
## A behavior rather than a base class, for the same reason [SummonBehavior] is one: the monsters
## extend three different engine bases. The host keeps calling move_and_slide itself; this only
## answers "which way".
##
## It deliberately does NOT reuse BotBrain's follower. That one emits InputCommands for a netmove
## player puppet — wishdir, FL_JUMP, a ladder axis — and a monster is a CharacterBody3D that walks
## its own velocity. What is shared is the graph underneath and the constants BotBrain paid for.
##
## Monsters get their own WaypointGraph instance rather than BotSystem's. path_ids re-stamps every
## node weight (O(n)) whenever a query's perturb/salt/avoid differs from the last one, and every bot
## carries its own _node_avoid — interleaving a wave of monsters with the bots on one AStar3D would
## re-stamp a 14k-node graph on nearly every query, which is the crawl that cost ww_monoliths its
## framerate. A second graph, only ever queried unperturbed and unavoided, stamps once and never
## again.

const WaypointGraph = preload("res://src/bot/waypoint_graph.gd")

## Route queries allowed across all monsters per frame. A monster refused one keeps walking the
## route it has, which is nearly always still right.
const QUERIES_PER_FRAME := 2
const REPATH_MIN := 0.4         # min seconds between queries for one monster (BotBrain.REPATH_MIN)
const REPATH_FAIL := 1.5        # longer backoff after a query that found no route
## Tighter than BotBrain's 1.4-2.2: that width buys a bot its speed through a corner, and it is
## also what walks one off a ledge (see the ledge-following notes). A monster would rather arrive.
const ARRIVE := 1.0
## Vertical slack on arrival — a step up plus hull slop. Arrival CANNOT be a horizontal test
## alone: a monster standing at the foot of a ledge is directly under every waypoint on top of
## it, so a flat test counts them all as reached. It then burns the whole route without moving,
## finds it empty, re-paths, and does it again — walking the whole time and never arriving, which
## is exactly what the stalls that showed almost no airborne time were doing. The graph makes the
## same point about ladders: advance on 3D proximity so a vertical move is not skipped.
const ARRIVE_RISE := 1.2
## Arrival and route-loss, for a swimmer. A floating monster is metres ABOVE the submerged
## waypoints it is following — the baker puts them on the bottom — so the land rules disown the
## route it is actually swimming: nothing is ever reached, nothing advances, and past OFF_ROUTE the
## route is thrown away and re-cut every time. Measured in ww_2fort's water tunnel before this:
## the route flapped between 259 nodes and none for thirty seconds while the monster drifted in
## circles. In open water there is nothing to fall off, so arrival goes flat and route-loss is
## measured horizontally.
const ARRIVE_RISE_SWIM := 12.0
const DIRECT := 3.0             # goal this close: walk straight at it, no route needed
const GOAL_MOVED := 2.5         # goal drifted this far from the one the route was cut for: re-cut
const OFF_ROUTE := 12.0         # further than this from the current waypoint: the route is lost
const STUCK_TIME := 1.5         # moved less than STUCK_DIST in this long: something is in the way
const STUCK_DIST := 0.5
## Wedge recovery. Re-pathing from the spot you are stuck in hands back the same route into the
## same wall, so a stuck monster commits to a sidestep for a moment first, alternating sides if it
## is still stuck when that runs out. A bot gets out of a corner by jumping and strafing; a monster
## cannot jump — the bake refuses it every jump edge but the swim-up out of water — so sliding along
## the wall is all it has. Measured on ww_2fort: a third of the trials that failed were pinned at
## 27-97% of their walking ticks, and none of them recovered on their own.
const UNWEDGE_TIME := 0.7
const UNWEDGE_BACK := 0.35      # how much of the sidestep is backwards, to peel off the surface
## Lateral wander, so a crowd spreads across an approach instead of filing down its centreline.
## BotBrain buys that with a perturbed A* weight; here it is a steering offset, because a perturb
## is exactly what would force the O(n) re-stamp the separate graph exists to avoid.
const SLOP_MAX := 0.8

static var _graph: WaypointGraph = null
static var _graph_map := ""
static var _budget_frame := -1
static var _budget_left := 0

var _host: Node3D
var _route: PackedInt64Array = PackedInt64Array()
var _route_i := 0
var _repath_t := 0.0
var _route_goal := Vector3.INF   # the goal this route was cut for
var _slop := 0.0
var _stuck_t := 0.0
var _stuck_from := Vector3.INF
var _last_dir := Vector3.ZERO
var _unwedge_t := 0.0
var _unwedge_dir := Vector3.ZERO
var _unwedge_side := 1.0
var _swimming := false           # the last desired_dir said the host is in water


func setup(host: Node3D) -> void:
	_host = host
	_slop = randf_range(-SLOP_MAX, SLOP_MAX)


## The navigation graph for the map in play, loaded once and shared by every monster. Null when the
## map has neither a bake nor a hand file — callers fall back to walking straight at the goal.
static func graph(host: Node) -> WaypointGraph:
	var main := host.get_tree().current_scene if host.is_inside_tree() else null
	if main == null:
		return null
	var map_name: String = Game.current_map_name
	if map_name.is_empty():
		# A scene that does not name a map is a harness that loaded one itself (the probes, the swim
		# test). Keep whatever graph is already loaded rather than refusing it routes; in the game
		# proper this is the gap between maps, and main.gd has called reset() by then, so it is null.
		return _graph if _graph != null and _graph.loaded else null
	if _graph != null and _graph_map == map_name:
		return _graph if _graph.loaded else null
	_graph_map = map_name
	var full := WaypointGraph.new()
	# Same order BotSystem._ensure_waypoints uses: the bake first, the hand file as the fallback.
	if not full.load_generated(map_name) and not full.load_map(map_name):
		Log.info("[MonsterNav] No waypoint file for '%s' — monsters walk straight at their goal" % map_name)
		_graph = full
		return null
	# The water probe below needs a Node3D to read the world off. Every caller is one — a monster,
	# or the scene root in the nav probe — but `host` is only typed Node here, so it is a cast.
	_graph = _walkable_only(full, host as Node3D)
	return _graph if _graph.loaded else null


## The graph with every leg a walker cannot perform taken out of it.
##
## The bake is cut for a player, who jumps, ducks, climbs ladders and rides lifts; a monster does
## none of those, and a route that assumes one strands it.
##
## The exception is the way out of water. The baker links a submerged node to its bank with an
## FL_JUMP edge — the swim-up pop-out — and nothing else gets out of a pool, so dropping that one
## with the rest left ww_2fort's moat a hole in the map: two skeletons walked into it and stopped
## at the identical spot. A monster swims now (see [MonsterBody]), and can perform exactly that
## leg, so a jump edge is kept when it leaves water. It is recognised by probing the world rather
## than by a flag of its own, because the flag the baker writes for it is FL_JUMP and nothing else,
## and re-cutting every map's bake to say so would be a bigger change than one point query per
## jump edge, once per map.
##
## Dropping the rest also lets _build_components see the truth, so path_ids resnaps a goal a walker
## cannot reach to one it can, instead of handing out a route that dead-ends on a ledge.
static func _walkable_only(src: WaypointGraph, world: Node3D) -> WaypointGraph:
	const BLOCKED := WaypointGraph.FL_JUMP | WaypointGraph.FL_LADDER \
			| WaypointGraph.FL_LIFT | WaypointGraph.FL_CROUCH
	var kept: Array = []
	var kept_flags := {}
	var swims := 0
	for e in src.edges():
		# The edge's own flag and both endpoints': a hand file carries no edge flags at all, so the
		# node flags are the only thing standing between a monster and a ladder on that path.
		var f: int = int(src.edge_flags.get(e, 0)) | src.node_flags[e.x] | src.node_flags[e.y]
		if f & BLOCKED:
			# A jump and nothing worse, leaving a submerged node: the climb-out a swimmer makes.
			if (f & BLOCKED) != WaypointGraph.FL_JUMP or world == null \
					or not SpatialQuery.is_point_in_water(world, src.positions[e.x]):
				continue
			swims += 1
		kept.append(e)
		if src.edge_flags.has(e):
			kept_flags[e] = src.edge_flags[e]
	var out := WaypointGraph.new()
	out.build_from(src.positions, src.node_flags, kept, kept_flags)
	Log.info("[MonsterNav] walkable graph: %d of %d edge(s) a monster can use (%d out of water)" % [
			kept.size(), src.edges().size(), swims])
	return out


## Drop the loaded graph. Called on map unload so the next map does not inherit this one's routes.
static func reset() -> void:
	_graph = null
	_graph_map = ""


## Horizontal unit direction the host should walk to reach `goal`, or Vector3.ZERO when there is no
## route to give — no graph, no path, or the goal is close enough to walk straight at. A caller that
## gets ZERO should fall back to whatever it did before it had a nav. `swimming` relaxes arrival
## to the rules open water needs (see ARRIVE_RISE_SWIM).
func desired_dir(delta: float, goal: Vector3, swimming := false) -> Vector3:
	if not is_instance_valid(_host):
		return Vector3.ZERO
	_swimming = swimming
	var here := _host.global_position
	if _horiz(goal - here) <= DIRECT:
		_route.clear()
		return Vector3.ZERO  # close enough to see it; the host's own straight line is better

	var g := graph(_host)
	if g == null:
		return Vector3.ZERO

	_repath_t = maxf(_repath_t - delta, 0.0)
	_tick_stuck(delta, here)

	# Peeling off a wall beats re-reasoning about the route while still pressed into it.
	if _unwedge_t > 0.0:
		_unwedge_t -= delta
		return _unwedge_dir

	if _route_goal != Vector3.INF and goal.distance_to(_route_goal) > GOAL_MOVED:
		_route.clear()  # it moved; the old route leads where it was
	_advance(here)

	if _route.is_empty() and _repath_t <= 0.0 and _take_query():
		_route = g.path_ids(here, goal)
		_route_i = 0
		_route_goal = goal
		_repath_t = REPATH_FAIL if _route.is_empty() else REPATH_MIN
		_advance(here)

	if _route.is_empty():
		return Vector3.ZERO

	var wp: Vector3 = g.position_of(_route[_route_i])
	var to_wp := wp - here
	to_wp.y = 0.0
	if to_wp.length_squared() < 0.0001:
		return Vector3.ZERO
	# Spread the crowd sideways, but taper it to nothing on approach so the offset never pushes a
	# monster past the waypoint it is trying to stand on.
	var dir := to_wp.normalized()
	var taper := clampf(to_wp.length() / (ARRIVE * 4.0), 0.0, 1.0)
	_last_dir = (dir + Vector3(-dir.z, 0.0, dir.x) * _slop * taper).normalized()
	return _last_dir


## Where the route says to go next — the waypoint the host is walking to, or INF when it has no
## route. A swimmer wants the height as well as the bearing, which desired_dir does not carry: in
## water a flat direction is not enough, because the way into ww_2fort's tunnels (and out of them
## again) is through a submerged opening that has to be dived for. See [MonsterBody].
func waypoint() -> Vector3:
	if _graph == null or _route_i >= _route.size():
		return Vector3.INF
	return _graph.position_of(_route[_route_i])


## Forget the current route. For a host that has just been teleported, revived, or handed a goal it
## should re-reason about from scratch.
func clear() -> void:
	_route.clear()
	_route_goal = Vector3.INF
	_repath_t = 0.0
	_stuck_from = Vector3.INF


## Walk the cursor past every waypoint already reached, and drop a route that has run out or that
## the host has lost touch with entirely (knocked off a ledge, teleported, pushed through a door).
func _advance(here: Vector3) -> void:
	while _route_i < _route.size() and _reached(_graph.position_of(_route[_route_i]), here):
		_route_i += 1
	if _route_i >= _route.size():
		_route.clear()
	# Lost by 3D distance, not flat distance: a monster that has dropped into a pit is still
	# directly under the route it fell off, and a flat test says it is doing fine.
	elif _off_route(_graph.position_of(_route[_route_i]), here):
		_route.clear()


## Close enough to this waypoint to move on to the next.
func _reached(wp: Vector3, here: Vector3) -> bool:
	var d := wp - here
	return _horiz(d) <= ARRIVE \
			and absf(d.y) <= (ARRIVE_RISE_SWIM if _swimming else ARRIVE_RISE)


## Too far from the waypoint being walked to for the route to still be the host's. Flat while
## swimming: floating high above a submerged node is normal, and dropping into a pit is not a thing
## that happens in water.
func _off_route(wp: Vector3, here: Vector3) -> bool:
	return (_horiz(wp - here) if _swimming else wp.distance_to(here)) > OFF_ROUTE


## A monster pressed against geometry still has a perfectly good route and will lean on it forever.
## Standing still for STUCK_TIME is the cue to peel off and ask for a different one.
##
## Skipping the unreachable node instead of re-pathing was tried and measured WORSE — 48 arrivals
## against 52 over twelve paired crossings — so the route is thrown away rather than edited.
func _tick_stuck(delta: float, here: Vector3) -> void:
	if _stuck_from == Vector3.INF or here.distance_to(_stuck_from) > STUCK_DIST:
		_stuck_from = here
		_stuck_t = 0.0
		return
	_stuck_t += delta
	if _stuck_t < STUCK_TIME:
		return
	_stuck_t = 0.0
	_stuck_from = here
	if _last_dir != Vector3.ZERO:
		_unwedge_dir = (Vector3(-_last_dir.z, 0.0, _last_dir.x) * _unwedge_side
				- _last_dir * UNWEDGE_BACK).normalized()
		_unwedge_t = UNWEDGE_TIME
		_unwedge_side = -_unwedge_side  # the other way if this one is no good either
	_route.clear()
	_repath_t = 0.0


## One slot out of this frame's shared query budget, or false.
static func _take_query() -> bool:
	var frame := Engine.get_physics_frames()
	if frame != _budget_frame:
		_budget_frame = frame
		_budget_left = QUERIES_PER_FRAME
	if _budget_left <= 0:
		return false
	_budget_left -= 1
	return true


static func _horiz(v: Vector3) -> float:
	return Vector2(v.x, v.z).length()
