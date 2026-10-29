extends Node

## Server-side lag compensation ("sv_unlag"): rewinds every target's hitbox colliders to
## where they were at the shooter's shot time, runs the hitscan query, restores.
##
## Shot time is the shooter's RENDER time (one INTERP_DELAY behind their clock estimate) —
## NetworkManager.shot_time_ms already does that subtraction before stamping.
##
## Hitboxes hang off BoneAttachment3Ds, so rewinding needs more than position: targets that
## can reproduce a past rig pose (lag_comp_apply_pose) get re-posed and read back off the
## skeleton; rigless damageables fall back to rigid-mapping their live boxes onto the
## recorded position/yaw.
##
## Deliberately game-side, not in goldnet: this manipulates Area3Ds via PhysicsServer3D and
## knows the hitbox rig. goldnet only supplies the already-reconciled time domain.

const SnapshotInterp = preload("res://src/systems/snapshot_interp.gd")

const HISTORY_SIZE := 128     # ~2s at the 60Hz sim rate it's recorded from
## Cap on how far back a shot may rewind targets (GoldSrc sv_maxunlag). Must cover a
## high-ping client's one-way delay PLUS their INTERP_DELAY, since the stamp they send
## is their render time — 200ms clipped that combination for anyone past ~130ms ping.
const MAX_REWIND_MS := 500
## Ghost only targets whose rewound origin sits this close to the shot ray. Every damageable
## player rewinds on every shot; on a full server all but the aimed-at ones are noise.
const GHOST_RAY_RADIUS := 2.0

## peer_id -> Array of [time_seconds: float, pos: Vector3, yaw: float, pose: Variant], oldest
## first. `pose` is the opaque rig snapshot from the target's lag_comp_capture_pose(), or null
## for damageables without a rig.
var _histories: Dictionary = {}

## When true, each rewound shot sends the boxes it queried against to the shooter's client,
## which draws them. See src/systems/rewind_ghosts.gd.
var debug_ghosts := false


## Server: record a player's authoritative pose at a known server timestamp, called each sim
## tick. Yaw is recorded too because the hitbox rig turns with the body — position alone would
## leave a turning target's limb boxes in their present-day orientation. `node`'s rig state
## (animation frame, crouch, pitch) rides along when it has one; the animation clip position
## is whatever the puppet's own _physics_process last left it, up to one tick behind — an
## order of magnitude below the latency the rewind exists to undo.
func record(peer_id: int, server_time_ms: int, pos: Vector3, yaw: float, node: Node = null) -> void:
	var buf = _histories.get(peer_id)  # untyped: null when absent
	if buf == null:
		buf = []
		_histories[peer_id] = buf
	var pose = node.lag_comp_capture_pose() if node and node.has_method("lag_comp_capture_pose") else null
	buf.append([server_time_ms / 1000.0, pos, yaw, pose])
	if buf.size() > HISTORY_SIZE:
		buf.pop_front()


## Drop a player's history — on despawn, respawn, or teleport, where past
## positions are no longer valid to rewind to.
func forget(peer_id: int) -> void:
	_histories.erase(peer_id)


## Drop all history — on map unload / disconnect, alongside the other per-peer
## server tables the NetworkManager wipes in bulk.
func clear_all() -> void:
	_histories.clear()


