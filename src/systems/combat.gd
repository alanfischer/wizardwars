extends Node
## Aim, traces and damage: where a shot starts, what it hits, and who takes what from it.
## Everything a weapon, projectile or summon does between "the caster pressed fire" and "the
## target's take_damage ran". Was the largest third of entity_util.gd.

# A shot leaves the eye a little low: GoldSrc's own view offset, shared by the projectile spawn
# point and the beam-origin fallback so the two cannot drift.
const _EYE_DROP := Vector3(0, -8 * GameConsts.SCALE_FACTOR, 0)

# CBaseMonster::TakeDamage/DamageForce: a blow shoves its victim 5 u/s per point (a player's
# hull), capped at 1000, away from an inflictor taken to sit 10 units low so bodies lift.
const _DAMAGE_FORCE_PER_POINT := 5.0 * GameConsts.SCALE_FACTOR
const _DAMAGE_FORCE_MAX := 1000.0 * GameConsts.SCALE_FACTOR
const _INFLICTOR_DROP := Vector3(0, -10 * GameConsts.SCALE_FACTOR, 0)

# Reused for find_homing_target's visibility ray: it runs over the whole damageable group on
# every monster's and homing projectile's think. Safe to share — `from`/`to`/`exclude` are all
# written per candidate, and collision_mask is the same constant on every call.
var _homing_ray_query := PhysicsRayQueryParameters3D.new()
var _homing_excludes: Array[RID] = []
# Same again for los_blocked, which three of the damageable sweeps below call per candidate.
var _los_ray_query := PhysicsRayQueryParameters3D.new()
var _los_excludes: Array[RID] = []
## Visibility rays find_homing_target has issued; zeroed and read by test_homing_target and
## src/tests/homing_probe.tscn.
var homing_ray_count := 0
## Where the blow being dealt right now comes from, when that isn't the attacker (a blast, a
## projectile) — GoldSrc's pevInflictor. INF = the attacker. Read by damage_force.
var _inflictor_pos := Vector3.INF


## Resolve aim origin and direction from an attacker node.
## aim_from: explicit world-space origin (e.g. VR hand position); Vector3.INF = derive automatically.
## aim_dir: explicit direction (e.g. from network sync); Vector3.ZERO = derive automatically.
## Returns {from: Vector3, aim_dir: Vector3, camera: Camera3D or null}.
func get_aim(attacker: Node3D, aim_from := Vector3.INF, aim_dir := Vector3.ZERO) -> Dictionary:
	var camera: Camera3D = attacker._active_camera()
	var from: Vector3
	var out_dir: Vector3
	if aim_dir.length_squared() > 0.001:
		out_dir = aim_dir.normalized()
		if aim_from.is_finite():
			from = aim_from
		elif camera:
			# Prefer the real camera over eye-height reconstruction, which can't
			# track crouch when there is no server movement.
			from = camera.global_position
		else:
			from = _eye_origin(attacker)
	elif XRManager.is_vr and XRManager.hand_tracking:
		var xr_right = attacker.get("xr_right")
		if xr_right and is_instance_valid(xr_right):
			from = xr_right.global_position
			out_dir = -xr_right.global_transform.basis.z
		elif camera:
			from = camera.global_position
			out_dir = -camera.global_transform.basis.z
		else:
			from = attacker.global_position
			out_dir = -attacker.global_transform.basis.z
	elif camera:
		from = camera.global_position
		out_dir = -camera.global_transform.basis.z
	else:
		from = _eye_origin(attacker)
		# Remote players have no camera — build aim from yaw + synced pitch
		var yaw_dir := -attacker.global_transform.basis.z
		var pitch: float = attacker.get("sync_pitch") if attacker.get("sync_pitch") != null else 0.0
		out_dir = yaw_dir.rotated(attacker.global_transform.basis.x, pitch)
	return {"from": from, "aim_dir": out_dir, "camera": camera}


