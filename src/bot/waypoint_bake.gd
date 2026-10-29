extends Node
## Offline bot-navigation bake: the map preparation, the sampling run and the diagnostics that
## measure it. Driven by main.gd's --bake-waypoints (one map per process; loop via
## tools/bake_waypoints.sh), which parents one of these to itself and calls run(self).
##
## Preparing the map is most of the job. A bake samples the geometry bots MEET, which is not the
## map's t=0 pose: timed trigger chains have to run out, approach-doors stand in for barriers that
## swing aside, and a mover whose brush is a floor has to survive both. That is what BAKE_WARMUP_SEC
## and barrier_movers() are for, and tools/navmesh_spike.gd and tools/probe_handedges.gd reuse them
## so a measurement is taken on the same map the bake saw.
##
## The sampler itself is WaypointBaker; this never decides where a waypoint goes.

const WaypointBaker = preload("res://src/bot/waypoint_baker.gd")

## Round-start simulation run before the graph is sampled, so timed geometry (ww_monoliths' ~46s
## drawbridge gates, ~30s auto-opening toggle-walls) is in its play-time pose.
const BAKE_WARMUP_SEC := 60.0

## The map being baked, for log lines. Set by run() or bind().
var _map := ""
## The node whose subtree the map hangs under — main.gd. Also the baker's move-sim owner.
var _main: Node3D


## Point a runner at a booted map without baking, for the nav tools that only want the preparation
## rules (barrier_movers). `main` is the map's root owner — main.gd — and every entity lookup here
## runs over its subtree.
func bind(main: Node3D) -> void:
	_main = main
	_map = String(Game.current_map_name)


