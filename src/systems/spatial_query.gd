extends Node
## What the world and the SceneTree are asked about a point: where a node's collision really is,
## which members of a group are near one, what liquid or hazard volume contains it, and what floor
## is under it. Split out of entity_util.gd.

# Reused across the point queries below so per-frame callers (the head-in-water check) don't
# allocate a query object every frame. Only position and mask vary, so the rest is set once.
var _point_query := PhysicsPointQueryParameters3D.new()


func _init() -> void:
	_point_query.collide_with_areas = true
	_point_query.collide_with_bodies = false


## The space to query for `node`, or null when it is not in the tree — the guard every trace
## needs before it reaches for direct_space_state.
func space_for(node: Node3D) -> PhysicsDirectSpaceState3D:
	var world := node.get_world_3d() if node.is_inside_tree() else null
	return world.direct_space_state if world else null


## The volumes on `mask` containing `pos`, at most `max_hits` of them.
func _point_hits(node: Node3D, pos: Vector3, mask: int, max_hits: int) -> Array[Dictionary]:
	_point_query.position = pos
	_point_query.collision_mask = mask
	return node.get_world_3d().direct_space_state.intersect_point(_point_query, max_hits)


## GoldSrc monsters step over knee-high geometry; a cylinder body would stall against it. Lift
## the body by the step height when its path is blocked at foot level but clear above — floor
## snapping pulls it straight back down when the lift wasn't needed.
func step_up(body: CharacterBody3D, motion: Vector3, step_height: float) -> void:
	if not body.is_on_floor() or not body.test_move(body.global_transform, motion):
		return
	var lifted := body.global_transform
	lifted.origin.y += step_height
	if body.test_move(lifted, motion):
		return  # blocked up there too — a real wall
	body.global_position.y += step_height


## World-space center of the collision-shape AABB spanning `node` and its descendants.
## Brush entities (func_breakable, movers) keep origin at the world origin with geometry in
## child shapes, so global_position is useless for distance — use this instead. Cached in the
## node's local frame after first computation (O(1) for AoE/homing hot loops).
## Shape-less nodes fall back to the feet+PLAYER_CENTER estimate.
func collision_center(node: Node3D) -> Vector3:
	# has_meta first: get_meta(key, null) can't distinguish absent from an explicit null default.
	var local
	if node.has_meta(&"_collision_center_local"):
		local = node.get_meta(&"_collision_center_local")
	else:
		var box = _collision_aabb(node)
		local = Vector3.INF if box == null else node.to_local((box as AABB).get_center())
		node.set_meta(&"_collision_center_local", local)
	if local == Vector3.INF:
		return node.global_position + GameConsts.PLAYER_CENTER
	return node.global_transform * local


## Union AABB (world space) of every CollisionShape3D under `root`, or null if none.
func _collision_aabb(root: Node) -> Variant:
	var box := AABB()
	var seeded := false
	var stack: Array = [root]
	while not stack.is_empty():
		var n = stack.pop_back()
		if n is CollisionShape3D and (n as CollisionShape3D).shape:
			var cs := n as CollisionShape3D
			var world: AABB = cs.global_transform * GeomUtil.shape_local_aabb(cs.shape)
			box = world if not seeded else box.merge(world)
			seeded = true
		for c in n.get_children():
			stack.append(c)
	if seeded:
		return box
	return null