## Eye height reconstructed for a body with no camera (a remote player, a bot puppet). Reads the
## crouch state off server movement so a ducking body shoots from the lower eye.
func _eye_origin(attacker: Node3D) -> Vector3:
	var eye_y := 1.6
	if attacker.has_method("get_server_movement"):
		var sm = attacker.get_server_movement()
		if sm:
			eye_y = sm.cfg.crouch_eye if sm.state.is_crouched else sm.cfg.stand_eye
	return attacker.global_position + Vector3(0, eye_y, 0)


## Compute projectile spawn position offset from aim origin.
func get_spawn_pos(aim: Dictionary) -> Vector3:
	var base: Vector3 = aim.from
	var aim_dir: Vector3 = aim.aim_dir
	if XRManager.is_vr and XRManager.hand_tracking:
		# Origin is already at the controller/hand; nudge just past the fingertip.
		return base + aim_dir * (8 * GameConsts.SCALE_FACTOR)
	return base + _EYE_DROP + aim_dir * (48 * GameConsts.SCALE_FACTOR)


## A beam leaves the caster's hand when the rig has that bone, and the camera when it does not.
func get_beam_origin(attacker: Node3D, aim: Dictionary, bone_name: String, fallback_bone := "") -> Vector3:
	var bone_pos = BoneUtil.get_bone_world_pos(attacker, bone_name, fallback_bone)
	if bone_pos != null:
		return bone_pos
	var base: Vector3 = aim.camera.global_position if aim.camera else aim.from
	return base + _EYE_DROP + aim.aim_dir * (8 * GameConsts.SCALE_FACTOR)


## Collect RIDs to exclude from a hitscan query so the ray hits per-bone hitbox
## Area3Ds instead of the player CharacterBody3D capsule. Excludes the attacker's
## entire collision-object tree plus every other damageable CharacterBody3D (their
## capsule — hitbox Area3Ds have their own RIDs and remain hittable).
func collect_hitscan_excludes(attacker: Node3D) -> Array[RID]:
	var excludes: Array[RID] = []
	_collect_collision_rids(attacker, excludes)
	# One player has two nodes sharing a peer_id (LocalPlayer + its server puppet HostBody);
	# exclude the other body's whole tree too, or the ray can land on our own head hitbox.
	# Every other player only excludes their capsule, so their hitbox Area3Ds stay hittable.
	var pid = attacker.get("peer_id")
	var own_pid := int(pid) if pid != null else 0
	for actor in attacker.get_tree().get_nodes_in_group("damageable"):
		if actor == attacker:
			continue
		var actor_pid = actor.get("peer_id")
		if own_pid > 0 and actor_pid != null and int(actor_pid) == own_pid:
			_collect_collision_rids(actor, excludes)
		elif actor is CharacterBody3D:
			excludes.append(actor.get_rid())
	return excludes


## Every collision RID a node owns, its descendants included — the body and any hitbox Area3Ds
## an .mdl brought with it. A summon that traces a ray out of its own chest needs all of them
## excluded, not just the body: the areas are children, so excluding the body alone leaves the
## thing shooting itself the moment its model's hitboxes cover the muzzle.
func collision_rids(node: Node) -> Array[RID]:
	var out: Array[RID] = []
	_collect_collision_rids(node, out)
	return out


func _collect_collision_rids(node: Node, excludes: Array[RID]) -> void:
	if node is CollisionObject3D:
		excludes.append(node.get_rid())
	for child in node.get_children():
		_collect_collision_rids(child, excludes)


## A caller's exclusion list with `rid` added, when it is one worth excluding.
func _exclude_list(extra: Array[RID], rid: RID) -> Array[RID]:
	var out: Array[RID] = extra.duplicate()
	if rid.is_valid():
		out.append(rid)
	return out


