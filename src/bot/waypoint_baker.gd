extends RefCounted
## Offline waypoint-graph generator for maps that ship no hand-authored .HPB_wpt file.
##
## No class_name — see README, "class_name and preload". Use:
##   const WaypointBaker = preload("res://src/bot/waypoint_baker.gd")
##
## Samples the loaded map's collision world into the same node/edge graph WaypointGraph loads, so
## bots on un-waypointed maps get real A* pathing instead of the reactive whisker fallback (which
## traps them in spawn rooms). Walkability is defined by the actual player hull (standing capsule
## matching movement_config):
##   * flood-fill outward from the map's spawn points on a horizontal grid,
##   * a column is a node when a walkable floor is found and the standing hull fits there,
##   * an edge A→B exists when the hull sweeps clear from A to B; the height delta tags it
##     walk / FL_JUMP (step up) / drop (one-way down),
##   * the fill only advances ALONG those edges, and a final prune keeps just the nodes a bot can
##     both reach from a spawn and get back out of (see _prune_unusable).
## Run via waypoint_bake.gd (main.gd's --bake-waypoints headless mode); the result is serialized next to the
## hand files as maps/waypoints/<map>.gen_wpt and loaded by WaypointGraph.load_generated.

const WaypointGraph = preload("res://src/bot/waypoint_graph.gd")
const Movement = preload("res://addons/pmove/movement.gd")
const MovementConfig = preload("res://addons/pmove/movement_config.gd")
const InputCommand = preload("res://addons/pmove/input_command.gd")

# Player hull + locomotion limits (movement_config.gd / project default_gravity). The bake is
# only as faithful as these, so they mirror the real mover rather than being re-tuned here.
const HULL_RADIUS := 0.3         # PLACEMENT probe, deliberately under the real 0.4 player hull
								 # (player.tscn): intersect_shape counts any contact as blocked,
								 # while a real player rests against a wall happily. Moving it to
								 # a true 0.4 was measured and does navigate better, but it moves
								 # every node and so moves every route — on ww_ravine it pushed
								 # bots off the lower level onto the contested deck, where they
								 # died twice as often and captures fell from ~10 a match to 2.
								 # See TODO. What DOES belong at full size is the traversal test,
								 # and that is now the real mover rather than a fatter probe.
# Placement at the REAL hull (see _resolve_stand). The probe radius above decides whether a hull
# OVERLAPS somewhere; it cannot say where the hull would FIT, and the only answer _hull_fits can
# give a near-miss is to throw the column away. Measured on ww_ravine: of 482 baked nodes a true
# 0.4 hull cannot occupy, 481 have standable floor a mean 12cm off and exactly ONE is a real crack —
# so rejecting is wrong essentially every time, and resolving the position is the honest fix.
const REAL_RADIUS := 0.4         # the true player radius (player.tscn), matching the move-sim hull
const RESOLVE_ITERS := 8         # hop reports ONE contact per collider, so a corner needs a few
const RESOLVE_EPS := 0.005       # push a hair past flush, or the next query re-reports depth 0
const RESOLVE_MAX := 0.45        # past this the node is somewhere ELSE, not nudged — drop it
const RESOLVE_NUDGE := 0.15      # ...and how far the DEFAULT path will move one: far enough to get
								 # a hull out of the rail it is 9cm inside, near enough that the
								 # sampling lattice, and so every route, stays where it was
const RESOLVE_FLUSH := 0.01      # resting against a wall is not penetrating it
## Height of the hull dropped by _floor_cast. Finding the floor needs WIDTH — enough to pick a clip
## hull rather than the render faces, and enough that a zero-width brush seam cannot swallow it —
## but it must NOT need standing headroom: the column scan starts above the parent floor, and a
## full 1.8m probe begins its cast already inside any normal ceiling, so cast_motion stops at zero
## and the column reports no floor at all. That cost ww_ravine 90% of its nodes (7778 -> 732).
## Whether a STANDING body fits is a separate question, asked later by _stand_at.
const FLOOR_PROBE_HEIGHT := 0.9
const STAND_HEIGHT := 1.8        # movement_config.stand_height
const STEP_HEIGHT := 0.45        # movement_config.step_height — steppable lip, walk edge
const JUMP_UP := 1.2             # max climb considered for a FL_JUMP edge. A plain jump's apex is
								 # ~1.125m and a body hugging the ledge face slips over at the top of
								 # the arc, so the useful limit sits just past it. This is only the
								 # window: _edge_jump_sim decides, so aiming a little high costs a
								 # few rejected tests and catches the ledges a bot really can climb
# Distance linking (see _link_neighbours): nodes this close are tried as edges whatever cells they
# landed in. Just over a cell diagonal, so a phase-shifted neighbour is reached without inviting
# every node in the room.
const LINK_RADIUS := CELL * 1.6
# Seam stitching (see _stitch_seams): how far from a node the prune is about to drop we look for
# surviving floor to link it to. A grid-phase seam is under a cell wide; the slack covers regions
# seeded far off the spawn grid (water beds, ladder rings).
const STITCH_RADIUS := 3.0
const LATERAL_SLACK := 0.9       # how far off the straight a->b line the arc sim may drift and
								 # still count as having got there (see _edge_jump_sim)
const DROP_MAX := 8.0            # deepest one-way drop we'll link (survivable fall, no return edge)
# Reverse-climbable drops (see _link_jump_backs): a sweep for drop edges whose climb back up was
# never tried, because the edge was added after the grid fill ended.
const JUMP_BACK_UP := 1.2        # max rise (m) to link back up — same window as JUMP_UP, and the
								 # same arc sim settles it. Getting BACK up a ledge you walked off
								 # is what decides whether a map routes both ways at all
# Gap jumps (see _link_gap_jumps). The grid only ever links ADJACENT cells, so any crossing wider
# than a cell diagonal — a broken bridge, a ledge across a canyon — is invisible to it however
# easily a running player clears it, and the two sides bake as separate components.
const GAP_JUMP_MAX := 10.0       # absolute reach cap; the per-pair limit comes from _jump_reach
const GAP_JUMP_SIMS := 6000      # cap on arc tests, so a shattered graph can't blow up the bake
const WALK_NORMAL_Y := 0.7       # floor normal.y above this is standable (~45°, matches GoldSrc)

# Water-jump exits (see _link_water_exits). A submerged node links to a nearby bank within
# WATER_EXIT_RISE of the surface — the swim-up + movement layer's water-jump pops the bot out.
#
# That reach is not a taste knob: it follows from the swim, and both ways of leaving the water
# agree on it. A swimmer rises only while its waist sphere still overlaps the liquid (player.tscn's
# WaterDetector: centre 0.9, radius 0.1), so the highest the swim override can hold it is with its
# FEET 0.8m under the waterline, and from there it is ballistic. Climbing at 45 degrees — steep
# enough to rise, shallow enough to still carry onto the lip — LadderWater.water_velocity leaves the
# water at water_speed * (1 + sin 45) = 8.5 m/s, which against gravity 20 buys 1.8m of rise — so
# one metre of it clears the waterline. And PM_CheckWaterJump arrives at the same number from the
# other side, since its launch only fires while the lip is inside stand_height of those same feet:
# STAND_HEIGHT - SWIM_FEET_DEPTH. That second route is the one written down below, because it is
# exact — the ballistic one agrees only because WATERJUMP_UP was hand-set to 8.5, near enough to
# the 8.54 the swim emerges with, and it would drift if water_speed or gravity moved.
#
# It used to be 1.8, which is the LAUNCH's rise mistaken for the lip it can clear, and that put
# 294 climb-outs around ww_2fort's moat that no body can perform: the yard stands 1.60m over the
# water, a bot aimed at it tops out 1.05m up (measured), falls back, and re-tries for as long as
# anything keeps asking. All four 20s+ stuck episodes of a 600s six-bot match were bots doing
# exactly that, and 69% of every bounce-lock trip happened in that moat. With the honest reach the
# moat has no climb-out at all — which is true, and is what the map intends: its water is the
# route INTO the enemy base, and the exits at the far end of each channel are 0.27m lips.
## = 1.0m. Derived, not tuned: both terms are named at their source, so moving the hull or the
## submersion sphere moves this with them instead of silently reopening the bug below.
const WATER_EXIT_RISE := STAND_HEIGHT - Player.SWIM_FEET_DEPTH
const WATER_EXIT_BAND := 0.3    # lips within this of each other count as equally high, so the
								# tie-break between them is reach rather than a centimetre of rise
const WATER_EXIT_CELLS := 2     # horizontal search radius (in CELLs) from a submerged node to a bank

# Lifts (see _link_lifts). A deck you RIDE is not floor you walk, so a plat is bridged the way a
# ladder is: a synthetic node on the deck at each of its two stops, joined by an edge no geometric
# test is asked about, because at bake time the deck is only ever at one of them.
const LIFT_REACH := 1.8         # how far past the deck's footprint a landing may sit and still be
								# linked as a step on/off — a little over a stride, so the bot is
								# never sent at a shaft it has to jump a gap to reach
const LIFT_LAND_DROP := 1.0     # how far BELOW the deck a landing may sit and still be stepped to

# Sampling grid. CELL is the horizontal node spacing; smaller = denser graph + slower bake.
const CELL := 1.0                # small enough that a step on a steep stair rises < JUMP_UP
								 # between neighbours, so stairs link
const CLIMB_MAX := CELL * 1.5    # steepest rise a column may adopt from its parent — a 45 degree
								 # ramp across a cell diagonal, which _walkable_ramp calls a walk
const FLOOR_SCAN_UP := 1.2       # start floor rays this far above the parent node's height
const SEED_SCAN_DOWN := 256.0    # how far a SEED (not the fill) scans down for its floor — spawns
								 # can sit far above it (see _seed_floor)
# Per-cell offsets so a column centred in a wall/pillar still finds a standable spot nearby.
const NUDGE: Array[Vector2] = [
	Vector2(0, 0), Vector2(0.6, 0), Vector2(-0.6, 0), Vector2(0, 0.6), Vector2(0, -0.6)]
const MAX_NODES := 80000         # safety cap (a large map at CELL=1.0 is ~30k nodes)
const Y_BUCKET := 1.0            # column dedup granularity in Y (allows stacked floors per column)

const PROBE_MASK := GameConsts.MASK_WORLD_AND_CLIP | GameConsts.MASK_ENTITY

var _space: PhysicsDirectSpaceState3D
var _positions: PackedVector3Array = PackedVector3Array()
# Where each node was SAMPLED, as opposed to where its body ends up standing (`_positions`).
# The fill walks a lattice: each column is the parent's column plus a cell, so whatever the parent
# reports as its position sets the phase for everything downstream of it. Once placement resolves a
# node out of a wall, feeding the moved position back in drifts that lattice by up to RESOLVE_MAX
# per generation and the regular grid degenerates into a scatter — which silently misses features
# only one column wide (ww_roc2's north-south tunnel is a single file of nodes; the drifted grid
# stepped around it and split the map in half). Only used during the fill, so the prune need not
# remap it.
var _samples: PackedVector3Array = PackedVector3Array()
var _seed_sample := Vector3.INF   # _seed_floor's pre-resolve sample, for _samples
var _flags: PackedInt32Array = PackedInt32Array()
var _edges: Array[Vector2i] = []        # directed (from_id, to_id)
var _edge_set: Dictionary = {}          # Vector2i(from,to) -> true, dedups directed edges
var _edge_flags: Dictionary = {}        # Vector2i(from,to) -> flags, for edges that need a jump
# Nodes the fill sampled standing on a lift deck, and the synthetic deck nodes that replace them.
# Read by _gap_jump_round, which must not aim a leap at either: the sampled ones are being deleted
# (see _link_lifts), and a deck node hangs in mid-air at a stop the deck is not parked at.
var _lift_nodes: Dictionary = {}        # node id -> true
var _index: Dictionary = {}             # Vector3i cell key -> node id
var _ray := PhysicsRayQueryParameters3D.new()
var _shape := PhysicsShapeQueryParameters3D.new()
var _capsule := CapsuleShape3D.new()
var _real_shape := PhysicsShapeQueryParameters3D.new()   # REAL-radius hull, for _resolve_stand
var _fc_shape := PhysicsShapeQueryParameters3D.new()     # REAL-radius hull, dropped for _floor_cast
var _fc_capsule := CapsuleShape3D.new()
var _real_capsule := CapsuleShape3D.new()
var _resolve_place := false              # WW_BAKE_R04: place nodes where the real hull fits
var _nudged := 0                         # nodes RESOLVE_NUDGE freed from geometry (see _stand_at)
var _nudge_failed := 0                   # ...and nodes it could not free, which is the count worth
										 # watching: a bot steered at one of those walks into a wall
var _sweep_shape := PhysicsShapeQueryParameters3D.new()  # corridor sweep; a step-height shorter
var _sweep_capsule := CapsuleShape3D.new()               # hull, riding a step above the floor
var _water_point := PhysicsPointQueryParameters3D.new()  # MASK_WATER submersion probe (see _in_water)
var _ladder_probe := PhysicsShapeQueryParameters3D.new()  # MASK_LADDER overlap probe for face mounts
var _hazard_point := PhysicsPointQueryParameters3D.new()  # MASK_HAZARD probe (see _in_hazard)