## Loads the map headless, samples a bot-navigation graph via WaypointBaker, writes
## maps/waypoints/<map>.gen_wpt, and quits. One map per process — loop via tools/bake_waypoints.sh.
func run(main: Node3D) -> void:
	bind(main)
	if _map.is_empty():
		push_error("[Bake] --bake-waypoints requires --map <name>")
		get_tree().quit(1)
		return
	Log.info("[Bake] Preparing map: %s" % _map)
	if not _main.prepare_host_map(_map):
		push_error("[Bake] Failed to prepare map: %s" % _map)
		get_tree().quit(1)
		return
	# Fast-forward timed trigger chains so round-start opening settles in a few frames instead of
	# real time. Set before the map loads so even a trigger_auto's own spawn delay collapses.
	TriggerRelay.bake_fast_forward = true
	_main.load_map_headless(_map)

	# Let the physics server build the map's static colliders before intersect_ray/cast_motion query
	# the space, or they'd see an empty world.
	for _f in 4:
		await get_tree().physics_frame

	# Simulate round-start so the map settles into the topology bots actually face (a trigger_auto
	# fires reset/round-start on spawn, driving things like ww_chasm's wall timer). Several maps only
	# become themselves on a timer — ww_monoliths' gate_1 drawbridges swing down at ~46s — so sampling
	# too early bakes a layout that never exists in play.
	for _f in int(BAKE_WARMUP_SEC * Engine.physics_ticks_per_second):
		await get_tree().physics_frame
	Log.info("[Bake] %s: simulated %.0fs of round start before sampling" % [
		_map, BAKE_WARMUP_SEC])

	for _wt in _main.find_children("*", "FuncWallToggle", true, false):
		Log.info("[Bake] toggle-wall %s solid=%s" % [_wt.name, str(_wt.get("_game_visible"))])

	# Open barriers that open on approach in a live match — doors — so a region genuinely reachable in
	# play isn't walled off at the door's shut t=0 state (which fragments the graph). Deferred
	# collision-disable needs a few frames to apply.
	#
	# NOT func_wall_toggle: unlike an approach-door it has no self-opening behaviour — it flips only when
	# a trigger fires it, and the two cases pull opposite ways. Some solid-start (spawnflags=0) toggle-
	# walls open automatically at round-start (ww_chasm redwall/bluewall, on a ~30s timer) and bots
	# SHOULD route through them; others are objective COVERS opened only by a player action (ww_storm
	# bluedet/reddet det-grates, ww_osaka detwall/flagNcover — detpack/capture) and bots must route
	# AROUND them. We don't force these open OR closed: the round-start simulation above has already run
	# A door the warmup above already opened is left ALONE — that pose IS the play-time geometry.
	# Many rotating doors are DRAWBRIDGES whose brush is the walkway, not a barrier in a doorway:
	# "open" lays them flat to bridge a gap, so deleting an already-open one removes the bridge
	# instead of clearing a path (this stranded both ww_monoliths bases as isolated graph islands).
	# Doors still shut after the warmup are ones nothing in the map ever triggers, and for those the
	# delete is a fair stand-in for a barrier swinging out of the way.
	#
	# Nor a LIFT, for the same reason a drawbridge is spared: its brush is the floor you ride, and
	# deleting it removes the only way up instead of clearing a way through. Collected first so the
	# loop below can recognise one (see _lift_entities).
	var lifts := _lift_entities()
	Log.info("[Bake] %s: %d lift(s) found for stop bridging" % [_map, lifts.size()])

	var opened := 0
	for b in barrier_movers():
		if b.has_method("set_entity_visible"):
			b.set_entity_visible(false)
			opened += 1
	if opened > 0:
		for _f in 4:
			await get_tree().physics_frame
		Log.info("[Bake] %s: opened %d approach-door(s) for sampling" % [_map, opened])

	var seeds: Array = []
	for sp in SpawnSystem.get_all_spawns():
		seeds.append(sp.global_position)
	if seeds.is_empty():
		# Deathmatch maps have no team spawns (SpawnSystem tracks only those); seed from
		# info_player_* nodes instead so FFA maps like ww_castlerush still bake.
		for sp in _main.find_children("*", "InfoPlayerSpawn", true, false):
			seeds.append((sp as Node3D).global_position)
	if seeds.is_empty():
		push_error("[Bake] %s has no spawn points to seed from" % _map)
		get_tree().quit(1)
		return

	# Objectives, for the same reason the water pass seeds pool beds: the spawn-seeded fill only
	# reaches what it can WALK to, and a flag room cut off from every spawn is as sealed as a pool.
	# ww_ravine had a bottomless slot at z=-18 that stopped the fill; ww_storm's flag room is ringed
	# by a trigger_hurt the sampler refuses to walk through. Both left the nearest node to the flag
	# on the ROOF above it, so every route there walked bots onto the roof and left them.
	#
	# These join `seeds`, the prune's ground truth for "somewhere a bot starts", so a flag also
	# VOUCHES for its room being reachable. That part is load-bearing: a flag is by definition
	# somewhere players get to, and seeding it as a mere helper leaves the prune free to delete the
	# room again the moment the fill can't walk in — measured on ww_storm, which put the flag back
	# out of reach and had bots dying 9-12 times a match.
	#
	# Grabbable PICKUPS only. Half a TF map's goals are logic entities (timers, respawn bookkeeping)
	# parked in voids under the floor; seeding those claims grid cells the real fill wanted and
	# severs corridors — measured on ww_castle, where seeding all 24 of its goals turned 5314 nodes
	# in 1 component into 5060 in 2, and it has no pickups at all. Same grabbable test the bot brain
	# uses to tell a flag from scenery, so ww_golem's un-pickupable crystals stay out too.
	var pickups := 0
	for g in _goal_entities():
		if GoalSystem.is_carriable_flag(g):
			seeds.append(_goal_world_position(g))
			pickups += 1
	Log.info("[Bake] %s: %d flag pickup(s) added as seeds" % [_map, pickups])

	# Ladders connect levels that floor-sampling can't link on its own — collect each func_ladder's
	# footprint so the baker can bridge its two landings.
	var ladders: Array = []
	for lad in _main.find_children("*", "FuncLadder", true, false):
		var aabb := _node_world_aabb(lad as Node3D)
		if aabb.size == Vector3.ZERO:
			continue
		ladders.append({
			center = aabb.get_center(),
			ymin = aabb.position.y,
			ymax = aabb.end.y,
			radius = maxf(aabb.size.x, aabb.size.z) * 0.5,
			# Full XZ footprint: a big climbable rock-face/ramp ladder is many metres across, so its
			# centre lands inside the cliff — the baker uses these bounds instead (WaypointBaker._footprint_node).
			xmin = aabb.position.x, xmax = aabb.end.x,
			zmin = aabb.position.z, zmax = aabb.end.z,
		})
	Log.info("[Bake] %s: %d func_ladder(s) found for level bridging" % [_map, ladders.size()])

	# A deep pool is sealed off from the spawn-seeded fill, so the baker seeds each water volume's
	# submerged floor to give the bed nodes a swimming bot can route out from.
	var water_aabbs: Array = []
	for a in _main.find_children("*", "Area3D", true, false):
		var ar := a as Area3D
		if (ar.collision_layer & GameConsts.MASK_WATER) == 0:
			continue
		var aabb := AABB()
		for cs in ar.find_children("*", "CollisionShape3D", true, false):
			var sh := (cs as CollisionShape3D).shape
			if sh == null:
				continue
			var b: AABB = (cs as CollisionShape3D).global_transform * sh.get_debug_mesh().get_aabb()
			aabb = aabb.merge(b) if aabb.size != Vector3.ZERO else b
		if aabb.size != Vector3.ZERO:
			water_aabbs.append(aabb)
	Log.info("[Bake] %s: %d water volume(s) found for pool seeding" % [_map, water_aabbs.size()])

	var space := _main.get_world_3d().direct_space_state
	var t0 := Time.get_ticks_msec()
	var baker := WaypointBaker.new()
	var graph := baker.bake(space, seeds, ladders, self, water_aabbs, lifts)
	if graph == null:
		push_error("[Bake] %s: no walkable nodes produced (bad seeds/collision?)" % _map)
		get_tree().quit(1)
		return

	var out_path := ProjectSettings.globalize_path("res://maps/waypoints/%s.gen_wpt" % _map)
	var err := graph.save_generated(out_path)
	if err != OK:
		push_error("[Bake] %s: failed to write %s (%s)" % [_map, out_path, error_string(err)])
		get_tree().quit(1)
		return
	Log.info("[Bake] %s: %d nodes, %d edges in %d ms -> %s" % [
		_map, graph.positions.size(), graph._edges.size(),
		Time.get_ticks_msec() - t0, out_path])

	# Connectivity sanity, two views: undirected components show whether the geometry sampled into
	# one connected mass; directed spawn→spawn reachability is what bots actually get (one-way drops
	# legitimately connect A→B without B→A).
	var comps: Dictionary = graph.component_sizes()
	var biggest := 0
	for c in comps.values():
		biggest = maxi(biggest, c)
	var directed := 0
	var ordered := 0
	for i in seeds.size():
		for j in seeds.size():
			if i == j:
				continue
			ordered += 1
			if not graph.path_ids(seeds[i], seeds[j]).is_empty():
				directed += 1
	Log.info("[Bake] %s: %d components (largest holds %d/%d nodes); %d/%d ordered spawn routes" % [
		_map, comps.size(), biggest, graph.positions.size(), directed, ordered])

	_diag_objective_coverage(graph)
	_diag_column_probe(space, graph)
	_diag_hull_audit(space, graph)
	_diag_span(graph)
	_diag_component_boxes(graph)
	_diag_stall_probe(space, graph)

	if not OS.get_environment("WW_BAKE_DIAG").is_empty():
		_diag_components(graph, seeds)
		_diag_islands(graph, space, seeds)
		if graph.positions.size() <= 6000:  # _diag_gap is O(n²) — skip on large graphs
			_diag_gap(graph, space)
		# Water-escape check: every submerged node should be able to DIRECTEDLY reach a dry spawn —
		# the water-exit links actually let a fallen bot path back out, not just drop in.
		var wq := PhysicsPointQueryParameters3D.new()
		wq.collision_mask = GameConsts.MASK_WATER
		wq.collide_with_areas = true
		wq.collide_with_bodies = false
		var submerged_ids: PackedInt32Array = PackedInt32Array()
		for i in graph.positions.size():
			wq.position = graph.positions[i]
			if not space.intersect_point(wq, 1).is_empty():
				submerged_ids.append(i)
		# Reachability A* is O(nodes) each; sample at a stride so a huge lake can't blow the bake time.
		@warning_ignore("integer_division")
		var stride: int = maxi(1, submerged_ids.size() / 400)
		var tested := 0
		var escape := 0
		var k := 0
		while k < submerged_ids.size():
			tested += 1
			for s in seeds:  # reachable to ANY spawn, since some maps perch a lone spawn on an island
				if not graph.path_ids(graph.positions[submerged_ids[k]], s).is_empty():
					escape += 1
					break
			k += stride
		Log.info("[Bake] %s: WATER-ESCAPE %d/%d sampled submerged nodes reach a spawn (%d submerged total)" % [
			_map, escape, tested, submerged_ids.size()])

	# Optional top-down QA render (WW_BAKE_PNG=<dir>): nodes coloured by connected component,
	# spawns marked, so a human can eyeball coverage/fragmentation at a glance.
	var png_dir := OS.get_environment("WW_BAKE_PNG")
	if not png_dir.is_empty():
		_dump_waypoint_png(graph, seeds, "%s/%s.png" % [png_dir, _map])
	get_tree().quit(0)