## Raycast from a point along aim_dir. Returns {result, impact_pos, space, to}.
## Pass hit_areas=true to include Area3D hitboxes (the per-bone MASK_HITBOX volumes).
## extra_excludes lets callers pass pre-built RID exclusion lists (e.g. from
## collect_hitscan_excludes) so player capsules don't occlude hitboxes.
func raycast_world(node: Node3D, from: Vector3, aim_dir: Vector3, range_dist: float, exclude_rid := RID(), mask := GameConsts.MASK_WORLD, hit_areas := false, extra_excludes: Array[RID] = []) -> Dictionary:
	var to := from + aim_dir * range_dist
	var space := SpatialQuery.space_for(node)
	if space == null:
		return {"result": {}, "impact_pos": to, "impact_norm": Vector3(), "space": null, "to": to}
	var params := PhysicsRayQueryParameters3D.create(from, to)
	params.collision_mask = mask
	params.collide_with_areas = hit_areas
	params.exclude = _exclude_list(extra_excludes, exclude_rid)
	var result := space.intersect_ray(params)
	var impact_pos: Vector3
	var impact_norm: Vector3
	if not result.is_empty():
		impact_pos = result.position
		impact_norm = result.normal
	else:
		impact_pos = to
		impact_norm = Vector3()
	return {"result": result, "impact_pos": impact_pos, "impact_norm": impact_norm, "space": space, "to": to}


## Hitscan trace shared by all direct-hit weapons. When ServerVars "hitscan_radius" > 0,
## follows GoldSrc's sv_clienttrace: a thin ray finds the world impact, then a fattened
## sphere sweep capped at that distance checks for a hitbox in the corridor — the sweep
## can't report a wall hit closer than the thin ray, so wide bullets can't eat corners.
## Falls through to a plain raycast when radius is 0.
func hitscan(node: Node3D, from: Vector3, aim_dir: Vector3, range_dist: float, exclude_rid := RID(), mask := GameConsts.MASK_HITSCAN, hit_areas := true, extra_excludes: Array[RID] = []) -> Dictionary:
	# Lag-comp: rewind targets to the shooter's shot time, query, restore.
	var saved := LagCompensation.rewind(node, from, aim_dir, range_dist)
	var result := _hitscan_query(node, from, aim_dir, range_dist, exclude_rid, mask, hit_areas, extra_excludes)
	LagCompensation.restore(saved)
	return result


