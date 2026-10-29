class_name ItemTFGoal
extends TFGoalBase
# TFC-style carriable goal item (key/flag), ported from TFItemGoalComponent.cpp.
# Host-authoritative: state changes happen on the host and are broadcast to clients.

var _carrier: Node = null  # player carrying this item (host only)
var _carrier_peer_id: int = 0  # peer ID of carrier (both host and client)
var _moved := false
var _spawn_position: Vector3
var _spawn_rotation_y: float
var _spawn_parent: Node

var _drop_return_time: float = 0.0
var _return_time: float = 0.0
var _return_silent: bool = false  # _return_time was scheduled by a capture removal — return without the stinger
var _no_touch_time: float = 0.0
var _inactivate_time: float = 0.0  # brush entity: auto-inactivate timer

var _area: Area3D
var _touch := TouchBehavior.new()
var _trail_particles: CPUParticles3D
var _has_model := false
var _is_brush := false  # true when this is a brush-volume trigger (not a carriable item)
var _needs_drop := false  # GA_DROP_MODEL_ON_SPAWN: drop on first physics frame
var _prev_carrier_pos := Vector3.ZERO  # tracks carrier position for movement-based trailing
var _trail_dir := Vector3.ZERO  # smoothed movement direction

const TOUCH_RADIUS := 1.0       # ~40 GoldSrc units
const TOUCH_GUARD_DIST := 2.0   # max distance for body_entered to count as valid
const TRAIL_DISTANCE := 1.5     # how far behind the carrier the item drags
const TRAIL_HEIGHT := 0.1       # slight lift off the ground
const TRAIL_LERP := 15.0        # how tightly the item follows (higher = tighter)
const NO_TOUCH_DELAY := 1.5     # seconds after drop before item can be picked up again


func _ready() -> void:
	super()
	if _anim_body:
		_anim_body.sync_to_physics = false
	_register_for_sync()
	_parse_tf_properties(get_meta("entity", {}))

	# Announcer words for flag events and the score stingers they lead to.
	for word in ["doop", "flag", "returned", "captured", "enemy", "scores"]:
		SoundSystem.precache("vox/%s.wav" % word)

	_spawn_position = position
	_spawn_rotation_y = rotation.y
	_spawn_parent = get_parent()

	_is_brush = is_brush_entity()

	if _is_brush:
		_area = GoldSrcEntity.use_volume_as_trigger(self, GameConsts.MASK_PLAYER)
		_area.body_entered.connect(_on_body_entered)
		if goal_state == GoalState.REMOVED:
			_area.set_deferred("monitoring", false)
			set_entity_visible(false)
		Log.info("item_tfgoal %d (brush): group=%d team=%d g_a=%d state=%d" % [
			goal_no, group_no, req_team, goal_activation, goal_state])
		return

	var mdl_path: String = ent.get("mdl", "")
	if not mdl_path.is_empty():
		var model := AssetLoader.load_model(mdl_path)
		if model:
			add_child(model)
			_has_model = true
			EntityRender.apply_model_render_properties(model, ent)
			# Re-track so _compute_local_aabb captures the real mesh AABB, not a
			# zero-size point — otherwise PVS uses only the base position and the
			# item vanishes if the base clips into a solid leaf.
			if _entity.entity_id >= 0:
				VisibilitySystem.untrack_node(_entity.entity_id)
				VisibilitySystem.track_node(_entity.entity_id, self)
		else:
			push_warning("item_tfgoal %d: failed to load %s" % [goal_no, mdl_path])

	# Signalled rather than polled: the goal item is carried off on contact, so there is no
	# standing-on-it-with-no-room case for a poll to catch (see TouchBehavior.tick).
	_touch.initialize(self)
	_area = _touch.add_sphere(TOUCH_RADIUS)
	_area.body_entered.connect(_on_body_entered)

	set_entity_visible(goal_state != GoalState.REMOVED)
	if goal_state == GoalState.REMOVED:
		_area.set_deferred("monitoring", false)

	if not _has_model:
		return
	
	add_child(BlobShadow.new(0.3))

	_trail_particles = CPUParticles3D.new()
	_trail_particles.emitting = false
	_trail_particles.amount = 10
	_trail_particles.lifetime = 0.5
	_trail_particles.speed_scale = 1.0
	_trail_particles.explosiveness = 0.0
	_trail_particles.local_coords = false  # world-space so trail lingers behind
	_trail_particles.direction = Vector3(0, 1, 0)
	_trail_particles.spread = 20.0
	_trail_particles.initial_velocity_min = 0.5
	_trail_particles.initial_velocity_max = 2.0
	_trail_particles.gravity = Vector3(0, -3.0, 0)
	_trail_particles.scale_amount_min = 0.04
	_trail_particles.scale_amount_max = 0.08
	_trail_particles.color = Color(1.0, 0.85, 0.3, 1.0)
	var gradient := Gradient.new()
	gradient.set_color(0, Color(1.0, 0.9, 0.4, 1.0))
	gradient.set_color(1, Color(1.0, 0.5, 0.1, 0.0))
	_trail_particles.color_ramp = gradient
	var spark_mesh := QuadMesh.new()
	spark_mesh.size = Vector2(0.06, 0.06)
	var mat := StandardMaterial3D.new()
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.8, 0.2)
	mat.emission_energy_multiplier = 4.0
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1.0, 0.85, 0.3, 1.0)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	spark_mesh.material = mat
	_trail_particles.mesh = spark_mesh
	add_child(_trail_particles)

	if goal_activation & GA_DROP_MODEL_ON_SPAWN:
		_needs_drop = true

	Log.info("item_tfgoal %d: group=%d owner=%d team=%d g_a=%d state=%d pos=%s mdl=%s" % [
		goal_no, group_no, owned_by, req_team, goal_activation, goal_state,
		str(position), ent.get("mdl", "")])