## The movers the bake deletes before sampling: approach-doors, the barriers a player would walk
## up to and have swing aside, which at their shut t=0 pose wall off regions that are reachable in
## play. Lifts and drawbridges are NOT among them — their brush is the floor (see _is_bake_barrier).
##
## run() hides these; the two nav tools reuse this so a measurement is taken on the map the bake
## saw (tools/probe_handedges.gd hides them too, tools/navmesh_spike.gd drops their meshes). It is
## one walk rather than three copies of the class list, so a rule added here reaches all of them.
##
## WW_DOOR_AUDIT=1 prints one line per door with both verdicts behind the decision.
func barrier_movers() -> Array[Node3D]:
	var out: Array[Node3D] = []
	var lift_nodes := {}
	for L in _lift_entities():
		lift_nodes[L.node] = true
	for cls in ["FuncDoor", "FuncDoorRotating"]:
		for b in _main.find_children("*", cls, true, false):
			if OS.has_environment("WW_DOOR_AUDIT"):
				var ab := _node_world_aabb(b)
				Log.info("[DoorAudit] %s %s state=%s AT_TOP=%s deck=%s size=%.1fx%.1fx%.1f" % [
					_map, b.name, str(b.state),
					str(b.state == FuncDoorBase.State.AT_TOP), str(_is_deck(b)),
					ab.size.x, ab.size.y, ab.size.z])
			if _is_bake_barrier(b, lift_nodes):
				out.append(b)
	return out


## Is this mover a barrier the bake should delete, standing in for it swinging out of the way?
##
## Four reasons it might not be, and they ask different questions. Whether the MAP put it in this
## pose is not the same question as whether the brush is a floor at all, and audited across all 77
## doors on the 12 maps that have any, the state test is currently redundant — every door it spares
## (ww_monoliths' four gates) is a deck as well. It stays as the backstop for what the shape test
## rejects on purpose: a drawbridge narrower than LIFT_MIN_DECK, which no shipped map has. If you
## are chasing a route a map lost, `_is_deck` is the term doing the work. WW_DOOR_AUDIT prints both.
func _is_bake_barrier(b: Node3D, lift_nodes: Dictionary) -> bool:
	if b is FuncBreakable:
		return false   # golem-only barrier — leave solid so the graph goes around it
	if lift_nodes.has(b):
		return false   # a deck, not a barrier — _link_lifts bridges its two stops
	if b.state == FuncDoorBase.State.AT_TOP:
		return false   # the map opened it itself — that pose IS the play-time geometry
	# ww_roc2's drawbridges start DOWN and stay there — lying flat is their CLOSED pose — so the
	# state test never sees them, and deleting them took the walkway out from under the only route
	# to the upper level, and with it both capture plates.
	if _is_deck(b):
		Log.info("[Bake] %s: %s is a deck, not a door — left in place" % [_map, b.name])
		return false
	return true


## Lifts the waypoint baker can bridge (see WaypointBaker._link_lifts). A lift is a brush mover
## whose travel is vertical, whose deck is a floor rather than a barrier, and that a bot can summon
## by standing on it — which is what makes the ride something the brain can actually perform.
##
## func_plat / func_platrot always qualify: both build a call volume a rider is inside, so touching
## the deck at either stop sends it to the other one. A func_door only qualifies when it has a touch
## area, because nothing a bot does will move a trigger-only one (ww_2fort's blue_lift) — and an
## edge the mover cannot perform is worse than no edge, since the prune keeps whatever hangs off it.
const LIFT_MIN_TRAVEL := 1.5   # below this the deck is a step, and the fill already walks it
const LIFT_MIN_DECK := 1.0     # a deck narrower than this is not a floor to stand and ride on