## Server: rewind every damageable player's hitboxes to the shooter's shot time so
## a hitscan query registers against where the shooter was actually aiming. Returns the
## state restore() needs; empty when there's nothing to rewind.
##
## The ray is only used to pick which targets are worth ghosting under debug_ghosts;
## callers without one (tests, non-hitscan damage) leave it at its zero default.
func rewind(attacker: Node3D, ray_from := Vector3.ZERO, ray_dir := Vector3.ZERO, ray_len := 0.0) -> Dictionary:
	var stamp = attacker.get(&"lag_comp_shot_time_ms")  # untyped: null on attackers without one
	if stamp == null or int(stamp) <= 0:
		return {}
	var now_ms := Time.get_ticks_msec()
	var target_ms := clampi(int(stamp), now_ms - MAX_REWIND_MS, now_ms)
	var area_xforms: Dictionary = {}   # RID -> live Transform3D
	var reposed: Array = []            # [node, live_pose, live_body_xform] per re-posed rig
	var ghosts := _GhostBuffer.new()
	for node in attacker.get_tree().get_nodes_in_group("damageable"):
		if node == attacker or not node is Node3D:
			continue
		var peer = node.get("peer_id")  # untyped: null on damageables that aren't players
		var buf = _histories.get(peer)  # untyped: null when absent
		if buf == null:
			continue
		var areas: Array = node.get_hitbox_areas() if node.has_method("get_hitbox_areas") else []
		if areas.is_empty():
			continue
		var past := _sample(buf, target_ms)
		var past_pos: Vector3 = past[0]
		var past_yaw: float = past[1]
		var past_pose = past[2]  # untyped: null on rigless targets
		var worlds: Array = []
		if past_pose != null and node.has_method("lag_comp_apply_pose"):
			worlds = _repose(node, past_pos, past_yaw, past_pose, reposed)
		if worlds.size() != areas.size():
			# No rig, or one that couldn't deliver a full set of boxes. A degraded rewind still
			# beats none: the position error it removes dwarfs the pose error it leaves behind.
			worlds = _rigid_map(node, past_pos, past_yaw, areas)
		if worlds.size() != areas.size():
			continue  # already where it was — nothing to rewind
		for i in areas.size():
			var rid: RID = areas[i].get_rid()
			area_xforms[rid] = PhysicsServer3D.area_get_transform(rid)
			PhysicsServer3D.area_set_transform(rid, worlds[i])
		if debug_ghosts and _near_ray(past_pos, ray_from, ray_dir, ray_len):
			ghosts.add(past_pos, areas, worlds)
	if not ghosts.origins.is_empty():
		NetworkManager.send_debug_rewind_ghosts(attacker.peer_id,
			ghosts.origins, ghosts.xforms, ghosts.sizes, ghosts.groups)
	if area_xforms.is_empty() and reposed.is_empty():
		return {}
	return {areas = area_xforms, reposed = reposed}


## Full-fidelity path: put the rig back into its recorded state (animation frame, crouch,
## pitch, position, facing) and read hitbox transforms straight off the skeleton — this
## sidesteps BoneAttachment3D's deferred update, since the boxes exist in the bone poses the
## instant the pose is applied, not a frame later. Returns [] (after restoring the target
## exactly as found) if the rig can't produce its boxes, since the caller's fallback needs
## to see an untouched target.
func _repose(node: Node3D, past_pos: Vector3, past_yaw: float, past_pose: Variant,
		reposed: Array) -> Array:
	var entry := [node, node.lag_comp_capture_pose(), node.global_transform]
	node.global_transform = Transform3D(Basis(Vector3.UP, past_yaw), past_pos)
	node.lag_comp_apply_pose(past_pose)
	var worlds: Array = node.lag_comp_hitbox_world_transforms()
	if worlds.is_empty():
		node.global_transform = entry[2]
		node.lag_comp_apply_pose(entry[1])
		return []
	reposed.append(entry)
	return worlds


## Fallback for damageables with hitboxes but no reproducible rig pose: rigid-map the live
## boxes onto the recorded position and yaw. Loses whatever the animation was doing, which is
## why anything with a skeleton takes _repose() instead.
func _rigid_map(node: Node3D, past_pos: Vector3, past_yaw: float, areas: Array) -> Array:
	var cur_pos: Vector3 = node.global_position
	# Shortest signed turn from the pose the hitboxes are in now back to the recorded one.
	var dyaw := angle_difference(node.global_rotation.y, past_yaw)
	if (past_pos - cur_pos).length_squared() < 0.00001 and absf(dyaw) < 0.001:
		return []
	# The pivot's height cancels under a Y-axis rotation, so cur_pos works as the pivot directly.
	var spin := Basis(Vector3.UP, dyaw)
	var out: Array = []
	for area in areas:
		var live: Transform3D = PhysicsServer3D.area_get_transform(area.get_rid())
		out.append(Transform3D(spin * live.basis, past_pos + spin * (live.origin - cur_pos)))
	return out


