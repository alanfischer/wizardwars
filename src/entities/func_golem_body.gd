class_name FuncGolemBody
extends EntityBase
# Central controller for the multi-part golem: server drives the body and
# syncs parts, clients interpolate.

const SCALE := GameConsts.SCALE_FACTOR
const GRAVITY := 20.0
const GROUND_PROBE_DIST := 20.0
const EDGE_PROBE_AHEAD := 2.5
const MAX_STEP_DROP := 6.0  # meters — bigger drop ahead reads as a cliff/void
# Padding on the golem's half-width so whiskers cover leg brush thickness, not just centerlines.
const PROBE_MARGIN := 0.75  # meters
const LADDER_MARGIN := 0.1  # meters (4 GoldSrc units) — climb volume padding around the leg hull
# Peak body bob as a fraction of step_height, mid-step (matches original's +/-stepHeight velocity).
const BOB_FRACTION := 0.5

var _step_height := 50.0 * SCALE
var _step_length := 50.0 * SCALE
var _turn_speed := 20.0
var _up_sound := ""
var _down_sound := ""

var _body: AnimatableBody3D
var _walking := false
var _turning_left := false
var _turning_right := false
var _gs_yaw := 0.0
var _gameplay_turn := 0.0
var _attacking := false
var _step_phase := 0
var _step_t := 0.0
var _vertical_vel := 0.0
var _base_y := 0.0   # ground-following body height, before the walk bob is added
var _bob := 0.0      # current vertical bob offset (0 at step boundaries, peak mid-step)
var _parts_resolved := false  # true once _resolve_parts (deferred) has run
var _interp_mode_applied := true  # last golem_interp mode pushed to the parts
var _first_sync := true
var _home_position: Vector3  # spawn transform, restored on round reset (Trigger('golem'))

# Matches the original's ~1.25 m/s walk pace (two 0.5s action-phases per stride).
const STEP_DURATION := 1.0
# Full arm-clap gesture length; matches original's swing-and-back cadence. A new
# attack can't start until this finishes.
const ARM_CLAP_DURATION := 1.0
const ARM_CLAP_ANGLE := deg_to_rad(55.0)  # peak inward yaw of each arm at the clap apex
const CLAP_RADIUS := 10.0  # meters — search radius for trigger_golem
const CLAP_VOLUME_DB := 8.0   # ~2.5x amplitude over a normal one-shot
const CLAP_MAX_DIST := 40.0   # meters — carries across the map, not just the room
const STEP_MAX_DIST := 20.0   # meters — footstep audible range
var _arm_clap_t := 0.0
var _clapped := false  # true once the trigger fired this gesture (fires once at apex)
var _clap_activator: Node = null

var _parts: Array[Dictionary] = []
var _probe_exclude: Array[RID] = []  # body + part RIDs, rebuilt in _resolve_parts
var _left_leg_idx := -1
var _right_leg_idx := -1
var _left_arm_idx := -1
var _right_arm_idx := -1
# How far a leg's brush hangs below the leg entity's own origin; ww_golem legs
# have mins.z = -16.
var _foot_drop := 0.0


func _ready() -> void:
	super()
	_step_height = parse_float(ent, "stepheight", 50.0) * SCALE
	_step_length = parse_float(ent, "steplength", 50.0) * SCALE
	_turn_speed = parse_float(ent, "turnspeed", 20.0)
	_up_sound = ent.get("upsound", "")
	_down_sound = ent.get("downsound", "")
	var angles_str: String = ent.get("angles", "0 0 0")
	var angles_parts := angles_str.split(" ")
	if angles_parts.size() >= 2:
		_gs_yaw = deg_to_rad(float(angles_parts[1]))

	_body = _anim_body
	_home_position = _body.global_position
	_base_y = _body.global_position.y
	_probe_exclude = [_body.get_rid()]
	# sync_to_physics must be off or direct position/rotation writes in _physics_process are dropped.
	_body.sync_to_physics = false
	_body.rotation.y = -PI * 0.5
	_register_for_sync()
	add_to_group("golem_body")
	SoundSystem.precache("spells/fissure_boom.wav")
	call_deferred("_resolve_parts")