# Movement-sim edge validator (ground truth): a real CharacterBody3D driven by the shared movement
# kernel, so an edge only links if the bot can PHYSICALLY walk it (step-up, slide, gravity), not
# merely if a hull sweep clears. Built in bake() when an owner Node is supplied.
var _sim_char: CharacterBody3D = null
var _sim_body = null                     # GodotBody wrapping _sim_char
var _sim = null                          # Movement.Simulation
var _sim_state = null                    # Movement.MovementState
var _sim_cfg = null                      # MovementConfig (for max_speed / step_height)
var _sim_flat := false                    # WW_BAKE_SIM: also walk-test the (many) flat edges
var _sim_tested := 0                      # edges walk-tested / rejected (diagnostics)
var _sim_rejected := 0
var _jump_tested := 0                     # jump edges arc-tested / rejected
var _jump_rejected := 0


## Flood-fill from `seeds` (world positions, e.g. spawn points) and build the graph, then bridge
## levels that only connect through ladders (`ladders`: {center, ymin, ymax, radius} per func_ladder
## — floor-sampling alone can't see a vertical climb). Returns a loaded WaypointGraph ready to
## serialize, or null if no seed produced a single walkable node. `owner` (a Node in the map's
## physics world) enables the movement-sim edge validator; without it the geometric checks stand alone.
func bake(space: PhysicsDirectSpaceState3D, seeds: Array, ladders: Array = [], owner: Node = null, water_aabbs: Array = [], lifts: Array = []) -> WaypointGraph:
	_space = space
	# Movement-sim validation is ground truth, and where the two disagree it wins. It always runs
	# on JUMP edges, and on any flat or drop edge the geometric sweep REJECTED — that is the whole
	# population where a cheap test can be wrong in the direction that costs us, since a rigid
	# cast_motion counts a graze as a wall while the real mover slides along it and carries on.
	# WW_BAKE_SIM=1 additionally sims the flat edges the sweep already passed; that is ~95% of the
	# graph for a 1.7x bake, and it rejected 151 of 56123 on ww_ravine, so it stays a diagnostic.
	if owner != null:
		_setup_move_sim(owner)
		_sim_flat = not OS.get_environment("WW_BAKE_SIM").is_empty()
	configure_queries()
	_nudged = 0
	_nudge_failed = 0

	# Seed the fill from spawns AND from around each ladder's ends — a platform reachable only by a
	# ladder has no spawn, so a spawn-only fill never explores it and _link_ladders has no node to
	# attach the ladder top to.
	var all_seeds: Array = seeds.duplicate()
	all_seeds.append_array(_ladder_seed_points(ladders))
	# Deep pools sealed off from the spawn-seeded fill (only reachable by swim/fall) leave a bot that
	# swims in with no node to route from. Seed the submerged floor so _link_water_exits can bridge
	# the pool bed up to the bank/rim.
	all_seeds.append_array(_water_seed_points(water_aabbs))
	# A lift's far stop serves floor nothing else reaches — that is what the lift is FOR — so the
	# spawn-seeded fill never explores it and _link_lifts would have no landing to step off onto.
	all_seeds.append_array(_lift_seed_points(lifts))

	# Seed the fill: snap each seed down to its floor and register it as the first node in its cell.
	# The PLAYER spawns among them double as the prune pass's ground truth for "somewhere a bot
	# actually starts", so their ids are tracked apart from the ladder/water helper seeds.
	var frontier: Array[int] = []
	var enqueued := {}   # node ids already pushed onto the frontier (BFS visited set)
	var spawn_ids := {}
	for si in all_seeds.size():
		var s: Vector3 = all_seeds[si]
		var floor_pos := _seed_floor(s)
		if floor_pos == Vector3.INF:
			continue
		var id := _add_or_get(floor_pos, _seed_sample)
		if id < 0:
			continue
		if si < seeds.size():
			spawn_ids[id] = true
		if not enqueued.has(id):
			enqueued[id] = true
			frontier.append(id)

	Log.info("[Bake]   seeds: %d node(s) from %d spawn(s), %d seeded in total" % [
		spawn_ids.size(), seeds.size(), frontier.size()])

	# Grid BFS: from each node, probe the 8 neighbouring columns; a walkable, reachable one
	# becomes a node (once per cell) and an edge is linked in whichever directions are traversable.
	while not frontier.is_empty() and _positions.size() < MAX_NODES:
		var id: int = frontier.pop_back()
		var p := _samples[id] if id < _samples.size() else _positions[id]
		for oz in [-1, 0, 1]:
			for ox in [-1, 0, 1]:
				if ox == 0 and oz == 0:
					continue
				var col := Vector2(p.x + ox * CELL, p.z + oz * CELL)
				var nb := _node_at_column(col, p.y)
				if nb < 0 or nb == id:
					continue  # a neighbour column can snap back into this same cell — not an edge
				# Link both directions independently — a step you can climb one way may be a drop
				# back (or vice versa), exactly as HPB edges are directed.
				var forward := _try_edge(id, nb)
				_try_edge(nb, id)
				# Expand ONLY through an edge the bot can actually travel. Expanding on mere
				# geometric adjacency walks the fill onto ledges overhead and shelves behind walls,
				# and each of those seeds a whole internally-connected island nothing can route to.
				if forward and not enqueued.has(nb):
					enqueued[nb] = true
					frontier.append(nb)

	_link_neighbours()
	_link_ladders(ladders)
	_link_lifts(lifts, spawn_ids)
	# The placement nudge's own report (see _stand_at). `left buried` is the tripwire: those are
	# nodes a bot will be steered INTO, and the count belongs in the log where a bake that starts
	# producing them is visible, rather than only in WW_HULL_AUDIT when someone thinks to ask.
	Log.info("[Bake]   hull nudge: moved %d node(s) out of geometry, %d left buried" % [
		_nudged, _nudge_failed])
	_link_water_exits()
	_link_jump_backs()
	_link_gap_jumps()
	_prune_unusable(spawn_ids)
	# The prune can reopen a seam it had no part in creating: two sides bridged only THROUGH an
	# island that the prune then dropped are split again. Re-run the linker on what survived.
	_link_gap_jumps()
	if not OS.get_environment("WW_BAKE_DIAG").is_empty():
		_diag_component_gaps()
	_teardown_move_sim()

	if _positions.is_empty():
		return null
	var g := WaypointGraph.new()
	g.build_from(_positions, _flags, _edges, _edge_flags)
	return g


## Shape and mask every reusable query the geometric tests run through. Split out of bake() so a
## caller that only wants the edge tests — the hand-file audit in tools/probe_handedges.gd — gets
## the same hulls and masks the bake uses. Skipping it leaves every mask at 0, which reads as a
## world with no geometry in it: every cast misses, and every edge comes back "floor-gap".
func configure_queries() -> void:
	_ray.collision_mask = PROBE_MASK
	_capsule.radius = HULL_RADIUS
	_capsule.height = STAND_HEIGHT
	_shape.shape = _capsule
	_shape.collision_mask = PROBE_MASK
	_shape.margin = 0.02
	_fc_capsule.radius = REAL_RADIUS
	_fc_capsule.height = FLOOR_PROBE_HEIGHT
	_fc_shape.shape = _fc_capsule
	_fc_shape.collision_mask = PROBE_MASK
	_fc_shape.margin = 0.0
	_real_capsule.radius = REAL_RADIUS
	_real_capsule.height = STAND_HEIGHT
	_real_shape.shape = _real_capsule
	_real_shape.collision_mask = PROBE_MASK
	_real_shape.margin = 0.0         # 0.4 IS the player's width; a margin re-fattens it
	_resolve_place = not OS.get_environment("WW_BAKE_R04").is_empty()
	_sweep_capsule.radius = HULL_RADIUS
	_sweep_capsule.height = STAND_HEIGHT - STEP_HEIGHT
	_sweep_shape.shape = _sweep_capsule
	_sweep_shape.collision_mask = PROBE_MASK
	_sweep_shape.margin = 0.02
	_water_point.collision_mask = GameConsts.MASK_WATER
	_hazard_point.collision_mask = GameConsts.MASK_HAZARD
	_hazard_point.collide_with_areas = true
	_hazard_point.collide_with_bodies = false
	_water_point.collide_with_areas = true   # water is an Area3D (worldspawn WaterVolumes / func_water)
	_water_point.collide_with_bodies = false


## Link every pair of nodes that is simply CLOSE, not just cell-adjacent.
##
## The fill only ever probes the 8 neighbouring COLUMNS, and a node keeps the position it was
## sampled at rather than snapping to its cell centre. Two regions the fill reached from different
## seeds therefore sit on different grid phases: their nodes can be 1.5m apart — walkable floor,
## no wall, nothing wrong — in cells that are two apart, so no edge is ever tried between them and
## the map bakes as pieces joined only by whatever marginal jump happens to exist. ww_ravine's
## inner ramp was reachable only by a 1.16m hop onto its side for exactly this reason, when a 0.6m
## step onto its foot was right there.
##
## Every pair still goes through _try_edge, so the geometry and the mover decide as always; this
## only widens what gets ASKED.
func _link_neighbours() -> void:
	var n := _positions.size()
	var buckets := {}
	for i in n:
		var key := Vector3i(floori(_positions[i].x / LINK_RADIUS), floori(_positions[i].y / LINK_RADIUS),
			floori(_positions[i].z / LINK_RADIUS))
		if not buckets.has(key):
			buckets[key] = PackedInt32Array()
		buckets[key].append(i)
	var linked := 0
	var tried := 0
	for i in n:
		var p := _positions[i]
		var c := Vector3i(floori(p.x / LINK_RADIUS), floori(p.y / LINK_RADIUS),
			floori(p.z / LINK_RADIUS))
		for dx in [-1, 0, 1]:
			for dy in [-1, 0, 1]:
				for dz in [-1, 0, 1]:
					var cell: Vector3i = c + Vector3i(dx, dy, dz)
					if not buckets.has(cell):
						continue
					for j in buckets[cell]:
						if j <= i or _positions[j].distance_to(p) > LINK_RADIUS:
							continue
						if not _edge_set.has(Vector2i(i, j)):
							tried += 1
							if _try_edge(i, j):
								linked += 1
						if not _edge_set.has(Vector2i(j, i)):
							tried += 1
							if _try_edge(j, i):
								linked += 1
	Log.info("[Bake]   near-pairs: tried %d unlinked pair(s) within %.2fm, linked %d" % [
		tried, LINK_RADIUS, linked])


## Extra flood-fill seeds sampled around each ladder's two ends, so platforms reachable only by
## climbing get explored (see bake). Rings of downward probes at both the foot and the head band;
## every walkable floor found where the hull fits becomes a seed.
func _ladder_seed_points(ladders: Array) -> Array:
	var pts: Array = []
	for L in ladders:
		var c: Vector3 = L.center
		pts.append_array(_ring_seeds(c, [L.ymin + 0.5, L.ymax - 0.5], [0.0, 1.5, 3.0], 8, 1.0, 3.0))
	return pts


## Walkable floor found by probing down from rings around a column — the shared body of the ladder
## and lift seeders, which differ only in where they put the rings and how far they reach. A ring of
## radius 0 is the column itself and is sampled once rather than `count` times over the same point.
func _ring_seeds(c: Vector3, bands: Array, radii: Array, count: int,
		lift: float, cast: float) -> Array:
	var pts: Array = []
	for band: float in bands:
		for ring: float in radii:
			var n := 1 if ring <= 0.0 else count
			for a in n:
				var ang := a * TAU / n
				var from := Vector3(c.x + cos(ang) * ring, band + lift, c.z + sin(ang) * ring)
				var fp := _floor_below(from, cast)
				if fp == Vector3.INF:
					continue
				var sp := _stand_at(fp)
				if sp != Vector3.INF:
					pts.append(sp)
	return pts


## Flood-fill seeds on the submerged floor of each water volume, so a deep pool the spawn fill can't
## reach gets nodes on its bed. Grid the volume footprint, drop a ray from above the surface to the
## first solid floor, and keep it only where the hull fits AND that floor actually sits under water
## (rejects the volume's dry overhang / the void false-positives a point-in-water test can throw).
func _water_seed_points(water_aabbs: Array) -> Array:
	var pts: Array = []
	for aabb: AABB in water_aabbs:
		var x := aabb.position.x
		while x <= aabb.end.x:
			var z := aabb.position.z
			while z <= aabb.end.z:
				var fp := _floor_below(Vector3(x, aabb.end.y + 2.0, z), aabb.size.y + DROP_MAX + 4.0)
				var sp := _stand_at(fp) if fp != Vector3.INF else Vector3.INF
				if sp != Vector3.INF and _in_water(sp + Vector3(0, 0.3, 0)):
					pts.append(sp)
				z += CELL * 2.0
			x += CELL * 2.0
	if not water_aabbs.is_empty():
		Log.info("[Bake]   water seeds: %d submerged floor point(s) from %d volume(s)" % [
			pts.size(), water_aabbs.size()])
	return pts


