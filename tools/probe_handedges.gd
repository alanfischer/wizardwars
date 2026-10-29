extends Node
## Are a hand-authored waypoint file's edges actually walkable by OUR player hull?
##
## The hand .HPB_wpt files were authored for the original mod's HPB bot. Their legs run 5-16m,
## far past this port's 3m obstacle horizon, so the bot crosses them trusting the straight line.
## This asks the other half of that question: is the straight line clear? Every edge in the file
## is put to the baker's own ground truth — the real Movement.Simulation driving a 0.4-radius
## capsule, the same kernel a player moves with — and the verdicts are tallied by leg length.
##
## A high pass rate means the file is fine and the BOT is what fails on it. A low one means the
## legs are not walkable by this port's player at all, whatever the bot does.
##
##   godot --headless --path . res://tools/probe_handedges.tscn -- --server --map ww_keep

const WaypointGraph = preload("res://src/bot/waypoint_graph.gd")
const WaypointBaker = preload("res://src/bot/waypoint_baker.gd")
const WaypointBake = preload("res://src/bot/waypoint_bake.gd")
## The same settle the real bake waits out, read from the bake so the two cannot drift.
const BAKE_WARMUP_SEC: float = WaypointBake.BAKE_WARMUP_SEC
const Movement = preload("res://addons/pmove/movement.gd")
const InputCommand = preload("res://addons/pmove/input_command.gd")
## HPB bot's own obstacle probe: two traces, eye and waist, 40 GoldSrc units ahead.
const HPB_TRACE := 40.0 * 0.025
const EYE := 1.6

var _main: Node3D


