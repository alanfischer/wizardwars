extends Node3D
## A navmesh baked on the TRUE player hull, measured against the waypoint bake.
##
##   MAP=ww_ravine godot --path . res://tools/navmesh_spike.tscn
##   MAP=ww_ravine SETTLE=1 godot --path . res://tools/navmesh_spike.tscn -- --server --map ww_ravine
##
## Why hull 1: the only collision geometry in the scene is hull 0, the RENDER faces, while the
## player collides with clipnode hull 1. GoldSrcBSP.get_hull_mesh(model, 1) hands over hull 1 as
## triangles, and hull 1 is already dilated by the player box, so it bakes with agent_radius 0 --
## a walkable polygon on it means "a player centre can be here", with no second model of the
## player to keep in sync with the movement kernel. SETTLE additionally boots the map and runs
## the bake's own preparation (fast-forward, 60s warm-up, barrier-door deletion).
##
## WHAT THIS ANSWERED, so nobody re-runs the experiment: NavigationServer3D should NOT replace
## the waypoint sampler.
##  - Sampling is not the cost. A full ww_ravine bake is 92s: 60s warm-up (which a navmesh path
##    needs too, for mover poses) + 28s of graph work, and that 28s is dominated by ~20k movement
##    simulations validating edges and 18k arc sims for gap jumps. All of it survives a sampler
##    swap. Floor sampling is a slice of a slice.
##  - It would not have fixed any bug we actually hit. Every one was edge validation, movers or
##    connectivity, never "the grid failed to find the floor".
##  - The coverage gap is structural. Navmesh reaches 56-93% of the waypoint footprint, and the
##    settle runs showed the deficit is movers: a lift is walkable ground at every stop it serves
##    and a drawbridge only while down, so no single static pose can hold them. The bake encodes
##    those as LINKS (FL_LIFT/FL_JUMP) plus runtime binding, which is a different representation,
##    not a slower one.
##
## What it is still good for: a 0.7s second opinion on coverage. The navmesh finds 20-129 cells
## per map that the bake never sampled, which is the ww_wstland4 mesa-lip class of bug. Before
## trusting that as an oracle, confirm those cells are genuinely standable rather than wall tops
## or surfaces under water -- that check has not been done.

const WaypointGraph = preload("res://src/bot/waypoint_graph.gd")
const WaypointBake = preload("res://src/bot/waypoint_bake.gd")
const BAKE_WARMUP_SEC: float = WaypointBake.BAKE_WARMUP_SEC

const AGENT_HEIGHT := 0.05   # hull 1 already accounts for the player's height and width, so the
const AGENT_RADIUS := 0.0    # agent is a POINT on it. This is the whole point of using hull 1.
const AGENT_CLIMB := 0.45    # movement_config.step_height
const AGENT_SLOPE := 45.0
const CELL_SIZE := 0.12
const CELL_HEIGHT := 0.05
## Hull 1 is the locus of player CENTRES, so its walkable floor sits half a stand height above
## the real floor — while waypoint_baker stores floor positions. Drop the navmesh by this before
## comparing the two, or every cell disagrees vertically for no reason.
const CENTRE_TO_FLOOR := 0.9


func _ready() -> void:
	_run.call_deferred()


## Model index -> where that brush entity currently sits. Brush geometry in the BSP is frozen in
## its COMPILED pose, so a drawbridge is shut and a lift is parked wherever the mapper left it.
## Taking the transform before and after the settle and applying the difference gives the pose the
## real bake sees, without having to reason about how the importer placed anything.
func _carrier_poses() -> Dictionary:
	var out := {}
	var stack: Array = [get_tree().current_scene]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if not (n is Node3D) or not n.has_meta("bsp_model"):
			continue
		if n.has_meta("bsp_blocking"):
			continue    # the sky body shares model 0 and is not walkable
		var mi := int(n.get_meta("bsp_model"))
		if not out.has(mi):
			out[mi] = (n as Node3D).global_transform
	return out


## BSP model indices belonging to a brush entity's own bodies.
func _models_under(root: Node) -> Array:
	var out: Array = []
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if n.has_meta("bsp_model") and not n.has_meta("bsp_blocking"):
			out.append(int(n.get_meta("bsp_model")))
	return out