## Bridge the levels a ladder joins. Floor-sampling picks the two landings (lowest/highest walkable
## nodes near the ladder), but they usually sit on the SAME side of the rungs, so a direct
## bottom→top edge steers the bot along the wall, away from the ladder, and climb physics never
## engages. Instead drop a synthetic FL_LADDER node on the ladder's own axis and route
## bottom→axis→top — heading to the axis presses the bot into the rungs (see bot_brain for the climb).
func _link_ladders(ladders: Array) -> void:
	# Face-mounts only pick nodes the router can actually reach.
	var connected := _connected_nodes()
	# MASK_LADDER overlap probe (slightly fatter than the hull, to match the LadderDetector). The
	# ladder Volume is often a thin/diagonal slab inside a much larger render AABB.
	var lad_cap := CapsuleShape3D.new()
	lad_cap.radius = HULL_RADIUS + 0.3
	lad_cap.height = STAND_HEIGHT
	_ladder_probe.shape = lad_cap
	_ladder_probe.collision_mask = GameConsts.MASK_LADDER
	_ladder_probe.collide_with_areas = true
	_ladder_probe.collide_with_bodies = false
	var linked := 0
	for L in ladders:
		var c: Vector3 = L.center
		# Big climbable-face ladder (several metres across in BOTH horizontal axes): its centre
		# lands inside the cliff, so the radius/centre landing logic below picks a wrong ledge.
		# Instead bridge a real walkable node at the base of the face (mount) to one at the top.
		var wx: float = L.get("xmax", c.x) - L.get("xmin", c.x)
		var wz: float = L.get("zmax", c.z) - L.get("zmin", c.z)
		if minf(wx, wz) > 2.0:
			# Bottom mount MUST overlap the Volume (climb engages) with its ORIGIN outside it. The top
			# landing is where the bot steps off — just the highest walkable node on the face.
			var bm := _footprint_node(L, connected, true, true)
			var tl := _footprint_node(L, connected, false, false)
			if bm >= 0 and tl >= 0 and bm != tl and _positions[tl].y - _positions[bm].y > 1.5:
				# Axis at the TOP LANDING's column (not the ladder centre): on a diagonal ramp the tall
				# end is under the top landing, so aiming the climb there rides the bot up the full height
				# and onto the landing, instead of topping out early over the shorter centre column.
				var faxis := _add_raw_node(Vector3(_positions[tl].x,
						maxf(L.ymax, _positions[tl].y) + 0.5, _positions[tl].z), WaypointGraph.FL_LADDER)
				_add_edges([Vector2i(bm, faxis), Vector2i(faxis, tl),
						Vector2i(tl, faxis), Vector2i(faxis, bm)])
				linked += 1
				if not OS.get_environment("WW_BAKE_DIAG").is_empty():
					Log.info("[Bake]   face-ladder @%.0f,%.0f: mount %s -> top %s" % [
						c.x, c.z, _positions[bm], _positions[tl]])
				continue
		# Thin ladder brushes: the landings sit beside the rungs, so search a generous radius and
		# pick, in each Y band, the node nearest that end of the ladder.
		var r: float = L.get("radius", 0.5) + 4.5
		# Lowest/highest walkable nodes within the ladder's footprint — robust to a brush that
		# extends past the actual step-on/off floors. Height span check keeps it an honest climb.
		var landings := _landings_in(c, r, L.ymin, L.ymax)
		var bottom: int = landings.x
		var top: int = landings.y
		if bottom >= 0 and top >= 0 and bottom != top \
				and _positions[top].y - _positions[bottom].y > 1.5:
			# Synthetic climb node at the top of the ladder brush — the route's climb gate. Sitting
			# high on the axis with 3D (not horizontal) arrival, it can't be skipped by standing
			# under the ladder: the bot must ride the rungs up near the top before the route
			# advances to the top landing, which by then is at/below it. Raw-added so it stays
			# distinct even if a landing shares its cell.
			var axis := _add_raw_node(Vector3(c.x, maxf(L.ymax, _positions[top].y), c.z), WaypointGraph.FL_LADDER)
			# Centered mount: landings sit off to the side of thin rungs, so routing landing→axis
			# directly only catches the edge and the climb stalls. Route through a mount at the
			# rungs' centre column first. Falls back to the direct link if the centre isn't standable.
			var mfloor := _ladder_mount(c, _positions[bottom].y)
			var mid := bottom
			if mfloor != Vector3.INF:
				mid = _add_raw_node(mfloor, WaypointGraph.FL_LADDER)
			var chain: Array = [Vector2i(bottom, mid), Vector2i(mid, axis), Vector2i(axis, top),
					Vector2i(top, axis), Vector2i(axis, mid), Vector2i(mid, bottom)] if mid != bottom \
					else [Vector2i(bottom, axis), Vector2i(axis, top), Vector2i(top, axis), Vector2i(axis, bottom)]
			for pair in chain:
				if not _edge_set.has(pair):
					_edge_set[pair] = true
					_edges.append(pair)
			linked += 1
		elif not OS.get_environment("WW_BAKE_DIAG").is_empty():
			Log.info("[Bake]   ladder @%.0f,%.0f,%.0f r=%.1f y[%.1f..%.1f] unbridged: b=%d(%s) t=%d(%s)" % [
				c.x, c.y, c.z, r, L.ymin, L.ymax,
				bottom, ("y%.1f" % _positions[bottom].y) if bottom >= 0 else "-",
				top, ("y%.1f" % _positions[top].y) if top >= 0 else "-"])
	if not ladders.is_empty():
		Log.info("[Bake]   bridged %d/%d ladders" % [linked, ladders.size()])


## Extra flood-fill seeds on the floors around BOTH of a lift's stops. The far stop is the whole
## point of the lift — the floor it serves is reachable no other way — so the spawn-seeded fill
## never gets there and _link_lifts would find nothing to step off onto.
func _lift_seed_points(lifts: Array) -> Array:
	var pts: Array = []
	for L in lifts:
		var deck: AABB = L.deck
		var r0: float = maxf(deck.size.x, deck.size.z) * 0.5
		pts.append_array(_ring_seeds(deck.get_center(),
				[deck.end.y, deck.end.y + float(L.travel)],
				[r0 + 1.0, r0 + 2.5, r0 + 4.0], 12, 1.5, 4.0))
	if not lifts.is_empty():
		Log.info("[Bake]   lift seeds: %d floor point(s) around %d lift stop pair(s)" % [
			pts.size(), lifts.size()])
	return pts


## Bridge a lift's two stops. Modelled on _link_ladders, and for the same reason: the connection is
## not floor anybody walks, so no geometric test can find it. The difference is that only ONE of a
## lift's stops has a deck under it while the bake runs, so the far stop's node is invented outright
## and everything attached to it is linked by fiat.
##
## Each lift is {deck: world AABB of the deck brush at its RESTING pose, travel: signed Y offset to
## the far stop, name}. Every lift the bake hands over can be summoned from either stop — that is
## what qualifies it — so every edge here is two-way. See waypoint_bake.gd's _lift_entities.
func _link_lifts(lifts: Array, spawn_ids: Dictionary) -> void:
	if lifts.is_empty():
		return
	var linked := 0
	for L in lifts:
		var deck: AABB = L.deck
		var c := deck.get_center()
		var rest_top := deck.end.y
		var far_top: float = rest_top + float(L.travel)
		# The resting deck IS solid geometry, so the fill has already walked onto it. Ride from the
		# node it left there rather than inventing a second one in the same place.
		# Whatever the fill left standing on the resting deck, nearest the centre column first.
		var on_deck := _deck_nodes(deck, rest_top)
		var near_id := on_deck[0] if not on_deck.is_empty() else -1
		if near_id < 0:
			var sp := _stand_at(Vector3(c.x, rest_top + 0.02, c.z))
			if sp == Vector3.INF:
				Log.info("[Bake]   lift %s: no standable node on the resting deck — unbridged" % L.name)
				continue
			near_id = _add_raw_node(sp, WaypointGraph.FL_LIFT)
		_flags[near_id] |= WaypointGraph.FL_LIFT
		# Everything else the fill left standing on the resting deck has to go. A deck is not floor:
		# it is under that waypoint at one of the lift's two stops and nowhere near it at the other,
		# so a route that merely CROSSES it walks a bot into an open shaft — and a bot standing in
		# the shaft is what the descending deck is blocked on, which reverses it and starts the
		# whole cycle again. One node, flagged, reached only by the ride logic.
		var orphaned := _drop_deck_nodes(on_deck, near_id, spawn_ids)
		# The one node kept is still wearing the fill's own edges, and any of those that lead ONTO
		# it are a bot walking onto a deck without first checking the deck is there. Flag them.
		for e: Vector2i in _edges:
			if e.y == near_id:
				_edge_flags[e] = int(_edge_flags.get(e, 0)) | WaypointGraph.FL_LIFT
		var far_id := _add_raw_node(Vector3(c.x, far_top, c.z), WaypointGraph.FL_LIFT)
		_lift_nodes[near_id] = true
		_lift_nodes[far_id] = true
		# The ride itself. Geometry has no opinion on it: at this instant the deck is at one stop
		# and the gap to the other is neither a walk, a jump nor a survivable drop.
		_lift_edge(near_id, far_id, WaypointGraph.FL_LIFT)
		_lift_edge(far_id, near_id, WaypointGraph.FL_LIFT)
		# Step off at each stop, and back on again. BOTH stops need this, the resting one included:
		# its deck node inherited the fill's edges, but they mostly ran to the deck nodes just
		# deleted, and the middle of a wide deck is further from the floor around it than any edge
		# test reaches. Stepping ON is flagged FL_LIFT — at either stop the deck is somewhere else
		# half the time, and a bot that walks that edge without waiting walks into the shaft.
		var connected := _connected_nodes()
		var lands := _link_stop(deck, near_id, rest_top, connected) \
				+ _link_stop(deck, far_id, far_top, connected)
		linked += 1
		Log.info("[Bake]   lift %s: %v <-> %v (%.1fm), %d landing(s), %d deck node(s) dropped" % [
			L.name, _positions[near_id], _positions[far_id], absf(float(L.travel)), lands, orphaned])
	Log.info("[Bake]   bridged %d/%d lift(s)" % [linked, lifts.size()])


## Join a deck waypoint to the floor it serves at one of its stops, both ways. Returns how many.
## Stepping ON is flagged FL_LIFT — at either stop the deck is somewhere else half the time, and a
## bot that walks that edge without waiting walks into the shaft.
func _link_stop(deck: AABB, sid: int, stop_y: float, connected: Dictionary) -> int:
	var lands := _lift_landings(deck, stop_y, connected, sid)
	for id in lands:
		var dy: float = _positions[id].y - stop_y
		_lift_edge(sid, id, WaypointGraph.FL_JUMP if dy > STEP_HEIGHT else 0)
		_lift_edge(id, sid,
			WaypointGraph.FL_LIFT | (WaypointGraph.FL_JUMP if -dy > STEP_HEIGHT else 0))
	return lands.size()


## Node ids with at least one edge — the linkers only aim at nodes the router can actually reach.
func _connected_nodes() -> Dictionary:
	var out := {}
	for e in _edges:
		out[e.x] = true
		out[e.y] = true
	return out


## Cut every edge touching a node the fill left standing on the resting deck, except the one node
## kept as the lift's waypoint. Isolated, they are dropped by _prune_unusable as unreachable —
## which is the honest answer, since the floor they were sampled on drives away.
func _drop_deck_nodes(on_deck: Array[int], keep: int, spawn_ids: Dictionary) -> int:
	var doomed := {}
	for i in on_deck:
		if i == keep or spawn_ids.has(i):
			continue
		doomed[i] = true
		_lift_nodes[i] = true
	if doomed.is_empty():
		return 0
	var kept: Array[Vector2i] = []
	for e: Vector2i in _edges:
		if doomed.has(e.x) or doomed.has(e.y):
			_edge_set.erase(e)
			_edge_flags.erase(e)
		else:
			kept.append(e)
	_edges = kept
	return doomed.size()


## Append a directed edge and OR `flag` into whatever it already carries.
func _lift_edge(a: int, b: int, flag: int) -> void:
	var e := Vector2i(a, b)
	_add_edges([e])
	if flag != 0:
		_edge_flags[e] = int(_edge_flags.get(e, 0)) | flag


## The fill's nodes standing on the deck where it rests, nearest the deck's centre column first.
## Empty when the fill never reached it (a shaft sealed off from every spawn). The head becomes the
## lift's waypoint and the tail is deleted — see _link_lifts.
func _deck_nodes(deck: AABB, top_y: float) -> Array[int]:
	var c := deck.get_center()
	var found: Array = []
	for i in _positions.size():
		var p := _positions[i]
		if _on_deck(deck, top_y, p):
			found.append([Vector2(p.x - c.x, p.z - c.z).length_squared(), i])
	found.sort_custom(func(l, r): return l[0] < r[0])
	var out: Array[int] = []
	for f in found:
		out.append(f[1])
	return out


## True when `p` stands on the deck's surface: inside its footprint, at its top face.
func _on_deck(deck: AABB, top_y: float, p: Vector3) -> bool:
	return absf(p.y - top_y) <= 0.45 \
		and p.x >= deck.position.x and p.x <= deck.end.x \
		and p.z >= deck.position.z and p.z <= deck.end.z