func _ready() -> void:
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
		print("[Edges] game never became active")
		tree.quit(1)
		return
	# Settle the map the way the bake does, or this measures a map that never exists in play.
	# Two separate things matter. Timed trigger chains move doors, walls and lifts into the pose
	# bots actually meet, so the warmup has to run. And an approach-door — one nothing in the map
	# ever opens by itself — stands in for a barrier that swings aside when a player walks up, so
	# the bake deletes it before sampling; leaving it shut reads a corridor as a wall. Without
	# this, ww_keep's four ~29m base corridors all failed at 39-41% of their length, which is a
	# door two fifths of the way down, not geometry.
	var warm := int(BAKE_WARMUP_SEC * Engine.physics_ticks_per_second)
	for _f in warm:
		await tree.physics_frame
	var bake := WaypointBake.new()
	bake.name = "WaypointBake"
	add_child(bake)
	bake.bind(_main)
	var opened := 0
	for b in bake.barrier_movers():
		if b.has_method("set_entity_visible"):
			b.set_entity_visible(false)
			opened += 1
	for _f in 8:
		await tree.physics_frame
	print("[Edges] settled %.0fs of round start, opened %d approach-door(s)" % [
			BAKE_WARMUP_SEC, opened])

	var map: String = _main.get("_current_map_name")
	var g := WaypointGraph.new()
	if not g.load_map(map):
		print("[Edges] %s has no hand .HPB_wpt file" % map)
		tree.quit(1)
		return

	var baker = WaypointBaker.new()
	baker._space = _main.get_world_3d().direct_space_state
	baker.configure_queries()       # masks and hulls; without it every cast misses (see the method)
	baker._sim_flat = true          # walk-test the flat edges too; that is the whole question
	baker._setup_move_sim(_main)
	await tree.physics_frame

	var verdicts := {}
	var wet := 0
	var by_len := {}                # length bucket -> [ok, total]
	var worst: Array = []
	var walkable: Array = []      # kept from this pass: re-deriving them below ran the whole
	var unobstructed: Array = []  # movement simulation a second time, for the same two answers
	for e in g._edges:
		var a: Vector3 = g.position_of(e.x)
		var b: Vector3 = g.position_of(e.y)
		var why: String = baker._why_no_edge(a, b)
		# How far the real mover actually got before it stopped. A leg that dies halfway has a
		# wall across it — the human who dropped these two waypoints walked a curve between them.
		# A leg that barely starts is blocked at the near end.
		var got := 1.0
		if why != "OK?":
			baker._edge_walk_sim(a, b, true)
			var end: Vector3 = baker._sim_char.global_position
			var full := Vector2(b.x - a.x, b.z - a.z).length()
			got = clampf(Vector2(end.x - a.x, end.z - a.z).length() / maxf(full, 0.01), 0.0, 1.0)
			# Did it stop at a waterline? The walk sim only walks; a real bot swims, so a leg that
			# dies where the water starts is the audit's limitation, not the map's.
			if baker._in_water(end + Vector3(0.0, 0.2, 0.0)) \
					or baker._in_water(end + Vector3(0.0, 0.9, 0.0)):
				wet += 1
		verdicts[why] = int(verdicts.get(why, 0)) + 1
		if why == "OK?":
			walkable.append(e)
		if why == "OK?" or got >= 0.8:
			unobstructed.append(e)
		var L := a.distance_to(b)
		var bucket := "0-3m" if L < 3.0 else ("3-6m" if L < 6.0 else ("6-10m" if L < 10.0 else "10m+"))
		var t: Array = by_len.get(bucket, [0, 0])
		t[1] += 1
		if why == "OK?":
			t[0] += 1
		else:
			worst.append([L, why, e.x, e.y, a, b, got])
		by_len[bucket] = t

	var total: int = g._edges.size()
	var ok: int = int(verdicts.get("OK?", 0))
	print("\n===== HAND EDGE AUDIT: %s =====" % map)
	print("%d edges, %d walkable by the real player hull (%.1f%%)" % [
			total, ok, 100.0 * ok / maxf(1.0, total)])
	print("\nBy leg length:")
	for k in ["0-3m", "3-6m", "6-10m", "10m+"]:
		if not by_len.has(k):
			continue
		var t: Array = by_len[k]
		print("  %-6s %4d/%4d walkable (%.0f%%)" % [k, t[0], t[1], 100.0 * t[0] / maxf(1.0, t[1])])
	print("\nWhy the rest fail:")
	var keys: Array = verdicts.keys()
	keys.sort_custom(func(x, y): return int(verdicts[x]) > int(verdicts[y]))
	for k in keys:
		if k == "OK?":
			continue
		print("  %-16s %4d (%.0f%%)" % [k, int(verdicts[k]), 100.0 * float(verdicts[k]) / maxf(1.0, total)])
	var buckets := [0, 0, 0, 0, 0]
	for w in worst:
		buckets[clampi(int(float(w[6]) * 5.0), 0, 4)] += 1
	var slid := 0
	for w in worst:
		if _slide_walk(baker, w[4], w[5]):
			slid += 1
	print("\nOf the %d legs the STRAIGHT walk failed, %d (%.0f%%) are traversable by an" % [
			worst.size(), slid, 100.0 * slid / maxf(1.0, worst.size())])
	print("HPB-style slider (turn parallel to the wall on contact, keep going).")
	print("\n%d of the %d failing legs stopped in water (the sim cannot swim; a bot can)" % [
			wet, worst.size()])
	print("\nHow far the failing legs got before the mover stopped:")
	var labels := ["0-20%", "20-40%", "40-60%", "60-80%", "80-100%"]
	for i in 5:
		print("  %-8s %4d" % [labels[i], buckets[i]])
	worst.sort_custom(func(x, y): return x[0] > y[0])
	print("\nLongest failing legs:")
	for w in worst.slice(0, 12):
		print("  %5.1fm  %-16s got %3.0f%% of the way   %3d %v -> %3d %v" % [
				w[0], w[1], 100.0 * w[6], w[2], w[4], w[3], w[5]])

	# Would dropping the unwalkable legs leave a graph bots can still use? A validator is only
	# worth building if the answer is yes — pruning a map into disconnected pieces is worse than
	# leaving the lies in, because A* at least returns SOMETHING today.
	# Two prune criteria, because they are not the same question. "Not walkable" is too blunt:
	# on a healthy file most failures are NEAR-MISSES — the mover walks the whole leg and stops a
	# little outside the 0.6m arrival radius, usually because the hand-placed node sits a bit
	# inside a wall. Dropping those throws away good edges. A leg the mover abandons partway has
	# something across it, and that is the one worth removing.
	print("\nPruning, two ways:")
	_components("  as authored:              ", g._edges, g.positions.size())
	print("  drop every unwalkable leg (%d -> %d edges):" % [total, walkable.size()])
	_components("                            ", walkable, g.positions.size())
	print("  drop only OBSTRUCTED legs, mover got <80%% (%d -> %d edges):" % [
			total, unobstructed.size()])
	_components("                            ", unobstructed, g.positions.size())
	baker._teardown_move_sim()
	tree.quit(0)