func _resolve_parts() -> void:
	var body_origin := parse_origin(ent)
	var parts_str: String = ent.get("parts", "")
	for pname in parts_str.split(","):
		pname = pname.strip_edges()
		if pname.is_empty():
			continue
		var nodes := TriggerSystem.get_nodes(pname)
		if nodes.is_empty():
			continue
		var node: Node = nodes[0]
		var part_origin: Vector3 = node.parse_origin(node.ent) if node.has_method("parse_origin") else Vector3.ZERO
		var offset := part_origin - body_origin
		var part_node := node as Node3D
		if not part_node:
			continue
		var part_body := node as AnimatableBody3D
		if part_body:
			part_body.sync_to_physics = false
		elif node.has_method("_register_for_sync"):
			node._register_for_sync()  # needed when golem_interp=off (per-part streaming)
		var ptype := ""
		if node.has_method("_get_golem_type"):
			ptype = node._get_golem_type()
		var idx := _parts.size()
		_parts.append({"node": part_node, "body": part_body, "offset": offset, "type": ptype, "step_offset": Vector3.ZERO, "step_rot": 0.0, "render_offset": Vector3.ZERO, "render_rot": 0.0})
		match ptype:
			"leftleg": _left_leg_idx = idx
			"rightleg": _right_leg_idx = idx
			"leftarm": _left_arm_idx = idx
			"rightarm": _right_arm_idx = idx

	for p in _parts:
		if p.body:
			_probe_exclude.append(p.body.get_rid())

	_measure_foot_drop()
	var ladders_on := false
	for idx in [_left_leg_idx, _right_leg_idx]:
		if idx >= 0 and _use_leg_ladders(_parts[idx].body):
			_add_leg_ladder(_parts[idx])
			ladders_on = true

	_sync_parts(0.0)
	# Gate the sim on this flag: before leg indices/exclusions are known, a gravity
	# settle would self-hit the golem's own legs and rest at the wrong height.
	_parts_resolved = true
	_apply_interp_mode(_interp_on())
	Log.info("Golem: %d parts, rests %.1f units above the floor (foot hull %.1f below the leg origin), leg ladders %s"
		% [_parts.size(), _leg_height() / SCALE, _foot_drop / SCALE, "on" if ladders_on else "off (hop hulls)"])


## Legs need a ladder unless hop is tracing their real BSP clip hull (otherwise
## they're just the render-face convex shape, which can't be climbed).
func _use_leg_ladders(leg: Node3D) -> bool:
	var server: Object = Engine.get_singleton(&"PhysicsServer3D")
	if server == null or not server.has_method("get_bsp_hulls_enabled"):
		return true
	if not bool(server.call("get_bsp_hulls_enabled")):
		return true
	return not _has_bsp_hull(leg)


## Mirrors HopPhysicsServer::try_build_bsp_hull: the body names its BSP model and
## scale, and the tree itself rides on an ancestor under "bsp_data".
func _has_bsp_hull(leg: Node3D) -> bool:
	if leg == null or not leg.has_meta("bsp_model") or not leg.has_meta("bsp_scale"):
		return false
	var n: Node = leg
	while n != null:
		if not (n.get_meta("bsp_data", PackedByteArray()) as PackedByteArray).is_empty():
			return true
		n = n.get_parent()
	return false