## Walkable nodes a bot can step between and a deck parked with its surface at `stop_y`: just
## outside the deck's footprint (within LIFT_REACH of it), within a jump of that surface, and
## connected to the rest of the graph. Nearest first, capped — a wide shaft has a whole floor's
## worth of nodes around it and linking them all buys nothing.
func _lift_landings(deck: AABB, stop_y: float, connected: Dictionary, skip: int) -> Array[int]:
	const MAX_LANDINGS := 8
	var cand: Array = []
	for i in _positions.size():
		if i == skip or not connected.has(i):
			continue
		var p := _positions[i]
		var dy := p.y - stop_y
		if dy > JUMP_UP or dy < -LIFT_LAND_DROP:
			continue
		# Distance from the deck's footprint, not from its centre: a wide deck's own edge is metres
		# from the middle and a landing beside it is a stride away, not a leap.
		var dx := maxf(maxf(deck.position.x - p.x, p.x - deck.end.x), 0.0)
		var dz := maxf(maxf(deck.position.z - p.z, p.z - deck.end.z), 0.0)
		var d := Vector2(dx, dz).length()
		if d > LIFT_REACH:
			continue
		cand.append([d, i])
	cand.sort_custom(func(l, r): return l[0] < r[0])
	var out: Array[int] = []
	for k in mini(MAX_LANDINGS, cand.size()):
		out.append(cand[k][1])
	return out


## A walkable node on a big ladder's climbable face: XZ inside the footprint, connected, and nearest
## the ladder column at the lowest (want_low) or highest band. When require_touch, the node's hull
## must overlap the MASK_LADDER Volume AND its origin be OUTSIDE it (interior gives a ZERO normal).
## Returns -1 when nothing qualifies (thin ladder — caller falls back to beside-the-rungs landings).
func _footprint_node(L: Dictionary, connected: Dictionary, want_low: bool, require_touch: bool) -> int:
	var c: Vector3 = L.center
	var m := 0.6
	var xmin: float = L.get("xmin", c.x) - m
	var xmax: float = L.get("xmax", c.x) + m
	var zmin: float = L.get("zmin", c.z) - m
	var zmax: float = L.get("zmax", c.z) + m
	var cand: Array[int] = []
	for i in _positions.size():
		var p := _positions[i]
		if p.x < xmin or p.x > xmax or p.z < zmin or p.z > zmax or not connected.has(i):
			continue
		if not require_touch or (_touches_ladder(p) and not _inside_ladder(p)):
			cand.append(i)
	if cand.is_empty():
		return -1
	var ext := INF if want_low else -INF
	for i in cand:
		ext = minf(ext, _positions[i].y) if want_low else maxf(ext, _positions[i].y)
	var best := -1
	var best_d := INF
	for i in cand:
		var p := _positions[i]
		if absf(p.y - ext) > 3.0:
			continue
		var d := Vector2(p.x - c.x, p.z - c.z).length_squared()
		if d < best_d:
			best_d = d
			best = i
	return best


## True when a standing hull at floor point `pos` overlaps a MASK_LADDER Volume (a bot there can climb).
func _touches_ladder(pos: Vector3) -> bool:
	_ladder_probe.transform = Transform3D(Basis.IDENTITY, pos + Vector3(0, STAND_HEIGHT * 0.5, 0))
	return not _space.intersect_shape(_ladder_probe, 1).is_empty()


## True when the body origin is INTERIOR to a MASK_LADDER Volume (get_ladder_normal returns ZERO there).
func _inside_ladder(pos: Vector3) -> bool:
	var pt := PhysicsPointQueryParameters3D.new()
	pt.position = pos + Vector3(0, 0.1, 0)
	pt.collision_mask = GameConsts.MASK_LADDER
	pt.collide_with_areas = true
	pt.collide_with_bodies = false
	return not _space.intersect_point(pt, 1).is_empty()


## Append directed edges, skipping ones already present.
func _add_edges(pairs: Array) -> void:
	for pair in pairs:
		if not _edge_set.has(pair):
			_edge_set[pair] = true
			_edges.append(pair)


## Standable floor centred on the ladder column, just in front of the rungs — the spot to route the
## bot through so it mounts the middle of the (thin) ladder rather than catching an edge. The column
## centre itself isn't standable (it's the rungs/wall), so search outward along ±X/±Z and take the
## nearest standable point. Returns INF if nothing qualifies (caller links the landings directly).
func _ladder_mount(c: Vector3, bottom_y: float) -> Vector3:
	for d in [0.5, 0.75, 1.0, 1.25, 1.5]:
		for cand in [Vector3(c.x, 0, c.z + d), Vector3(c.x, 0, c.z - d),
				Vector3(c.x + d, 0, c.z), Vector3(c.x - d, 0, c.z)]:
			var fp := _floor_below(Vector3(cand.x, bottom_y + FLOOR_SCAN_UP, cand.z), STAND_HEIGHT + 2.0)
			# Keep it at the bottom level — an in-front spot on a different floor isn't this mount.
			if fp == Vector3.INF:
				continue
			var sp := _stand_at(fp)
			if sp != Vector3.INF and absf(sp.y - bottom_y) < 1.0:
				return sp
	return Vector3.INF


## Append a node at an exact position with `flag`, bypassing the cell-dedup grid (`_add_or_get`).
## Used for synthetic ladder-axis nodes that must exist even when a landing occupies the same cell.
func _add_raw_node(pos: Vector3, flag: int) -> int:
	var id := _positions.size()
	_positions.append(pos)
	_samples.append(pos)
	_flags.append(flag)
	return id


## The lowest and highest walkable nodes standing within horizontal radius `r` of the ladder
## column `c` — the ladder's two landings. Returns Vector2i(bottom_id, top_id), components -1 when
## none qualify. Nodes are constrained to the ladder's height span (a small margin past ymin/ymax)
## so a tall face doesn't grab an unrelated floor stacked far above or below it.
func _landings_in(c: Vector3, r: float, ymin: float, ymax: float) -> Vector2i:
	var lo := -1
	var hi := -1
	var r2 := r * r
	for i in _positions.size():
		var p := _positions[i]
		# A ladder brush often floats above its foot floor, especially over water (climbable slab
		# starts a couple metres up, real floor is well below ymin). Allow a body-height-plus drop
		# so that foot still counts as the bottom landing.
		if p.y < ymin - (STAND_HEIGHT + STEP_HEIGHT) or p.y > ymax + 2.0:
			continue
		if Vector2(p.x - c.x, p.z - c.z).length_squared() > r2:
			continue
		if lo < 0 or p.y < _positions[lo].y:
			lo = i
		if hi < 0 or p.y > _positions[hi].y:
			hi = i
	return Vector2i(lo, hi)


# --- Water exits ----------------------------------------------------------------------------

## True when world-point `p` is inside a MASK_WATER volume (worldspawn WaterVolumes or a func_water).
func _in_water(p: Vector3) -> bool:
	_water_point.position = p
	return not _space.intersect_point(_water_point, 1).is_empty()


## The water surface Y at or above `p`, found by marching a point probe up until it exits the water,
## or -INF when p is not submerged. Per-column (not an AABB top), so stacked pools at different levels
## each resolve correctly. Capped so an unbounded volume can't loop forever.
func _water_surface_at(p: Vector3) -> float:
	if not _in_water(p):
		return -INF
	var y := p.y
	var top := p.y + DROP_MAX + STAND_HEIGHT  # generous cap; deeper water just reports this ceiling
	while y < top:
		y += 0.5
		if not _in_water(Vector3(p.x, y, p.z)):
			return y - 0.25  # midpoint of the last submerged step ≈ the surface
	return top


## Bridge the one gap floor-sampling can't: a submerged node has only drop-in edges, so a bot that
## fell in is trapped. For each submerged node, link (FL_JUMP) the best nearby bank whose floor sits
## between the waterline and WATER_EXIT_RISE above it and that the hull sweeps to cleanly. Directed
## water→bank only (the reverse is an ordinary drop).
func _link_water_exits() -> void:
	# Horizontal cell hash of all nodes — _index is keyed on Y too, so it can't answer "any node
	# near this column at ~surface height", which is the bank lookup we need here.
	var xz: Dictionary = {}
	var submerged: PackedInt32Array = PackedInt32Array()
	for i in _positions.size():
		var k := Vector2i(roundi(_positions[i].x / CELL), roundi(_positions[i].z / CELL))
		if not xz.has(k):
			xz[k] = PackedInt32Array()
		xz[k].append(i)
		if _in_water(_positions[i]):
			submerged.append(i)
	if submerged.is_empty():
		return

	var linked := 0
	for i in submerged:
		var pi := _positions[i]
		var surf := _water_surface_at(pi)
		if surf == -INF or surf <= pi.y + 0.1:
			continue  # right at the surface already — nothing to climb toward
		var ci := Vector2i(roundi(pi.x / CELL), roundi(pi.z / CELL))
		var best_j := -1
		var best_band := 1 << 30   # rise, in WATER_EXIT_BAND buckets
		var best_reach := INF      # ...and how far out over the water the lip sits
		for dz in range(-WATER_EXIT_CELLS, WATER_EXIT_CELLS + 1):
			for dx in range(-WATER_EXIT_CELLS, WATER_EXIT_CELLS + 1):
				if dx == 0 and dz == 0:
					continue
				var arr = xz.get(Vector2i(ci.x + dx, ci.y + dz))
				if arr == null:
					continue
				for j in arr:
					var pj := _positions[j]
					# A bank sitting at the waterline (within a step below, up to the exit reach above).
					if pj.y < surf - STEP_HEIGHT or pj.y > surf + WATER_EXIT_RISE:
						continue
					# Lowest lip wins, and among lips of much the same height the NEAREST one —
					# the leap is up AND out, so a lip two metres back over open water is a
					# different move from the same lip at arm's length. Height alone left the
					# choice to iteration order, and since a bank is usually flat (ww_2fort's
					# basins are one 0.27m step all along) that meant arbitrary: measured there,
					# climb-outs ranged from 0.84m to 2.83m of reach for identical rises, and the
					# long ones are where carriers fell back in.
					var band := floori((pj.y - surf) / WATER_EXIT_BAND)
					var reach := Vector2(pj.x - pi.x, pj.z - pi.z).length()
					if not (band < best_band or (band == best_band and reach < best_reach)):
						continue
					if _in_water(pj + Vector3(0.0, 0.1, 0.0)):
						continue  # j is itself under water — an underwater shelf, not an exit
					if not _sweep_clear(pi, pj):
						continue  # a wall/overhang above the lip blocks the climb-out
					best_band = band
					best_reach = reach
					best_j = j
		if best_j >= 0:
			var key := Vector2i(i, best_j)
			if not _edge_set.has(key):
				_edge_set[key] = true
				_edges.append(key)
			_edge_flags[key] = WaypointGraph.FL_JUMP  # jump/swim-up performed climbing out here
			linked += 1
	Log.info("[Bake]   water exits: %d submerged node(s), linked %d out to banks" % [
		submerged.size(), linked])


## Add the reverse of a one-way drop as a jump-up when a bot can make it with a running jump, for
## the drops _try_edge never tried the reverse of — the ladder, water-exit and gap-jump passes all
## add edges after the grid fill is over. Window is JUMP_BACK_UP by height and _jump_reach by
## distance, and the arc sim has the last word.
func _link_jump_backs() -> void:
	var linked := 0
	var snapshot := _edges.duplicate()   # iterate a copy; we append during the loop
	for e in snapshot:
		var hi: int = e.x   # a -> b where a is higher = a descent to b; reverse b -> a is the climb
		var lo: int = e.y
		var rise := _positions[hi].y - _positions[lo].y
		if rise <= STEP_HEIGHT or rise > JUMP_BACK_UP:
			continue                        # a walk edge, or too tall to jump back up
		var horiz := Vector2(_positions[hi].x - _positions[lo].x,
				_positions[hi].z - _positions[lo].z).length()
		if horiz > _jump_reach(rise):
			continue
		var key := Vector2i(lo, hi)
		if _edge_set.has(key):
			continue                        # already climbable back
		if not _sweep_clear(_positions[lo], _positions[hi]):
			continue                        # a wall between — not a clean jump
		if not _edge_jump_sim(_positions[lo], _positions[hi]):
			continue                        # the arc can't actually make it back up
		_edge_set[key] = true
		_edges.append(key)
		_edge_flags[key] = WaypointGraph.FL_JUMP
		linked += 1
	Log.info("[Bake]   jump-backs: linked %d reverse ledge climbs" % linked)


## Jump the gaps the grid cannot see. Edges are only ever tried between neighbouring cells, so a
## crossing wider than a cell diagonal does not exist to the baker however easily a running player
## clears it — and a map built around them (ww_chasm's canyon ledges) bakes as pieces sitting a
## jump apart.
##
## Pairs are taken across STRONGLY-connected regions, not merely disconnected ones, because the
## failure this fixes is usually directional. Sampling a map of ledges naturally produces a one-way
## cascade: every drop links downhill, nothing links back, and the graph is "connected" while a bot
## that walks to the enemy base can never come home. Those regions are undirected-connected, so a
## component test never even asks about them. Closest pairs first, and the union-find early-out
## keeps it to roughly one repair per seam rather than a test per pair.
func _link_gap_jumps(rounds := 3) -> void:
	for _r in rounds:
		if _gap_jump_round() == 0:
			return