## Walk a leg the way the ORIGINAL HPB bot did, rather than the way our baker tests it.
##
## _edge_walk_sim steers straight at the target every tick, so it answers "is the straight line
## clear". HPB bot never required that: BotCantMoveForward traced 40 units ahead at eye and waist,
## and on a hit BotTurnAtWall took the surface normal, turned the bot parallel to it (normal +/- 90,
## whichever side faced more toward where it was going, plus 5-20 degrees of jitter half the time)
## and kept walking. It slid along walls by design, which is why waypoints 5-10m apart were enough
## for it. This reproduces that, so a leg can be scored against the movement model the waypoint
## files were actually authored for.
func _slide_walk(baker, a: Vector3, b: Vector3) -> bool:
	var sim = baker._sim
	if sim == null:
		return false
	baker._sim_char.global_position = a
	baker._sim_char.velocity = Vector3.ZERO
	baker._sim_body.force_sync_physics()
	var state = Movement.MovementState.new()
	state.on_floor = true
	var space: PhysicsDirectSpaceState3D = _main.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.new()
	q.collision_mask = baker.PROBE_MASK
	q.exclude = [baker._sim_char.get_rid()]
	var floor_y := minf(a.y, b.y)
	var horiz0 := Vector2(b.x - a.x, b.z - a.z).length()
	# Sliding takes a longer path than the straight line, so it needs a longer clock than the
	# straight test gets — but a bounded one, or a bot orbiting a pillar runs forever.
	var max_ticks := int(clampf(horiz0 / 0.08 * 2.5 + 60.0, 120.0, 420.0))
	var delta := 1.0 / 60.0
	for _t in max_ticks:
		var p: Vector3 = baker._sim_char.global_position
		if Vector2(b.x - p.x, b.z - p.z).length() < 0.6 and absf(p.y - b.y) < 0.55:
			return true
		if p.y < floor_y - 2.0:
			return false
		var d := Vector3(b.x - p.x, 0.0, b.z - p.z)
		if d.length() < 0.05:
			return false
		d = d.normalized()
		# BotCantMoveForward: eye and waist, 40 units.
		var hit := {}
		for h in [EYE, 0.0]:
			q.from = p + Vector3(0.0, h, 0.0)
			q.to = q.from + d * HPB_TRACE
			var r: Dictionary = space.intersect_ray(q)
			if not r.is_empty():
				hit = r
				break
		if not hit.is_empty():
			# BotTurnAtWall: parallel to the surface, on the side that faces more toward the goal.
			var n: Vector3 = hit["normal"]
			n.y = 0.0
			if n.length() > 0.01:
				n = n.normalized()
				var p1 := Vector3(-n.z, 0.0, n.x)
				var p2 := Vector3(n.z, 0.0, -n.x)
				d = p1 if p1.dot(d) > p2.dot(d) else p2
				if randf() < 0.5:                       # HPB's 5-20 degree jitter
					d = d.rotated(Vector3.UP, deg_to_rad(randf_range(5.0, 20.0)))
		var cmd = InputCommand.create(0, 0.0, -1.0, atan2(-d.x, -d.z), 0.0, 0, delta)
		sim.simulate_tick(baker._sim_body, state, cmd)
	var pf: Vector3 = baker._sim_char.global_position
	return Vector2(b.x - pf.x, b.z - pf.z).length() < 0.6 and absf(pf.y - b.y) < 0.55


## Weakly-connected component sizes over `edges`, counting only nodes that have one.
func _components(label: String, edges: Array, n: int) -> void:
	var parent := PackedInt32Array()
	parent.resize(n)
	for i in n:
		parent[i] = i
	var linked := PackedByteArray()
	linked.resize(n)
	for e in edges:
		linked[int(e.x)] = 1
		linked[int(e.y)] = 1
		var ra: int = e.x
		while parent[ra] != ra:
			ra = parent[ra]
		var rb: int = e.y
		while parent[rb] != rb:
			rb = parent[rb]
		if ra != rb:
			parent[ra] = rb
	var sizes := {}
	for i in n:
		if not linked[i]:
			continue
		var r := i
		while parent[r] != r:
			r = parent[r]
		sizes[r] = int(sizes.get(r, 0)) + 1
	var counts: Array = sizes.values()
	counts.sort()
	counts.reverse()
	var live := 0
	for c in counts:
		live += c
	print("%s %d connected node(s) in %d component(s) %s" % [
			label, live, counts.size(), str(counts.slice(0, 6))])