func _add_leg_ladder(part: Dictionary) -> void:
	var leg_body: AnimatableBody3D = part.body
	if not leg_body:
		return
	var pts: Array[Vector3] = []
	for child in leg_body.get_children():
		if child is CollisionShape3D and child.shape is ConvexPolygonShape3D:
			for pt in child.shape.get_points():
				pts.append((child as CollisionShape3D).position + pt)
	if pts.is_empty():
		return
	# Golem forward/lateral in leg-local space; fixed as the golem turns since the
	# leg rotates with the body. Forward maps to +Z at angles-yaw 0.
	var fwd := Vector3(sin(_gs_yaw), 0.0, cos(_gs_yaw)).normalized()
	var lat := Vector3(cos(_gs_yaw), 0.0, -sin(_gs_yaw)).normalized()
	var min_f := INF; var max_f := -INF
	var min_l := INF; var max_l := -INF
	var min_y := INF; var max_y := -INF
	for p in pts:
		var f := p.dot(fwd); var l := p.dot(lat)
		min_f = minf(min_f, f); max_f = maxf(max_f, f)
		min_l = minf(min_l, l); max_l = maxf(max_l, l)
		min_y = minf(min_y, p.y); max_y = maxf(max_y, p.y)
	var depth := (max_f - min_f) + LADDER_MARGIN * 2.0
	var center_f := (min_f + max_f) * 0.5
	var center_l := (min_l + max_l) * 0.5
	var center_y := (min_y + max_y) * 0.5
	var center_local := fwd * center_f + lat * center_l + Vector3(0.0, center_y, 0.0)

	var wrapper := Node3D.new()
	wrapper.name = "GolemLadder"
	wrapper.set_script(preload("res://src/entities/golem_ladder.gd"))
	var area := Area3D.new()
	area.collision_layer = GameConsts.MASK_LADDER
	area.collision_mask = 0
	area.monitoring = false
	area.monitorable = true
	var box := BoxShape3D.new()
	box.size = Vector3((max_l - min_l) + LADDER_MARGIN * 2.0, (max_y - min_y) + LADDER_MARGIN * 2.0, depth)
	var col := CollisionShape3D.new()
	col.shape = box
	col.position = center_local
	col.rotation.y = _gs_yaw
	area.add_child(col)
	wrapper.add_child(area)
	leg_body.add_child(wrapper)


func _get_forward() -> Vector3:
	var yaw := _gs_yaw + _gameplay_turn
	return Vector3(-cos(yaw), 0, sin(yaw)).normalized()


func _get_rotation() -> float:
	return -PI * 0.5 + _gameplay_turn


func _probe_ground(from: Vector3) -> Dictionary:
	var space := get_tree().root.get_world_3d().direct_space_state
	var params := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * GROUND_PROBE_DIST)
	params.collision_mask = GameConsts.MASK_WORLD
	params.exclude = _probe_exclude
	var result := space.intersect_ray(params)
	if not result.is_empty() and result.collider is CharacterBody3D:
		result = {}
	return result


## Lowest point of the legs' collision hulls relative to the leg's own origin —
## the original measured the floor from the hull bottom, not the origin (see _leg_height()).
func _measure_foot_drop() -> void:
	var lowest := 0.0
	for idx in [_left_leg_idx, _right_leg_idx]:
		if idx < 0:
			continue
		var leg: AnimatableBody3D = _parts[idx].body
		if not leg:
			continue
		for child in leg.get_children():
			if child is CollisionShape3D and child.shape is ConvexPolygonShape3D:
				for pt in (child.shape as ConvexPolygonShape3D).get_points():
					lowest = minf(lowest, (child as CollisionShape3D).position.y + pt.y)
	_foot_drop = -lowest


## Distance from the body origin to the bottom of the legs — rest height above the
## floor. Must include _foot_drop or the golem sinks by however far the leg brush
## hangs below its origin (matches CGolem::MoveThink in GOLEM.CPP).
func _leg_height() -> float:
	if _left_leg_idx < 0:
		return 0.0
	return absf(_parts[_left_leg_idx].offset.y) + _foot_drop


func _max_step_rise() -> float:
	return _step_height * 2.0