## One sweep of _link_gap_jumps; returns how many edges it added. Linking a seam changes which
## regions are mutually reachable, and the union-find merges optimistically (one validated
## direction is assumed to close the cycle), so the caller repeats this with freshly computed
## SCCs until a round finds nothing.
func _gap_jump_round() -> int:
	var n := _positions.size()
	if n == 0:
		return 0
	var fwd: Array = []
	var rev: Array = []
	fwd.resize(n)
	rev.resize(n)
	for i in n:
		fwd[i] = PackedInt32Array()
		rev[i] = PackedInt32Array()
	for e: Vector2i in _edges:
		fwd[e.x].append(e.y)
		rev[e.y].append(e.x)
	var live := PackedByteArray()
	live.resize(n)
	live.fill(1)
	var scc := _scc_ids(fwd, rev, live, n)
	var rep := {}
	for i in n:
		if not rep.has(scc[i]):
			rep[scc[i]] = i
	if rep.size() <= 1:
		return 0            # already one strongly-connected mass — nothing to repair
	var parent := PackedInt32Array()
	parent.resize(n)
	for i in n:
		parent[i] = i
	for i in n:
		_union(parent, rep[scc[i]], i)
	# Candidate pairs: different regions, within a jump's reach, and not a fall past DROP_MAX.
	var cell := GAP_JUMP_MAX
	var grid := {}
	for i in n:
		var k := Vector2i(floori(_positions[i].x / cell), floori(_positions[i].z / cell))
		if not grid.has(k):
			grid[k] = PackedInt32Array()
		grid[k].append(i)
	var cands: Array = []
	for i in n:
		var pi := _positions[i]
		var gi := Vector2i(floori(pi.x / cell), floori(pi.z / cell))
		for dz in [-1, 0, 1]:
			for dx in [-1, 0, 1]:
				var arr = grid.get(Vector2i(gi.x + dx, gi.y + dz))
				if arr == null:
					continue
				for j in arr:
					if j <= i or _find(parent, i) == _find(parent, j):
						continue
					if _lift_nodes.has(i) or _lift_nodes.has(j):
						continue  # a deck is ridden, not jumped to (see _lift_nodes)
					var pj := _positions[j]
					var dy := pj.y - pi.y
					if dy > JUMP_BACK_UP or dy < -DROP_MAX:
						continue
					var h := Vector2(pj.x - pi.x, pj.z - pi.z).length()
					# A leap that falls stays airborne longer and so reaches further — sizing the
					# window off the actual arc is what lets a ledge-to-canyon-floor crossing link
					# while keeping level jumps honest.
					if h < CELL or h > minf(_jump_reach(dy), GAP_JUMP_MAX):
						continue
					cands.append([h, i, j])
	if cands.is_empty():
		return 0
	cands.sort_custom(func(l, r): return l[0] < r[0])
	var linked := 0
	var sims := 0
	for c in cands:
		if sims >= GAP_JUMP_SIMS:
			break
		var i: int = c[1]
		var j: int = c[2]
		if _find(parent, i) == _find(parent, j):
			continue          # an earlier, shorter jump already joined these two sides
		# Try the uphill/level direction first; a fall the other way is then an ordinary drop edge.
		for pair in [Vector2i(i, j), Vector2i(j, i)]:
			if _edge_set.has(pair):
				continue
			sims += 1
			if not _edge_jump_sim(_positions[pair.x], _positions[pair.y]):
				continue
			_edge_set[pair] = true
			_edges.append(pair)
			_edge_flags[pair] = WaypointGraph.FL_JUMP
			_union(parent, i, j)
			linked += 1
	Log.info("[Bake]   gap jumps: %d region(s), %d candidate pair(s), %d arc test(s), linked %d" % [
		rep.size(), cands.size(), sims, linked])
	return linked


## How far a running jump carries when the landing is `dy` below (negative) or above the take-off.
## Solves the arc for when it crosses `dy`, times the run speed, with a fifth held back for the
## acceleration and steering a real approach loses. The arc test is still the authority; this only
## decides which pairs are worth asking about.
func _jump_reach(dy: float) -> float:
	var g: float = _sim_cfg.gravity if _sim_cfg != null else 20.0
	var vj: float = _sim_cfg.jump_speed if _sim_cfg != null else 6.7082
	var vh: float = _sim_cfg.max_speed if _sim_cfg != null else 8.0
	var t := (vj + sqrt(maxf(vj * vj - 2.0 * g * dy, 0.0))) / g
	return vh * t * 0.8


func _find(parent: PackedInt32Array, x: int) -> int:
	while parent[x] != x:
		parent[x] = parent[parent[x]]
		x = parent[x]
	return x


func _union(parent: PackedInt32Array, a: int, b: int) -> void:
	var ra := _find(parent, a)
	var rb := _find(parent, b)
	if ra != rb:
		parent[rb] = ra


# --- Reachability prune ---------------------------------------------------------------------

## Drop every node a bot can't actually use, so the graph stops promising places it can't go.
## A node survives two tests:
##   * it is forward-reachable from a player spawn — otherwise it is an island, a ledge or roof or
##     shelf the sampler reached but nothing links into, and A* still snaps objectives onto it and
##     hands the bot an empty route,
##   * it can reach the CORE, the largest strongly-connected region of what the spawns reach —
##     otherwise it is a one-way trap, a pit the bot drops into and can never leave, which A*
##     routes into happily because the drop edge is perfectly real.
## The core, not the spawns, is the return target on purpose. Plenty of maps spawn players on a
## ledge they walk off and cannot climb back to (ww_feudal), and demanding a route home to the
## spawn condemns almost the whole map as a trap.
## Left alone if it would empty the graph (a map whose spawns themselves sampled badly).
func _prune_unusable(spawn_ids: Dictionary) -> void:
	var n := _positions.size()
	if n == 0:
		return
	if spawn_ids.is_empty():
		push_warning("[Bake] prune skipped: no spawn snapped to a walkable node — the graph is " +
			"seeded only by ladder/water helpers and its reachability is unverified")
		return
	var seeds: Array[int] = []
	for k in spawn_ids:
		seeds.append(k)
	var verdict := _reachability(seeds, n)
	# A region the fill reached from a DIFFERENT seed sits on its own grid phase, half a cell off
	# its neighbours, and the fill — which only ever links cell-adjacent columns — never tries the
	# seam between the two. Whatever one-way drop does join them then reads as a trap and the prune
	# deletes the region wholesale (ww_ravine's flag basement: walkable kept floor 0.7m away, flat,
	# no edge). Try the seam before dropping anything.
	if _stitch_seams(verdict["arrives"], verdict["returns"], n) > 0:
		verdict = _reachability(seeds, n)
	var arrives: PackedByteArray = verdict["arrives"]
	var returns: PackedByteArray = verdict["returns"]
	var core: Array[int] = verdict["core"]

	var new_id := PackedInt32Array()
	new_id.resize(n)
	var kept := 0
	var unreachable := 0
	var trapped := 0
	for i in n:
		if arrives[i] == 1 and returns[i] == 1:
			new_id[i] = kept
			kept += 1
		else:
			new_id[i] = -1
			if arrives[i] == 1:
				trapped += 1
			else:
				unreachable += 1
	if kept == 0:
		push_warning("[Bake] prune would empty the graph (%d spawn node(s) isolated) — kept as-is" %
			spawn_ids.size())
		return

	if not OS.get_environment("WW_BAKE_DIAG").is_empty():
		_diag_dropped(new_id, arrives, n)   # must run while _positions still holds the old ids

	var pos := PackedVector3Array()
	var fl := PackedInt32Array()
	pos.resize(kept)
	fl.resize(kept)
	for i in n:
		if new_id[i] >= 0:
			pos[new_id[i]] = _positions[i]
			fl[new_id[i]] = _flags[i]
	var edges: Array[Vector2i] = []
	var eflags := {}
	for e: Vector2i in _edges:
		if new_id[e.x] >= 0 and new_id[e.y] >= 0:
			var ne := Vector2i(new_id[e.x], new_id[e.y])
			edges.append(ne)
			if _edge_flags.has(e):
				eflags[ne] = _edge_flags[e]
	var dropped_edges := _edges.size() - edges.size()
	_positions = pos
	_flags = fl
	_edges = edges
	_edge_flags = eflags
	_edge_set.clear()
	for e: Vector2i in _edges:
		_edge_set[e] = true
	_index.clear()   # node ids moved; the cell index is only read during the fill, which is over
	Log.info("[Bake]   prune: kept %d/%d nodes (core %d; dropped %d unreachable, %d one-way traps) and %d edges" % [
		kept, n, core.size(), unreachable, trapped, dropped_edges])


## Who can be reached from a spawn (`arrives`), who can get back to somewhere a bot can operate
## from (`returns`), and the `core` that second question is asked against.
##
## "Somewhere a bot can operate from" is the map's main mass plus the spawns themselves. Both
## halves are needed: some maps spawn players on a ledge they walk off and cannot climb back to,
## so spawns alone condemn the whole map; and a base joined to the rest of the map one-way still
## has its own spawns and its own ground to fight over, so the core alone deletes it.
func _reachability(seeds: Array[int], n: int) -> Dictionary:
	var fwd: Array = []
	var rev: Array = []
	fwd.resize(n)
	rev.resize(n)
	for i in n:
		fwd[i] = PackedInt32Array()
		rev[i] = PackedInt32Array()
	for e: Vector2i in _edges:
		fwd[e.x].append(e.y)
		rev[e.y].append(e.x)
	var arrives := _reach(fwd, seeds, n)
	var core := _largest_scc(fwd, rev, arrives, n)
	var homes := core.duplicate()
	homes.append_array(seeds)
	return {"arrives": arrives, "returns": _reach(rev, homes, n), "core": core}


## Last chance for the regions the prune is about to delete: try a real edge between each doomed
## node and the surviving floor near it. Only the pairs that matter are tested (a doomed node and a
## keeper), and every one goes through the same _try_edge the fill uses, so a seam is stitched only
## where a bot can genuinely walk/jump it. Returns how many edges were added.
func _stitch_seams(arrives: PackedByteArray, returns: PackedByteArray, n: int) -> int:
	var doomed: Array[int] = []
	var buckets := {}          # STITCH_RADIUS-sized spatial hash of the survivors
	for i in n:
		if arrives[i] == 1 and returns[i] == 1:
			var key := _stitch_key(_positions[i])
			if not buckets.has(key):
				buckets[key] = PackedInt32Array()
			buckets[key].append(i)
		elif arrives[i] == 1 or returns[i] == 1:
			doomed.append(i)   # sampled and half-connected: a seam, not an island in the void
	var added := 0
	for i in doomed:
		var p := _positions[i]
		var c := _stitch_key(p)
		for dx in [-1, 0, 1]:
			for dy in [-1, 0, 1]:
				for dz in [-1, 0, 1]:
					var cell: Vector3i = c + Vector3i(dx, dy, dz)
					if not buckets.has(cell):
						continue
					for j in buckets[cell]:
						if _positions[j].distance_to(p) > STITCH_RADIUS:
							continue
						if _try_edge(i, j):
							added += 1
						if _try_edge(j, i):
							added += 1
	if added > 0:
		Log.info("[Bake]   seams: stitched %d edge(s) onto %d node(s) the prune would have dropped"
			% [added, doomed.size()])
	return added


func _stitch_key(p: Vector3) -> Vector3i:
	return Vector3i(floori(p.x / STITCH_RADIUS), floori(p.y / STITCH_RADIUS),
		floori(p.z / STITCH_RADIUS))


## WW_BAKE_DIAG: where the prune bit. It is the one pass that can delete real coverage, so when a
## map comes out missing a wing or a basement this says whether the fill never sampled it (nothing
## reported here) or sampled it and threw it away as unreachable / a one-way trap.
func _diag_dropped(new_id: PackedInt32Array, arrives: PackedByteArray, n: int) -> void:
	for pass_trap in [false, true]:
		var mn := Vector3.INF
		var mx := -Vector3.INF
		var count := 0
		for i in n:
			if new_id[i] >= 0 or (arrives[i] == 1) != pass_trap:
				continue
			count += 1
			mn = mn.min(_positions[i])
			mx = mx.max(_positions[i])
		if count == 0:
			continue
		Log.info("[Bake]     dropped %d %s node(s), spanning x[%.0f,%.0f] y[%.0f,%.0f] z[%.0f,%.0f]" % [
			count, "one-way trap" if pass_trap else "unreachable",
			mn.x, mx.x, mn.y, mx.y, mn.z, mx.z])


