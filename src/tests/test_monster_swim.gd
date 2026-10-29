extends "res://src/tests/test_base.gd"
## A monster in water has to get out of it.
##
## ww_2fort is the fixture because the moat is what made this matter: the siege walks its waves
## across the bridge, and before monsters could swim, one that went in the water stayed there for
## the rest of the round — the bake's only edge out of a submerged node is the swim-up climb-out,
## which [MonsterNav] used to drop along with every other jump.
##
## Two halves, measured apart: the graph has to still offer the climb-out, and the body has to be
## able to perform it. Neither needs the monster's brain, so this drives a bare hull.
##
## COVERAGE, measured against the build before swimming: a_climb_out_edge_survives fails outright
## (every jump edge was dropped), and the_hulls_climb_out has nobody get out at all — without the
## swim there is no way up and the hull just stands on the bottom.

const WaypointGraph = preload("res://src/bot/waypoint_graph.gd")
const MonsterNavScript = preload("res://src/monsters/monster_nav.gd")
const MonsterBodyScript = preload("res://src/monsters/monster_body.gd")

const MAP := "ww_2fort"
const TICK := 1.0 / 60.0
const BUDGET := 900          # ticks allowed to get out — 15 s, and it takes 4-6 s in the probe
const SWIMMABLE := 1.5       # water this deep is swum rather than waded (the hull's waist is 0.9)
const HULLS := 6             # swimmers per run, all in the water at once
const SPREAD := 10.0         # metres between the pools they go in, so it is not one spot several times
const GOAL_AWAY := 25.0      # how far off the dry goal is, so the route steers and not the straight line
const RADIUS := Skeleton.RADIUS
const HEIGHT := Skeleton.HEIGHT

var _map_root: Node3D
var _graph: WaypointGraph
var _hulls: Array[CharacterBody3D] = []