func _run() -> void:
	var map_name := OS.get_environment("MAP")
	if map_name.is_empty():
		push_error("[NavSpike] set MAP")
		get_tree().quit(1)
		return

	# With SETTLE the map is booted for real and given the bake's own warm-up, so movers reach
	# the pose the waypoint bake samples: drawbridges down, lifts at rest, approach doors open.
	var settle := OS.has_environment("SETTLE")
	var rest := {}
	var moved := {}
	var dropped := {}
	if settle:
		var tree := get_tree()
		# Exactly what main.gd does before loading, so a trigger_auto's spawn delay collapses and
		# round-start actually happens. Without it the warm-up is 60s of an idle map.
		TriggerRelay.bake_fast_forward = true
		var main = load("res://src/main.tscn").instantiate()
		tree.root.add_child(main)
		tree.current_scene = main
		var w := 0.0
		while w < 240.0 and not bool(main.get("_game_active")):
			await tree.create_timer(1.0).timeout
			w += 1.0
		if not bool(main.get("_game_active")):
			push_error("[NavSpike] map never became active")
			tree.quit(1)
			return
		rest = _carrier_poses()
		for _f in int(BAKE_WARMUP_SEC * Engine.physics_ticks_per_second):
			await tree.physics_frame
		var now := _carrier_poses()
		for mi in now:
			if rest.has(mi) and not (now[mi] as Transform3D).is_equal_approx(rest[mi]):
				moved[mi] = (now[mi] as Transform3D) * (rest[mi] as Transform3D).affine_inverse()
		# The bake does not only WAIT -- after the warm-up it deletes the doors that would open
		# on approach in a live match, so a region reachable in play is not walled off at the
		# door's shut pose. Lifts and drawbridges are spared, because their brush is the floor.
		# Matching that here is the difference between comparing two samplers and comparing two
		# different maps.
		var bake := WaypointBake.new()
		bake.name = "WaypointBake"
		add_child(bake)
		bake.bind(main)
		for b in bake.barrier_movers():
			for mi in _models_under(b):
				dropped[mi] = true
		print("\n[NavSpike] settled %.0fs: %d carrier(s), %d re-posed, %d barrier door(s) dropped" % [
				BAKE_WARMUP_SEC, now.size(), moved.size(), dropped.size()])

	var bsp := GoldSrcBSP.new()
	add_child(bsp)
	if bsp.load_bsp("res://maps/%s.bsp" % map_name) != OK:
		push_error("[NavSpike] cannot load %s" % map_name)
		get_tree().quit(1)
		return

	# Worldspawn AND every brush entity. Model 0 alone leaves out doors, lifts and ww_roc2's
	# drawbridges, and those carry whole levels of the map -- comparing without them would flatter
	# the waypoint bake, which does see them. They are frozen in their BSP (closed) pose here,
	# which is the honest limit of a STATIC navmesh rather than a flaw in the measurement.
	var t0 := Time.get_ticks_msec()
	var tris: PackedVector3Array = PackedVector3Array()
	var models := 0
	for mi in 256:
		var part: PackedVector3Array = bsp.get_hull_mesh(mi, 1)
		if part.is_empty():
			if mi > 0:
				break
			continue
		if dropped.has(mi):
			continue
		if moved.has(mi):
			var x: Transform3D = moved[mi]
			for i in part.size():
				part[i] = x * part[i]
		tris.append_array(part)
		models += 1
	var t_hull := Time.get_ticks_msec() - t0
	print("\n===== NAVMESH SPIKE: %s =====" % map_name)
	var hbox := AABB()
	for i in tris.size():
		hbox = AABB(tris[i], Vector3.ZERO) if i == 0 else hbox.expand(tris[i])
	print("hull 1 -> %d triangles from %d model(s)%s in %d ms, extent %.0f x %.0f x %.0f m" % [
			tris.size() / 3, models,
			"" if not settle else " (%d re-posed, %d dropped)" % [moved.size(), dropped.size()],
			t_hull, hbox.size.x, hbox.size.y, hbox.size.z])
	if tris.is_empty():
		push_error("[NavSpike] hull 1 produced no geometry")
		get_tree().quit(1)
		return

	# Hand the triangles straight to the baker as source geometry — no scene, no colliders.
	var src := NavigationMeshSourceGeometryData3D.new()
	src.add_faces(tris, Transform3D.IDENTITY)

	var nm := NavigationMesh.new()
	nm.agent_height = AGENT_HEIGHT
	nm.agent_radius = AGENT_RADIUS
	nm.agent_max_climb = AGENT_CLIMB
	nm.agent_max_slope = AGENT_SLOPE
	nm.cell_size = CELL_SIZE
	nm.cell_height = CELL_HEIGHT

	t0 = Time.get_ticks_msec()
	NavigationServer3D.bake_from_source_geometry_data(nm, src)
	var t_bake := Time.get_ticks_msec() - t0

	var verts: PackedVector3Array = nm.get_vertices()
	var npoly := nm.get_polygon_count()
	# Recast pads polygons to nvp slots with RC_MESH_NULL_IDX, and those come back as vertices
	# parked at 0xffff voxels (~3.2km at this cell height). Anything outside the source hull is
	# one of those, not geometry.
	var bounds := hbox.grow(1.0)
	var junk := 0
	var area := 0.0
	var box := AABB()
	var seeded := false
	var nav_cells := {}
	for pi in npoly:
		var poly: PackedInt32Array = nm.get_polygon(pi)
		var pts: PackedVector3Array = PackedVector3Array()
		for idx in poly:
			var v: Vector3 = verts[idx]
			if not bounds.has_point(v):
				junk += 1
				continue
			pts.append(v)
			nav_cells[Vector3i(floori(v.x / 4.0),
					floori((v.y - CENTRE_TO_FLOOR) / 4.0), floori(v.z / 4.0))] = true
			box = AABB(v, Vector3.ZERO) if not seeded else box.expand(v)
			seeded = true
		for i in range(2, pts.size()):
			area += (pts[i - 1] - pts[0]).cross(pts[i] - pts[0]).length() * 0.5
	print("navmesh: %d polygons, %d vertices, %.0f m2 walkable, baked in %d ms%s" % [
			npoly, verts.size(), area, t_bake,
			"" if junk == 0 else "  (%d padding slots skipped)" % junk])
	print("         extent %.0f x %.0f x %.0f m" % [box.size.x, box.size.y, box.size.z])

	# Same comparison the soak uses: distinct 4m cells, so the two samplers are measured the same
	# way. Node and polygon counts are not comparable; ground covered is.
	var g := WaypointGraph.new()
	var wpt_cells := {}
	if g.load_generated(map_name):
		for p in g.positions:
			wpt_cells[Vector3i(floori(p.x / 4.0), floori(p.y / 4.0), floori(p.z / 4.0))] = true
		print("waypoint bake: %d nodes, %d component(s)" % [
				g.positions.size(), g.component_sizes().size()])
	else:
		print("waypoint bake: no .gen_wpt for this map")

	var both := 0
	for c in wpt_cells:
		if nav_cells.has(c):
			both += 1
	print("\n4m cells (3D):  navmesh %d   waypoints %d   shared %d" % [
			nav_cells.size(), wpt_cells.size(), both])
	print("  navmesh-only %d   waypoint-only %d" % [
			nav_cells.size() - both, wpt_cells.size() - both])
	# CENTRE_TO_FLOOR is an estimate, so repeat it in plan view where that cannot bite.
	var nav_xz := {}
	var wpt_xz := {}
	for c in nav_cells: nav_xz[Vector2i(c.x, c.z)] = true
	for c in wpt_cells: wpt_xz[Vector2i(c.x, c.z)] = true
	var both_xz := 0
	for c in wpt_xz:
		if nav_xz.has(c):
			both_xz += 1
	print("4m cells (XZ):  navmesh %d   waypoints %d   shared %d  |  nav-only %d  wpt-only %d" % [
			nav_xz.size(), wpt_xz.size(), both_xz,
			nav_xz.size() - both_xz, wpt_xz.size() - both_xz])
	get_tree().quit(0)