# --- Group proximity index ---
# Most walks of "damageable" are a sphere query wearing a group scan: the whole group is listed
# and all but the few members inside a radius thrown away. Bucketing the group by coarse cell
# turns that into a visit of the cells the sphere touches.
#
# The buckets are rebuilt, not maintained. A damageable moves every tick, so a maintained cell
# would want a hook on every mover; a rebuild costs about 1.3x the walk each caller used to do
# alone, so a frame nobody asks pays nothing and a frame with two or more askers wins. The
# rebuild re-reads the group, and the stamped member count forces another when something has
# joined or left since — so membership stays the SceneTree's, at the price of a second rebuild
# in a frame that kills someone between two queries (apply_aoe_damage then apply_aoe_knockback).
# A join and a leave in the same frame cancel out in the count and leave the query a frame
# behind, which is the resolution the cached centres have anyway.
#
# Keyed on collision_center, which is what decides who can use this: a caller measuring a raw
# global_position (cockleburr's trap, grimfeast's corpses) would get a different answer, since on
# a brush entity the two disagree by the whole map.
#
# What it is worth depends entirely on how big the group is, and this game's is small: a server
# full of bots holds 8 damageables on ww_2fort/keep/golem (the players, nothing else) and 14-16
# on the breakable-heavy maps (ww_castle, ww_library) before a single summon joins. Measured
# against the walk over one frame's worth of real queries: 0.91x at 10 members, 0.76x at 20,
# 0.58x at 40, 0.53x at 80. _PROX_CELL is what decides the small end — at 4 m, 10 members cost
# 1.04x, i.e. the index lost to the walk in exactly the case most matches are in.
const _PROX_CELL := 8.0
## A cached centre is up to a frame old, so the pad covers a tick of travel: sv_maxvelocity
## (addons/pmove/movement_config.gd) is 50 m/s per axis, which is 0.83 m at 60 Hz. A teleport is
## not covered and cannot be — the candidates are a superset of the true sphere by this much, and
## the caller's own test, against the live centre, still decides.
const _PROX_SLACK := 1.0
const _NO_NODES := []              # probing an empty cell, without a null check at the hot site
var _prox_stamp: Dictionary = {}   # group -> Vector2i(physics frame, member count)
var _prox_cells: Dictionary = {}   # group -> {Vector3i: Array of members}


## Members of `group` that could be within `radius` of `pos`. A superset, by up to a cell plus
## _PROX_SLACK: the caller keeps its own exact distance test, and gets what the group walk it
## replaces gave it — live, in-tree nodes, in a fresh array it is free to outlive.
##
## Array[Node] and not Array: erasing the element type puts every caller's loop back through a
## Variant and costs a quarter of the saving.
func nodes_near(group: StringName, pos: Vector3, radius: float) -> Array[Node]:
	return nodes_near_segment(group, pos, pos, radius)


## Same, for the capsule a projectile or a leap swept this tick: members that could be within
## `radius` of the segment from `from` to `to`.
func nodes_near_segment(group: StringName, from: Vector3, to: Vector3, radius: float) -> Array[Node]:
	var tree := get_tree()
	var count := tree.get_node_count_in_group(group)
	var pad := Vector3.ONE * (radius + _PROX_SLACK)
	var lo := _prox_key(from.min(to) - pad)
	var hi := _prox_key(from.max(to) + pad)
	var span := hi - lo + Vector3i.ONE

	# More cells to probe than members to walk: take the walk. A probe is far cheaper than a
	# walked member, so one probe per member looks over-cautious — but the grid only earns its
	# probes where it can prune, and it cannot when the group is bunched into a few cells. This
	# bound is what caps the loss there. Every sight scan and the 10 m harvest take this branch
	# at any group size this game reaches.
	if span.x * span.y * span.z > count:
		return tree.get_nodes_in_group(group)

	var cells := _prox_buckets(group, count)
	var out: Array[Node] = []
	for x in range(lo.x, hi.x + 1):
		for y in range(lo.y, hi.y + 1):
			for z in range(lo.z, hi.z + 1):
				# A bucket outlives the frame it was keyed in, so a member freed since then
				# must not reach a caller that never asked for the index.
				for node in cells.get(Vector3i(x, y, z), _NO_NODES):
					if is_instance_valid(node) and node.is_inside_tree():
						out.append(node)
	return out


