class_name MoverNetPublisher
extends Node

## The mover transform replication protocol as one composed unit: the five replicated shadow props,
## the MultiplayerSynchronizer that carries them, and the publish/apply funnel at each end.
##
## Composed in (EntityBase._setup_mover_sync) rather than inherited, because only the entities that
## call _register_for_sync() stream a transform while every EntityBase subclass would otherwise
## carry the protocol — func_illusionary and env_glow have no business holding a mover_net_angvel.
##
## Sits under the entity as "MoverNet", the shape NetInterpBridge already has for dynamic entities.
## Its MoverSync stays a child of the ENTITY, not of this node: NetworkManager._on_entity_relevance_lost
## finds the entity a sync belongs to by reading the sync's parent.

## The node name the MOVER_SPEC paths below are written against (a const table can't interpolate
## it, so test_gn_push_declarations pins the two together).
const NODE_NAME := "MoverNet"
const NODE_PATH := ^"MoverNet"  # the same name, prebuilt for of()

## A mover's MoverSync: SyncSpec derives the config and goldnet's quant/push metas from this
## table. mover_net_pos stays unquantized — half-float precision degrades with magnitude and read
## as visible jitter on the golem (removing it cut jitter events ~63%). All five are written by
## publish(), which marks the entity dirty; a slot declaring no push is polled instead, so adding
## one later can't silently stale it.
const MOVER_SPEC := {
	"MoverNet:mover_net_pos": {"push": true},
	"MoverNet:mover_net_rot": {"quant": "vec3_half", "push": true},
	"MoverNet:mover_net_vel": {"push": true},
	"MoverNet:mover_net_angvel": {"push": true},
	"MoverNet:mover_net_stamp": {"quant": "time_delta", "push": true},
}

## Client: a replicated update arrived, which means the entity is relevant to us again. The host
## never emits this (it has no stream to receive).
signal relevance_entered

var mover_net_pos := Vector3.ZERO
var mover_net_rot := Vector3.ZERO
var mover_net_vel := Vector3.ZERO
var mover_net_angvel := Vector3.ZERO
var mover_net_stamp := 0

# Split because they don't always travel together: golem LIMBS want both (server saves
# bandwidth, client driven by the body); the golem BODY wants only interp_skip (still
# streams to observers, client just positions it itself).
var publish_suppressed := false  # server: skip streaming this mover's transform
var interp_skip := false         # client: interp_entities leaves this transform to a parent/self

var _target: Node3D = null
var _entity_id := -1
# Elapsed time between the last two moving publishes, on the same clock as mover_net_stamp
# (Time.get_ticks_msec()) — velocity must be measured on the same clock the position/stamp
# pair uses, or a client's "delta / stamp delta" cross-check disagrees with it (confirmed:
# 30-70% off with a separately-timed clock). Reset to 0 on idle for a fresh baseline.
var _last_moving_publish_msec := 0
var _sync: MultiplayerSynchronizer = null


## The publisher of `node`, or null if it doesn't stream a transform. The one place the node name
## is resolved, so a reader never has to know where the shadow props live.
static func of(node: Node) -> MoverNetPublisher:
	return node.get_node_or_null(NODE_PATH) as MoverNetPublisher if node else null


func _ready() -> void:
	_target = get_parent() as Node3D


## Build the synchronizer and start streaming. Called once, from the host entity's
## _setup_mover_sync, after this node has been added as the entity's child.
func setup(entity_id: int) -> void:
	_target = get_parent() as Node3D  # _ready hasn't run yet when the entity is still being built
	_entity_id = entity_id
	# Built unconditionally (not gated on is_online) since map entities load before networking comes up.
	_sync = SyncSpec.build("MoverSync", MOVER_SPEC)
	NetworkManager.register_pvs_sync(_sync, _visible_to,
		VisibilitySystem.entity_epoch.bind(entity_id))
	_target.add_child(_sync)
	_sync.synchronized.connect(_on_synchronized)
	_sync.delta_synchronized.connect(_on_synchronized)


## Withhold until the peer has loaded the map (an early send poisons the path cache),
## then cull by the same BSP PVS the entity stream uses.
func _visible_to(peer: int) -> bool:
	if not NetworkManager.is_peer_map_ready(peer):
		return false
	return VisibilitySystem.is_entity_visible_to_peer(_entity_id, peer)


