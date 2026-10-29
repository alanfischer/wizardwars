extends RefCounted
## No class_name — see README, "class_name and preload". Reference via preload:
##   const WaypointGraph = preload("res://src/bot/waypoint_graph.gd")
## Loads the original mod's hand-authored HPB-bot waypoint files (maps/waypoints/<map>.HPB_wpt)
## and exposes them as a navigation graph for bots. Each edge is a connection a human confirmed
## traversable (stairs, lifts, jumps, routes to capture points) that a baked navmesh can't recover.
##
## File format (HPB bot, little-endian — see the original WAYPOINT.CPP/.H):
##   header: char filetype[8]="HPB_bot\0", int version, int flags, int count, char mapname[32]
##   count × waypoint: int flags, float origin[3]   (GoldSrc units, Z-up)
##   count × paths:    short num, num × short neighbour_index
##
## Coordinate transform to Godot (verified exactly against the flag entities):
##   godot = Vector3(-x, z, y) * SCALE_FACTOR

const SCALE := 0.025  # GameConsts.SCALE_FACTOR — GoldSrc units → metres
## An HPB waypoint records the player ORIGIN that dropped it, and a GoldSrc origin is the centre of
## the 72-unit standing hull, not the feet. Baked graphs are floor-level and so is a bot's own
## global_position, so the whole hand file has to come down half a hull or every node reads as
## chest-high: on any climb the bot is then "below its target" and re-routes instead of walking up.
const HULL_HALF := 0.9  # movement_config.stand_height * 0.5

# HPB flag bits we act on (the format defines others — crouch/ladder/lift/team/etc. — unused here).
const FL_CROUCH := 1 << 3
## The editor tombstones a removed waypoint in place rather than renumbering the file: flag bit 31,
## origin zeroed. They must never become graph nodes — a pile of them at the world origin sits in
## the middle of most maps and swallows get_closest_point for anyone standing near it.
const FL_DELETED := 1 << 31
const FL_CAP := 1 << 11
const FL_DEFEND := 1 << 12
const FL_JUMP := 1 << 18
# Baker-only, marks a synthetic node on a func_ladder's axis. The bot climbs by pressing into
# the rungs + looking at the target rather than steering to the top landing (which would push
# it off), and advances off this node on 3D proximity so a vertical climb isn't skipped.
const FL_LADDER := 1 << 19
## Baker-only, marks a lift deck at one of its two stops, and (as an EDGE flag) the ride between
## them. A ride is the one leg of a route where standing still is correct, so the bot has to know
## it is on one: see bot_brain's riding state, which holds position on the deck and muzzles every
## anti-stuck watchdog until the deck arrives.
const FL_LIFT := 1 << 20
## Nodes to be steered at exactly, with none of the lateral roll that keeps bots off a single rail:
## the move through them is a jump, a duck or a climb, and all three are narrower than the roll.
const FL_PRECISE := FL_JUMP | FL_CROUCH | FL_LADDER

var loaded := false
var positions: PackedVector3Array = PackedVector3Array()
var node_flags: PackedInt32Array = PackedInt32Array()
# FL_DEFEND = spot to defend / bring the enemy flag to (CTF cap dropoff). FL_CAP = contested
# control-point zone.
var cap_positions: PackedVector3Array = PackedVector3Array()
var defend_positions: PackedVector3Array = PackedVector3Array()
var _edges: Array = []  # directed (from,to) pairs, kept so save_generated can re-serialize them
var edge_flags: Dictionary = {}  # Vector2i(from,to) -> flags; empty for hand files (see GEN_VERSION)
var _astar := AStar3D.new()
# Cache of what the AStar3D's weights currently hold, so an identical query can skip the O(n)
# re-stamp. -1.0 means nothing stamped yet (a real perturb is never negative).
## Route variety (see path_ids). The A* perturbation is hashed per REGION, not per waypoint, and
## that distinction is the whole feature. Per-node noise averages out: N independent draws sum to a
## spread growing as sqrt(N) against a path cost growing as N, so on a 100-node route a perturb of
## 0.7 moves the total by only ~1.5% and the shorter door wins every single time. Hashing a coarse
## cell instead gives one shared draw to a whole doorway and its approach, so a route crossing a
## handful of regions gets a handful of large draws rather than a hundred tiny ones — and bots
## actually pick different ways in. A bot holds its salt for a life, so the choice is consistent
## while it runs rather than dithering at every re-path.
const REGION := 12.0              # metres per variety region — about a room / an approach
var _region_of: PackedInt32Array = PackedInt32Array()   # node id -> region hash key
var _stamp_perturb := -1.0
var _stamp_salt := 0
var _stamp_avoid := {}
## Weakly-connected component id per node, and whether the node has any edge at all. AStar3D's
## get_closest_point knows nothing about connectivity: it will happily hand back a node with no
## edges, or one in a different component from the other end of the query, and get_id_path then
## returns nothing. On ww_wolteg that is the whole map — the hand file covers one corridor and
## leaves a single edgeless node stranded on the other side, so every bot spawning over there
## snapped to it and no bot ever got a route (measured: 92.5% of ticks with no route at all).
var _component: PackedInt32Array = PackedInt32Array()
var _linked: PackedByteArray = PackedByteArray()
# The nodes _nearest_reachable may answer with, collected once: every linked node, and the same
# split by component. Rebuilt with _component.
var _linked_ids: PackedInt32Array = PackedInt32Array()
var _comp_members := {}
# Diagnostics for the re-snap above: how often each end had to be moved, and how far.
var resnap_dest := 0
var resnap_src := 0
var resnap_dist := 0.0