## Half the golem's body width, used to fan step-probe whiskers to +/- this so a
## pillar off to one side of the wide torso is seen too, not just the centerline.
func _half_width() -> float:
	var lat := 3.0 * SCALE  # fallback if legs aren't resolved yet
	if _left_leg_idx >= 0:
		lat = maxf(lat, absf(_parts[_left_leg_idx].offset.x))
	if _right_leg_idx >= 0:
		lat = maxf(lat, absf(_parts[_right_leg_idx].offset.x))
	return lat + PROBE_MARGIN


## True if the terrain along one whisker ahead can carry the golem (ground exists,
## within step-drop/rise limits, torso not blocked). `side`: 0=centerline, +/-1=body edge.
func _whisker_clear(forward: Vector3, right: Vector3, feet_y: float, side: float) -> bool:
	var lateral := right * (_half_width() * side)
	var base := _body.global_position + lateral
	var ahead := Vector3(base.x, _base_y, base.z) + forward * EDGE_PROBE_AHEAD
	var result := _probe_ground(ahead)
	if result.is_empty():
		return false
	var rise: float = result.position.y - feet_y
	if rise < -MAX_STEP_DROP or rise > _max_step_rise():
		return false
	# Torso ray just above steppable height, using the player movement mask (world +
	# clip + sky) so the golem also respects info_clipbrush water fences.
	var space := get_tree().root.get_world_3d().direct_space_state
	var chest := Vector3(base.x, feet_y + _max_step_rise() + 0.5, base.z)
	var params := PhysicsRayQueryParameters3D.create(chest, chest + forward * (EDGE_PROBE_AHEAD + 1.0))
	params.collision_mask = GameConsts.MASK_WORLD_AND_CLIP
	params.exclude = _probe_exclude
	var blocker := space.intersect_ray(params)
	return blocker.is_empty() or blocker.collider is CharacterBody3D


## All three whiskers (left edge, center, right edge) must be clear so the wide
## body doesn't clip a wall or walk a shoulder off a ledge.
func _can_step_forward() -> bool:
	var forward := _get_forward()
	var right := Basis(Vector3.UP, _get_rotation()).x
	var feet_y := _base_y - _leg_height()
	return _whisker_clear(forward, right, feet_y, 0.0) \
		and _whisker_clear(forward, right, feet_y, -1.0) \
		and _whisker_clear(forward, right, feet_y, 1.0)


## Highest ground under the golem's support points (body center + each leg). Probed
## from above the body, not _base_y, so a dipped-below-floor baseline can still recover.
## NAN when nothing solid is under any support point.
func _support_ground_y() -> float:
	var start_h := _base_y + _max_step_rise()
	var points: Array[Vector3] = [_body.global_position]
	for idx in [_left_leg_idx, _right_leg_idx]:
		if idx >= 0 and _parts[idx].node:
			points.append((_parts[idx].node as Node3D).global_position)
	var best := NAN
	for pt in points:
		var res := _probe_ground(Vector3(pt.x, start_h, pt.z))
		if not res.is_empty() and (is_nan(best) or res.position.y > best):
			best = res.position.y
	return best


func _apply_gravity(delta: float) -> void:
	if not _body:
		return
	var ground_y := _support_ground_y()
	if is_nan(ground_y):
		# No ground under body or either leg (straddling a pit/gap): hold height
		# instead of free-falling the torso below its still-planted legs.
		_vertical_vel = 0.0
		return

	var target_y := ground_y + _leg_height()
	var diff := target_y - _base_y
	if diff < -0.1:
		_vertical_vel = maxf(_vertical_vel - GRAVITY * delta, -20.0)
		_base_y += _vertical_vel * delta
		if _base_y <= target_y:
			_base_y = target_y
			_vertical_vel = 0.0
	elif absf(diff) > 0.02:
		_base_y += diff * 10.0 * delta
		_vertical_vel = 0.0
	else:
		_vertical_vel = 0.0


## Client-only: rebuild limbs at display rate. _physics_process would lag a step at high FPS.
func _process(delta: float) -> void:
	if not (_is_network_client() and _body and _parts_resolved):
		return
	if _poll_interp_mode():
		_client_animate(delta)