func _prox_buckets(group: StringName, count: int) -> Dictionary:
	var stamp := Vector2i(Engine.get_physics_frames(), count)
	if _prox_stamp.get(group) == stamp:
		return _prox_cells[group]

	var cells: Dictionary = {}
	for node in get_tree().get_nodes_in_group(group):
		if not (node is Node3D) or not node.is_inside_tree():
			continue  # guards collision_center, which needs a global transform
		var key := _prox_key(collision_center(node))
		if cells.has(key):
			cells[key].append(node)
		else:
			cells[key] = [node]
	_prox_stamp[group] = stamp
	_prox_cells[group] = cells
	return cells


func _prox_key(pos: Vector3) -> Vector3i:
	return Vector3i(floori(pos.x / _PROX_CELL), floori(pos.y / _PROX_CELL),
			floori(pos.z / _PROX_CELL))


## True if `pos` is inside a water/lava/slime volume. `node` supplies the world.
## Lava and slime register on MASK_WATER too (see func_water.gd).
func is_point_in_water(node: Node3D, pos: Vector3) -> bool:
	return not _point_hits(node, pos, GameConsts.MASK_WATER, 1).is_empty()


## The trigger_hurt whose volume contains `pos`, or null. The innermost thing a hurt volume can
## do is touch what is in it, and an Area3D only touches colliders — a projectile is a bare Node3D,
## so it cannot be touched and has to come asking instead (see Projectile._check_hazards). The
## volumes carry MASK_HAZARD for exactly this question; overlapping ones resolve to the first hit.
func hurt_volume_at(node: Node3D, pos: Vector3) -> Node:
	for hit in _point_hits(node, pos, GameConsts.MASK_HAZARD, 4):
		var volume: Node = hit.collider.get_meta(&"hurt_volume", null)
		if volume and is_instance_valid(volume):
			return volume
	return null


## Which liquid contains `pos`, as a GameConsts.Liquid value. Lava and slime volumes also carry
## MASK_WATER (they swim the same), so the extra layers are the only thing that tells them
## apart — which is why this asks for all three and reads the collider's own layer back.
## Overlapping volumes resolve to the more dangerous one; a map that stacks lava into water
## means the lava.
func liquid_at_point(node: Node3D, pos: Vector3) -> GameConsts.Liquid:
	var hits := _point_hits(node, pos,
			GameConsts.MASK_WATER | GameConsts.MASK_LAVA | GameConsts.MASK_SLIME, 4)
	var found := GameConsts.Liquid.NONE
	for hit in hits:
		var layer: int = hit.collider.collision_layer
		if layer & GameConsts.MASK_LAVA:
			return GameConsts.Liquid.LAVA
		if layer & GameConsts.MASK_SLIME:
			found = GameConsts.Liquid.SLIME
		elif found == GameConsts.Liquid.NONE:
			found = GameConsts.Liquid.WATER
	return found


## Ground height under `pos` for something being put down — a dropped flag, a model placed on
## spawn — or INF when nothing is under it within 200 m.
##
## Three callers hand-rolled this same trace, which is how the hit_from_inside decision below
## came to be written (and commented) three times. It is deliberately NOT hit_from_inside: the
## question is "what floor is BELOW me", and hop reports a surface a ray starts inside, so asking
## for those stops the trace at the drop point and leaves the item in the wall it was dropped in.
## hit_back_faces is on because a drop spot can be under a one-sided brush.
func ground_y_below(node: Node3D, pos: Vector3, exclude_body: Node = null) -> float:
	var space := space_for(node)
	if space == null:
		return INF
	var query := PhysicsRayQueryParameters3D.create(pos + Vector3(0, 0.5, 0),
			pos + Vector3(0, -200, 0))
	query.collision_mask = GameConsts.MASK_WORLD
	query.hit_back_faces = true
	# The carrier's own collider may still be enabled (it is disabled via set_deferred) and
	# would otherwise block the ray.
	if exclude_body is CollisionObject3D:
		query.exclude = [exclude_body.get_rid()]
	var hit := space.intersect_ray(query)
	return INF if hit.is_empty() else float(hit.position.y) + 0.05
