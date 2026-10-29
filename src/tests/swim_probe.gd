extends Node3D
## Probe: a monster that fell in the water has to get itself out.
##
##   godot --headless --path . res://src/tests/swim_probe.tscn
##
## Boots the map itself rather than main.gd — no hosting, so it runs beside a live server — and
## drives a bare monster hull on MonsterBody + MonsterNav, which is the movement half of
## Skeleton._physics_process with none of its targeting in the way. Each trial starts floating in
## one of the map's pools with a dry goal a walk away, and is scored on whether it ever stands on
## dry land again.
##
## Deliberately tolerant of a build with no swimming in it (MonsterBody.in_water, the swimming flag
## and MonsterNav.waypoint() are all probed for before use), so the same starts can be scored before
## and after the change. Measured that way, on 10 trials of 40 s:
##
##   ww_2fort   0 of 10 out   ->   8 of 10, in 4-20 s   (9 of the 10 had no route out of the water
##                                                       at all before — the bake's only edge out is
##                                                       the swim-up MonsterNav used to drop)
##   ww_ravine  0 of 10       ->  10 of 10
##   ww_osaka   0 of 10       ->  10 of 10
##
## The ww_2fort failures are both deep in its flooded tunnels, under a roof they never surface
## through; the moat, which is what a siege wave walks past, is the case that comes out in 4-6 s.
##
## Env: SWIM_MAP (ww_2fort), SWIM_TRIALS (6), SWIM_SECONDS (30, trials run together),
##      SWIM_TRACE (trial index to follow tick by tick, default 0 — set it to -1 for none).

const MonsterNavScript = preload("res://src/monsters/monster_nav.gd")
const MonsterBodyScript = preload("res://src/monsters/monster_body.gd")
const SkeletonScript = preload("res://src/monsters/skeleton.gd")

const GOAL_AWAY := 25.0         # how far off the dry goal is, so the route steers and not the straight line
const WAIST := 0.9              # the hull's waterlevel-2 height, as MonsterBody measures it
const EYE := 1.62               # and its eye, so "surfaced" means the same thing here as there
const SURFACE_MARCH := 20.0     # how far up a pool is searched for its surface

## What MonsterNav.graph() reads off the current scene to find the bake.
var _current_map_name := "ww_2fort"

var _trials: Array = []
var _limit := 30.0
var _started := false
var _trace := 0
# What this build of the monster code can do, so a before/after pair can be run on it.
var _nav_takes_swim := false
var _nav_has_waypoint := false
var _body_swims := false


func _ready() -> void:
	if OS.has_environment("SWIM_MAP"):
		_current_map_name = OS.get_environment("SWIM_MAP")
	_limit = float(OS.get_environment("SWIM_SECONDS")) if OS.has_environment("SWIM_SECONDS") else 30.0
	_trace = int(OS.get_environment("SWIM_TRACE")) if OS.has_environment("SWIM_TRACE") else 0
	for m in MonsterNavScript.new().get_method_list():
		if m.name == "desired_dir":
			_nav_takes_swim = m.args.size() >= 3
		_nav_has_waypoint = _nav_has_waypoint or m.name == "waypoint"
	for pr in MonsterBodyScript.new().get_property_list():
		_body_swims = _body_swims or pr.name == "in_water"
	_run.call_deferred()