## Load maps/waypoints/<map_name>.HPB_wpt. Returns false if there's no waypoint file.
func load_map(map_name: String) -> bool:
	var path := "res://maps/waypoints/%s.HPB_wpt" % map_name
	if not FileAccess.file_exists(path):
		return false
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	f.big_endian = false
	var magic := f.get_buffer(8).get_string_from_ascii()
	if not magic.begins_with("HPB_bot"):
		push_warning("[Waypoints] %s: bad magic '%s'" % [map_name, magic])
		return false
	f.get_32()  # version
	f.get_32()  # file flags
	var n := f.get_32()
	f.get_buffer(32)  # mapname
	positions.resize(n)
	node_flags.resize(n)
	var live := []
	live.resize(n)
	var dead := 0
	for i in n:
		var fl := f.get_32()
		var x := f.get_float()
		var y := f.get_float()
		var z := f.get_float()
		positions[i] = Vector3(-x, z, y) * SCALE - Vector3(0.0, HULL_HALF, 0.0)
		node_flags[i] = fl
		live[i] = not (fl & FL_DELETED) and Vector3(x, y, z) != Vector3.ZERO
		if not live[i]:
			dead += 1
			continue
		if fl & FL_CAP:
			cap_positions.append(positions[i])
		if fl & FL_DEFEND:
			defend_positions.append(positions[i])
		_astar.add_point(i, positions[i])
	var pairs := {}
	for i in n:
		var cnt := f.get_16()
		for _j in cnt:
			var idx := f.get_16()
			if idx >= 0 and idx < n and idx != i and live[i] and live[idx]:
				pairs[Vector2i(i, idx)] = true
	f.close()
	var repaired := _symmetrize(pairs)
	for e in pairs:
		_astar.connect_points(e.x, e.y, false)  # HPB edges are directed
		_edges.append(e)
	_build_regions()
	_build_components()
	loaded = true
	Log.info("[Waypoints] Loaded %s: %d waypoints (%d tombstoned), %d edges (+%d return)"
			% [map_name, n - dead, dead, pairs.size(), repaired])
	return true


## The hand files were authored a waypoint at a time and their one-way edges are mostly slips, not
## intent: on ww_2fort a single unpaired edge left team 2's own spawn room enterable by nobody, so
## no bot could ever carry a grail home to it. Give every edge its return leg unless the forward
## leg is a real drop, which is the one case a human plausibly meant to be one-way. Returns the
## number added.
func _symmetrize(pairs: Dictionary) -> int:
	const MAX_CLIMB_BACK := 1.5  # metres; a fall further than this has no walk-up reverse
	var added := 0
	for e in pairs.keys():
		var back := Vector2i(e.y, e.x)
		if pairs.has(back):
			continue
		if positions[e.y].y < positions[e.x].y - MAX_CLIMB_BACK:
			continue
		pairs[back] = true
		added += 1
	return added