## True when a mover's brush is a floor you stand ON rather than a barrier you pass THROUGH: broad
## in both horizontal axes, thinner than it is wide, and with a walkable top face. A drawbridge deck
## and a lift deck both answer yes; a portcullis — just as wide, but taller than it is deep — does not.
func _is_deck(d: Node3D) -> bool:
	var aabb := _node_world_aabb(d)
	if aabb.size.x < LIFT_MIN_DECK or aabb.size.z < LIFT_MIN_DECK:
		return false
	if aabb.size.y >= minf(aabb.size.x, aabb.size.z):
		return false
	var c := aabb.get_center()
	var q := PhysicsRayQueryParameters3D.new()
	q.collision_mask = GameConsts.MASK_WORLD_AND_CLIP | GameConsts.MASK_ENTITY
	q.from = Vector3(c.x, aabb.end.y + 0.3, c.z)
	q.to = Vector3(c.x, aabb.end.y - 0.3, c.z)
	var hit := _main.get_world_3d().direct_space_state.intersect_ray(q)
	return not hit.is_empty() and float((hit.normal as Vector3).y) >= 0.7


func _lift_entities() -> Array:
	var out: Array = []
	for m in _main.find_children("*", "FuncDoorBase", true, false):
		var d := m as FuncDoorBase
		var is_plat: bool = d is FuncPlat or d is FuncPlatRot
		if not is_plat:
			if not (d is FuncDoor) or d._touch_area == null:
				continue
		# Which stop it is resting at, and how far the other one is. The subclass has already
		# placed the node at its start pose, so the offset it holds names the stop it is at.
		var rest: Vector3 = d.position - d._base_position
		var far: Vector3 = d.position2 if rest.is_equal_approx(d.position1) else d.position1
		var travel: Vector3 = far - rest
		if absf(travel.y) < LIFT_MIN_TRAVEL or Vector2(travel.x, travel.z).length() > 0.2:
			continue
		# The brush has to be a floor. A tall thin barrier that happens to slide upward is not a
		# lift however far it travels, and a bot sent to stand on one stands in a wall.
		if not _is_deck(d):
			continue
		out.append({node = d, deck = _node_world_aabb(d), travel = travel.y, name = String(d.name)})
	return out


## Warn when an objective has no waypoint near it. The baker prunes nodes bots can't reach or can't
## get back out of, which is what stops them routing into traps — but it is also the one pass that
## can DELETE coverage, and a flag or capture point left with no node beside it is a map where the
## bots quietly never play the objective. Distance only: if a goal has a node within a couple of
## metres the graph reaches it.
func _diag_objective_coverage(graph) -> void:
	var goals := _goal_entities()
	if goals.is_empty():
		return
	var stranded := 0
	var worst: Array = []
	for g in goals:
		var gp := _goal_world_position(g)
		var best := INF
		for p in graph.positions:
			best = minf(best, gp.distance_squared_to(p))
		best = sqrt(best)
		if best <= 3.0:
			continue
		stranded += 1
		worst.append([best, g.name, gp])
		# Only a PICKUP this far out is worth shouting about. Half of a TF map's goal entities are
		# logic — timers, respawn bookkeeping — and some are parked far under the floor, so warning
		# on those trains you to ignore the warning.
		if g is ItemTFGoal and best > 8.0:
			push_warning("[Bake] %s: pickup %s at %s is %.1fm from the nearest waypoint" % [
				_map, g.name, gp, best])
	worst.sort_custom(func(l, r): return l[0] > r[0])
	var tail := ""
	for k in mini(4, worst.size()):
		tail += " %s(%.0fm)" % [worst[k][1], worst[k][0]]
	Log.info("[Bake] %s: objective coverage %d/%d goal entities within 3m of a waypoint;%s" % [
		_map, goals.size() - stranded, goals.size(),
		" furthest:" + tail if not tail.is_empty() else " all covered"])


## WW_PROBE="x0,z0,x1,z1[,step]" — vertical profile of every column in that XZ box, one line each:
## the height of every standable floor down the column, tagged /NOFIT when the player hull does not
## fit there and /NONODE when the baked graph has nothing near it.
##
## This answers the question component counts cannot: a level missing from a bake is either geometry
## the sampler never reached (nothing reported), a surface it found but could not stand on (/NOFIT),
## or one it sampled and the prune discarded (/NONODE, cross-check _diag_dropped). It is how
## ww_2fort's flag basements were pinned down — walkable floors at y -14.1 and -17.3 with nothing
## between them and the ramp above, so no adjacent-cell edge can ever reach them.
func _diag_column_probe(space: PhysicsDirectSpaceState3D, graph) -> void:
	var spec := OS.get_environment("WW_PROBE")
	if spec.is_empty():
		return
	var f := spec.split(",")
	if f.size() < 4:
		return
	var x0 := float(f[0])
	var z0 := float(f[1])
	var x1 := float(f[2])
	var z1 := float(f[3])
	var step := float(f[4]) if f.size() > 4 else 2.0
	var ray := PhysicsRayQueryParameters3D.new()
	ray.collision_mask = GameConsts.MASK_WORLD_AND_CLIP | GameConsts.MASK_ENTITY
	var cap := CapsuleShape3D.new()
	cap.radius = 0.3
	cap.height = 1.8
	var sq := PhysicsShapeQueryParameters3D.new()
	sq.shape = cap
	sq.collision_mask = ray.collision_mask
	sq.margin = 0.02
	var z := z0
	while z <= z1:
		var x := x0
		while x <= x1:
			var out := "[Probe] (%.0f,%.0f)" % [x, z]
			var y := 40.0
			var guard := 0
			while y > -40.0 and guard < 60:
				guard += 1
				ray.from = Vector3(x, y, z)
				ray.to = Vector3(x, -40.0, z)
				var r := space.intersect_ray(ray)
				if r.is_empty():
					break
				var hit: Vector3 = r.position
				var nrm: Vector3 = r.normal
				if nrm.y >= 0.7:
					sq.transform = Transform3D(Basis.IDENTITY, hit + Vector3(0, 0.9 + 0.05, 0))
					var fits := space.intersect_shape(sq, 1).is_empty()
					var near := INF
					for p in graph.positions:
						near = minf(near, Vector2(p.x - x, p.z - z).length_squared()
							+ (p.y - hit.y) * (p.y - hit.y) * 4.0)
					out += "  y%.1f%s%s" % [hit.y, "" if fits else "/NOFIT",
						"" if sqrt(near) < 1.5 else "/NONODE"]
				y = hit.y - 0.1
			if out.length() > 20:
				Log.info(out)
			x += step
		z += step