func _hitscan_query(node: Node3D, from: Vector3, aim_dir: Vector3, range_dist: float, exclude_rid: RID, mask: int, hit_areas: bool, extra_excludes: Array[RID]) -> Dictionary:
	var radius: float = ServerVars.get_value("hitscan_radius", 0.0)
	if radius <= 0.0:
		return raycast_world(node, from, aim_dir, range_dist, exclude_rid, mask, hit_areas, extra_excludes)

	var entity_mask: int = mask & GameConsts.MASK_HITBOX
	var world_mask: int = mask & ~GameConsts.MASK_HITBOX
	var world_ray := raycast_world(node, from, aim_dir, range_dist, exclude_rid, world_mask, false, extra_excludes)
	var space: PhysicsDirectSpaceState3D = world_ray.space
	if entity_mask == 0 or space == null:
		return world_ray

	# Cap the fat sweep at the world impact so a grazed hitbox can't be reported
	# past a wall the thin ray already terminated against.
	var corridor_dist: float = range_dist
	if not world_ray.result.is_empty():
		corridor_dist = from.distance_to(world_ray.impact_pos)
	if corridor_dist <= 0.0:
		return world_ray

	var sphere := SphereShape3D.new()
	sphere.radius = radius
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = sphere
	params.transform = Transform3D(Basis.IDENTITY, from)
	params.motion = aim_dir * corridor_dist
	params.collision_mask = entity_mask
	params.collide_with_areas = hit_areas
	params.collide_with_bodies = true
	params.exclude = _exclude_list(extra_excludes, exclude_rid)

	var motion: PackedFloat32Array = space.cast_motion(params)
	# cast_motion returns [safe_fraction, unsafe_fraction] in [0,1]; safe<1 means a hit.
	if motion.is_empty() or motion[0] >= 1.0:
		return world_ray

	var hit_t: float = motion[0]
	# safe_fraction places the sphere center just before contact; advance by
	# radius so impact_pos lands at the surface (matters for hit-effect spawn).
	var hit_pos := from + aim_dir * minf(corridor_dist * hit_t + radius, corridor_dist)
	# Probe at unsafe_fraction so intersect_shape actually sees the contact.
	var probe_t := minf(motion[1] if motion.size() > 1 else hit_t + 0.001, 1.0)
	params.transform = Transform3D(Basis.IDENTITY, from + aim_dir * corridor_dist * probe_t)
	params.motion = Vector3.ZERO
	var hits := space.intersect_shape(params, 8)
	if hits.is_empty():
		return world_ray

	# Multiple shapes can overlap the probe transform (e.g. head + body Areas);
	# pick the one whose origin is nearest along the ray so headshots register
	# when the ray grazes both.
	var best: Dictionary = {}
	var best_dist := INF
	for h in hits:
		var c = h.get("collider")
		if not c is Node3D:
			continue
		var d := from.distance_to((c as Node3D).global_position)
		if d < best_dist:
			best_dist = d
			best = h
	if best.is_empty():
		return world_ray

	var result := {
		"collider": best.get("collider"),
		"collider_id": best.get("collider_id"),
		"rid": best.get("rid"),
		"shape": best.get("shape"),
		"normal": -aim_dir,
		"position": hit_pos,
	}
	return {"result": result, "impact_pos": hit_pos, "impact_norm": -aim_dir, "space": space, "to": world_ray.to}


## The body that answers for a collider: a hit lands on a per-bone hitbox Area3D or a shape
## child, and the thing that owns a health pool is somewhere above it. Null when nothing in
## the chain takes damage (world geometry).
func find_damageable(collider: Object) -> Node:
	var node := collider as Node
	while node:
		if node.has_method("take_damage"):
			return node
		node = node.get_parent()
	return null


## Damage whatever `collider` belongs to. Returns the node that took it, or null when the
## collider was world geometry. The one way anything hits a single target — a projectile, a
## melee swing, a spell — so a change to what counts as a damageable body lands everywhere.
## `from` is the inflictor's position for a blow that isn't the attacker's own (a projectile).
func damage_chain(collider: Object, damage: float, damage_type: int, attacker: Node3D = null,
		from := Vector3.INF) -> Node:
	var target := find_damageable(collider)
	if target == null:
		return null
	var outer := _inflictor_pos
	_inflictor_pos = from
	target.take_damage(damage, damage_type, attacker)
	_inflictor_pos = outer
	return target


## The shove `damage` gives `victim` (see _DAMAGE_FORCE_PER_POINT). A blow with neither an
## inflictor nor an attacker — lava, a fall, a burn — shoves nothing, as in the original.
func damage_force(victim: Node3D, damage: float, attacker: Node3D) -> Vector3:
	var from := _inflictor_pos
	if from == Vector3.INF:
		if attacker == null or not is_instance_valid(attacker):
			return Vector3.ZERO
		from = SpatialQuery.collision_center(attacker)
	var dir := SpatialQuery.collision_center(victim) - (from + _INFLICTOR_DROP)
	if dir.length_squared() < 0.0001:
		return Vector3.ZERO
	return dir.normalized() * minf(damage * _DAMAGE_FORCE_PER_POINT, _DAMAGE_FORCE_MAX)