## True when a rewound origin is close enough to the shot ray to be worth drawing. A
## zero-length ray means the caller supplied none — then everything qualifies.
func _near_ray(point: Vector3, from: Vector3, dir: Vector3, length: float) -> bool:
	if length <= 0.0:
		return true
	var closest := Geometry3D.get_closest_point_to_segment(point, from, from + dir * length)
	return closest.distance_squared_to(point) <= GHOST_RAY_RADIUS * GHOST_RAY_RADIUS


## Undo rewind(): hitbox transforms first, then the rigs and bodies that were re-posed, so
## nothing observes a target mid-rewind after the query returns.
func restore(saved: Dictionary) -> void:
	if saved.is_empty():
		return
	for rid in saved.areas:
		PhysicsServer3D.area_set_transform(rid, saved.areas[rid])
	for entry in saved.reposed:
		var node: Node3D = entry[0]
		if not is_instance_valid(node):
			continue
		node.global_transform = entry[2]
		node.lag_comp_apply_pose(entry[1])


## Authoritative pose [pos: Vector3, yaw: float, pose: Variant] at a server timestamp. Position
## and yaw interpolate between the bracketing samples; the rig pose is taken whole from the
## nearer one, since an animation clip name doesn't blend and sub-tick phase error (<=16ms) is
## far below what the pose rewind is correcting for. buf is always non-empty — _histories only
## holds recorded buffers, and forget() erases the key.
func _sample(buf: Array, target_ms: int) -> Array:
	if buf.size() == 1:
		return [buf[0][1], buf[0][2], buf[0][3]]
	var target_s := target_ms / 1000.0
	var bracket := SnapshotInterp.find_bracket(buf, target_s)
	var s0_idx: int = bracket.s0_idx
	if s0_idx == -1:
		return [buf[0][1], buf[0][2], buf[0][3]]
	if s0_idx >= buf.size() - 1:
		var last: Array = buf[buf.size() - 1]
		return [last[1], last[2], last[3]]
	var nearer: Array = buf[s0_idx] if bracket.t < 0.5 else buf[s0_idx + 1]
	return [
		SnapshotInterp.lerp_vec3(buf[s0_idx], buf[s0_idx + 1], bracket.t, 1),
		SnapshotInterp.lerp_rot(buf[s0_idx], buf[s0_idx + 1], bracket.t, 2),
		nearer[3]]


## Accumulates what the shooter's client needs to draw: the body origins that were rewound to,
## plus the actual boxes the query ran against. The boxes go over the wire as geometry (four
## Vector3s of transform, one of size) rather than as a pose the client re-derives — once the
## rewind re-poses a skeleton, no client-side reconstruction can reproduce it.
class _GhostBuffer:
	var origins: PackedVector3Array = []
	var xforms: PackedVector3Array = []
	var sizes: PackedVector3Array = []
	var groups: PackedInt32Array = []

	func add(origin: Vector3, areas: Array, worlds: Array) -> void:
		origins.append(origin)
		for i in areas.size():
			var shape := _box_shape(areas[i])
			if shape == null:
				continue
			# worlds[i] is the Area3D's transform (what area_set_transform takes); the box
			# itself sits at the shape's own offset inside it.
			var x: Transform3D = worlds[i] * shape.transform
			xforms.append_array([x.basis.x, x.basis.y, x.basis.z, x.origin])
			sizes.append((shape.shape as BoxShape3D).size)
			groups.append(int(areas[i].get_meta("hitbox_group", 0)))

	func _box_shape(area: Area3D) -> CollisionShape3D:
		for child in area.get_children():
			if child is CollisionShape3D and child.shape is BoxShape3D:
				return child
		return null