## The map with its liquid volumes live. A func_water is a door, but nothing about the moat moves,
## so the volume's layer is all this needs — FuncWater's own _ready wants the trigger and target
## wiring main.gd does.
func _load_map() -> bool:
	var converter := MapConverter.new()
	_root().add_child(converter)
	var ok: bool = converter.convert(MAP)
	converter.queue_free()
	if not ok:
		return false
	var scn := ResourceLoader.load("user://resources/maps/%s.scn" % MAP, "",
			ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	_map_root = scn.instantiate()
	for child in _map_root.get_children():
		if not child.has_meta("entity"):
			continue
		if (child.get_meta("entity") as Dictionary).get("classname", "") != "func_water":
			continue
		# SOLID_NOT: the brush itself stops colliding, or the pool is a block of glass.
		if child is AnimatableBody3D:
			(child as AnimatableBody3D).collision_layer = 0
			(child as AnimatableBody3D).collision_mask = 0
		var vol := child.get_node_or_null("Volume") as Area3D
		if vol:
			vol.collision_layer = GameConsts.MASK_WATER
			vol.monitorable = true
	_root().add_child(_map_root)
	var full := WaypointGraph.new()
	if not full.load_generated(MAP):
		return false
	_graph = MonsterNavScript._walkable_only(full, _map_root)
	# Staged into the static every MonsterNav shares, so the navs below route on it: the runner scene
	# does not name a map, which is the case graph() keeps the loaded graph for.
	MonsterNavScript._graph = _graph
	MonsterNavScript._graph_map = MAP
	return true


## Every climb-out the walkable graph still offers: a kept edge from a submerged node to a dry one,
## in shallowest-water-first order and no two within SPREAD of each other. None at all is the
## failure the whole thing is about.
##
## Only water a monster would actually swim in counts — a puddle it wades out of tests nothing — and
## the shallow end is taken first because that is the siege's case (a wave crossing ww_2fort's
## bridge, into the moat); the deep ones are a swim through a flooded maze before any climb. The
## spread matters as much: ww_2fort has hundreds of these and its shallowest few are all the same
## pocket under the bridge, which would measure one spot over and over.
func _climb_outs() -> Array:
	var found: Array = []
	for e in _graph.edges():
		var from: Vector3 = _graph.position_of(e.x)
		if not SpatialQuery.is_point_in_water(_map_root, from + Vector3(0.0, HEIGHT * 0.5, 0.0)) \
				or SpatialQuery.is_point_in_water(_map_root, _graph.position_of(e.y)):
			continue
		var depth := _surface_above(from) - from.y
		if depth < SWIMMABLE:
			continue
		if not _open_to_the_surface(from):
			continue
		found.append({"from": from, "depth": depth})
	found.sort_custom(func(a, b): return a["depth"] < b["depth"])
	var spread: Array = []
	for cand: Dictionary in found:
		var near := false
		for kept: Dictionary in spread:
			near = near or cand["from"].distance_to(kept["from"]) < SPREAD
		if not near:
			spread.append(cand)
	return spread


func test_a_climb_out_edge_survives() -> void:
	if not _load_map():
		assert_true(false, "%s converts and has a bake" % MAP)
		return
	assert_gt(_climb_outs().size(), 0,
		"the walkable graph should keep the bake's way out of the water")


## HULLS swimmers at once, in different pools, because which one you pick decides the answer: some
## of these pools are pockets under the bridge where the way out starts by swimming away from the
## bank. Each is given a dry goal a walk away, so it is routed rather than aimed — the movement half
## of Skeleton._physics_process and nothing else of it.
##
## Measured on this fixture: five of the six are out of the water in 1-4.4 s, and the sixth swims
## its pool for the whole budget. The bar is set at half, because what this guards is that water
## stopped being a hole in the map — not a per-pool score, which belongs in the probe.
func test_the_hulls_climb_out() -> void:
	if not _load_map():
		assert_true(false, "%s converts and has a bake" % MAP)
		return
	var picks := _climb_outs()
	if picks.is_empty():
		return   # the test above is the one that reports this
	seed(1)   # MonsterNav draws a lateral wander per instance; fix it so the run repeats
	var swimmers: Array = []
	for i in mini(HULLS, picks.size()):
		var node: Vector3 = picks[i]["from"]
		var goal := _dry_goal(node)
		if goal == Vector3.INF:
			continue
		# Floating at the surface, which is where a monster that fell in ends up. Not on the bottom
		# (the hull can land inside the geometry there) and not dropped from above it: the bake links
		# a climb-out under an overhang as happily as one in the open, and a drop onto the bridge over
		# the moat never gets wet at all.
		var hull := _make_hull(Vector3(node.x, _surface_above(node) - (HEIGHT * 0.5 + 0.3), node.z))
		var walk = MonsterBodyScript.new()
		walk.setup(hull, Skeleton.MOVE_SPEED, HEIGHT)
		var nav = MonsterNavScript.new()
		nav.setup(hull)
		swimmers.append({"hull": hull, "walk": walk, "nav": nav, "goal": goal, "out": 0, "wet": 0,
			"swam": false})
	assert_gt(swimmers.size(), 0, "at least one pool with somewhere dry to route to")
	await _settle()   # the hulls only reach the broad phase once the server has stepped

	for tick in range(1, BUDGET + 1):
		for sw: Dictionary in swimmers:
			if sw["out"] > 0:
				continue
			var walk = sw["walk"]
			var hull: CharacterBody3D = sw["hull"]
			var dir: Vector3 = sw["nav"].desired_dir(TICK, sw["goal"], walk.in_water)
			if dir == Vector3.ZERO:
				dir = sw["goal"] - hull.global_position
				dir.y = 0.0
				dir = dir.normalized() if dir.length_squared() > 0.0001 else Vector3.ZERO
			walk.walk(TICK, dir, sw["nav"].waypoint())
			if walk.in_water:
				sw["wet"] += 1
				sw["swam"] = sw["swam"] or tick <= 2   # it really did start in the water
			elif hull.is_on_floor() and tick > 30:
				sw["out"] = tick
		await _physics_frame()

	var out := 0
	var tried := 0
	for sw: Dictionary in swimmers:
		if not sw["swam"]:
			continue   # never actually started in water: not a trial, and not a pass either
		tried += 1
		if sw["out"] > 0:
			out += 1
	assert_gt(tried, 0, "the swimmers should start in the water")
	assert_gt(out, tried / 2,
		"most of the %d swimmers should be out of the water inside %d ticks (got %d)"
			% [tried, BUDGET, out])


## Whether a swimmer at `p` can rise to the surface at all, rather than sitting in a pocket under a
## slab — ww_2fort's bridge has water under it, and getting out from under that is a swim sideways
## first, which is a different thing from climbing out and not what this measures.
func _open_to_the_surface(p: Vector3) -> bool:
	var ray := PhysicsRayQueryParameters3D.new()
	ray.collision_mask = GameConsts.MASK_WORLD_AND_CLIP
	ray.from = p + Vector3(0.0, HEIGHT * 0.5, 0.0)
	ray.to = Vector3(p.x, _surface_above(p) + HEIGHT, p.z)
	return _map_root.get_world_3d().direct_space_state.intersect_ray(ray).is_empty()


## A dry node a good walk from `node` that the graph can route to from it — far enough that the
## route, rather than the straight line MonsterNav hands back for a goal within DIRECT, is what
## steers. INF when the pool has nowhere to go, which is the bake's business, not the body's.
func _dry_goal(node: Vector3) -> Vector3:
	var best := Vector3.INF
	for i in _graph.positions.size():
		var p: Vector3 = _graph.position_of(i)
		if p.distance_to(node) < GOAL_AWAY or SpatialQuery.is_point_in_water(_map_root, p):
			continue
		if best != Vector3.INF and p.distance_to(node) >= best.distance_to(node):
			continue
		if _graph.path_ids(node, p).is_empty():
			continue
		best = p
	return best


func _make_hull(at: Vector3) -> CharacterBody3D:
	var body := CharacterBody3D.new()
	var cs := CollisionShape3D.new()
	cs.name = "CollisionShape3D"
	var cyl := CylinderShape3D.new()
	cyl.radius = RADIUS
	cyl.height = HEIGHT
	cs.shape = cyl
	cs.position.y = HEIGHT * 0.5
	body.add_child(cs)
	body.collision_layer = GameConsts.MASK_ENTITY
	body.collision_mask = GameConsts.MASK_WORLD | GameConsts.MASK_CLIP
	body.floor_snap_length = Skeleton.STEP_HEIGHT
	_root().add_child(body)
	body.global_position = at
	_hulls.append(body)
	return body


## The liquid surface above `p`, marched up a point probe at a time (as the baker does).
func _surface_above(p: Vector3) -> float:
	var y := p.y
	while y < p.y + 20.0:
		if not SpatialQuery.is_point_in_water(_map_root, Vector3(p.x, y, p.z)):
			return y - 0.1
		y += 0.2
	return p.y


func _teardown_test() -> void:
	for h in _hulls:
		if is_instance_valid(h):
			h.free()
	_hulls.clear()
	if is_instance_valid(_map_root):
		_map_root.free()
	_map_root = null
	_graph = null
	MonsterNavScript.reset()   # the graph is a static — don't leave this map's one loaded