func _physics_process(delta: float) -> void:
	if not _body or _is_network_client() or not _parts_resolved:
		return

	_poll_interp_mode()

	# Turning is never gated — the golem has no reverse, so pivoting is its only way
	# out of a spot. Forward stepping is what's kept safe (_can_step_forward).
	if _turning_left:
		_gameplay_turn += deg_to_rad(_turn_speed) * delta
	if _turning_right:
		_gameplay_turn -= deg_to_rad(_turn_speed) * delta

	# Walking and turning share the same leg-step cycle; a pure turn steps in place.
	var stepping := _any_moving()
	if stepping and _step_phase == 0:
		_step_phase = 1
		_step_t = 0.0

	if _step_phase > 0:
		if not _walking or _can_step_forward():  # a pivot always steps; only forward needs clear ground
			var prev_t := _step_t
			_step_t += delta / STEP_DURATION
			if _step_t >= 1.0:
				_step_t = 0.0
				if stepping:
					_step_phase = 2 if _step_phase == 1 else 1
				else:
					_step_phase = 0
			if _walking:
				_body.position += _get_forward() * _step_length * (delta / STEP_DURATION)
			_bob = (1.0 - absf(2.0 * _step_t - 1.0)) * _step_height * BOB_FRACTION  # triangle wave, peak mid-step
			_animate_legs()
			# Fire on the t==0/t>=0.5 edges (not fixed windows) so each cue plays exactly once regardless of fps.
			if prev_t == 0.0 and not _up_sound.is_empty():
				SoundSystem.play_3d(_up_sound, _body.global_position, 1.0, 0.0, STEP_MAX_DIST)
			if prev_t < 0.5 and _step_t >= 0.5 and not _down_sound.is_empty():
				SoundSystem.play_3d(_down_sound, _body.global_position, 1.0, 0.0, STEP_MAX_DIST)
		else:
			# Blocked: auto-stop and snap parts to rest so nothing is left mid-stride.
			_stop_all()
			_bob = 0.0
			_snap_parts_to_rest()
			_step_phase = 0
			_step_t = 0.0
	else:
		_bob = 0.0
		_settle_legs()

	if _advance_clap(delta):
		_sync_notify()  # clap done — clients reset the arms

	# Run every frame, not just while moving, or _base_y freezes at a mid-stride
	# height when a stop happens and the body stays sunk.
	_apply_gravity(delta)

	_body.global_position.y = _base_y + _bob

	var target_rot := _get_rotation()
	var rot_diff := angle_difference(_body.rotation.y, target_rot)
	if absf(rot_diff) > 0.001:
		_body.rotation.y += rot_diff * minf(20.0 * delta, 1.0)

	_sync_parts(delta)


## Client-side limb reconstruction, driven off synced control flags instead of streaming
## + interpolating every limb (which trailed/jittered on high-ping links).
func _client_animate(delta: float) -> void:
	# Recover gameplay turn from the interpolated body yaw, not a stale local angle.
	_gameplay_turn = _body.rotation.y + PI * 0.5

	var stepping := _any_moving()
	if stepping and _step_phase == 0:
		_step_phase = 1
		_step_t = 0.0
	if _step_phase > 0:
		_step_t += delta / STEP_DURATION
		if _step_t >= 1.0:
			_step_t = 0.0
			if stepping:
				_step_phase = 2 if _step_phase == 1 else 1
			else:
				_step_phase = 0
		_bob = (1.0 - absf(2.0 * _step_t - 1.0)) * _step_height * BOB_FRACTION
		_animate_legs()
	else:
		_bob = 0.0
		_settle_legs()

	_advance_clap(delta)
	_sync_parts(delta)