## WW_HULL_AUDIT=1 — measure the real player hull against the baked graph.
##
## The placement probe bakes with a 0.3 capsule while the player is 0.4 (see WaypointBaker's
## HULL_RADIUS), so some baked nodes sit where only the slim probe fits. Moving the constant to 0.4
## was measured and navigates better, but `_hull_fits` can only ACCEPT or REJECT, and a rejected
## column produces no node at all — which is why the change deleted whole routes rather than
## improving them. This counts the three populations that decides between:
##   FITS    the 0.4 hull already stands there; nothing would change
##   PUSH    it does not, but a depenetration push of under PUSH_MAX finds standable floor nearby —
##           a node that would MOVE a few cm, not vanish
##   CRACK   nothing within PUSH_MAX fits: a genuine crack the bake should never have used
## If PUSH dominates REJECT, resolving the position beats flipping the constant.
func _diag_hull_audit(space: PhysicsDirectSpaceState3D, graph) -> void:
	if OS.get_environment("WW_HULL_AUDIT").is_empty():
		return
	const R := 0.4                # the real player radius (player.tscn)
	const STAND := 1.8
	const STEP := 0.45
	const ITERS := 12             # hop reports ONE contact per collider, so a corner needs a few
	const EPS := 0.005            # push a hair past flush, or the next query re-reports depth 0
	const PUSH_MAX := 0.45        # what _resolve_stand actually allows
	const PUSH_FAR := 1.5         # diagnostic headroom: separates "no room at all" from "needed
								  # more room than the baker allows", which the counts alone conflate
	const FLUSH := 0.01           # resting against a wall is not penetrating it
	var mask := GameConsts.MASK_WORLD_AND_CLIP | GameConsts.MASK_ENTITY
	var cap := CapsuleShape3D.new()
	cap.radius = R
	cap.height = STAND
	var sq := PhysicsShapeQueryParameters3D.new()
	sq.shape = cap
	sq.collision_mask = mask
	sq.margin = 0.0
	var ray := PhysicsRayQueryParameters3D.new()
	ray.collision_mask = mask

	var fits := 0
	var pushed := 0
	var far := 0                  # fits, but further than the baker would move it
	var hard := 0                 # nothing fits within PUSH_FAR — a real crack
	var far_sum := 0.0
	var far_bb := [Vector3.INF, -Vector3.INF]
	var hard_bb := [Vector3.INF, -Vector3.INF]
	var no_floor := 0
	var push_sum := 0.0
	var push_max := 0.0
	var t0 := Time.get_ticks_msec()
	for i in graph.positions.size():
		var p0: Vector3 = graph.positions[i]
		var d0 := _hull_depth(space, sq, p0, STAND)
		if d0[0] <= FLUSH:
			fits += 1
			continue
		# Resolve: step out along the deepest contact, re-query, repeat. Converges into a standable
		# band when one exists and oscillates when the gap is narrower than the body.
		var p := p0
		var ok := false
		for _k in ITERS:
			var d := _hull_depth(space, sq, p, STAND)
			if d[0] <= FLUSH:
				ok = true
				break
			var sep: Vector3 = d[1]
			p += sep + sep.normalized() * EPS
			if p.distance_to(p0) > PUSH_FAR:
				break
		var moved := p.distance_to(p0)
		if not ok:
			hard += 1
			_bbox_add(hard_bb, p0)
			continue
		if moved > PUSH_MAX:
			far += 1
			far_sum += moved
			_bbox_add(far_bb, p0)
			continue
		# A spot the hull fits is only a waypoint if there is floor under it at the same level.
		ray.from = p + Vector3(0, STEP, 0)
		ray.to = p - Vector3(0, STEP + 0.5, 0)
		var r := space.intersect_ray(ray)
		if r.is_empty() or float(r.normal.y) < 0.7:
			no_floor += 1
			continue
		pushed += 1
		push_sum += moved
		push_max = maxf(push_max, moved)
	var n: int = graph.positions.size()
	Log.info("[HullAudit] %s: %d nodes in %d ms — FITS %d (%.1f%%), PUSH %d (%.1f%%, mean %.3fm max %.3fm), NOFLOOR %d, FAR %d (mean %.2fm, %s), HARD %d (%.1f%%, %s)" % [
		_map, n, Time.get_ticks_msec() - t0,
		fits, 100.0 * fits / maxi(1, n),
		pushed, 100.0 * pushed / maxi(1, n), push_sum / maxf(1.0, float(pushed)), push_max,
		no_floor,
		far, far_sum / maxf(1.0, float(far)), _bbox_str(far_bb),
		hard, 100.0 * hard / maxi(1, n), _bbox_str(hard_bb)])


func _bbox_add(bb: Array, p: Vector3) -> void:
	bb[0] = Vector3(minf(bb[0].x, p.x), minf(bb[0].y, p.y), minf(bb[0].z, p.z))
	bb[1] = Vector3(maxf(bb[1].x, p.x), maxf(bb[1].y, p.y), maxf(bb[1].z, p.z))


func _bbox_str(bb: Array) -> String:
	if bb[0] == Vector3.INF:
		return "none"
	var lo: Vector3 = bb[0]
	var hi: Vector3 = bb[1]
	return "x[%.0f,%.0f] y[%.1f,%.1f] z[%.0f,%.0f]" % [lo.x, hi.x, lo.y, hi.y, lo.z, hi.z]


