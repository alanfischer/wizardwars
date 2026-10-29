class_name NetInterpBridge
extends Node

## Client-side smoothing bridge for spawner-managed dynamic entities (projectiles, corpses, plants, …).
## Replicates net_pos/net_rot/net_vel/net_angvel/net_stamp shadow props so these entities ride the
## same clock-synced interp buffer as movers/players, instead of snapping each net-tick packet
## straight onto the node (which made fast projectiles stutter).

var net_pos := Vector3.ZERO
var net_rot := Vector3.ZERO
var net_vel := Vector3.ZERO
var net_angvel := Vector3.ZERO
var net_stamp := 0
## Host clock at the spawn, from the spawn data; cleared once the spawn pose is seeded.
var born_ms := 0
## Server time of the earliest sample interp holds: the seeded spawn pose, else the first snapshot.
var first_ms := 0
## Authority's current animation, replicated as a shadow prop (like the transform fields).
var net_anim := "":
	set(value):
		if net_anim == value:
			return
		net_anim = value
		# goldnet only re-reads entities marked dirty; root is _target, not this bridge.
		if _target != null:
			NetworkManager.mark_entity_dirty(_target)
		play_anim()

var _target: Node3D
var _anim_player: AnimationPlayer
var _cid := -1
var _present := true  # whether we still believe we know where this entity is


## Called by EntityBehavior once the host has built its model.
func set_anim_player(anim_player: AnimationPlayer) -> void:
	_anim_player = anim_player
	play_anim()  # the authority's animation may already have arrived


func play_anim() -> void:
	if not _anim_player or net_anim.is_empty():
		return
	if _anim_player.has_animation(net_anim) and _anim_player.current_animation != net_anim:
		_anim_player.play(net_anim)


func _ready() -> void:
	_target = get_parent() as Node3D
	if _target == null:
		return
	if NetworkManager.is_authority():
		# Publish immediately so spawn-time sync carries the real transform, not the default
		# (0,0,0), which would lerp the entity in from the world origin.
		_publish()
		set_physics_process(true)
	else:
		set_physics_process(false)
		_cid = int(_target.get_instance_id())
		NetworkManager.register_interp_node(_cid, _target)
		_target.tree_exiting.connect(_on_target_exiting)


func _physics_process(delta: float) -> void:
	_publish(delta)


## Refresh the shadow only when the target moved, so a settled entity ships a byte-identical
## triplet that ack-delta netcode skips — GoldSrc idle-free, same as movers.
const _MOVED_EPS_SQ := 1e-6  # (0.001 units)² position / radians rotation
## Banked across frames the early-out below skips. Uses frame deltas, not the net_stamp clock
## (whole milliseconds) — two publishes in one ms would divide by zero elapsed time.
var _since_publish := 0.0

func _publish(delta := 0.0) -> void:
	_since_publish += delta
	var pos := _target.global_position
	var rot := _target.global_rotation
	if net_stamp != 0 \
			and pos.distance_squared_to(net_pos) <= _MOVED_EPS_SQ \
			and rot.distance_squared_to(net_rot) <= _MOVED_EPS_SQ:
		# The last sample still carries the final move's velocity, so the client buffer would
		# extrapolate past the real stop and freeze there instead of at rest. Emit one zero-vel
		# snapshot so extrapolation resolves to the resting position, then go idle as usual.
		if net_vel != Vector3.ZERO or net_angvel != Vector3.ZERO:
			net_vel = Vector3.ZERO
			net_angvel = Vector3.ZERO
			net_stamp = Time.get_ticks_msec()
			NetworkManager.mark_entity_dirty(_target)
		return
	# Velocity/angvel let the client buffer extrapolate through a dropped/late packet instead of
	# freezing then snapping. Derived from pos/rot delta (angle-wrapped) so it works generically
	# for any bridge-managed entity. net_pos/net_rot still hold the previous values here.
	if _since_publish > 0.0:
		var vel := (pos - net_pos) / _since_publish
		var max_speed := GameConsts.ENTITY_PUBLISH_TELEPORT_SPEED
		if vel.length_squared() > max_speed * max_speed:
			net_vel = Vector3.ZERO  # a reposition, not travel — let the client snap
			net_angvel = Vector3.ZERO
		else:
			net_vel = vel
			net_angvel = Vector3(
				angle_difference(net_rot.x, rot.x),
				angle_difference(net_rot.y, rot.y),
				angle_difference(net_rot.z, rot.z)) / _since_publish
	net_pos = pos
	net_rot = rot
	net_stamp = Time.get_ticks_msec()
	_since_publish = 0.0
	NetworkManager.mark_entity_dirty(_target)


## Connected to the synchronizer's synchronized / delta_synchronized signals on the client.
func _on_synced() -> void:
	if born_ms > 0:
		_seed_spawn_pose()
	if first_ms == 0:
		first_ms = net_stamp
	NetworkManager.push_mover_snapshot(_cid, net_stamp, net_pos, net_rot, net_vel, net_angvel)
	if not _present:
		# Write the resumed position before showing, or the reveal frame renders at the
		# stale position and interp only corrects it a frame later.
		_target.global_position = net_pos
		_target.global_rotation = net_rot
		set_present(true)


## Called once the buffer has gone stale past extrapolation. If the entity's last known state was
## moving, we've lost track of where it really is — hide it rather than stranding it mid-air at the
## tick it went quiet. A resting entity already sent an explicit zero-velocity sample (see _publish),
## so a quiet stream after that is not stale, which is what makes this safe to drive off the stream
## alone rather than transport-specific relevance events.
func park_if_stream_died() -> void:
	if not _present:
		return
	if net_vel == Vector3.ZERO and net_angvel == Vector3.ZERO:
		return
	set_present(false)


## The first snapshot can be a tick or two of flight past the spawn, so start interp from the spawn
## pose at born_ms. A create held back for PVS is too old to seed: the entity has moved since.
const _SEED_WINDOW_MS := 100

func _seed_spawn_pose() -> void:
	var age := net_stamp - born_ms
	if age > 0 and age <= _SEED_WINDOW_MS:
		NetworkManager.push_mover_snapshot(_cid, born_ms, _target.global_position, net_rot, Vector3.ZERO)
		first_ms = born_ms
	born_ms = 0


func set_present(on: bool) -> void:
	if _present == on or _target == null:
		return
	_present = on
	if not on:
		# A resumed stream must snap to the entity's real position, not lerp from a stale sample.
		NetworkManager.clear_mover_buffer(_cid)
	_target.visible = on


func _on_target_exiting() -> void:
	NetworkManager.unregister_interp_node(_cid)