## dt is the caller's own elapsed time, not get_physics_process_delta_time() (which always
## reports the fixed physics tick) — the client drives this from _process at display rate,
## so using the physics-tick getter here would make the ease blend converge instantly.
func _sync_parts(dt: float) -> void:
	if not _body:
		return
	var body_pos := _body.global_position
	var rot := _body.rotation.y
	var offset_basis := Basis(Vector3.UP, rot)
	# Ease only the per-part animation offsets (leg settle, arm reset); the rigid
	# body-follow itself is exact every frame so parts never trail the torso.
	var blend := 1.0 if _first_sync else minf(20.0 * dt, 1.0)
	_first_sync = false
	for p in _parts:
		var pn: Node3D = p.node
		if not pn:
			continue
		p.render_offset = (p.render_offset as Vector3).lerp(p.step_offset, blend)
		p.render_rot = lerp_angle(p.render_rot, p.step_rot, blend)
		pn.global_position = body_pos + offset_basis * p.offset + p.render_offset
		pn.rotation.y = rot + p.render_rot
		flush_mover_transform(pn)
	# Riders tick after us and trace against the server's copy, which Godot would not
	# have refreshed until every _physics_process had run — see flush_mover_transform.
	flush_mover_transform(_body)


func _settle_legs() -> void:
	if _left_leg_idx >= 0:
		_parts[_left_leg_idx].step_offset = Vector3.ZERO
	if _right_leg_idx >= 0:
		_parts[_right_leg_idx].step_offset = Vector3.ZERO


## Snaps target and eased render offset both, so an auto-stop doesn't leave a
## mid-stride pose that would otherwise ease out gradually.
func _snap_parts_to_rest() -> void:
	for p in _parts:
		p.step_offset = Vector3.ZERO
		p.step_rot = 0.0
		p.render_offset = Vector3.ZERO
		p.render_rot = 0.0


func _animate_legs() -> void:
	var forward := _get_forward()
	var half := _step_length * 0.5
	var stepping := _left_leg_idx if _step_phase == 1 else _right_leg_idx
	var planted := _right_leg_idx if _step_phase == 1 else _left_leg_idx
	# Swing leg rides the body bob (clears the ground); planted leg cancels the bob
	# so it stays pinned to the floor, keeping the walk from turning into a hop.
	if stepping >= 0:
		_parts[stepping].step_offset = forward * lerp(-half, half, _step_t)
	if planted >= 0:
		_parts[planted].step_offset = forward * lerp(half, -half, _step_t) + Vector3.DOWN * _bob


## Returns true on the frame the clap finishes, so the server can re-sync the arm reset.
func _advance_clap(delta: float) -> bool:
	if not _attacking:
		return false
	_arm_clap_t += delta / ARM_CLAP_DURATION
	if _arm_clap_t >= 1.0:
		_arm_clap_t = 0.0
		_attacking = false
		_reset_arms()
		return true
	_animate_arms()
	return false


func _reset_arms() -> void:
	if _left_arm_idx >= 0:
		_parts[_left_arm_idx].step_offset = Vector3.ZERO
		_parts[_left_arm_idx].step_rot = 0.0
	if _right_arm_idx >= 0:
		_parts[_right_arm_idx].step_offset = Vector3.ZERO
		_parts[_right_arm_idx].step_rot = 0.0


func _animate_arms() -> void:
	var t := _arm_clap_t
	# Symmetric triangle: swing together then apart, meeting at the apex (t=0.5).
	var swing := 1.0 - absf(2.0 * t - 1.0)
	if t >= 0.5 and not _clapped:
		_clapped = true
		_do_clap()
	var right := Basis(Vector3.UP, _get_rotation()).x
	var slide := 1.0  # meters — inward translation layered on the rotation so hands actually meet
	if _left_arm_idx >= 0:
		_parts[_left_arm_idx].step_rot = -ARM_CLAP_ANGLE * swing
		_parts[_left_arm_idx].step_offset = right * slide * swing
	if _right_arm_idx >= 0:
		_parts[_right_arm_idx].step_rot = ARM_CLAP_ANGLE * swing
		_parts[_right_arm_idx].step_offset = -right * slide * swing