## Deepest penetration of a STAND-tall capsule standing at `floor_pos`, as [depth, separation].
## `separation` is the vector that pushes the hull back out of that contact: hop's collide_shape
## reports the pair (point on the query hull, that point pushed out along the contact normal by the
## penetration depth), so the difference IS the depenetration vector.
func _hull_depth(space: PhysicsDirectSpaceState3D, sq: PhysicsShapeQueryParameters3D,
		floor_pos: Vector3, stand: float) -> Array:
	sq.transform = Transform3D(Basis.IDENTITY, floor_pos + Vector3(0, stand * 0.5 + 0.03, 0))
	var pairs := space.collide_shape(sq, 8)
	var best := 0.0
	var sep := Vector3.ZERO
	var k := 0
	while k + 1 < pairs.size():
		var v: Vector3 = pairs[k + 1] - pairs[k]
		if v.length() > best:
			best = v.length()
			sep = v
		k += 2
	return [best, sep]

## WW_BAKE_SPAN="x0,y0,z0,x1,y1,z1" — how much graph lives inside that box, and how much of it
## reaches the rest of the map. A component split says the graph fell in two; it does not say WHERE
## the connection used to run. Pointing this at the structure that is supposed to join them (a
## bridge, a tunnel) answers that directly: nodes inside, edges wholly inside, and edges with one
## end inside and one end out — the last being the number that matters, since that is the crossing.
func _diag_span(graph) -> void:
	var spec := OS.get_environment("WW_BAKE_SPAN")
	if spec.is_empty():
		return
	var f := spec.split(",")
	if f.size() < 6:
		return
	var box := AABB(Vector3(float(f[0]), float(f[1]), float(f[2])), Vector3.ZERO)
	box = box.expand(Vector3(float(f[3]), float(f[4]), float(f[5])))
	var inside := PackedByteArray()
	inside.resize(graph.positions.size())
	var n_in := 0
	for i in graph.positions.size():
		var hit := 1 if box.has_point(graph.positions[i]) else 0
		inside[i] = hit
		n_in += hit
	var e_in := 0
	var e_cross := 0
	for e: Vector2i in graph._edges:
		var a := int(inside[e.x])
		var b := int(inside[e.y])
		if a == 1 and b == 1:
			e_in += 1
		elif a != b:
			e_cross += 1
	Log.info("[Span] %s %s: %d node(s) inside, %d edge(s) inside, %d edge(s) crossing the boundary" % [
		_map, spec, n_in, e_in, e_cross])
	# The positions themselves, so a follow-up probe can aim at the real nodes instead of a region
	# guessed from the map's description.
	var shown := 0
	for i in graph.positions.size():
		if inside[i] == 1 and shown < 24:
			shown += 1
			Log.info("[Span]   node %d at %v" % [i, graph.positions[i]])

## Every connected component with its size and bounding box, biggest first (WW_BAKE_DIAG).
##
## "3 components (largest holds 7309/14309)" says the graph fell apart; it does not say along what.
## The boxes do: two halves split by a chasm read as two boxes meeting at a plane, while a stranded
## ledge reads as a small box floating at its own height. Guessing the region by hand and probing it
## is how you end up measuring the wrong place.
func _diag_component_boxes(graph) -> void:
	var parent_of: Dictionary = graph.node_component_map()
	var boxes := {}
	var counts := {}
	for i in graph.positions.size():
		var root = parent_of.get(i, i)
		var p: Vector3 = graph.positions[i]
		counts[root] = int(counts.get(root, 0)) + 1
		if not boxes.has(root):
			boxes[root] = [p, p]
		else:
			var bb: Array = boxes[root]
			bb[0] = Vector3(minf(bb[0].x, p.x), minf(bb[0].y, p.y), minf(bb[0].z, p.z))
			bb[1] = Vector3(maxf(bb[1].x, p.x), maxf(bb[1].y, p.y), maxf(bb[1].z, p.z))
	var order: Array = counts.keys()
	order.sort_custom(func(l, r): return int(counts[l]) > int(counts[r]))
	for k in order.slice(0, 6):
		var bb: Array = boxes[k]
		var lo: Vector3 = bb[0]
		var hi: Vector3 = bb[1]
		Log.info("[Comp] %s: %6d node(s)  x[%.0f,%.0f] y[%.1f,%.1f] z[%.0f,%.0f]" % [
			_map, int(counts[k]), lo.x, hi.x, lo.y, hi.y, lo.z, hi.z])