## Drop the client's interp history for this mover, so the next sample snaps to the real position
## instead of lerping from a stale one.
func clear_buffer() -> void:
	if _entity_id >= 0:
		NetworkManager.clear_mover_buffer(_entity_id)


## Taking over: server stops streaming, client drops its stale interp buffer. Releasing:
## server clears its stamp so the resumed stream re-seeds instead of publishing a huge
## stale-delta velocity.
func set_externally_driven(on: bool) -> void:
	publish_suppressed = on
	interp_skip = on
	if not NetworkManager.is_authority():
		if on:
			clear_buffer()
	elif not on:
		mover_net_stamp = 0


## Server: publish the mover's authoritative transform into the shadow props, once per net tick.
## Only refreshes on real change, so an idle mover's byte-identical triplet lets ack-delta netcode
## (goldnet) skip it entirely. Stamp freezes at the last real movement's server time.
const _MOVER_MOVED_EPS_SQ := 1e-6  # (0.001 units)² position / radians rotation

func publish() -> void:
	if publish_suppressed:
		return  # a parent contraption drives this mover; don't stream its transform
	var pos := _target.global_position
	var rot := _target.global_rotation
	if pos.distance_squared_to(mover_net_pos) <= _MOVER_MOVED_EPS_SQ \
			and rot.distance_squared_to(mover_net_rot) <= _MOVER_MOVED_EPS_SQ \
			and mover_net_stamp != 0:
		# Abrupt stop: without a zero-vel snapshot, the client buffer extrapolates the
		# last velocity past the real stop and freezes there (a golem rider jitters).
		if mover_net_vel != Vector3.ZERO or mover_net_angvel != Vector3.ZERO:
			mover_net_vel = Vector3.ZERO
			mover_net_angvel = Vector3.ZERO
			mover_net_stamp = Time.get_ticks_msec()
			NetworkManager.mark_entity_dirty(_target)
		_last_moving_publish_msec = 0  # idle: the next real move starts a fresh dt baseline
		return  # idle — shadow frozen so idle movers cost nothing on the wire
	# dt is measured against mover_net_stamp's own clock (Time.get_ticks_msec()), not a separate
	# finer timer or the nominal tick interval: only that clock agrees with what the client
	# actually receives, so cross-checking "delta / stamp delta" against velocity matches up.
	# Skipped on the first publish and the first publish after an idle stretch (no dt baseline yet).
	var stamp_now := Time.get_ticks_msec()
	if mover_net_stamp != 0 and _last_moving_publish_msec != 0:
		var dt := (stamp_now - _last_moving_publish_msec) / 1000.0
		if dt > 0.001:  # guards a near-zero dt from two synchronous publishes (e.g. in a test)
			var lin := (pos - mover_net_pos) / dt
			var max_speed := GameConsts.ENTITY_PUBLISH_TELEPORT_SPEED
			if lin.length_squared() > max_speed * max_speed:
				# Reposition, not travel (e.g. item_tfgoal RETURN/DROP): zero velocity, or the
				# client extrapolates away from the new spot once the stream falls quiet.
				mover_net_vel = Vector3.ZERO
				mover_net_angvel = Vector3.ZERO
			else:
				mover_net_vel = lin
				mover_net_angvel = Vector3(
					angle_difference(mover_net_rot.x, rot.x),
					angle_difference(mover_net_rot.y, rot.y),
					angle_difference(mover_net_rot.z, rot.z)) / dt
	mover_net_pos = pos
	mover_net_rot = rot
	mover_net_stamp = stamp_now
	_last_moving_publish_msec = stamp_now
	NetworkManager.mark_entity_dirty(_target)


## Client: feed the replicated transform into the shared entity interp buffer.
func _on_synchronized() -> void:
	if NetworkManager.is_host():
		return
	# Any replicated update = relevance ENTER (dedup'd by the entity, cheap). Leaves come from the backend.
	relevance_entered.emit()
	NetworkManager.push_mover_snapshot(_entity_id, mover_net_stamp,
		mover_net_pos, mover_net_rot, mover_net_vel, mover_net_angvel)