func _do_clap() -> void:
	# Server-only: authoritative rock-breaking; the client's arm animation must not re-fire it.
	if _is_network_client():
		return
	var clap_pos := _body.global_position + _get_forward() * 5.0
	for node in get_tree().get_nodes_in_group("trigger_golem"):
		if node.global_position.distance_to(clap_pos) <= CLAP_RADIUS:
			if node.has_method("golem_activate"):
				node.golem_activate(_clap_activator)
	SoundSystem.play_3d("spells/fissure_boom.wav", clap_pos, 1.0, CLAP_VOLUME_DB, CLAP_MAX_DIST)


func _stop_all() -> void:
	if not _any_moving():
		return
	_walking = false
	_turning_left = false
	_turning_right = false
	_sync_notify()  # tell clients to wind the walk cycle down (covers block auto-stop)

func _any_moving() -> bool:
	return _walking or _turning_left or _turning_right

# Any movement button pressed while already moving just stops it; movement only
# starts from a stopped state.
func _set_movement(walk: bool, left: bool, right: bool) -> void:
	if _any_moving():
		_stop_all()
		return
	_walking = walk
	_turning_left = left
	_turning_right = right
	_sync_notify()  # broadcast the new movement so clients start the same walk cycle

func golem_walk() -> void:
	_set_movement(true, false, false)

func golem_turn_left() -> void:
	_set_movement(false, true, false)

func golem_turn_right() -> void:
	_set_movement(false, false, true)

func golem_attack(activator: Node = null) -> void:
	_stop_all()
	if not _attacking:
		_attacking = true
		_arm_clap_t = 0.0
		_clapped = false
		_clap_activator = activator
		_sync_notify()  # broadcast the clap so clients animate the arms

## Resets to spawn (matches CGolem::Use). Round reset fires Trigger('golem'); a
## player's +use can't land here directly since CGolem has no FCAP_IMPULSE_USE —
## players drive the golem only through its control brushes.
func trigger(_activator: Node, _type: TriggerSystem.Type) -> void:
	if _is_network_client():
		return
	_reset_to_home()


func _reset_to_home() -> void:
	_stop_all()
	_attacking = false
	_step_phase = 0
	_step_t = 0.0
	_arm_clap_t = 0.0
	_clapped = false
	_vertical_vel = 0.0
	_bob = 0.0
	_gameplay_turn = 0.0
	_body.global_position = _home_position
	_base_y = _home_position.y
	_body.rotation.y = -PI * 0.5
	_snap_parts_to_rest()
	_sync_parts(0.0)


## Server -> clients discrete control state; clients rebuild the walk/clap pose from
## these flags (_client_animate). Only sent on change via _sync_notify, not per-tick.
func _get_sync_state() -> Dictionary:
	var state := super._get_sync_state()
	state["gw"] = _walking
	state["gl"] = _turning_left
	state["gr"] = _turning_right
	state["ga"] = _attacking
	return state


func _apply_sync_state(state: Dictionary) -> void:
	super._apply_sync_state(state)
	if "gw" in state:
		_walking = state["gw"]
	if "gl" in state:
		_turning_left = state["gl"]
	if "gr" in state:
		_turning_right = state["gr"]
	if "ga" in state:
		var was := _attacking
		_attacking = state["ga"]
		if _attacking and not was:
			_arm_clap_t = 0.0  # restart the clap animation cleanly on the client


## true = client reconstructs limb pose from the body; false = each limb self-syncs (old path).
func _interp_on() -> bool:
	return bool(ServerVars.get_value("golem_interp", true))


func _poll_interp_mode() -> bool:
	var on := _interp_on()
	if on != _interp_mode_applied:
		_apply_interp_mode(on)
	return on


## Switches every LIMB between body-driven and self-synced; the body itself always
## uses normal entity interpolation.
func _apply_interp_mode(on: bool) -> void:
	_interp_mode_applied = on
	for p in _parts:
		if p.node is EntityBase:
			p.node.set_transform_externally_driven(on)