func _physics_process(delta: float) -> void:
	if _needs_drop:
		_needs_drop = false
		_do_drop_to_ground()

	_update_trail(delta)
	# Writing a solid's transform in _physics_process means flushing it, same as any
	# other mover — see EntityBase.flush_mover_transform.
	flush_mover_transform()

	if _is_network_client():
		return

	var time := Time.get_ticks_msec() / 1000.0

	# Only if still ACTIVE — a goal its own ops removed stays REMOVED until something restores it.
	if _is_brush and _inactivate_time != 0.0 and time >= _inactivate_time:
		_inactivate_time = 0.0
		if goal_state == GoalState.ACTIVE:
			goal_inactivate(null)

	if _activate_pending_time != 0.0 and time >= _activate_pending_time:
		_activate_pending_time = 0.0
		if not is_instance_valid(_activator):
			_activator = null
		if _activator:
			process_goals(_activator)
		else:
			Log.warn("[item_tfgoal %d] Pending activation skipped: activator no longer valid" % goal_no)

	if _return_time != 0.0 and time >= _return_time:
		goal_return(null, _return_silent)
		_return_time = 0.0
		_return_silent = false

	if _drop_return_time != 0.0 and time >= _drop_return_time:
		if goal_activation & GA_REMOVE_AFTER_PAUSE:
			goal_remove(null)
			if goal_activation & GA_RETURN_AFTER_PAUSE_REMOVE:
				goal_return(null)
		else:
			goal_return(null)
		_drop_return_time = 0.0


## A team-owned goal granting no item (owned_by set, item_to_give == 0) is a base
## objective, not a pickup — e.g. the ww_golem crystal must never be carried off.
func _is_touch_grabbable() -> bool:
	return item_to_give != 0 or owned_by == 0


func _on_body_entered(body: Node3D) -> void:
	if not body is CharacterBody3D:
		return
	if body.get("is_dead"):
		return
	if _is_network_client():
		return
	var time := Time.get_ticks_msec() / 1000.0

	if goal_state != GoalState.INACTIVE:
		return
	if _no_touch_time != 0.0 and time <= _no_touch_time:
		return
	if _is_brush:
		if not (goal_activation & GA_PLAYER_TOUCH):
			return
	else:
		if not _is_touch_grabbable():
			return
		# Guard against a stale body_entered before physics sync
		var dist := global_position.distance_to(body.global_position)
		if dist > TOUCH_GUARD_DIST:
			return
	call_deferred("_deferred_activate", body)  # avoid removing CollisionObject mid-callback


# --- State transitions (override tf_goal_base) ---

func goal_activate(player: Node) -> void:
	if not _try_activate(player):
		return

	if delay_time != 0.0:
		_activate_pending_time = Time.get_ticks_msec() / 1000.0 + delay_time
	else:
		if _is_brush and stay_active > 0.0:
			_inactivate_time = Time.get_ticks_msec() / 1000.0 + stay_active
		process_goals(_activator)
		if _is_brush:
			_area.set_deferred("monitoring", false)

	Log.debug("[item_tfgoal %d] activated by %s" % [goal_no, str(player.name) if player else "null"])


func goal_inactivate(_player: Node) -> void:
	goal_state = GoalState.INACTIVE
	set_entity_visible(true)
	if _carrier:
		_detach()
	if _is_brush and _area:
		_area.set_deferred("monitoring", true)