## WW_STALL_PROBE="x,y,z" — everything about one spot a bot got stuck in: the floors down its
## column, which way a REAL hull can actually leave it (at the feet and after a step-up), and the
## waypoints around it with their edges.
##
## A stuck bot is one of three things and they need different fixes: it is walled in (no direction
## clears), it is on a waypoint it cannot leave (node here, no usable edge out), or it is being
## sent somewhere it cannot go (edges exist, the mover cannot follow them). Reporting all three
## together is what tells them apart.
func _diag_stall_probe(space: PhysicsDirectSpaceState3D, graph) -> void:
	var spec := OS.get_environment("WW_STALL_PROBE")
	if spec.is_empty():
		return
	var f := spec.split(",")
	if f.size() < 3:
		return
	var at := Vector3(float(f[0]), float(f[1]), float(f[2]))
	var mask := GameConsts.MASK_WORLD_AND_CLIP | GameConsts.MASK_ENTITY
	Log.info("[Stall] ==== %s at %v ====" % [_map, at])

	var ray := PhysicsRayQueryParameters3D.new()
	ray.collision_mask = mask
	var y := at.y + 5.0
	var line := ""
	for _i in 12:
		ray.from = Vector3(at.x, y, at.z)
		ray.to = Vector3(at.x, at.y - 12.0, at.z)
		var r := space.intersect_ray(ray)
		if r.is_empty():
			break
		line += " y%.2f(n%.2f)" % [float(r.position.y), float(r.normal.y)]
		y = float(r.position.y) - 0.05
	Log.info("[Stall] floors down the column:%s" % line)

	# Water or dry? A bot pinned in a flooded shaft needs a swim/water-exit link; one pinned in a
	# dry hole needs the hole not to be walked into. Same symptom, opposite fix.
	var wp := PhysicsPointQueryParameters3D.new()
	wp.collision_mask = GameConsts.MASK_WATER
	wp.collide_with_areas = true
	wp.collide_with_bodies = false
	var wet := ""
	for dy in [0.0, 0.5, 1.0, 2.0, 3.0]:
		wp.position = at + Vector3(0, dy, 0)
		wet += " +%.1f:%s" % [dy, "WATER" if not space.intersect_point(wp, 1).is_empty() else "dry"]
	Log.info("[Stall] water column:%s" % wet)

	# Which way can a REAL 0.4 hull leave, at the feet and after a step up?
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.8
	var sq := PhysicsShapeQueryParameters3D.new()
	sq.shape = cap
	sq.collision_mask = mask
	sq.margin = 0.0
	for lift in [0.05, 0.55]:
		var open := ""
		for a in 8:
			var ang := a * TAU / 8.0
			var dir := Vector3(cos(ang), 0, sin(ang))
			sq.transform = Transform3D(Basis.IDENTITY, at + Vector3(0, 0.9 + lift, 0))
			sq.motion = dir * 1.5
			var res := space.cast_motion(sq)
			var frac: float = res[0] if res.size() == 2 else 0.0
			open += " %3d:%.2f" % [int(round(rad_to_deg(ang))), frac]
		Log.info("[Stall] hull sweep +%.2fm:%s" % [lift, open])

	# The graph around it: what is here, and where can it go from here?
	var near: Array = []
	for i in graph.positions.size():
		var d: float = at.distance_to(graph.positions[i])
		if d < 4.0:
			near.append([d, i])
	near.sort_custom(func(l, r): return l[0] < r[0])
	Log.info("[Stall] %d waypoint(s) within 4m" % near.size())
	for k in mini(5, near.size()):
		var id: int = near[k][1]
		var outn := 0
		var inn := 0
		for e: Vector2i in graph._edges:
			if e.x == id:
				outn += 1
			elif e.y == id:
				inn += 1
		Log.info("[Stall]   node %d at %v  %.2fm away  out=%d in=%d" % [
			id, graph.positions[id], float(near[k][0]), outn, inn])

## The map's objective entities — flags, capture points and their markers.
func _goal_entities() -> Array[Node]:
	var goals: Array[Node] = []
	for cls in ["ItemTFGoal", "InfoTFGoal"]:
		goals.append_array(_main.find_children("*", cls, true, false))
	return goals


## Where an objective actually IS. Brush-based goals sit at the origin with their geometry off in
## the map (see the ORIGIN-key note on the importer), so the node position alone points at (0,0,0);
## the world AABB is the truth wherever there is one.
func _goal_world_position(g: Node) -> Vector3:
	var aabb := _node_world_aabb(g as Node3D)
	return aabb.get_center() if aabb.size != Vector3.ZERO else (g as Node3D).global_position


## Top-down PNG of a baked graph for eyeballing: each node a dot coloured by its undirected
## component (so disconnected islands are obvious), spawns drawn as white crosses.
func _dump_waypoint_png(graph, seeds: Array, path: String) -> void:
	var comps: Dictionary = graph.component_sizes()
	var parent_of: Dictionary = graph.node_component_map()  # node id -> component root
	# World bounds (X/Z) from the nodes.
	var mn := Vector2(INF, INF)
	var mx := Vector2(-INF, -INF)
	for p in graph.positions:
		mn.x = minf(mn.x, p.x); mn.y = minf(mn.y, p.z)
		mx.x = maxf(mx.x, p.x); mx.y = maxf(mx.y, p.z)
	var span := mx - mn
	var size := 1200.0
	var px_scale: float = (size - 40.0) / maxf(maxf(span.x, span.y), 1.0)
	var w := int(span.x * px_scale) + 40
	var h := int(span.y * px_scale) + 40
	var img := Image.create(maxi(w, 64), maxi(h, 64), false, Image.FORMAT_RGBA8)
	img.fill(Color(0.08, 0.08, 0.1, 1.0))
	# Stable colour per component root.
	var col := {}
	for root in comps:
		col[root] = Color.from_hsv(fmod(float(hash(root) & 0xFFFF) / 65535.0, 1.0), 0.7, 1.0)
	var to_px := func(p: Vector3) -> Vector2i:
		return Vector2i(int((p.x - mn.x) * px_scale) + 20, int((p.z - mn.y) * px_scale) + 20)
	for i in graph.positions.size():
		var px: Vector2i = to_px.call(graph.positions[i])
		var c: Color = col.get(parent_of.get(i, -1), Color.GRAY)
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				var x := px.x + dx; var y := px.y + dy
				if x >= 0 and x < img.get_width() and y >= 0 and y < img.get_height():
					img.set_pixel(x, y, c)
	for s in seeds:
		var px: Vector2i = to_px.call(s as Vector3)
		for d in range(-4, 5):
			for pt in [Vector2i(px.x + d, px.y), Vector2i(px.x, px.y + d)]:
				if pt.x >= 0 and pt.x < img.get_width() and pt.y >= 0 and pt.y < img.get_height():
					img.set_pixel(pt.x, pt.y, Color.WHITE)
	img.save_png(path)
	Log.info("[Bake] wrote QA render %s (%dx%d)" % [path, img.get_width(), img.get_height()])


## World-space AABB of a node's geometry, used to size func_ladder footprints for the waypoint
## bake. Prefers render meshes but falls back to collision shapes — many ladder brushes carry only
## a Volume collision area (no render face), so a mesh-only AABB would miss them. Empty if neither.
func _node_world_aabb(node: Node3D) -> AABB:
	var out := AABB()
	var have := false
	for m in node.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		if mi.mesh == null:
			continue
		var world := mi.global_transform * mi.mesh.get_aabb()
		out = world if not have else out.merge(world)
		have = true
	if have:
		return out
	for c in node.find_children("*", "CollisionShape3D", true, false):
		var cs := c as CollisionShape3D
		if cs.shape == null:
			continue
		var world := cs.global_transform * cs.shape.get_debug_mesh().get_aabb()
		out = world if not have else out.merge(world)
		have = true
	return out