## WW_BAKE_DIAG: explain the seams. Two pieces of a map that a player walks between but the graph
## splits into separate components always show up as node pairs a cell apart with no edge, so list
## the closest such pairs and name the check that rejected each. Without this a split is just a
## component count and you are guessing.
func _diag_component_gaps(max_report := 12) -> void:
	var n := _positions.size()
	var und: Array = []
	und.resize(n)
	for i in n:
		und[i] = PackedInt32Array()
	for e: Vector2i in _edges:
		und[e.x].append(e.y)
		und[e.y].append(e.x)
	var comp := PackedInt32Array()
	comp.resize(n)
	comp.fill(-1)
	var sizes: Array[int] = []
	for i in n:
		if comp[i] >= 0:
			continue
		var c := sizes.size()
		var count := 0
		var stack: Array[int] = [i]
		comp[i] = c
		while not stack.is_empty():
			var u: int = stack.pop_back()
			count += 1
			for v in und[u]:
				if comp[v] < 0:
					comp[v] = c
					stack.append(v)
		sizes.append(count)
	if sizes.size() < 2:
		return
	# Horizontal cell hash so the pair search stays linear instead of O(n²).
	var xz := {}
	for i in n:
		var k := Vector2i(roundi(_positions[i].x / CELL), roundi(_positions[i].z / CELL))
		if not xz.has(k):
			xz[k] = PackedInt32Array()
		xz[k].append(i)
	var pairs: Array = []
	for i in n:
		var pi := _positions[i]
		var ci := Vector2i(roundi(pi.x / CELL), roundi(pi.z / CELL))
		for dz in [-1, 0, 1]:
			for dx in [-1, 0, 1]:
				var arr = xz.get(Vector2i(ci.x + dx, ci.y + dz))
				if arr == null:
					continue
				for j in arr:
					if j <= i or comp[j] == comp[i]:
						continue
					var d := pi.distance_to(_positions[j])
					if d <= CELL * 1.6:
						pairs.append([d, i, j])
	if pairs.is_empty():
		Log.info("[Bake]   gaps: %d components, none within a cell of each other" % sizes.size())
		return
	pairs.sort_custom(func(l, r): return l[0] < r[0])
	Log.info("[Bake]   gaps: %d components; closest unlinked cross-component pairs:" % sizes.size())
	for k in mini(max_report, pairs.size()):
		var d: float = pairs[k][0]
		var i: int = pairs[k][1]
		var j: int = pairs[k][2]
		Log.info("[Bake]     d=%.2f dy=%+.2f %s|%d <-> %s|%d  a->b:%s  b->a:%s" % [
			d, _positions[j].y - _positions[i].y,
			_positions[i], sizes[comp[i]], _positions[j], sizes[comp[j]],
			_why_no_edge(_positions[i], _positions[j]), _why_no_edge(_positions[j], _positions[i])])


## Name the first edge check that rejects a->b, for _diag_component_gaps.
func _why_no_edge(a: Vector3, b: Vector3) -> String:
	var dy := b.y - a.y
	if absf(dy) <= STEP_HEIGHT:
		if not _floor_continuous(a, b):
			return "floor-gap"
		if not _sweep_clear(a, b):
			return "OK?" if _edge_walk_sim(a, b, true) else "sweep+walk-sim"
		if not _edge_walk_sim(a, b):
			return "walk-sim"
		return "OK?"
	if _walkable_ramp(a, b):
		return "OK?"
	if dy > STEP_HEIGHT and dy <= JUMP_UP:
		if not _edge_jump_sim(a, b):
			return "jump-arc"
		return "OK?"
	if dy < 0 and dy >= -DROP_MAX:
		if not _sweep_clear(a, b) and not _edge_walk_sim(a, b, true):
			return "sweep+walk-sim"
		if not _drop_lands(a, b):
			return "drop-blocked"
		return "OK?"
	return "out-of-range"


## The largest strongly-connected set of nodes among those marked in `live` — the map's main mass,
## the region a bot can wander indefinitely. Returns its member ids.
func _largest_scc(fwd: Array, rev: Array, live: PackedByteArray, n: int) -> Array[int]:
	var ids := _scc_ids(fwd, rev, live, n)
	var groups := {}
	for i in n:
		if ids[i] < 0:
			continue
		if not groups.has(ids[i]):
			groups[ids[i]] = [] as Array[int]
		groups[ids[i]].append(i)
	var best: Array[int] = []
	for g in groups.values():
		if g.size() > best.size():
			best = g
	return best


## Strongly-connected component id per node (-1 where `live` is 0). Two nodes share an id exactly
## when a bot can get from either to the other and back. Iterative Kosaraju — the graph is far too
## deep for recursion.
func _scc_ids(fwd: Array, rev: Array, live: PackedByteArray, n: int) -> PackedInt32Array:
	# Pass 1: push nodes in order of DFS finish time over the forward edges.
	var seen := PackedByteArray()
	seen.resize(n)
	seen.fill(0)
	var order: Array[int] = []
	for s in n:
		if live[s] == 0 or seen[s] == 1:
			continue
		seen[s] = 1
		var stack: Array = [[s, 0]]
		while not stack.is_empty():
			var top: Array = stack[-1]
			var u: int = top[0]
			var adj: PackedInt32Array = fwd[u]
			if top[1] < adj.size():
				var v: int = adj[top[1]]
				top[1] += 1
				if live[v] == 1 and seen[v] == 0:
					seen[v] = 1
					stack.append([v, 0])
			else:
				order.append(u)
				stack.pop_back()
	# Pass 2: walk that order backwards over the reversed edges; each flood is one component.
	var ids := PackedInt32Array()
	ids.resize(n)
	ids.fill(-1)
	var next_id := 0
	for k in range(order.size() - 1, -1, -1):
		var s: int = order[k]
		if ids[s] >= 0:
			continue
		ids[s] = next_id
		var stack: Array[int] = [s]
		while not stack.is_empty():
			var u: int = stack.pop_back()
			for v in rev[u]:
				if live[v] == 1 and ids[v] < 0:
					ids[v] = next_id
					stack.append(v)
		next_id += 1
	return ids


## Flood `starts` over adjacency `adj`; returns a per-node 0/1 visited mask.
func _reach(adj: Array, starts, n: int) -> PackedByteArray:
	var seen := PackedByteArray()
	seen.resize(n)
	seen.fill(0)
	var stack: Array[int] = []
	for s in starts:
		if seen[s] == 0:
			seen[s] = 1
			stack.append(s)
	while not stack.is_empty():
		var u: int = stack.pop_back()
		for v in adj[u]:
			if seen[v] == 0:
				seen[v] = 1
				stack.append(v)
	return seen


# --- Node discovery -------------------------------------------------------------------------

## Find (or create) a walkable node in the grid column at `col`, near height `near_y`. Tries small
## in-cell nudges so a column centre buried in a wall still lands a node on adjacent open floor.
## Returns the node id (existing or new), or -1 if nothing walkable is near that height.
func _node_at_column(col: Vector2, near_y: float) -> int:
	# Start the down-scan above the highest floor a bot could climb to from here (near_y + JUMP_UP),
	# so reachable higher ledges aren't missed, and scan down through the deepest linkable drop.
	var scan_top := near_y + JUMP_UP + 0.3
	var scan_depth := JUMP_UP + 0.3 + DROP_MAX
	for off in NUDGE:
		var from := Vector3(col.x + off.x, scan_top, col.y + off.y)
		# Multi-level sampling: one column can expose several stacked walkable floors (e.g. a glass
		# roof over a courtyard sitting above a ramp/pit floor). Taking only the topmost hit strands
		# everything under a roof/overhang, so gather every standable floor down the column and pick
		# the one nearest the parent's height.
		var floor_pos := _nearest_floor(_floors_below(from, scan_depth), near_y)
		if floor_pos == Vector3.INF:
			continue
		var key := _cell_key(floor_pos)
		if _index.has(key):
			return _index[key]
		var stand := _stand_at(floor_pos)
		if stand == Vector3.INF:
			continue
		return _add_or_get(stand, floor_pos)
	return -1


## The floor from `floors` whose height is nearest `near_y`, but only within the reachable band;
## Vector3.INF when none qualifies. The band is ASYMMETRIC because reach is: a bot climbs at most a
## cell-long 45 degree ramp but falls DROP_MAX. A symmetric band (the old JUMP_UP + DROP_MAX either
## way) let a column adopt a floor eight metres overhead, which links to nothing and just leaves a
## stub node sitting in the cell.
func _nearest_floor(floors: Array, near_y: float) -> Vector3:
	var best := Vector3.INF
	var best_d := INF
	for fp: Vector3 in floors:
		var dy := fp.y - near_y
		if dy > CLIMB_MAX or dy < -DROP_MAX:
			continue
		var d := absf(dy)
		if d <= best_d:
			best_d = d
			best = fp
	return best


## Every standable floor down a column from `from`, top to bottom (capped at `max_floors`). Unlike
## _floor_below (topmost hit only), this pierces thin roofs and overhangs: after each hit it restarts
## the ray just below the surface, so it continues on to the floor beneath.
func _floors_below(from: Vector3, max_dist: float, max_floors := 4) -> Array:
	var out: Array = []
	var bottom := from.y - max_dist
	var y := from.y
	while y > bottom and out.size() < max_floors:
		var r := _floor_cast(from.x, from.z, y, bottom)
		if r.is_empty():
			break
		var hit: Vector3 = r["position"]
		if float(r["normal"].y) >= WALK_NORMAL_Y:
			out.append(hit + Vector3(0, 0.02, 0))
		y = hit.y - 0.1   # step below this surface to look for a floor beneath it (roof/overhang)
	return out



## Cast a ray down from `from` up to `max_dist`; return the floor point (nudged up off the
## surface) if it is standable (normal steep enough), else Vector3.INF.
func _floor_below(from: Vector3, max_dist: float) -> Vector3:
	var r := _floor_cast(from.x, from.z, from.y, from.y - max_dist)
	if r.is_empty():
		return Vector3.INF
	if (r.normal as Vector3).y < WALK_NORMAL_Y:
		return Vector3.INF
	return (r.position as Vector3) + Vector3(0, 0.02, 0)


## Where a player can STAND in this column, walking down it.
##
## Two things have to be true at once and they are not the same question:
##
##   * The probe must be WIDE. A ray has no width, so where two brushes abut it slips through the
##     zero-width join and reports whatever lies far below — and the fill samples on a 1m lattice,
##     so it lands on such a seam whenever one runs along an integer coordinate. ww_2fort's bridge
##     halves meet at z=0; its centre column sampled the moat bed 6m down, the walkway was severed,
##     and every bot crossing stepped into the water at the midpoint. Width also decides which BSP
##     tree hop answers from: under 32 GoldSrc units a query runs on hull 0, the render faces, which
##     carry no CLIP brushes at all. REAL_RADIUS 0.4 is exactly 32 units, so this reads the clipnode
##     tree the player actually collides with.
##
##   * The probe must not be a SWEEP. cast_motion stops at the first contact of ANY kind, so a hull
##     dropped down a long column aborts on a wall it brushes on the way past — which asks "could a
##     body fall in here", not "can a body stand here". Those coincide in the open and diverge
##     against geometry: sweeping cost ww_ravine 55% of its canyon floor and shattered ww_wstland4
##     into 4 components (272 spawn routes down to 120) with its node count barely moved, because
##     the same sweep sits under _floor_continuous and killed the EDGES.
##
## So: a cheap ray proposes candidate heights, the wide sweep proposes one more (the one a seam
## would have hidden), and every candidate is then confirmed by resting the real hull ON it. A
## bogus candidate simply fails that test, so the sweep can be wrong for free.
func _floor_cast(x: float, z: float, y_from: float, y_to: float) -> Dictionary:
	var cands: Array[float] = []
	# Cheap ray pass: every surface down the column.
	var y := y_from
	var guard := 0
	while y > y_to and guard < 12:
		guard += 1
		_ray.from = Vector3(x, y, z)
		_ray.to = Vector3(x, y_to, z)
		var r := _space.intersect_ray(_ray)
		if r.is_empty():
			break
		var hy := float((r["position"] as Vector3).y)
		cands.append(hy)
		y = hy - 0.1
	# Seam pass: a wide hull cannot fall through a hairline join, so it sees the surface the ray
	# missed. It may also stop early against a wall — that candidate just fails confirmation below.
	var half := FLOOR_PROBE_HEIGHT * 0.5
	_fc_shape.transform = Transform3D(Basis.IDENTITY, Vector3(x, y_from + half, z))
	_fc_shape.motion = Vector3(0.0, y_to - y_from, 0.0)
	var res := _space.cast_motion(_fc_shape)
	if res.size() == 2:
		var frac := float(res[0])
		if frac > 0.0 and frac < 1.0:
			cands.append(y_from + (y_to - y_from) * frac)
	# Highest confirmed surface wins: at a seam that is the deck, not the bed far below it.
	cands.sort()
	cands.reverse()
	for cy in cands:
		var info := _hull_rest(x, cy, z)
		if not info.is_empty():
			return info
	return {}


## Confirm a player-sized hull actually comes to rest with its feet at `y`: clear with the feet a
## hair above the surface, blocked a hair below it. Two static overlap tests, so nothing about the
## path taken to get there can veto a spot a body can legitimately occupy.
func _hull_rest(x: float, y: float, z: float) -> Dictionary:
	var half := FLOOR_PROBE_HEIGHT * 0.5
	_fc_shape.motion = Vector3.ZERO
	_fc_shape.transform = Transform3D(Basis.IDENTITY, Vector3(x, y + half + 0.03, z))
	if not _space.intersect_shape(_fc_shape, 1).is_empty():
		return {}                        # the hull does not fit here at all
	_fc_shape.transform = Transform3D(Basis.IDENTITY, Vector3(x, y + half - 0.06, z))
	var info := _space.get_rest_info(_fc_shape)
	if info.is_empty():
		return {}                        # nothing under it — not a floor
	var n: Vector3 = info["normal"]
	if n.y < 0.0:
		n = -n
	return {"position": Vector3(x, y, z), "normal": n}