## Load a baked graph (maps/waypoints/<map>.gen_wpt) produced by WaypointBaker for maps with no
## hand-authored HPB file. Same in-memory shape as load_map; positions are already in Godot space
## (no GoldSrc transform). Baked graphs carry no FL_CAP/FL_DEFEND nodes — nothing in the collision
## world says where a flag is brought — so control-point contest and the CTF cap dropoff still need
## the hand files.
const GEN_MAGIC := "WWGENWPT"
## v2 added a flags word per edge. FL_JUMP belongs on the EDGE, not the node: a ledge-top waypoint
## is reached by a jump from below AND by a plain walk from along the top, and a node flag makes a
## bot hop on both approaches — pointlessly on flat ground, and straight off the ledge on a narrow
## one. Hand-authored HPB files have no edge flags, so those keep using node flags.
const GEN_VERSION := 2


func load_generated(map_name: String) -> bool:
	var path := "res://maps/waypoints/%s.gen_wpt" % map_name
	if not FileAccess.file_exists(path):
		return false
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	f.big_endian = false
	if f.get_buffer(8).get_string_from_ascii() != GEN_MAGIC:
		push_warning("[Waypoints] %s.gen_wpt: bad magic" % map_name)
		return false
	var version := f.get_32()
	var n := f.get_32()
	positions.resize(n)
	node_flags.resize(n)
	for i in n:
		var x := f.get_float()
		var y := f.get_float()
		var z := f.get_float()
		positions[i] = Vector3(x, y, z)
		node_flags[i] = f.get_32()
		_astar.add_point(i, positions[i])
	var edge_count := f.get_32()
	for _e in edge_count:
		var a := f.get_32()
		var b := f.get_32()
		var ef := f.get_32() if version >= 2 else 0
		if a >= 0 and a < n and b >= 0 and b < n and a != b:
			_astar.connect_points(a, b, false)  # baked edges are directed
			# Recorded as well as connected, the way load_map does it: _edges is what save_generated
			# re-serializes and what edges() hands a caller rebuilding a restricted copy. Without
			# this a loaded graph reported no edges at all, and saving one back wrote none.
			_edges.append(Vector2i(a, b))
			if ef != 0:
				edge_flags[Vector2i(a, b)] = ef
	f.close()
	_build_regions()
	_build_components()
	loaded = true
	Log.info("[Waypoints] Loaded baked %s: %d waypoints, %d edges" % [map_name, n, edge_count])
	return true


## Populate the graph from a baker's arrays so it can be queried or serialized with save_generated.
func build_from(p_positions: PackedVector3Array, p_flags: PackedInt32Array,
		p_edges: Array, p_edge_flags: Dictionary = {}) -> void:
	positions = p_positions
	node_flags = p_flags
	_edges = p_edges
	edge_flags = p_edge_flags
	for i in positions.size():
		if node_flags[i] & FL_CAP:
			cap_positions.append(positions[i])
		if node_flags[i] & FL_DEFEND:
			defend_positions.append(positions[i])
		_astar.add_point(i, positions[i])
	_build_regions()
	for e in p_edges:
		_astar.connect_points(e.x, e.y, false)
	_build_components()
	loaded = true


## Serialize a built graph to maps/waypoints/<map>.gen_wpt (see load_generated for the format).
func save_generated(path: String) -> Error:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.big_endian = false
	f.store_buffer(GEN_MAGIC.to_ascii_buffer())
	f.store_32(GEN_VERSION)
	f.store_32(positions.size())
	for i in positions.size():
		f.store_float(positions[i].x)
		f.store_float(positions[i].y)
		f.store_float(positions[i].z)
		f.store_32(node_flags[i])
	f.store_32(_edges.size())
	for e in _edges:
		f.store_32(e.x)
		f.store_32(e.y)
		f.store_32(edge_flags.get(e, 0))
	f.close()
	return OK