## Diagnostic: per-component size + height range + XZ centre, and which component each spawn lands
## in — reveals whether fragments are raised platforms, isolated ledges, etc.
func _diag_components(graph, seeds: Array) -> void:
	var pmap: Dictionary = graph.node_component_map()
	var info := {}  # root -> [count, ymin, ymax, xsum, zsum]
	for i in graph.positions.size():
		if not pmap.has(i):
			continue  # tombstoned hand-file waypoint
		var r: int = pmap[i]
		var p: Vector3 = graph.positions[i]
		var e = info.get(r, [0, INF, -INF, 0.0, 0.0])
		info[r] = [e[0] + 1, minf(e[1], p.y), maxf(e[2], p.y), e[3] + p.x, e[4] + p.z]
	var roots := info.keys()
	roots.sort_custom(func(a, b): return info[a][0] > info[b][0])
	for r in roots:
		var e = info[r]
		if e[0] < 15:
			continue
		Log.info("[Diag] comp %d: %d nodes, y %.1f..%.1f, xz~(%.0f,%.0f)" % [
			r, e[0], e[1], e[2], e[3] / e[0], e[4] / e[0]])
	for si in seeds.size():
		var nn: int = graph._astar.get_closest_point(seeds[si])
		Log.info("[Diag] spawn %d y=%.1f -> comp %d" % [si, (seeds[si] as Vector3).y, pmap.get(nn, -1)])


## Diagnostic: for each SPAWN-bearing component that isn't the biggest (a stranded spawn — the
## real bot problem), report its closest node to the main component and the gap geometry, so we can
## tell whether it's a jump-gap, a too-tall ledge, or a one-way drop that isolates it.
func _diag_islands(graph, _space: PhysicsDirectSpaceState3D, seeds: Array) -> void:
	var pmap: Dictionary = graph.node_component_map()
	var comps: Dictionary = graph.component_sizes()
	var big := -1
	for r in comps:
		if big < 0 or comps[r] > comps[big]:
			big = r
	# Components that hold at least one spawn but aren't the main mass.
	var stranded := {}
	for s in seeds:
		var c: int = pmap[graph._astar.get_closest_point(s)]
		if c != big:
			stranded[c] = true
	for isl in stranded:
		var ba := -1
		var bb := -1
		var bd := INF
		for i in graph.positions.size():
			if not pmap.has(i) or pmap[i] != isl:
				continue
			for j in graph.positions.size():
				if not pmap.has(j) or pmap[j] != big:
					continue
				var d: float = graph.positions[i].distance_squared_to(graph.positions[j])
				if d < bd:
					bd = d; ba = i; bb = j
		if ba < 0:
			continue
		var pa: Vector3 = graph.positions[ba]
		var pbig: Vector3 = graph.positions[bb]
		var horiz := Vector2(pa.x - pbig.x, pa.z - pbig.z).length()
		Log.info("[Diag] stranded comp %d (%d nodes): nearest main node %.1fm away, dy=%.1f (island y%.1f, main y%.1f)" % [
			isl, comps[isl], horiz, pa.y - pbig.y, pa.y, pbig.y])


## Diagnostic: find the closest pair of nodes in two DIFFERENT components, then sample the floor
## straight between them, so we can see whether the fill skipped a walkable path (floor present the
## whole way) or the regions are genuinely split by a void/wall.
func _diag_gap(graph, space: PhysicsDirectSpaceState3D) -> void:
	var pmap: Dictionary = graph.node_component_map()
	# Largest component root.
	var comps: Dictionary = graph.component_sizes()
	var big := -1
	for r in comps:
		if big < 0 or comps[r] > comps[big]:
			big = r
	# Closest big-vs-other node pair.
	var ba := -1
	var bb := -1
	var bd := INF
	for i in graph.positions.size():
		if not pmap.has(i) or pmap[i] != big:
			continue
		for j in graph.positions.size():
			if not pmap.has(j) or pmap[j] == big:
				continue
			var d: float = graph.positions[i].distance_squared_to(graph.positions[j])
			if d < bd:
				bd = d; ba = i; bb = j
	if ba < 0:
		Log.info("[Diag] no inter-component pair"); return
	var pa: Vector3 = graph.positions[ba]
	var pb: Vector3 = graph.positions[bb]
	Log.info("[Diag] closest gap %.1fm: A=%v (big) B=%v (other comp)" % [sqrt(bd), pa, pb])
	var ray := PhysicsRayQueryParameters3D.new()
	ray.collision_mask = GameConsts.MASK_WORLD_AND_CLIP | GameConsts.MASK_ENTITY
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.8
	var sq := PhysicsShapeQueryParameters3D.new()
	sq.shape = cap
	sq.collision_mask = GameConsts.MASK_WORLD_AND_CLIP | GameConsts.MASK_ENTITY
	var n := 12
	var profile := ""
	for k in range(n + 1):
		var t := float(k) / n
		var p := pa.lerp(pb, t)
		ray.from = p + Vector3(0, 3, 0)
		ray.to = p + Vector3(0, -12, 0)
		var res := space.intersect_ray(ray)
		if res.is_empty():
			profile += " [void]"
		else:
			var fy: float = (res.position as Vector3).y
			sq.transform = Transform3D(Basis.IDENTITY, Vector3(p.x, fy + 0.93, p.z))
			var fits := space.intersect_shape(sq, 1).is_empty()
			profile += " %.1f%s" % [fy, ("" if fits else "!BLOCKED")]
	Log.info("[Diag] floor+hull A→B:%s" % profile)