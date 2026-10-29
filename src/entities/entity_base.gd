class_name EntityBase
extends Node3D

var ent: Dictionary
var _anim_body: AnimatableBody3D
var _initial_visible := true
var _game_visible := true  # game-logic visibility; unaffected by PVS rendering
var _state_dirty := false
# Client PVS presence: deactivated (hidden + collision off) when the server reports a
# mover left our PVS, so it doesn't linger as a stale ghost. Active = _present AND _game_visible.
var _present := true
@warning_ignore("unused_private_class_variable")
var _transform_node: Node3D = null
var _entity := EntityBehavior.new()

# --- Kinematic velocity sync (movers) ---
# Movers write transforms directly (MoveKinematic model), which teleports the physics
# body with zero velocity, so contacts resolve against an officially motionless wall.
# Publish the implied velocity each physics frame so rigid bodies get carried/struck
# believably. Players don't use this — netmove computes its own carry.
var _mover_last_xform: Transform3D
var _mover_was_moving := false

# --- MultiplayerSynchronizer transport (opt-in) ---
# Movers that call _setup_mover_sync() get their own synchronizer instead of riding the per-tick
# entity-transform RPC. The protocol itself is composed in, not inherited — see MoverNetPublisher;
# null on the entities that never register for sync. NetworkManager drives it off this property.
var _mover_net: MoverNetPublisher = null


## GoldSrc FCAP_IMPULSE_USE: can a player press +use on this entity directly?
## False by default; being *targetable* by a trigger is separate, don't infer this from trigger().
func is_player_usable() -> bool:
	return false


func _is_network_client() -> bool:
	return not NetworkManager.is_authority()


## Network peer_id of a player node (0 if not a player / not found).
func node_peer_id(node: Node) -> int:
	if is_instance_valid(node) and "peer_id" in node:
		return int(node.peer_id)
	return 0


func _ready() -> void:
	_anim_body = get_node(".") as AnimatableBody3D
	_entity.initialize(self)
	ent = get_meta("entity", {})
	var targetname: String = ent.get("targetname", "")
	# A spawner-created entity keeps the unique name the spawner gave it: host and clients have
	# to agree on the node path, and renaming to a bare classname collides (Godot then appends
	# @2 per peer, independently).
	if not has_meta("_dyn_spawner_entity"):
		name = targetname if not targetname.is_empty() else ent.get("classname", "entity")
	if not targetname.is_empty():
		TriggerSystem.register(targetname, self)
	if _anim_body and not _is_network_client():
		_mover_last_xform = _anim_body.global_transform
		get_tree().physics_frame.connect(_sync_kinematic_velocity)