## A* path (as waypoint ids) from the nearest waypoint to `from_pos` to the nearest to `to_pos`.
## Empty if either end has no waypoint or no route exists.
##
## `perturb` > 0 scales each waypoint's weight by a pseudo-random factor in [1, 1+perturb] derived
## deterministically from `salt`, so comparably-priced alternate routes split by salt but a given
## salt always picks the same one (no flip-flopping on a re-query).
## `avoid` maps node id -> extra weight_scale: a bot stalling on one route (e.g. a ladder it can't
## climb) piles penalty on those nodes so re-paths swing elsewhere. Soft push, not a wall — if
## avoided nodes are the only route, A* still takes them.
func path_ids(from_pos: Vector3, to_pos: Vector3, perturb := 0.0, salt := 0, avoid := {}) -> PackedInt64Array:
	if positions.is_empty():
		return PackedInt64Array()
	# The AStar3D is shared by every bot, so weights belong to whoever queried last and must be
	# (re)stamped. That's O(n), so skip it when the weights already match this query (the common
	# case: a bot re-querying a drifting objective holds its salt, see bot_brain).
	if perturb <= 0.0:
		salt = 0  # unperturbed queries all stamp the same
	if perturb != _stamp_perturb or salt != _stamp_salt or not _avoid_matches(avoid):
		for i in positions.size():
			if not _astar.has_point(i):
				continue  # tombstoned hand-file waypoint, never added
			var w := 1.0
			if perturb > 0.0:
				# Fall back to the node id when the region table is missing: losing route variety
				# is a cosmetic regression, while an out-of-range index throws and leaves every
				# bot on the map without a route at all (it did — the hand-file loader did not
				# build the table, so all 11 .HPB_wpt maps had bots standing still in spawn).
				w += perturb * _hash01(salt, _region_of[i] if i < _region_of.size() else i)
			if not avoid.is_empty() and avoid.has(i):
				w += avoid[i]
			_astar.set_point_weight_scale(i, w)
		_stamp_perturb = perturb
		_stamp_salt = salt
		_stamp_avoid = avoid.duplicate()
	var a := _astar.get_closest_point(from_pos)
	var b := _astar.get_closest_point(to_pos)
	if a < 0 or b < 0:
		return PackedInt64Array()
	# Snap to somewhere a route can actually start and end (see _component). The DESTINATION is
	# resolved first and wins: where the bot has to get to is the fixed half of the question, and
	# if the two ends disagree the useful answer is a route toward the objective's own component,
	# not a route to whatever happens to share the bot's.
	if not _linked[b]:
		var b2 := _nearest_reachable(to_pos, -1)
		if b2 < 0:
			return PackedInt64Array()
		resnap_dest += 1
		resnap_dist += positions[b].distance_to(positions[b2])
		b = b2
	if _component[a] != _component[b]:
		var a2 := _nearest_reachable(from_pos, _component[b])
		if a2 < 0:
			return PackedInt64Array()
		resnap_src += 1
		resnap_dist += positions[a].distance_to(positions[a2])
		a = a2
	return _astar.get_id_path(a, b)


## Nearest node to `pos` that has at least one edge, restricted to component `comp` (-1 = any).
## Scans the candidate list _build_components already collected rather than every node: the
## conditions that get us here are properties of the MAP, not of one unlucky query — a bot whose
## spawn component differs from its objective's takes this path on every re-path for the whole
## match, so "rare" was wrong and a full pass over a 14k-node graph 15x a second was the cost.
func _nearest_reachable(pos: Vector3, comp: int) -> int:
	var best := -1
	var best_d := INF
	var cands: PackedInt32Array = _comp_members.get(comp, PackedInt32Array()) \
			if comp >= 0 else _linked_ids
	for i in cands:
		var d := pos.distance_squared_to(positions[i])
		if d < best_d:
			best_d = d
			best = i
	return best


## Label every node with its weakly-connected component, so path_ids can tell "no route exists"
## from "you asked the wrong node". Weak (edge direction ignored) on purpose: it is the cheap
## NECESSARY condition — two nodes in different weak components can never be connected by any
## directed path, so rejecting on it never refuses a route that existed. Within one component a
## one-way edge can still leave b unreachable from a; that is rarer, and get_id_path returning
## empty is the honest answer there.
func _build_components() -> void:
	var n := positions.size()
	_component = PackedInt32Array()
	_component.resize(n)
	_linked = PackedByteArray()
	_linked.resize(n)
	for i in n:
		_component[i] = i
		_linked[i] = 0
	for i in n:
		if not _astar.has_point(i):
			continue
		for j in _astar.get_point_connections(i):
			_linked[i] = 1
			_linked[j] = 1
			_union_comp(i, j)
	var sizes := {}
	_linked_ids = PackedInt32Array()
	_comp_members = {}
	for i in n:
		_component[i] = _find_comp(i)
		if _linked[i]:
			sizes[_component[i]] = int(sizes.get(_component[i], 0)) + 1
			_linked_ids.append(i)
			if not _comp_members.has(_component[i]):
				_comp_members[_component[i]] = PackedInt32Array()
			_comp_members[_component[i]].append(i)
	var stranded := 0
	for i in n:
		if _astar.has_point(i) and not _linked[i]:
			stranded += 1
	if sizes.size() > 1 or stranded > 0:
		var counts: Array = sizes.values()
		counts.sort()
		counts.reverse()
		Log.info("[Waypoints] %d component(s) %s, %d stranded node(s)" % [
				sizes.size(), str(counts.slice(0, 5)), stranded])