## Snap a seed point down to the floor a player starting there ends up on. Unlike the fill's own
## column probe this scans the whole way down (SEED_SCAN_DOWN) and skips non-standable hits: several
## maps spawn players in the air — ww_skytower drops them 15-36m — and a short scan, or one that
## gives up on the first steep surface, snaps no spawn at all and leaves the graph seeded only by
## the ladder/water helpers. Returns the first standable floor the hull fits on, else Vector3.INF.
func _seed_floor(p: Vector3) -> Vector3:
	for fp: Vector3 in _floors_below(p + Vector3(0, FLOOR_SCAN_UP, 0), SEED_SCAN_DOWN, 8):
		var sp := _stand_at(fp)
		if sp != Vector3.INF:
			_seed_sample = fp      # the lattice point this came from; see _samples
			return sp
	_seed_sample = Vector3.INF
	return Vector3.INF


## True when the slim PROBE hull fits at `floor_pos` (no wall/ceiling overlap). floor_pos is the
## surface point; the capsule is centred a half-height above it.
##
## This is an EDGE predicate now, not a placement one: _walkable_ramp sub-samples a slope with it,
## where a deliberately-slim hull is right, because that branch has no move-sim override and a
## full-width graze would drop whole staircases through _try_edge's final `else`. Placement asks
## _stand_at instead, which resolves the REAL hull's position rather than rejecting the column.
func _hull_fits(floor_pos: Vector3) -> bool:
	_shape.transform = Transform3D(Basis.IDENTITY,
		floor_pos + Vector3(0, STAND_HEIGHT * 0.5 + 0.03, 0))
	if not _space.intersect_shape(_shape, 1).is_empty():
		return false
	return not _in_hazard(floor_pos)


## Where a node BELONGS, given a floor sample at `floor_pos`, or Vector3.INF when there is no room
## for a body there at all. Every placement site goes through here; the edge tests keep the slim
## probe, which is a different question.
##
## Two answers, because two things are being traded off. By default the slim probe decides whether
## the column is usable and the real hull only gets a RESOLVE_NUDGE to come unstuck, so positions
## stay on the sampling lattice. Under WW_BAKE_R04 the real hull decides outright, resolving up to
## RESOLVE_MAX and dropping the column when nothing fits. See the branches below for what each
## costs.
func _stand_at(floor_pos: Vector3) -> Vector3:
	# A submerged node is not a standing position and must not be judged as one. Underwater the bot
	# SWIMS: nothing has to support a 1.8m capsule, and the clearance a standing body needs is not
	# the clearance a swimming one needs. ww_roc2's entire north-south link is a single-file tunnel
	# 2m under the pool surface — resolving those nodes against a standing hull nudged them off the
	# centreline, broke the edges along the tunnel and split the map in two.
	if _resolve_place:
		if _in_water(floor_pos + Vector3(0, 0.3, 0)):
			return floor_pos
		return _resolve_stand(floor_pos)
	# Free the hull if a few centimetres will do it, and otherwise leave the sample exactly where it
	# is. Both halves of that are measured. A node the real 0.4 hull cannot occupy is somewhere a
	# bot is steered INTO rather than at: of ww_2fort's 95 bridge-deck waypoints, 10 sat inside the
	# player's own clip hull, 9cm deep in the rope rail along the edge — the bots scraping the ropes
	# the whole way across. A nudge that small barely moves the lattice, which is what matters:
	# resolving in FULL (WW_BAKE_R04, RESOLVE_MAX 0.45) frees every one of them and still costs
	# more than it buys, because nodes drift off the corridor the fill validated — n=2 600s soaks
	# on ww_2fort twice over, captures 8.5 -> 5.5, distance -12%, grinding 5.7% -> 8.0%. And
	# rejecting the column outright, which is what a fat PLACEMENT probe amounts to, deletes tight
	# corridors wholesale (see HULL_RADIUS).
	if not _hull_fits(floor_pos):
		return Vector3.INF
	var nudged := _resolve_stand(floor_pos, RESOLVE_NUDGE)
	if nudged == Vector3.INF:
		_nudge_failed += 1
		return floor_pos   # nothing a nudge can do; the slim probe's answer stands
	if floor_pos.distance_to(nudged) > RESOLVE_FLUSH:
		_nudged += 1       # a real push, not the re-seat's last millimetre
	return nudged


## Push a REAL_RADIUS hull out of whatever it is buried in until it fits, and report the floor it
## then stands on. Vector3.INF when it never comes free inside RESOLVE_MAX — the gap is genuinely
## narrower than the body, which is the one case where dropping the node is right.
##
## This is what `_hull_fits` cannot do. intersect_shape answers yes/no at the exact sample point,
## and a 1.0m grid almost never samples the few centimetres of standable band in a tight corridor,
## so raising the probe to the real radius deletes those corridors outright instead of improving
## them (the ww_ravine route collapse in TODO.txt). collide_shape reports the penetration VECTOR,
## so the same query that says "blocked" also says which way to move and by how much.
func _resolve_stand(floor_pos: Vector3, max_push := RESOLVE_MAX) -> Vector3:
	var p := floor_pos
	for _k in RESOLVE_ITERS:
		var pen := _hull_penetration(p)
		if float(pen[0]) <= RESOLVE_FLUSH:
			# Clear of the geometry. The push is 3-D and may have lifted the hull, so re-seat it on
			# the floor actually under the resolved column rather than trusting the drifted height.
			# Re-seating REFINES a lateral push; it must not gate the node. The caller already
			# established this floor when it sampled the position, and a short down-scan finds
			# nothing in exactly the places that matter most: a submerged node's real bed is metres
			# below (ww_roc2's whole north-south crossing is 20 nodes swimming a pool whose floor is
			# 14m down, and gating on the scan deleted all 20, splitting the map).
			var fp := _floor_below(p + Vector3(0, STEP_HEIGHT, 0), STEP_HEIGHT * 2.0 + 0.5)
			if fp == Vector3.INF:
				fp = Vector3(p.x, floor_pos.y, p.z)   # keep the sampled height; the push was lateral
			if fp.distance_to(floor_pos) > max_push:
				return Vector3.INF
			if float(_hull_penetration(fp)[0]) > RESOLVE_FLUSH:
				return Vector3.INF          # seating it put it back in the wall
			return Vector3.INF if _in_hazard(fp) else fp
		var sep: Vector3 = pen[1]
		p += sep + sep.normalized() * RESOLVE_EPS
		if p.distance_to(floor_pos) > max_push:
			return Vector3.INF
	return Vector3.INF                      # never converged: narrower than the body


## Deepest overlap of a standing REAL_RADIUS hull at `floor_pos`, as [depth, separation].
## `separation` is the vector that frees it: hop's collide_shape reports each contact as the pair
## (point on the queried hull, that point pushed out along the contact normal by the penetration
## depth), so the difference between them IS the depenetration vector.
func _hull_penetration(floor_pos: Vector3) -> Array:
	_real_shape.transform = Transform3D(Basis.IDENTITY,
		floor_pos + Vector3(0, STAND_HEIGHT * 0.5 + 0.03, 0))
	var pairs := _space.collide_shape(_real_shape, 8)
	var best := 0.0
	var sep := Vector3.ZERO
	var k := 0
	while k + 1 < pairs.size():
		var v: Vector3 = pairs[k + 1] - pairs[k]
		var l := v.length()
		if l > best:
			best = l
			sep = v
		k += 2
	return [best, sep]


## True when a bot standing at `floor_pos` would be inside a damaging trigger_hurt.
##
## Somewhere that hurts to stand is not somewhere to walk, and the fill has no other way to know:
## a lethal floor traces as good ground. ww_storm's flag room is the case that forced this — its
## floor is a kill volume with the grail on a ledge above, and the fill used that floor as the
## bridge between the ledges, so EVERY route to the grail marched bots through it. They died 7-16
## times a match and never once carried the flag.
##
## A volume with dmg <= 0 heals rather than hurts (CTriggerHurt::HurtTouch) and one switched off
## at round start does nothing, so neither counts. Neither does a team_no volume, and that one
## matters: ww_storm guards each spawn room with a dmg-1000 volume across its doorway that hurts
## only the OTHER team. Treating those as hazards walls every bot inside its own spawn (measured:
## 3 components and 112 of 272 spawn routes). The team that lives there walks out through it
## untouched, and a bot charging the enemy spawn dying in the doorway is the map working.
func _in_hazard(floor_pos: Vector3) -> bool:
	# Feet and chest: a shin-deep volume is missed by a centre-only probe, a head-height one by a
	# feet-only probe.
	for h in [0.1, STAND_HEIGHT * 0.5]:
		_hazard_point.position = floor_pos + Vector3(0.0, h, 0.0)
		for hit in _space.intersect_point(_hazard_point, 4):
			var vol: Node = hit.collider.get_meta(&"hurt_volume", null)
			if vol == null or not is_instance_valid(vol):
				continue
			if float(vol.get("_dmg")) > 0.0 and bool(vol.get("_active")) \
					and int(vol.get("_req_team")) == 0:
				return true
	return false


## Return the node in the sample cell, creating it if none exists (so clustered seeds and columns
## rediscovered from several parents never spawn a duplicate node).
##
## `key_pos` is the position that decides WHICH CELL this is, and defaults to floor_pos. They differ
## once placement resolves a node out of a wall: the sampling grid is the node's identity and has to
## stay on the grid's phase, while `floor_pos` is merely where the body ends up standing. Keying on
## the resolved position instead lets one sample cell register under a neighbour's key, so the fill
## rediscovers the same column as a fresh node and the graph drifts off its own grid.
func _add_or_get(floor_pos: Vector3, key_pos := Vector3.INF) -> int:
	var key := _cell_key(floor_pos if key_pos == Vector3.INF else key_pos)
	if _index.has(key):
		return _index[key]
	var id := _positions.size()
	_positions.append(floor_pos)
	_samples.append(floor_pos if key_pos == Vector3.INF else key_pos)
	_flags.append(0)
	_index[key] = id
	return id


func _cell_key(p: Vector3) -> Vector3i:
	return Vector3i(roundi(p.x / CELL), roundi(p.y / Y_BUCKET), roundi(p.z / CELL))


# --- Edge tests -----------------------------------------------------------------------------

## Link a→b if the hull can travel there. Classifies the move by how the floor behaves between
## the two nodes — a continuous walkable slope/stair is a plain walk however tall the endpoint
## delta; a sheer rise is a jump (FL_JUMP) up to JUMP_UP; a sheer fall is a one-way drop to
## DROP_MAX. Tunnelling through walls is ruled out by a swept-hull check (flat/step/jump) or the
## per-sub-point hull fit inside _walkable_ramp (slopes).
func _try_edge(a: int, b: int) -> bool:
	var key := Vector2i(a, b)
	if _edge_set.has(key):            # both BFS directions probe each pair — link it only once
		return true
	var pa := _positions[a]
	var pb := _positions[b]
	var dy := pb.y - pa.y
	var flag := 0
	if absf(dy) <= STEP_HEIGHT:
		# Flat / small step. The swept hull rules out a head-height wall but says nothing about the
		# FLOOR between a and b, so a "walk" straight over a pit or hidden dip would pass. Require a
		# continuous walkable floor (floor-only test; walls are already covered by the sweep), then
		# confirm with the real movement kernel as ground truth (no-op if the sim isn't set up).
		if not _floor_continuous(pa, pb):
			return false
		if _sweep_clear(pa, pb):
			if not _edge_walk_sim(pa, pb):
				return false
		# The sweep says walled out. It is a rigid cast_motion, so ANY contact blocks, and the hull
		# it sweeps is now the player's own — which is exactly as wide as a GoldSrc doorway, since
		# both are 32 units. A body that would slide through one reads as stopped dead. So do not
		# take the geometric answer here: run the real mover, which slides, and let it decide. It
		# costs a sim only on edges already rejected, and it is the difference between ww_ravine's
		# flag alcove being reachable and one team never scoring.
		elif not _edge_walk_sim(pa, pb, true):
			return false
	elif _walkable_ramp(pa, pb):
		flag = 0                      # continuous walkable slope or staircase — a plain walk
	elif dy > STEP_HEIGHT and dy <= JUMP_UP:
		# No sweep veto here at all. _edge_jump_sim IS the real mover, it always runs, and a jump
		# is the one move the swept hull describes worst: it tests a horizontal slide at standing
		# height, while the body actually arcs over the obstruction. Letting the cheap test veto
		# the authoritative one is backwards.
		if not _edge_jump_sim(pa, pb):
			return false
		flag = WaypointGraph.FL_JUMP  # a sheer ledge the bot jumps up to
	elif dy < 0 and dy >= -DROP_MAX:
		# Walk off a ledge (one-way; the reverse is tested separately). Same override as the flat
		# case — the mover walking off the lip lands at b, and a doorway it has to pass through on
		# the way is exactly what the full-width sweep gets wrong. ww_ravine is the case: with the
		# geometric veto standing, the whole lower level pruned away as one-way traps (1867 of
		# them against 248) and every bot was pushed onto the contested middle deck, where they
		# died twice as often and stopped capturing.
		if not _sweep_clear(pa, pb) and not _edge_walk_sim(pa, pb, true):
			return false
		if not _drop_lands(pa, pb):
			return false              # target sits under a solid floor/overhang — the fall is blocked
	else:
		return false                  # too high to jump / too deep to drop and not a walkable ramp
	_edge_set[key] = true
	_edges.append(key)
	if flag != 0:
		_edge_flags[key] = flag       # the jump belongs to THIS approach, not to b — walking onto
									  # the same ledge from along the top is not a jump
	return true