func _run() -> void:
	var tree := get_tree()
	if not await _load_map():
		tree.quit(1)
		return

	var g = MonsterNavScript.graph(self)
	if g == null:
		print("[Swim] no walkable graph for %s" % _current_map_name)
		tree.quit(1)
		return
	var wet: Array = []
	var dry: Array = []
	for i in g.positions.size():
		var p: Vector3 = g.position_of(i)
		if SpatialQuery.is_point_in_water(self, p + Vector3(0.0, WAIST, 0.0)):
			wet.append(p)
		elif not SpatialQuery.is_point_in_water(self, p):
			dry.append(p)
	print("[Swim] graph %d node(s): %d submerged, %d dry" % [g.positions.size(), wet.size(), dry.size()])
	if wet.is_empty() or dry.is_empty():
		print("[Swim] nothing to probe here")
		tree.quit(1)
		return

	seed(99)   # the same pools every run, so two runs are a pair
	wet.shuffle()
	var want := int(OS.get_environment("SWIM_TRIALS")) if OS.has_environment("SWIM_TRIALS") else 6
	for i in mini(want, wet.size()):
		var node: Vector3 = wet[i]
		var goal := _dry_goal(g, dry, node)
		if goal == Vector3.INF:
			print("[Swim] %d: no routable dry goal from %s — skipped" % [i, node])
			continue
		# Floating at the surface, where a monster that fell in ends up. Not on the bottom (the hull
		# can land inside the geometry there and freeze) and not dropped from above it: plenty of
		# these columns have a bridge or a floor over them, and the drop never reaches the water.
		_start(Vector3(node.x, _surface_above(node) - (WAIST + 0.3), node.z), goal)
	print("[Swim] %d trial(s), %.0fs" % [_trials.size(), _limit])
	_started = true

	var elapsed := 0.0
	while elapsed < _limit:
		await tree.create_timer(1.0).timeout
		elapsed += 1.0
	for t: Dictionary in _trials:
		var body: CharacterBody3D = t["body"]
		var moved: Vector3 = body.global_position - t["from"]
		print(("[Swim] %d: out=%-4s at %5.1fs | wet %4d/%4d ticks | surfaced %4d | dy %+6.2f m"
				+ " | moved %5.1f m | %3.0f m short | climbs %d | no route %d") % [
			t["i"], "yes" if t["out_t"] > 0.0 else "NO", t["out_t"], t["wet"], t["ticks"], t["surf"],
			moved.y, Vector2(moved.x, moved.z).length(),
			t["goal"].distance_to(body.global_position), t["climbs"], t["noroute"]])
	var out := _trials.filter(func(t): return t["out_t"] > 0.0).size()
	print("[Swim] %d of %d got out of the water" % [out, _trials.size()])
	tree.quit(0)