## Apply damage to the target of a hitscan ray, honoring headshot multipliers
## on per-bone hitbox colliders. Returns true if damage was applied.
func apply_hitscan_damage(ray: Dictionary, damage: float, damage_type: int, attacker: Node3D) -> bool:
	if ray.is_empty() or ray.result.is_empty():
		return false
	var collider: Node = ray.result.collider
	var damage_mult := 1.0
	if collider and collider.has_meta("hitbox_group"):
		if int(collider.get_meta("hitbox_group")) == GameConsts.HITBOX_GROUP_HEAD:
			damage_mult = GameConsts.HEADSHOT_MULT
	return damage_chain(collider, damage * damage_mult, damage_type, attacker) != null


## Walk parent chain from node, find first with take_damage, apply damage if not already in
## damaged dict. Deliberately NOT find_damageable + a ledger check: a body already hit by this
## blast is stepped over and the walk carries on, so a second damageable further up the chain
## (a golem's body above one of its limbs) still takes its share.
func _damage_walk(node: Node, damage: float, damage_type: int, damaged: Dictionary, attacker: Node3D = null) -> void:
	while node:
		if node.has_method("take_damage") and not damaged.has(node):
			damaged[node] = true
			node.take_damage(damage, damage_type, attacker)
			return
		node = node.get_parent()


## Sphere query at impact_pos, walk parents for take_damage, dedup with ray_result direct hit.
## skip_friendly: if true and attacker is set, skip nodes on the same team as attacker.
func apply_aoe_damage(space: PhysicsDirectSpaceState3D, impact_pos: Vector3, damage: float, radius: float, ray_result := {}, damage_type := GameConsts.DamageType.PHYSICAL, attacker: Node3D = null, exclude: Node3D = null, skip_friendly: bool = false) -> void:
	if space == null:
		return
	var shape := SphereShape3D.new()
	shape.radius = radius
	var shape_params := PhysicsShapeQueryParameters3D.new()
	shape_params.shape = shape
	shape_params.transform = Transform3D(Basis.IDENTITY, impact_pos)
	shape_params.collision_mask = GameConsts.MASK_ENTITY | GameConsts.MASK_PLAYER | GameConsts.MASK_DYNAMIC
	shape_params.collide_with_bodies = true
	shape_params.collide_with_areas = false
	if exclude:
		shape_params.exclude = [exclude.get_rid()]
	var results := space.intersect_shape(shape_params, 32)
	var foe_only := skip_friendly and attacker != null
	var damaged := {}
	var outer := _inflictor_pos
	_inflictor_pos = impact_pos
	for r in results:
		if los_blocked(space, impact_pos, r.collider):
			continue
		if foe_only and Teams.nodes_friendly(attacker, r.collider):
			continue
		_damage_walk(r.collider, damage, damage_type, damaged, attacker)
	if not ray_result.is_empty() and ray_result.collider != exclude:
		if not (foe_only and Teams.nodes_friendly(attacker, ray_result.collider)):
			_damage_walk(ray_result.collider, damage, damage_type, damaged, attacker)
	# Fallback: intersect_shape can miss players in dense BSP geometry, and never sees
	# WORLD-layer func_breakables. MASK_WORLD admits breakables; plain world geometry
	# isn't in the "damageable" group so it's harmless here.
	var aoe_mask := GameConsts.MASK_ENTITY | GameConsts.MASK_PLAYER | GameConsts.MASK_DYNAMIC | GameConsts.MASK_WORLD
	for node in SpatialQuery.nodes_near(&"damageable", impact_pos, radius):
		if damaged.has(node):
			continue
		if node == exclude:
			continue
		if node is CollisionObject3D and not (node.collision_layer & aoe_mask):
			continue
		if foe_only and Teams.nodes_friendly(attacker, node):
			continue
		var center: Vector3 = SpatialQuery.collision_center(node)
		if impact_pos.distance_to(center) > radius:
			continue
		if los_blocked(space, impact_pos, node):
			continue
		if node.has_method("take_damage"):
			damaged[node] = true
			node.take_damage(damage, damage_type, attacker)
	_inflictor_pos = outer