## True when a continuous walkable floor runs from a to b — sub-samples the floor and requires each
## consecutive sample to exist and rise/fall no more than a step. Floor-only (walls are already
## handled by the swept hull); catches pits/gaps/hidden ledges a head-height sweep misses.
func _floor_continuous(a: Vector3, b: Vector3) -> bool:
	var horiz := Vector2(b.x - a.x, b.z - a.z).length()
	var steps := maxi(2, ceili(horiz / 0.4))
	var prev_y := a.y
	for k in range(1, steps + 1):
		var t := float(k) / steps
		var mid := Vector3(lerpf(a.x, b.x, t), lerpf(a.y, b.y, t), lerpf(a.z, b.z, t))
		var fp := _floor_below(mid + Vector3(0, STEP_HEIGHT + 0.5, 0), STEP_HEIGHT * 2.0 + 0.5)
		if fp == Vector3.INF or absf(fp.y - prev_y) > STEP_HEIGHT + 0.05:
			return false
		prev_y = fp.y
	return true


# --- Movement-sim edge validation (ground truth) -------------------------------------------------

## Build the real CharacterBody3D + movement kernel used to walk-test edges. `owner` must be in the
## map's physics world so the body collides against the loaded geometry.
func _setup_move_sim(owner: Node) -> void:
	_sim_char = CharacterBody3D.new()
	_sim_char.collision_layer = 0
	_sim_char.collision_mask = PROBE_MASK
	_sim_char.floor_block_on_wall = false
	_sim_char.safe_margin = 0.01
	_sim_char.floor_snap_length = 0.0
	_sim_char.floor_max_angle = acos(WALK_NORMAL_Y)
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4                     # the REAL player radius (player.tscn), not the slim probe hull
	cap.height = STAND_HEIGHT
	cs.shape = cap
	cs.position = Vector3(0, STAND_HEIGHT * 0.5, 0)
	_sim_char.add_child(cs)
	owner.add_child(_sim_char)
	_sim_body = GodotBody.new(_sim_char)
	_sim_cfg = MovementConfig.new()
	_sim = Movement.Simulation.new(_sim_cfg)


func _teardown_move_sim() -> void:
	if _sim != null:
		Log.info("[Bake]   move-sim: jump-tested %d edges (rejected %d), walk-tested %d flat (rejected %d)" % [
			_jump_tested, _jump_rejected, _sim_tested, _sim_rejected])
	if _sim_char != null and is_instance_valid(_sim_char):
		_sim_char.queue_free()
	_sim_char = null
	_sim_body = null
	_sim = null
	_sim_state = null


## Ground truth for a walk edge: drive the shared movement kernel from a to b and report whether the
## bot actually arrives. Catches what the geometric checks pass but the mover can't do — clipping a
## wall corner, a floor dip it falls into, a step it can't climb. No-op (true) when the sim isn't set
## up. Callers pre-filter with the cheap checks so this only runs on plausible edges.
func _edge_walk_sim(a: Vector3, b: Vector3, force := false) -> bool:
	if _sim == null:
		# No kernel (bake() got no owner to parent the sim body to). A forced call is the caller
		# asking physics to overrule a geometric rejection, so with no physics to ask, the
		# rejection has to stand — returning "clear" here would wave through every edge the sweep
		# turned down, unchecked.
		return not force
	if not _sim_flat and not force:
		return true
	_sim_tested += 1
	_sim_char.global_position = a
	_sim_char.velocity = Vector3.ZERO
	_sim_body.force_sync_physics()
	_sim_state = Movement.MovementState.new()
	_sim_state.on_floor = true
	var floor_y := minf(a.y, b.y)
	var horiz0 := Vector2(b.x - a.x, b.z - a.z).length()
	var max_ticks := int(clampf(horiz0 / 0.08 + 20.0, 24.0, 90.0))
	var delta := 1.0 / 60.0
	var stuck := 0
	var prev := a
	for _t in max_ticks:
		var p: Vector3 = _sim_char.global_position
		if Vector2(b.x - p.x, b.z - p.z).length() < 0.45 and absf(p.y - b.y) < STEP_HEIGHT + 0.1:
			return true                                    # arrived
		if p.y < floor_y - 2.0:
			_sim_rejected += 1
			return false                                   # fell off a ledge / into a pit
		var d := Vector3(b.x - p.x, 0.0, b.z - p.z)
		if d.length() < 0.05:
			d = Vector3(b.x - a.x, 0.0, b.z - a.z)          # right over it: keep aiming along the edge
		d = d.normalized()
		var cmd = InputCommand.create(0, 0.0, -1.0, atan2(-d.x, -d.z), 0.0, 0, delta)
		_sim.simulate_tick(_sim_body, _sim_state, cmd)
		var np: Vector3 = _sim_char.global_position
		if np.distance_to(prev) < 0.01:
			stuck += 1
			if stuck >= 6:
				_sim_rejected += 1
				return false                               # wedged — not making progress
		else:
			stuck = 0
		prev = np
	var pf: Vector3 = _sim_char.global_position
	if Vector2(b.x - pf.x, b.z - pf.z).length() < 0.6 and absf(pf.y - b.y) < STEP_HEIGHT + 0.1:
		return true
	_sim_rejected += 1
	return false


## Ground truth for a JUMP edge: run at `b` with a full head of speed while holding jump the way
## bot_brain does at an FL_JUMP waypoint, and report whether the bot gets up onto the ledge. This is
## what the hull sweep cannot answer — the sweep tests a corridor at the LANDING's height and says
## nothing about the arc: a ledge too tall for the gap, a ceiling that caps the jump, a lip the body
## clips on the way up all sweep clear and then wedge the bot hopping underneath forever.
func _edge_jump_sim(a: Vector3, b: Vector3) -> bool:
	if _sim == null:
		return true
	var d := Vector3(b.x - a.x, 0.0, b.z - a.z)
	if d.length() < 0.01:
		# Straight up or straight down through the node's own column. There is no run-up for the
		# climb and no direction to walk off for the fall, so the bot just holds jump under its own
		# waypoint — only a same-level pair is trivially fine. (_link_gap_jumps can pair two floors
		# of one column, and this used to wave them through.)
		return absf(b.y - a.y) <= STEP_HEIGHT
	_jump_tested += 1
	d = d.normalized()
	_sim_char.global_position = a
	_sim_char.velocity = Vector3.ZERO
	_sim_body.force_sync_physics()
	_sim_state = Movement.MovementState.new()
	_sim_state.on_floor = true
	# A bot arrives at a jump waypoint walking, not from a standstill: GoldSrc air control is capped
	# at air_speed_cap, so a standing jump barely moves horizontally and would reject every real
	# ledge. Give it the run-up it would actually have.
	_sim_state.velocity = d * _sim_cfg.max_speed
	var yaw := atan2(-d.x, -d.z)
	var delta := 1.0 / 60.0
	var jump_flags: int = InputCommand.FLAG_JUMP
	var reach := Vector2(b.x - a.x, b.z - a.z).length()
	# Long enough for the arc actually being asked about: a hop onto a lip is over in a third of a
	# second, but a leap across a canyon onto a ledge six metres down is still falling after one,
	# and a fixed budget quietly fails every one of those as "didn't make it".
	var ticks := clampi(int((_jump_reach(b.y - a.y) / maxf(_sim_cfg.max_speed, 0.1)) * 60.0) + 24,
		48, 180)
	# Success is CROSSING THE LIP, not stopping on the node: a bot holding jump bunny-hops and
	# sails several metres past a one-cell ledge, so "arrived and grounded" never fires. What
	# separates a makeable ledge from one the bot bonks and slides back down is whether it ever
	# gets past b's column at b's height.
	for _t in ticks:
		# Released in the air, as BotBrain does, so each landing is a fresh press.
		var flags: int = jump_flags if _sim_state.on_floor else 0
		var cmd = InputCommand.create(0, 0.0, -1.0, yaw, 0.0, flags, delta)
		_sim.simulate_tick(_sim_body, _sim_state, cmd)
		var p: Vector3 = _sim_char.global_position
		var from_a := Vector2(p.x - a.x, p.z - a.z)
		var travelled := from_a.dot(Vector2(d.x, d.z))
		# How far the body has wandered SIDEWAYS off the a->b line. Distance along the heading
		# alone cannot tell a jump from a body sliding along a wall that happens to lie at an
		# angle to it: the slide racks up "progress" the whole way and the arc reads as made.
		# ww_ravine has a long diagonal wall that linked a dozen edges straight through it.
		var lateral := absf(from_a.cross(Vector2(d.x, d.z)))
		# Over the lip and high enough to be standing on it. A DESCENDING edge has to have actually
		# come down, too: "high enough" is free when the target is below, so a bot merely running
		# along the floor ABOVE b satisfied it, and the link it produced was a drop through solid
		# floor — the bot walks over the spot and hops in place on top of its own waypoint forever.
		if travelled >= reach and lateral <= LATERAL_SLACK and p.y >= b.y - 0.05 \
				and (b.y >= a.y or p.y <= b.y + STEP_HEIGHT):
			return true
		if p.y < minf(a.y, b.y) - 1.0:
			break                     # fell past both ends — the gap won
	_jump_rejected += 1
	if not OS.get_environment("WW_BAKE_DIAG").is_empty():
		Log.info("[Bake]     jump rejected: %s -> %s (rise %.2f over %.2f), stopped at %s" % [
			a, b, b.y - a.y, reach, _sim_char.global_position])
	return false


func _walkable_ramp(a: Vector3, b: Vector3) -> bool:
	var horiz := Vector2(b.x - a.x, b.z - a.z).length()
	var steps := maxi(2, ceili(horiz / 0.4))
	var prev_y := a.y
	for k in range(1, steps + 1):
		var t := float(k) / steps
		var mid := Vector3(lerpf(a.x, b.x, t), lerpf(a.y, b.y, t), lerpf(a.z, b.z, t))
		var fp := _floor_below(mid + Vector3(0, STEP_HEIGHT + 0.5, 0), STEP_HEIGHT * 2.0 + 0.5)
		if fp == Vector3.INF:
			return false              # a gap / non-walkable patch — not a continuous surface
		if absf(fp.y - prev_y) > STEP_HEIGHT + 0.05:
			return false              # a step bigger than the hull climbs — a ledge, not a ramp
		if not _hull_fits(fp):
			return false              # blocked (wall/low ceiling) along the way
		prev_y = fp.y
	return true


## True when a bot dropping off `a`'s ledge can actually reach `b` — i.e. `b`'s column is exposed to
## the fall, not buried under an intervening floor/overhang. `_sweep_clear` only checks for a HEAD-
## height wall along the top of the move, so on stacked floors it happily links a "drop" to a lower
## node even when an upper deck blocks the fall. This rays straight down `b`'s column instead: the
## first solid surface must be `b`'s own floor, not something higher up.
func _drop_lands(a: Vector3, b: Vector3) -> bool:
	_ray.from = Vector3(b.x, a.y + 0.5, b.z)
	_ray.to = Vector3(b.x, b.y - 0.3, b.z)
	var hit: Dictionary = _space.intersect_ray(_ray)
	if hit.is_empty():
		return false                  # no floor at all at the target column — not a real landing
	return absf((hit.position as Vector3).y - b.y) <= STEP_HEIGHT


## True when the hull sweeps clear horizontally from a to b, tested on the higher floor (after any
## step-up) so low steppable lips don't block but real walls do.
##
## The sweep rides a STEP above that floor, not 5cm above it, because feet don't graze surfaces —
## a walking body steps over anything up to step_height. At +0.05 the hull skims the floor itself
## and the trace clips it: measured on ww_ravine's grail ramp, the identical pair reported 0.90 of
## the way uphill and 1.00 downhill, so every uphill step of a continuous ramp was rejected and the
## whole floor it leads to was pruned as unreachable. The head stays at floor + STAND_HEIGHT, so a
## real lintel or low ceiling still blocks.
func _sweep_clear(a: Vector3, b: Vector3) -> bool:
	var base_y: float = maxf(a.y, b.y) + STEP_HEIGHT
	_sweep_shape.transform = Transform3D(Basis.IDENTITY,
		Vector3(a.x, base_y + (STAND_HEIGHT - STEP_HEIGHT) * 0.5, a.z))
	_sweep_shape.motion = Vector3(b.x - a.x, 0, b.z - a.z)
	var res := _space.cast_motion(_sweep_shape)
	# cast_motion returns [safe, unsafe] fractions of `motion`; ~1.0 safe = travelled unobstructed.
	return res.size() == 2 and res[0] >= 0.99