## Runs on physics_frame so it works regardless of how the mover animates (physics
## process, tween, AnimationPlayer) — the per-tick transform delta is the truth.
func _sync_kinematic_velocity() -> void:
	if not is_instance_valid(_anim_body) or not _anim_body.is_inside_tree():
		return
	var xform := _anim_body.global_transform
	if xform == _mover_last_xform:
		if _mover_was_moving:
			_mover_was_moving = false
			PhysicsServer3D.body_set_state(_anim_body.get_rid(),
				PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
			PhysicsServer3D.body_set_state(_anim_body.get_rid(),
				PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, Vector3.ZERO)
		return
	var dt := get_physics_process_delta_time()
	var lin := (xform.origin - _mover_last_xform.origin) / dt
	# Faster than any mover = teleport (map reset) — don't fling resting props.
	if lin.length_squared() > GameConsts.MOVER_TELEPORT_SPEED * GameConsts.MOVER_TELEPORT_SPEED:
		lin = Vector3.ZERO
	var ang := Vector3.ZERO
	var rel_q := (xform.basis * _mover_last_xform.basis.inverse()).get_rotation_quaternion()
	var angle := rel_q.get_angle()
	if angle > 0.0001:
		ang = rel_q.get_axis() * (angle / dt)
	if not _mover_was_moving:
		_mover_was_moving = true
		_wake_touching_props()
	PhysicsServer3D.body_set_state(_anim_body.get_rid(),
		PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, lin)
	PhysicsServer3D.body_set_state(_anim_body.get_rid(),
		PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, ang)
	_mover_last_xform = xform


## Make a transform this mover just wrote visible to physics queries NOW.
##
## The rule every mover owes its riders: WHEN A RIDER TICKS, THE NODE AND THE PHYSICS
## SERVER MUST HOLD THE SAME POSE. A rider's carry is measured off the node's transform
## and its sweep is answered by the server, so if the two disagree the carry pushes the
## rider against geometry the sweep does not know has moved. It ends the tick
## (mover displacement - safe_margin) deep inside: 0.4 units a tick for a walking golem,
## which is the penetration its cockpit riders used to be ejected on.
##
## Godot queues a Node3D's transform change and flushes it to the server only after every
## _physics_process has run, so a mover that writes its transform IN _physics_process
## breaks the rule for anything that ticks after it — and main adds the map before the
## player. This restores it. A mover driven by a TWEEN_PROCESS_PHYSICS tween needs no
## call: the tween writes after every _physics_process, so node and server already agree
## when riders tick, a tick behind but agreeing, and that measures identically.
##
## Measured both ways in hop-godot's tests/probe_wall_press.gd and pinned by
## tests/test_moving_wall_press.gd: zero resting penetration written-and-flushed, zero
## tweened, and 0.399 units written without the flush.
func flush_mover_transform(body: Node3D = null) -> void:
	var node := body if body else _anim_body
	if node:
		node.force_update_transform()


## A mover starting up doesn't wake rigid bodies sleeping on it (a descending floor
## just leaves them floating), so wake anything touching it. Runs once per stop→move edge.
func _wake_touching_props() -> void:
	var space := _anim_body.get_world_3d().direct_space_state
	var params := PhysicsShapeQueryParameters3D.new()
	params.collision_mask = GameConsts.MASK_DYNAMIC | GameConsts.MASK_CORPSE
	params.margin = 0.1
	for child in _anim_body.get_children():
		if child is CollisionShape3D and child.shape:
			params.shape = child.shape
			params.transform = child.global_transform
			for hit in space.intersect_shape(params, 8):
				var b: Object = hit.get("collider")
				if b is RigidBody3D:
					b.sleeping = false


func _register_for_sync() -> void:
	if _entity.entity_id >= 0:
		return  # already registered (e.g. a part adopted by the golem)
	_entity.entity_id = NetworkManager.register_synced_entity(self, self)
	_setup_mover_sync()


## Opt-in (from a mover's setup, after _register_for_sync): route this entity's transform through its
## own MultiplayerSynchronizer instead of the send_entity_transforms batch. The entity stays registered
## (entity_id, PVS tracking, late-join _get_sync_state); only its transform leaves the RPC batch.
func _setup_mover_sync() -> void:
	_mover_net = MoverNetPublisher.new()
	_mover_net.name = MoverNetPublisher.NODE_NAME
	add_child(_mover_net)
	_mover_net.setup(_entity.entity_id)
	_mover_net.relevance_entered.connect(set_present_from_server.bind(true))
	# GoldSrc-faithful presence: client starts each map-static mover ABSENT and materializes it
	# on the first PVS report, avoiding a join-time "hide everything" burst that overran the MTU.
	# Deferred so it runs after _seed_game_visible reads `visible` further down in the caller's
	# _ready — hiding for PVS first made every client entity seed _game_visible = false and stay
	# dark for the whole map (160 of ww_2fort's env_sprites were affected).
	if _is_network_client() and NetworkManager.transport.relevance_events:
		_set_present.call_deferred(false)


## Hand this mover's transform to a parent contraption (the golem) or take it back.
func set_transform_externally_driven(on: bool) -> void:
	if _mover_net:
		_mover_net.set_externally_driven(on)


## Server -> client PVS enter/leave. Host/offline never receive this (their copy stays active).
func set_present_from_server(on: bool) -> void:
	if NetworkManager.is_host():
		return
	_set_present(on)


func _record_initial_visible() -> void:
	_initial_visible = visible


func set_entity_visible(on: bool) -> void:
	_game_visible = on
	_state_dirty = true
	if _entity.entity_id >= 0:
		VisibilitySystem.set_entity_game_visible(_entity.entity_id, on)
	_apply_active_state()


## Call once at the end of _ready — without it the first _get_sync_state() can report a
## stale value and un-hide a start-hidden entity.
func _seed_game_visible() -> void:
	_game_visible = visible
	_record_initial_visible()


## Trigger handlers must funnel through this instead of writing `visible` directly —
## a bare write leaves _game_visible stale, so clients never hear about the change.
func _set_game_visible_synced(on: bool) -> void:
	set_entity_visible(on)
	_sync_notify()


func _set_present(on: bool) -> void:
	if _present == on:
		return
	# Drop stale interp history on re-entry so the first fresh sample snaps to the real
	# position instead of lerping from the pre-leave spot. Clear before pushing the sample.
	if on and _mover_net:
		_mover_net.clear_buffer()
	_present = on
	_apply_active_state()


func _apply_active_state() -> void:
	var active := _game_visible and _present
	visible = active
	for child in get_children():
		if child is CollisionShape3D:
			child.set_deferred("disabled", not active)
		elif child is StaticBody3D or child is AnimatableBody3D:
			child.process_mode = Node.PROCESS_MODE_INHERIT if active else Node.PROCESS_MODE_DISABLED
			for shape in child.get_children():
				if shape is CollisionShape3D:
					shape.set_deferred("disabled", not active)


func _get_sync_state() -> Dictionary:
	if _state_dirty or _game_visible != _initial_visible:
		return {"visible": _game_visible}
	return {}


func _apply_sync_state(state: Dictionary) -> void:
	if "visible" in state:
		set_entity_visible(state["visible"])


func _sync_notify() -> void:
	_state_dirty = true
	_entity.sync_notify()


func _exit_tree() -> void:
	var targetname: String = ent.get("targetname", "")
	if not targetname.is_empty():
		TriggerSystem.unregister(targetname, self)


# --- Rotation axis parsing ---

const SF_ROTATE_BACKWARDS := 2
const SF_ROTATE_X := 128
const SF_ROTATE_Z := 64


func parse_rotation_axis(spawnflags: int) -> Vector3:
	var axis := Vector3.ZERO
	var sign_val := 1.0
	if spawnflags & SF_ROTATE_X:
		axis = Vector3(0, 0, 1)
	elif spawnflags & SF_ROTATE_Z:
		axis = Vector3(1, 0, 0)
		sign_val = -1.0
	else:
		axis = Vector3(0, 1, 0)
	if spawnflags & SF_ROTATE_BACKWARDS:
		sign_val *= -1.0
	return axis * sign_val


# --- GoldSrc entity property parsing ---

func parse_origin(e: Dictionary) -> Vector3:
	return parse_vector3(e.get("origin", "0 0 0"))


func parse_vector3(s: String) -> Vector3:
	var parts := s.split(" ")
	if parts.size() < 3:
		return Vector3.ZERO
	var x := float(parts[0])
	var y := float(parts[1])
	var z := float(parts[2])
	return Vector3(-x * GameConsts.SCALE_FACTOR, z * GameConsts.SCALE_FACTOR, y * GameConsts.SCALE_FACTOR)


func parse_angles(e: Dictionary) -> Vector3:
	if not e.has("angles"):
		return Vector3(0, parse_yaw(e), 0)
	var parts: PackedStringArray = str(e["angles"]).split(" ")
	var pitch := deg_to_rad(-float(parts[0])) if parts.size() > 0 else 0.0
	var yaw := deg_to_rad(float(parts[1])) + PI / 2.0 if parts.size() > 1 else 0.0
	var roll := deg_to_rad(-float(parts[2])) if parts.size() > 2 else 0.0
	return Vector3(pitch, yaw, roll)


func parse_yaw(e: Dictionary) -> float:
	var angle_deg := 0.0
	if e.has("angles"):
		var parts: PackedStringArray = str(e["angles"]).split(" ")
		angle_deg = float(parts[1])
	elif e.has("angle"):
		angle_deg = float(str(e["angle"]))
	else:
		return 0.0
	return deg_to_rad(angle_deg) + PI / 2.0


func parse_spawnflags(e: Dictionary) -> int:
	return int(e.get("spawnflags", "0"))


func parse_color(s: String) -> Color:
	var parts := s.split(" ")
	if parts.size() < 3:
		return Color.WHITE
	var r := float(parts[0]) / 255.0
	var g := float(parts[1]) / 255.0
	var b := float(parts[2]) / 255.0
	var brightness := float(parts[3]) / 255.0 if parts.size() >= 4 else 1.0
	return Color(r * brightness, g * brightness, b * brightness)


func parse_float(e: Dictionary, key: String, default_val: float = 0.0) -> float:
	return float(e.get(key, str(default_val)))


func parse_int(e: Dictionary, key: String, default_val: int = 0) -> int:
	return int(e.get(key, str(default_val)))


func is_brush_entity() -> bool:
	return (ent.get("model", "") as String).begins_with("*")


func parse_movedir(e: Dictionary) -> Vector3:
	if e.has("angles"):
		var parts: PackedStringArray = str(e["angles"]).split(" ")
		var pitch := float(parts[0]) if parts.size() > 0 else 0.0
		var yaw_deg := float(parts[1]) if parts.size() > 1 else 0.0
		if pitch == 0.0 and yaw_deg == -1.0:
			return Vector3.UP
		if pitch == 0.0 and yaw_deg == -2.0:
			return Vector3.DOWN
		var p := deg_to_rad(pitch)
		var y := deg_to_rad(yaw_deg)
		return Vector3(-cos(p) * cos(y), -sin(p), cos(p) * sin(y))
	var angle := float(e.get("angle", "0"))
	if angle == -1.0:
		return Vector3.UP
	if angle == -2.0:
		return Vector3.DOWN
	var rad := deg_to_rad(angle)
	return Vector3(-cos(rad), 0.0, sin(rad))