## Quake-style radial push from an explosion. Speed is `strength` at the impact point,
## falling off linearly to zero at `radius`. The attacker is pushed like anyone else —
## that is what makes a shot at your own feet a rocket jump — but teammates are spared,
## same as the damage pass.
## up_bias tilts the push skyward (0 = straight out of the blast, 1 = 45° up for a target
## standing level with it). set_along replaces the velocity component along the push instead
## of adding to it, so a repeat-fire spell can't stack a target into orbit.
## Returns {node: falloff factor} for everyone pushed, so a caller that scales damage by the
## same falloff can reuse the line-of-sight and team decisions made here.
func apply_aoe_knockback(space: PhysicsDirectSpaceState3D, impact_pos: Vector3, strength: float, radius: float, attacker: Node3D = null, up_bias := 0.0, set_along := false) -> Dictionary:
	var pushed := {}
	if attacker and not is_instance_valid(attacker):
		attacker = null
	for node in SpatialQuery.nodes_near(&"damageable", impact_pos, radius):
		if not is_instance_valid(node) or not node is Node3D:
			continue
		if node.get("is_dead"):
			continue
		# Teams.nodes_friendly() reports self as NOT friendly, but the caster's LocalPlayer and its
		# server puppet are two nodes on one team — is_same_player keeps the puppet pushable.
		if attacker and not Teams.is_same_player(attacker, node) and Teams.nodes_friendly(attacker, node):
			continue
		var diff: Vector3 = SpatialQuery.collision_center(node) - impact_pos
		var dist := diff.length()
		if dist > radius:
			continue
		if space and los_blocked(space, impact_pos, node):
			continue
		# A dead-centre hit has no direction to push along; lift instead.
		var push_dir := diff / dist if dist > 0.01 else Vector3.UP
		if up_bias != 0.0:
			var biased := push_dir + Vector3.UP * up_bias
			# Straight down plus an equal lift cancels out — fall back to the raw direction.
			push_dir = biased.normalized() if biased.length_squared() > 0.0001 else push_dir
		var factor := 1.0 - dist / radius
		pushed[node] = factor
		var push := push_dir * strength * factor
		if node is CharacterBody3D:
			node.velocity = _push_onto(node.velocity, push_dir, push, set_along)
		elif node is RigidBody3D:
			node.linear_velocity = _push_onto(node.linear_velocity, push_dir, push, set_along)
	return pushed


## Set what a node is moving at, whatever shape of body it turns out to be: one that walks,
## one loose rigid body, or a corpse — which is twenty-one bodies and answers for itself
## (TumblingCorpse.push). Returns whether anything moved: nothing branches on it today, and it
## is here because a body that declines a shove is an answer rather than a silence.
##
## A corpse IS a RigidBody3D, so the `push` probe has to come before the type tests or the rig
## never hears about it and the frozen reference node takes the velocity instead.
func push_body(node: Node3D, velocity: Vector3) -> bool:
	if node.has_method("push"):
		return node.push(velocity)
	if node is CharacterBody3D:
		(node as CharacterBody3D).velocity = velocity
		return true
	if node is RigidBody3D:
		(node as RigidBody3D).linear_velocity = velocity
		return true
	return false


func _push_onto(velocity: Vector3, push_dir: Vector3, push: Vector3, set_along: bool) -> Vector3:
	if set_along:
		return velocity - push_dir * velocity.dot(push_dir) + push
	return velocity + push