func _find_comp(x: int) -> int:
	var r := x
	while _component[r] != r:
		r = _component[r]
	while _component[x] != r:   # path-compress
		var nxt := _component[x]
		_component[x] = r
		x = nxt
	return r


func _union_comp(a: int, b: int) -> void:
	var ra := _find_comp(a)
	var rb := _find_comp(b)
	if ra != rb:
		_component[ra] = rb


## True when `avoid` holds exactly the penalties currently stamped.
func _avoid_matches(avoid: Dictionary) -> bool:
	if avoid.size() != _stamp_avoid.size():
		return false
	for k in avoid:
		if _stamp_avoid.get(k) != avoid[k]:
			return false
	return true


## Bucket every waypoint into a coarse spatial region, so the route perturbation can vary a whole
## approach at a time instead of one node at a time. Y is included at a coarser scale than XZ: two
## floors of the same stairwell are different ways in and should be able to disagree.
func _build_regions() -> void:
	_region_of.resize(positions.size())
	for i in positions.size():
		var p: Vector3 = positions[i]
		var c := Vector3i(floori(p.x / REGION), floori(p.y / (REGION * 0.5)), floori(p.z / REGION))
		_region_of[i] = hash(c)


## Deterministic per-(salt, waypoint) value in [0, 1].
static func _hash01(salt: int, i: int) -> float:
	return float(hash(Vector2i(salt, i)) & 0xFFFF) / 65535.0


## Connected-component sizes (root node id -> size). Baker diagnostic: a healthy graph is one big
## component; many small ones mean sampling failed to link areas. Reads the labelling
## _build_components did at load, rather than running a second union-find over _edges — that copy
## also answered a slightly different question, since it joined components through edges naming
## tombstoned points that _astar never got and so could never route along.
func component_sizes() -> Dictionary:
	var sizes := {}
	for i in positions.size():
		if not _astar.has_point(i):
			continue  # tombstoned hand-file waypoint; not part of any component
		sizes[_component[i]] = int(sizes.get(_component[i], 0)) + 1
	return sizes


## node id -> component root id, the per-node companion to component_sizes.
func node_component_map() -> Dictionary:
	var out := {}
	for i in positions.size():
		if _astar.has_point(i):
			out[i] = _component[i]
	return out


func defend_nearest(near_pos: Vector3) -> Vector3:
	return _nearest_of(defend_positions, near_pos)


func cap_nearest(near_pos: Vector3) -> Vector3:
	return _nearest_of(cap_positions, near_pos)


func _nearest_of(pts: PackedVector3Array, near_pos: Vector3) -> Vector3:
	var best := Vector3.INF
	var best_d := INF
	for p in pts:
		var d := near_pos.distance_squared_to(p)
		if d < best_d:
			best_d = d
			best = p
	return best


func position_of(id: int) -> Vector3:
	return positions[id]


func flags_of(id: int) -> int:
	return node_flags[id]


## Flags for traversing `a` -> `b`. 0 when the edge carries none, and always 0 for a hand-authored
## HPB graph — callers fall back to the destination's node flags there (see GEN_VERSION).
## The directed (from,to) pairs this graph was built from, for a caller rebuilding a restricted copy
## of it (see MonsterNav, which drops everything a walker cannot perform).
func edges() -> Array:
	return _edges


func flags_of_edge(a: int, b: int) -> int:
	return edge_flags.get(Vector2i(a, b), 0)


## True when this graph carries per-edge flags at all (a baked v2 file), i.e. the destination's
## node flags are NOT the authority on whether the move is a jump.
func has_edge_flags() -> bool:
	return not edge_flags.is_empty()