func goal_remove(player: Node) -> void:
	if _carrier:
		_detach()
	goal_state = GoalState.REMOVED
	set_entity_visible(false)
	_area.set_deferred("monitoring", false)
	_broadcast(_ACTION_REMOVE)

	if goal_activation & GA_RETURN_IF_REMOVE_BY_GOAL:
		# A player-driven removal is a capture already announced by the score stinger, so
		# the return stays silent. A null-player removal (dropped-flag pause timeout) plays
		# the normal "flag returned" stinger.
		_return_silent = player != null
		_return_time = Time.get_ticks_msec() / 1000.0


func goal_restore(_player: Node) -> void:
	if _carrier:
		goal_drop(null)
	_carrier = null
	_carrier_peer_id = 0
	goal_state = GoalState.INACTIVE
	set_entity_visible(true)
	_area.set_deferred("monitoring", true)
	_broadcast(_ACTION_RESTORE)


func goal_return(_player: Node, silent := false) -> void:
	if _carrier:
		_detach()
	# Only a timer-driven return (_player == null, not silent) of a configured flag
	# (noise3/noise4) plays the "flag returned" announcer + map's per-team message.
	# Incidental goalitems (e.g. the ww_hunt notepad) return silently, matching TFC.
	var flag_return := not silent and _player == null and has_return_message()
	_place_item(flag_return)
	if flag_return and not _is_network_client():
		show_return_messages()

	if goal_on_return != 0:
		var g := GoalSystem.get_goal(goal_on_return)
		if g:
			if g.goal_state == GoalState.REMOVED:
				g.goal_restore(_player)
			g.goal_activate(_player)

	Log.debug("[item_tfgoal %d] returned to spawn" % goal_no)


# A carried item trails behind its carrier, so the touch overlap that calls this via
# process_goals never really ends while they hold it — without the _carrier guard below,
# _attach/_broadcast would fire every tick of the entire carry instead of once on pickup.
func goal_grab(player: Node) -> void:
	if not player or not player is CharacterBody3D:
		return
	if player == _carrier:
		return
	Log.info("[item_tfgoal %d] goal_grab: player=%s is_cb3d=%s" % [
		goal_no, str(player.name), str(player is CharacterBody3D)])
	if goal_state != GoalState.ACTIVE:
		goal_state = GoalState.ACTIVE
	_attach(player)
	_return_time = 0.0
	_drop_return_time = 0.0
	set_entity_visible(true)


func goal_drop(player: Node) -> void:
	var drop_pos := global_position
	var exclude_body: Node = player if player else _carrier  # resolve before _detach clears _carrier
	_detach()
	var drop_y := SpatialQuery.ground_y_below(self, drop_pos, exclude_body)
	global_position = drop_pos if drop_y == INF else Vector3(drop_pos.x, drop_y, drop_pos.z)

	var time := Time.get_ticks_msec() / 1000.0
	goal_state = GoalState.INACTIVE
	_drop_return_time = time + pause_time
	_no_touch_time = time + NO_TOUCH_DELAY

	if goal_activation & GA_RETURN_ON_DEATH_DROP:
		_drop_return_time = time

	_broadcast(_ACTION_DROP, 0, global_position)
	Log.info("[item_tfgoal %d] dropped at %s (no_touch until %.1f)" % [goal_no, str(global_position), _no_touch_time])


func process_goals(player: Node) -> void:
	super.process_goals(player)
	if not _is_brush:
		goal_grab(player)



# --- Public queries ---

func get_carrier() -> Node:
	return _carrier


func is_moved() -> bool:
	return _moved


# --- TriggerSystem interface ---

func trigger(activator: Node, _type: TriggerSystem.Type) -> void:
	if goal_state == GoalState.REMOVED:
		return
	goal_activate(activator)


# --- Internal ---

const _ACTION_GRAB := 0
const _ACTION_DROP := 1
const _ACTION_RETURN := 2
const _ACTION_REMOVE := 3
const _ACTION_RESTORE := 4


func _broadcast(action: int, peer_id: int = 0, pos: Vector3 = Vector3.ZERO) -> void:
	Log.info("[item_tfgoal %d] _broadcast: action=%d peer=%d client=%s" % [
		goal_no, action, peer_id, str(_is_network_client())])
	if not _is_network_client():
		NetworkManager.sync_goal_item.rpc(goal_no, action, peer_id, pos)
		# The authority never receives its own call_remote RPC, so the host announces here;
		# clients announce in _local_sync.
		_announce(action, peer_id)