## Check if a wall blocks line of sight from a point (e.g. AOE origin, pellet
## impact) to a target collider.
func los_blocked(space: PhysicsDirectSpaceState3D, from: Vector3, collider: Node) -> bool:
	if not collider is Node3D:
		return false
	# Collision center, not global_position — brush entities (func_breakable) keep
	# their node origin at the world origin, so +0.5 there aims at empty space.
	var target_pos: Vector3 = SpatialQuery.collision_center(collider)
	if from.distance_to(target_pos) < 0.01:
		return false
	_los_excludes.clear()
	if collider is CollisionObject3D:
		_los_excludes.append(collider.get_rid())
	_los_ray_query.from = from
	_los_ray_query.to = target_pos
	_los_ray_query.exclude = _los_excludes
	_los_ray_query.collision_mask = GameConsts.MASK_WORLD
	return not space.intersect_ray(_los_ray_query).is_empty()


## Find the closest visible enemy in the "damageable" group within search_radius.
## Excludes self_node, dead nodes, the "unhunted" group and anything Teams.summon_spares() says to
## leave alone — which covers friendly teams, and the summoner and their other summons when
## there are none.
## from_override: custom ray origin (default: self_node.global_position).
## facing: when non-zero, only enemies inside a cone about that direction count — GoldSrc's
## m_flFieldOfView, which is what anything that has to be looking at you uses. fov_cos is that
## field: 0.0 (the default) is the spirit wiz's 90 degrees either side, 0.25 the meteor spell's
## narrower 75. Leaving facing unset sees in every direction, like the rest of the summons.
## spare: an extra `func(node) -> bool` veto for a summon whose IRelationship is narrower than
## friend-or-foe — a skeleton is allied with every other skeleton, whatever team either is on.
## Returns the best target Node3D, or null if none found.
func find_homing_target(self_node: Node3D, owner_node: Node3D, team: int,
		search_radius: float, exclude_rid: RID = RID(),
		from_override: Vector3 = Vector3.INF,
		facing: Vector3 = Vector3.ZERO, fov_cos: float = 0.0,
		spare: Callable = Callable()) -> Node3D:
	var space := self_node.get_world_3d().direct_space_state
	var from_pos := self_node.global_position if from_override == Vector3.INF else from_override
	var best: Node3D = null
	var best_dist := search_radius
	_homing_ray_query.collision_mask = GameConsts.MASK_WORLD | GameConsts.MASK_ENTITY

	# Cheapest rejection first, and the ray — by far the most expensive thing here — last.
	for node in SpatialQuery.nodes_near(&"damageable", from_pos, search_radius):
		if node == self_node:
			continue
		if not node.is_inside_tree():
			continue
		# "unhunted": in "damageable" so a blast or a stray shot still hurts it, and a target for
		# nothing (R_NM, which is what a sheep answered to everything). Dropped here, above
		# collision_center and the ray, which is the whole saving — the walk itself is the group's
		# and this does not shorten it.
		if node.is_in_group("unhunted"):
			continue

		var center: Vector3 = SpatialQuery.collision_center(node)
		var dist := from_pos.distance_to(center)
		# Also enforces the radius: best_dist starts at search_radius and only ever falls. Only
		# `dist < best_dist` is ever accepted, so anything this drops could not have won.
		if dist < 0.1 or dist >= best_dist:
			continue
		if facing != Vector3.ZERO and facing.dot((center - from_pos) / dist) < fov_cos:
			continue  # outside the cone the searcher can see down

		if node.get("is_dead"):
			continue
		if Teams.summon_spares(team, owner_node, node):
			continue
		if spare.is_valid() and spare.call(node):
			continue

		# Visibility check — exclude the target's own collision body/bodies
		_homing_excludes.clear()
		if exclude_rid.is_valid():
			_homing_excludes.append(exclude_rid)
		if node is CollisionObject3D:
			_homing_excludes.append(node.get_rid())
		else:
			for child in node.get_children():
				if child is CollisionObject3D:
					_homing_excludes.append(child.get_rid())
		_homing_ray_query.from = from_pos
		_homing_ray_query.to = center
		_homing_ray_query.exclude = _homing_excludes
		homing_ray_count += 1
		if not space.intersect_ray(_homing_ray_query).is_empty():
			continue

		best_dist = dist
		best = node

	return best