## The map, with its liquid volumes live. The layer is FuncWater's doing at runtime, and none of the
## door machinery around it matters to a pool that never moves, so this stamps it directly.
func _load_map() -> bool:
	var converter := MapConverter.new()
	add_child(converter)
	var ok: bool = converter.convert(_current_map_name)
	converter.queue_free()
	if not ok:
		print("[Swim] could not convert %s" % _current_map_name)
		return false
	var scn := ResourceLoader.load("user://resources/maps/%s.scn" % _current_map_name, "",
			ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	var map_root: Node = scn.instantiate()
	for child in map_root.get_children():
		if not child.has_meta("entity"):
			continue
		if (child.get_meta("entity") as Dictionary).get("classname", "") != "func_water":
			continue
		# A func_water is spawned SOLID_NOT: the brush body has to stop colliding, or the pool is a
		# block of glass the hull is ejected from — which is what this probe saw first.
		if child is AnimatableBody3D:
			(child as AnimatableBody3D).collision_layer = 0
			(child as AnimatableBody3D).collision_mask = 0
		var vol := child.get_node_or_null("Volume") as Area3D
		if vol == null:
			continue
		vol.collision_layer = GameConsts.MASK_WATER
		vol.monitorable = true
		var box := _volume_bounds(vol)
		print("[Swim] pool '%s': y %.1f..%.1f, %.0f x %.0f m" % [child.name, box.position.y,
			box.position.y + box.size.y, box.size.x, box.size.z])
	add_child(map_root)
	await get_tree().physics_frame
	await get_tree().physics_frame
	return true


func _volume_bounds(vol: Area3D) -> AABB:
	var box := AABB()
	var first := true
	for cs: CollisionShape3D in vol.find_children("*", "CollisionShape3D", true, false):
		if cs.shape == null:
			continue
		for v in cs.shape.get_debug_mesh().get_faces():
			var w: Vector3 = cs.global_transform * v
			box = AABB(w, Vector3.ZERO) if first else box.expand(w)
			first = false
	return box


## The nearest dry node a good walk from `node` that the graph can route to from it. The furthest one
## is often in another component, which scores the follower for the bake's gaps.
func _dry_goal(g, dry: Array, node: Vector3) -> Vector3:
	var best := Vector3.INF
	for p: Vector3 in dry:
		if p.distance_to(node) < GOAL_AWAY:
			continue
		if best != Vector3.INF and p.distance_to(node) >= best.distance_to(node):
			continue
		if g.path_ids(node, p).is_empty():
			continue
		best = p
	return best


## The liquid surface above `p`, marched up a point probe at a time (as the baker does).
func _surface_above(p: Vector3) -> float:
	var y := p.y
	while y < p.y + SURFACE_MARCH:
		if not SpatialQuery.is_point_in_water(self, Vector3(p.x, y, p.z)):
			return y - 0.1
		y += 0.2
	return p.y


## A bare monster hull: the skeleton's shape and speed, none of its brain.
func _start(from: Vector3, goal: Vector3) -> void:
	var body := CharacterBody3D.new()
	var col := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = SkeletonScript.RADIUS
	cyl.height = SkeletonScript.HEIGHT
	col.shape = cyl
	col.position.y = SkeletonScript.HEIGHT * 0.5
	body.add_child(col)
	body.collision_layer = GameConsts.MASK_ENTITY
	body.collision_mask = GameConsts.MASK_WORLD | GameConsts.MASK_CLIP
	body.floor_snap_length = SkeletonScript.STEP_HEIGHT
	add_child(body)
	body.global_position = from
	var nav = MonsterNavScript.new()
	nav.setup(body)
	var walk = MonsterBodyScript.new()
	walk.setup(body, SkeletonScript.MOVE_SPEED, SkeletonScript.HEIGHT)
	_trials.append({
		"i": _trials.size(), "body": body, "nav": nav, "walk": walk, "goal": goal, "from": from,
		"t": 0.0, "ticks": 0, "wet": 0, "surf": 0, "out_t": 0.0, "climbs": 0, "noroute": 0,
	})


func _physics_process(delta: float) -> void:
	if not _started:
		return
	for t: Dictionary in _trials:
		var body: CharacterBody3D = t["body"]
		t["t"] += delta
		t["ticks"] += 1
		var here: Vector3 = body.global_position
		# Scored with the probe's own waist probe rather than the body's, so a build with no swimming
		# in it at all is measured the same way.
		var wet := SpatialQuery.is_point_in_water(self, here + Vector3(0.0, WAIST, 0.0))
		var args: Array = [delta, t["goal"], wet] if _nav_takes_swim else [delta, t["goal"]]
		var dir: Vector3 = t["nav"].callv("desired_dir", args)
		if dir == Vector3.ZERO:
			var flat: Vector3 = t["goal"] - here
			flat.y = 0.0
			dir = flat.normalized() if flat.length_squared() > 0.0001 else Vector3.ZERO
		if _body_swims:
			t["walk"].walk(delta, dir, t["nav"].waypoint() if _nav_has_waypoint else Vector3.INF)
			if t["walk"]._waterjump_t >= preload("res://addons/pmove/ladder_water.gd").WATERJUMP_TIME:
				t["climbs"] += 1
		else:
			t["walk"].walk(delta, dir)
		if t["nav"]._route.is_empty():
			t["noroute"] += 1
		if not SpatialQuery.is_point_in_water(self, here + Vector3(0.0, EYE, 0.0)):
			t["surf"] += 1
		if wet:
			t["wet"] += 1
		elif t["out_t"] == 0.0 and t["t"] > 1.0 and body.is_on_floor():
			t["out_t"] = t["t"]   # dry and standing on something: it is out
		if t["i"] == _trace and t["ticks"] % 60 == 0:
			_trace_tick(t, dir, wet)


func _trace_tick(t: Dictionary, dir: Vector3, wet: bool) -> void:
	var body: CharacterBody3D = t["body"]
	var wp := Vector3.INF
	if _nav_has_waypoint:
		wp = t["nav"].waypoint()
	print(("[Trace] t%4d pos=%.1f,%.1f,%.1f floor=%s waist=%s surfaced=%s vel=%.1f,%.1f,%.1f"
			+ " dir=%.2f,%.2f wp=%.1f,%.1f,%.1f route=%d climbs=%d") % [
		t["ticks"], body.global_position.x, body.global_position.y, body.global_position.z,
		body.is_on_floor(), wet,
		not SpatialQuery.is_point_in_water(self, body.global_position + Vector3(0.0, EYE, 0.0)),
		body.velocity.x, body.velocity.y, body.velocity.z, dir.x, dir.z, wp.x, wp.y, wp.z,
		t["nav"]._route.size() - t["nav"]._route_i, t["climbs"]])