## `param`: RPC's peer_id slot (grabber for GRAB, unused; announce marker for RETURN —
## 0 = play the "flag returned" stinger, 1 = silent).
func _announce(action: int, param: int = 0) -> void:
	match action:
		_ACTION_GRAB:
			# Flags with their own speak keys (!CTF_YOUGOTFLAG etc.) announce the grab
			# themselves — the stinger would just repeat it.
			if speak_coverage() != GoalSystem.SPOKEN_FRIENDLY | GoalSystem.SPOKEN_ENEMY:
				SentenceSystem.play_words(["vox/doop.wav"])
		_ACTION_RETURN:
			if param == 0:
				SentenceSystem.play_words(["vox/flag.wav", "vox/returned.wav"])


func _get_peer_id(player: Node) -> int:
	if not player:
		return 0
	if "peer_id" in player and player.peer_id != 0:  # handles bot puppets (negative ids) too
		return player.peer_id
	return 1  # local player on host


func _attach(player: Node) -> void:
	_carrier = player
	_carrier_peer_id = _get_peer_id(player)
	_moved = true
	# Item stays under _spawn_parent, not reparented to player; _update_trail() follows it each frame.
	if get_parent() != _spawn_parent:
		var wpos := global_position
		get_parent().remove_child(self)
		_spawn_parent.add_child(self)
		global_position = wpos
	if player is Node3D:
		_prev_carrier_pos = player.global_position
		_trail_dir = player.global_basis.z  # start behind facing direction
		var behind: Vector3 = player.global_position + _trail_dir * TRAIL_DISTANCE
		global_position = Vector3(behind.x, player.global_position.y + TRAIL_HEIGHT, behind.z)
	_area.set_deferred("monitoring", false)

	if player.has_method("_add_carried_item"):
		player._add_carried_item(self)

	_broadcast(_ACTION_GRAB, _carrier_peer_id)


func _detach() -> void:
	if not _carrier:
		return
	var player := _carrier
	_carrier = null
	_carrier_peer_id = 0
	_area.set_deferred("monitoring", true)

	if player.has_method("_remove_carried_item"):
		player._remove_carried_item(self)


func _do_drop_to_ground() -> void:
	var ground_y := SpatialQuery.ground_y_below(self, global_position)
	if ground_y != INF:
		Log.info("[item_tfgoal %d] DROP_MODEL_ON_SPAWN: y %.2f -> %.2f" % [
			goal_no, global_position.y, ground_y])
		global_position.y = ground_y
		_spawn_position = position
	else:
		Log.info("[item_tfgoal %d] DROP_MODEL_ON_SPAWN: no ground found below y=%.2f" % [
			goal_no, global_position.y])


func _deferred_activate(body: Node) -> void:
	if not is_instance_valid(body):
		return
	if goal_state != GoalState.INACTIVE:
		return
	# Handles respawn teleport where position was set but not yet flushed to physics.
	await get_tree().physics_frame
	if not is_instance_valid(body):
		return
	if goal_state != GoalState.INACTIVE:
		return
	if not _is_brush:
		if body is Node3D and global_position.distance_to(body.global_position) > TOUCH_GUARD_DIST:
			return
	goal_activate(body)


func _place_item(announce := true) -> void:
	_moved = false
	_carrier = null
	_carrier_peer_id = 0
	goal_state = GoalState.INACTIVE
	if get_parent() != _spawn_parent:
		if get_parent():
			get_parent().remove_child(self)
		_spawn_parent.add_child(self)
	position = _spawn_position
	rotation.y = _spawn_rotation_y
	set_entity_visible(true)
	_area.set_deferred("monitoring", true)
	_drop_return_time = 0.0
	_return_time = 0.0
	_no_touch_time = 0.0
	# RETURN reuses the peer_id slot as a silent marker (1 = capture return, no stinger).
	_broadcast(_ACTION_RETURN, 0 if announce else 1)


## Client-side visual sync — called from NetworkManager RPC.
func _local_sync(action: int, carrier_peer_id: int, pos: Vector3) -> void:
	Log.info("[item_tfgoal %d] _local_sync: action=%d peer=%d pos=%s" % [goal_no, action, carrier_peer_id, str(pos)])
	_announce(action, carrier_peer_id)
	_ensure_world_parent()
	# The branches below reposition the item out of band, so drop stale interp history first —
	# otherwise interp_entities keeps stamping the old trailing position over this write until a
	# capture return moves the item out of PVS and no fresh sample ever corrects it, parking the
	# client's flag at the altar it was captured on.
	if _entity.entity_id >= 0:
		NetworkManager.clear_mover_buffer(_entity.entity_id)
	match action:
		_ACTION_GRAB:
			_carrier_peer_id = carrier_peer_id
			var player := _find_player_by_peer(carrier_peer_id)
			Log.info("[item_tfgoal %d] _local_sync GRAB: player=%s" % [goal_no, str(player.name) if player else "null"])
			if player and player is Node3D:
				var behind : Vector3 =  player.global_position + player.global_basis.z * TRAIL_DISTANCE
				global_position = Vector3(behind.x, player.global_position.y + TRAIL_HEIGHT, behind.z)
			set_entity_visible(true)
		_ACTION_DROP:
			_carrier_peer_id = 0
			global_position = pos
			set_entity_visible(true)
		_ACTION_RETURN:
			_carrier_peer_id = 0
			position = _spawn_position
			rotation.y = _spawn_rotation_y
			set_entity_visible(true)
		_ACTION_REMOVE:
			_carrier_peer_id = 0
			set_entity_visible(false)
		_ACTION_RESTORE:
			_carrier_peer_id = 0
			position = _spawn_position
			rotation.y = _spawn_rotation_y
			set_entity_visible(true)


## Trailing position is simulated host-only and networked normally; clients never set it
## locally, only drive the sparkle visual — keeps the flag subject to ordinary PVS culling.
func _update_trail(delta: float) -> void:
	if not _trail_particles:
		return
	var player: Node3D = null
	if _is_network_client():
		if _carrier_peer_id == 0:
			_trail_particles.emitting = false
			return
		player = _find_player_by_peer(_carrier_peer_id)
	else:
		if not _carrier or not is_instance_valid(_carrier):
			_trail_particles.emitting = false
			return
		player = _carrier as Node3D
	if not player:
		_trail_particles.emitting = false
		return
	# Clients leave global_position to the entity interpolator; only the host simulates it.
	if not _is_network_client():
		# Trail behind movement direction, not facing direction, so turning around while
		# running still shows the chalice trailing behind.
		var move_delta := player.global_position - _prev_carrier_pos
		move_delta.y = 0.0
		_prev_carrier_pos = player.global_position
		if move_delta.length_squared() > 0.0001:
			_trail_dir = _trail_dir.lerp(-move_delta.normalized(), minf(8.0 * delta, 1.0))
		if _trail_dir.length_squared() < 0.01:
			_trail_dir = player.global_basis.z  # fall back to facing direction when standing still
		var trail_offset := _trail_dir.normalized() * TRAIL_DISTANCE
		var target := player.global_position + Vector3(trail_offset.x, TRAIL_HEIGHT, trail_offset.z)
		global_position = global_position.lerp(target, minf(TRAIL_LERP * delta, 1.0))
	var away_from_carrier := global_position - player.global_position
	if away_from_carrier.length_squared() > 0.01:
		_trail_particles.direction = away_from_carrier.normalized()
	_trail_particles.emitting = true


func _ensure_world_parent() -> void:
	if get_parent() != _spawn_parent:
		var wpos := global_position
		if get_parent():
			get_parent().remove_child(self)
		_spawn_parent.add_child(self)
		global_position = wpos


func _get_sync_state() -> Dictionary:
	var state := {}
	if goal_state != GoalState.INACTIVE or _moved:
		state["goal_state"] = goal_state
	if _carrier_peer_id != 0:
		state["carrier_peer"] = _carrier_peer_id
	if _moved and _carrier_peer_id == 0:
		state["drop_pos"] = global_position
	if _game_visible != _initial_visible:
		state["visible"] = _game_visible
	return state


func _apply_sync_state(state: Dictionary) -> void:
	_ensure_world_parent()
	if "goal_state" in state:
		var gs: int = state["goal_state"]
		match gs:
			GoalState.REMOVED:
				set_entity_visible(false)
			_:
				set_entity_visible(true)
	if "carrier_peer" in state:
		_carrier_peer_id = state["carrier_peer"]
		var player := _find_player_by_peer(_carrier_peer_id)
		if player and player is Node3D:
			var behind : Vector3 = player.global_position + player.global_basis.z * TRAIL_DISTANCE
			global_position = Vector3(behind.x, player.global_position.y + TRAIL_HEIGHT, behind.z)
		set_entity_visible(true)
	elif "drop_pos" in state:
		_carrier_peer_id = 0
		global_position = state["drop_pos"]
	if "visible" in state:
		set_entity_visible(state["visible"])


func _find_player_by_peer(peer_id: int) -> Node:
	var main_scene = get_tree().current_scene
	if not main_scene:
		return null
	if peer_id == multiplayer.get_unique_id():
		return Game.local_player
	return NetworkManager.get_player(peer_id)  # handles remote players and bots (negative ids)
