extends Node
## BSP PVS visibility system for Wizard Wars.
##
## Thin coordinator over the VisibilityManager GDExtension node, which owns
## all BSP math (observer PVS caching, AABB→leaf-set queries, visibility checks).
##
## set_local_position() drives client rendering — call every physics frame.
## set_peer_position()  drives server network filtering — call at net tick rate.

var _vm: Object = null  # VisibilityManager when extension is loaded
var _local_observer: int = -1   # observer handle for the local camera

## Per-entity tracking record. A typed object rather than a string-keyed Dictionary so the
## hot per-frame AABB-update and cull loops use direct member access — no per-field string
## hashing every frame for every tracked entity.
class EntityEntry:
	var handle: int = -1
	var node: Node3D = null
	var local_aabb: AABB = AABB()
	var local_aabb_computed: bool = false
	var aabb_tries: int = 0  # frames spent retrying an empty visual-AABB compute (see _AABB_MAX_TRIES)
	var last_xform: Transform3D = Transform3D()
	var game_visible: bool = true

## Per-worldspawn-leaf-set tracking record (static geometry groups).
class LeafEntry:
	var handle: int = -1
	var node: Node3D = null

# entity_id → EntityEntry
var _entities: Dictionary = {}

# node_id → LeafEntry
var _leaf_sets: Dictionary = {}

# Player puppets registered for server-side PVS send filtering. Kept separate from _entities
# on purpose: player rendering is driven by network presence (the host only sends a player's
# state to peers who can see it), not by the local observer's PVS, so players get an AABB
# handle for is_player_visible_to_peer without ever being locally culled. peer_id → EntityEntry
var _player_entries: Dictionary = {}

# Fixed local-space hull box used as every player's PVS footprint. Players link into all
# leaves this box touches (GoldSrc SV_FindTouchedLeafs parity) rather than a single origin
# leaf, so a player straddling a leaf boundary stays visible from both sides. Sized to the
# standing hull (~1m wide, ~1.9m tall) in scaled world metres.
const _PLAYER_HULL_AABB := AABB(Vector3(-0.5, 0.0, -0.5), Vector3(1.0, 1.9, 1.0))

# Half-extent (metres) of the fallback box for an entity with no visual bounds (yet or ever). Culling
# by a zero-size point is fragile — it can fall into a solid/occluded leaf and wrongly hide the entity;
# a small box links it into the surrounding leaf set (GoldSrc SV_FindTouchedLeafs parity), failing visible.
const _DEGENERATE_AABB_PAD := 0.5
# Frames to keep re-attempting the visual-AABB compute before treating the entity as genuinely
# visual-less (visuals load within a few frames).
const _AABB_MAX_TRIES := 240

# peer_id → observer handle
var _peer_observers: Dictionary = {}

# PVS change epochs (server-side send filtering): a PVS answer is a pure function of the
# entity's registered leaf set and the observer's PVS, which is rebuilt only when it crosses
# into a new leaf — so these counters make "did it change?" a cheap int compare, letting
# NetworkManager.push_pvs_visibility skip whole rows/columns instead of re-evaluating every
# (entity × peer) pair at 30Hz, which was the server's dominant cost. Only inequality matters,
# never magnitude — always read as `epoch != last_epoch`.
var _entity_epoch: Dictionary = {}  # entity_id → int, bumped when its registered leaf set changes
var _player_epoch: Dictionary = {}  # peer_id → int, same for a tracked player puppet
var _peer_epoch: Dictionary = {}    # peer_id → int, bumped when that observer crosses a leaf
var _peer_leaf: Dictionary = {}     # peer_id → int, last observer leaf seen (drives _peer_epoch)

# entity_id set (→ true) of entries whose PVS answer may have changed since the last cull:
# leaf set re-registered this tick, newly tracked, or game visibility toggled. Consumed and
# cleared by _cull_local. See the invariant documented there.
var _dirty: Dictionary = {}

# True once set_local_position() has been called at least once. Prevents the
# server (which has no local player) from running PVS-based visibility toggling
# and avoids the brief window before the client's first player position update.
var _local_position_valid := false

# Last observer position pushed via set_local_position(), used to detect spawn/teleport
# jumps that need an immediate re-cull (see set_local_position). Vector3.INF = none yet.
var _last_local_pos := Vector3.INF

# A jump larger than this (metres) is treated as a spawn/teleport rather than normal
# movement, triggering an immediate re-cull so the frame doesn't render stale PVS.
const RECULL_JUMP_DIST := 2.0

# Last observer BSP leaf the worldspawn leaf-sets were culled against; the leaf-set loop
# is skipped while unchanged. -1 is a safe "none yet / force re-cull" sentinel since a
# real leaf is always >= 0 (the `leaf < 0` guard in _cull_local returns before storing one).
const _LEAF_NONE := -1
var _last_culled_leaf: int = _LEAF_NONE


func setup(scene_root: Node) -> void:
	teardown()
	if not ClassDB.class_exists(&"VisibilityManager"):
		_disabled_reason = "extension missing"
		Log.info("[Visibility] VisibilityManager extension not available — PVS disabled")
		return
	# One stripped BSP serves both PVS and hull collision — see MapConverter.
	var bsp_data: PackedByteArray = scene_root.get_meta("bsp_data", PackedByteArray())
	if bsp_data.is_empty():
		_disabled_reason = "no bsp_data in scene (map needs reconversion)"
		Log.info("[Visibility] No bsp_data in scene metadata — PVS disabled (map needs reconversion)")
		return
	_vm = ClassDB.instantiate(&"VisibilityManager")
	var leaf_count: int = _vm.setup_from_data(bsp_data, GameConsts.SCALE_FACTOR)
	if leaf_count == 0:
		_disabled_reason = "setup_from_data returned 0 leaves"
		Log.info("[Visibility] setup_from_data returned 0 leaves — PVS disabled (corrupt or incompatible data)")
		_vm = null
		return
	_local_observer = _vm.add_observer(0, Vector3.ZERO)
	Log.info("[Visibility] BSP loaded from scene metadata: %d leaves, bsp_data=%d bytes" % [leaf_count, bsp_data.size()])


func _exit_tree() -> void:
	teardown()


func teardown() -> void:
	if _vm:
		_vm.teardown()
		_vm.free()
		_vm = null
	_local_observer = -1
	_local_position_valid = false
	_last_local_pos = Vector3.INF
	_last_culled_leaf = _LEAF_NONE
	_disabled_reason = ""
	_entities.clear()
	_leaf_sets.clear()
	_player_entries.clear()
	_peer_observers.clear()
	_dirty.clear()
	_entity_epoch.clear()
	_player_epoch.clear()
	_peer_epoch.clear()
	_peer_leaf.clear()


## Update local camera observer. Call every physics frame while a local player exists.
func set_local_position(pos: Vector3) -> void:
	_local_position_valid = true
	if not _vm:
		return
	# VisibilitySystem (autoload) runs its cull pass earlier in the frame than the caller
	# that pushes this position, so the cull always uses the *previous* position. For normal
	# sub-metre movement that one-frame lag is invisible, but a spawn/teleport jumps the
	# observer across the map — the frame about to render would show stale PVS (missing
	# geometry) for one frame. Detect the jump and re-cull now, before this frame draws.
	var jumped := _last_local_pos != Vector3.INF and _last_local_pos.distance_to(pos) > RECULL_JUMP_DIST
	_last_local_pos = pos
	_vm.update_observer_position(_local_observer, pos)
	if jumped:
		_cull_local()


## Update a server-side peer observer. Creates the observer on first call for this peer.
func set_peer_position(peer_id: int, pos: Vector3) -> void:
	if not _vm:
		return
	var handle: int = _peer_observers.get(peer_id, -1)
	if handle == -1:
		handle = _vm.add_observer(peer_id, pos)
		_peer_observers[peer_id] = handle
	else:
		_vm.update_observer_position(handle, pos)
	# One native leaf query per peer per tick (not per entity per peer) buys the epoch that lets
	# the send filter skip this peer's whole column while it stays in the same leaf — which, for a
	# player walking normally, is the overwhelming majority of ticks.
	var leaf: int = _vm.get_observer_leaf(handle)
	if leaf != int(_peer_leaf.get(peer_id, _LEAF_NONE - 1)):
		_peer_leaf[peer_id] = leaf
		_peer_epoch[peer_id] = int(_peer_epoch.get(peer_id, 0)) + 1


func remove_peer(peer_id: int) -> void:
	# Erased before the _vm guard: these are plain bookkeeping and must not outlive the peer even
	# when PVS is disabled. (The send filter drops its own cached column too, so a recycled peer id
	# is re-evaluated from scratch either way — this is about not leaking, not about correctness.)
	_peer_epoch.erase(peer_id)
	_peer_leaf.erase(peer_id)
	if not _vm:
		return
	var handle: int = _peer_observers.get(peer_id, -1)
	if handle != -1:
		_vm.remove_observer(handle)
		_peer_observers.erase(peer_id)


## Is a tracked player potentially visible from the LOCAL camera? Mirrors is_player_visible_to_peer
## but against the local observer, so the listen-server host culls remote puppets on its own
## screen the same way clients do. Fail-open until the host has a valid local view (dedicated
## servers / pre-spawn) and when PVS or the player's AABB handle is unavailable.
func is_player_locally_visible(peer_id: int) -> bool:
	if not _vm or not _local_position_valid:
		return true
	var entry: EntityEntry = _player_entries.get(peer_id)
	if entry == null or entry.handle == -1:
		return true
	return _vm.is_entity_visible_to_observer(entry.handle, _local_observer)


## Change counter for one entity's PVS inputs — see _entity_epoch. Callers cache the value
## alongside a computed visibility answer and recompute only when it differs.
func entity_epoch(entity_id: int) -> int:
	return int(_entity_epoch.get(entity_id, 0))


## Change counter for one tracked player puppet's PVS inputs — see _entity_epoch.
func player_epoch(peer_id: int) -> int:
	return int(_player_epoch.get(peer_id, 0))


## Change counter for one peer observer's PVS — bumps when that peer crosses into a new leaf,
## which is the only thing that rebuilds its PVS and so the only thing that can change what it
## can see. See _peer_epoch.
func peer_epoch(peer_id: int) -> int:
	return int(_peer_epoch.get(peer_id, 0))


## Is entity_id potentially visible to peer_id? Uses AABB-based leaf set (same
## query as client rendering). Untracked entities are always sent.
func is_entity_visible_to_peer(entity_id: int, peer_id: int) -> bool:
	if not _vm:
		return true
	var obs: int = _peer_observers.get(peer_id, -1)
	if obs == -1:
		return true
	var entry: EntityEntry = _entities.get(entity_id)
	if entry == null:
		return true
	var h: int = entry.handle
	if h == -1:
		return true
	return _vm.is_entity_visible_to_observer(h, obs)


## PVS diagnostic (scoreboard): [visible, total] tracked entities for a peer's observer, computed on demand at ~2 Hz.
func count_visible_to_peer(peer_id: int) -> Vector2i:
	var total: int = _entities.size()
	if not _vm:
		return Vector2i(total, total)
	var obs: int = _peer_observers.get(peer_id, -1)
	if obs == -1:
		return Vector2i(total, total)
	var visible := 0
	for eid in _entities:
		var entry: EntityEntry = _entities[eid]
		if entry.handle == -1 or _vm.is_entity_visible_to_observer(entry.handle, obs):
			visible += 1
	return Vector2i(visible, total)


## Register a node for automatic client rendering visibility toggling.
## The node's world-space AABB is derived from its visual subtree and pushed
## through the BSP to find its leaf set. The leaf set recomputes automatically
## in _physics_process whenever the node's transform changes.
func track_node(entity_id: int, node: Node) -> void:
	if not (node is Node3D):
		return
	var n := node as Node3D
	var in_tree := n.is_inside_tree()
	var local_aabb := _compute_local_aabb(n) if in_tree else AABB()
	var handle := -1
	if _vm and in_tree:
		handle = _vm.register_entity(_world_aabb(n, local_aabb))
	var entry := EntityEntry.new()
	entry.handle = handle
	entry.node = n
	entry.local_aabb = local_aabb
	# Never lock the AABB at registration: entities register during _ready before (or while building)
	# their visual, so _refresh_entry_aabb tracks it until the bounds SETTLE, matching the real sprite/mesh.
	entry.local_aabb_computed = false
	entry.last_xform = n.global_transform if in_tree else Transform3D()
	entry.game_visible = true
	_entities[entity_id] = entry
	_entity_epoch[entity_id] = int(_entity_epoch.get(entity_id, 0)) + 1
	_dirty[entity_id] = true  # never culled yet — needs an initial evaluation


## Called by EntityBase.set_entity_visible to keep game-intended visibility in sync.
func set_entity_game_visible(entity_id: int, on: bool) -> void:
	var entry: EntityEntry = _entities.get(entity_id)
	if entry != null:
		entry.game_visible = on
		# Unconditional, even when `on` is unchanged: the caller (EntityBase.set_entity_visible)
		# writes node.visible itself right after, so the cull has to re-assert over that write.
		_dirty[entity_id] = true


## Pin an entity's PVS footprint (node-local) instead of deriving it from its visual subtree, for
## an entity that draws somewhere else — env_beam's strip lives in a top_level holder at the origin.
func set_entity_local_aabb(entity_id: int, local_aabb: AABB) -> void:
	var entry: EntityEntry = _entities.get(entity_id)
	if entry == null:
		return
	entry.local_aabb = local_aabb
	entry.local_aabb_computed = true
	entry.last_xform = Transform3D()  # force re-push of the world AABB


func untrack_node(entity_id: int) -> void:
	var entry: EntityEntry = _entities.get(entity_id)
	if entry == null:
		return
	var h: int = entry.handle
	if _vm and h != -1:
		_vm.unregister_entity(h)
	_entities.erase(entity_id)
	_dirty.erase(entity_id)
	# Untracking flips the answer to "always send", and the epoch dicts must not outlive their
	# entries (projectiles churn through ids), so drop it rather than bumping it. A re-tracked id
	# always comes with a NEW synchronizer, and the send filter caches per synchronizer, so a
	# recycled id can never collide with a stale cached row.
	_entity_epoch.erase(entity_id)


## Register a player puppet for server-side PVS send filtering (host-only consumer).
## Uses the fixed hull footprint rather than the visual subtree so first-person locals
## (whose model may be hidden) and freshly-spawned puppets still get a correct AABB.
func track_player(peer_id: int, node: Node3D) -> void:
	if not (node is Node3D):
		return
	var n := node as Node3D
	var entry := EntityEntry.new()
	entry.node = n
	entry.local_aabb = _PLAYER_HULL_AABB
	entry.local_aabb_computed = true
	entry.game_visible = true
	if _vm and n.is_inside_tree():
		entry.handle = _vm.register_entity(_world_aabb(n, _PLAYER_HULL_AABB))
		entry.last_xform = n.global_transform
	_player_entries[peer_id] = entry
	_player_epoch[peer_id] = int(_player_epoch.get(peer_id, 0)) + 1


func untrack_player(peer_id: int) -> void:
	var entry: EntityEntry = _player_entries.get(peer_id)
	if entry == null:
		return
	if _vm and entry.handle != -1:
		_vm.unregister_entity(entry.handle)
	_player_entries.erase(peer_id)
	_player_epoch.erase(peer_id)


## Is target_peer's player potentially visible to observer_peer? The host queries this to
## decide which players to include in each peer's state packet. Returns true (send) for
## self, for an observer we have no leaf for yet, for an untracked target, and when PVS is
## disabled (no BSP) — same fail-open contract as is_entity_visible_to_peer.
func is_player_visible_to_peer(target_peer_id: int, observer_peer_id: int) -> bool:
	if not _vm or target_peer_id == observer_peer_id:
		return true
	var obs: int = _peer_observers.get(observer_peer_id, -1)
	if obs == -1:
		return true
	var entry: EntityEntry = _player_entries.get(target_peer_id)
	if entry == null or entry.handle == -1:
		return true
	return _vm.is_entity_visible_to_observer(entry.handle, obs)


## The peers whose PVS reaches `box`: GoldSrc's MSG_PVS, for a one-shot effect that has no tracked
## entity to ask about. Fail-open like the rest — no PVS, or a peer with no observer yet, is sent.
func peers_seeing(box: AABB, peers: PackedInt32Array) -> PackedInt32Array:
	if not _vm:
		return peers
	if not box.has_volume():
		box = box.grow(_DEGENERATE_AABB_PAD)
	var handle: int = _vm.register_entity(box)
	var out := PackedInt32Array()
	for peer_id in peers:
		var obs: int = _peer_observers.get(peer_id, -1)
		if obs == -1 or _vm.is_entity_visible_to_observer(handle, obs):
			out.append(peer_id)
	_vm.unregister_entity(handle)
	return out


## Register a worldspawn spatial group using its pre-baked BSP leaf set.
func track_node_by_leaves(node_id: int, node: Node3D, leaves: PackedInt32Array) -> void:
	var handle := -1
	if _vm:
		handle = _vm.register_leaf_set(leaves)
	var entry := LeafEntry.new()
	entry.handle = handle
	entry.node = node
	_leaf_sets[node_id] = entry
	# Force the next _cull_local to re-evaluate leaf-sets even if the observer hasn't
	# moved leaves, so this newly-tracked node gets its initial visibility set.
	_last_culled_leaf = _LEAF_NONE


## _physics_process: update entity AABBs every frame (server + client) so server-side
## PVS filtering stays accurate for moving entities. Visual culling is client-only.
func _physics_process(_delta: float) -> void:
	if not _vm:
		return
	for entity_id: int in _entities:
		if _refresh_entry_aabb(_entities[entity_id]):
			_dirty[entity_id] = true
			_entity_epoch[entity_id] = int(_entity_epoch.get(entity_id, 0)) + 1
	for peer_id: int in _player_entries:
		# Players are never locally culled, but the server DOES gate sends on their leaf set,
		# so the return value that _cull_local uses for entities still has to be recorded here.
		if _refresh_entry_aabb(_player_entries[peer_id]):
			_player_epoch[peer_id] = int(_player_epoch.get(peer_id, 0)) + 1
	if _local_position_valid:
		_cull_local()


## Keep one tracked entry's registered AABB in sync with its node: lazily computes the local
## AABB on the first in-tree frame (skipped for players, fixed at track_player), registers the
## handle once ready, and re-pushes the world AABB only when the transform changes. Shared by
## entity and player tracking. Returns true when the leaf set changed (the sole movement detector).
func _refresh_entry_aabb(entry: EntityEntry) -> bool:
	var node := entry.node
	if not is_instance_valid(node) or not node.is_inside_tree():
		return false
	if not entry.local_aabb_computed:
		var computed := _compute_local_aabb(node)
		entry.aabb_tries += 1
		# Lock in the visual bounds once SETTLED (non-empty and unchanged since last frame): follow the
		# real bounds until they stop changing rather than grabbing a half-built first value. Visual-less
		# entities never settle → give up at the cap and keep the padded-box footprint.
		var settled := computed.size != Vector3.ZERO and computed.is_equal_approx(entry.local_aabb)
		entry.local_aabb = computed
		if settled or entry.aabb_tries >= _AABB_MAX_TRIES:
			entry.local_aabb_computed = true
		entry.last_xform = Transform3D()  # force re-push of the (updated) world AABB
	if entry.handle == -1:
		entry.handle = _vm.register_entity(_world_aabb(node, entry.local_aabb))
		entry.last_xform = node.global_transform
		return true
	var xform := node.global_transform
	if xform != entry.last_xform:
		_vm.update_entity_aabb(entry.handle, _world_aabb(node, entry.local_aabb))
		entry.last_xform = xform
		return true
	return false


## Toggle visibility for tracked entities and worldspawn leaf-sets against the current
## local observer. Assumes entity AABBs are already current (kept up to date in
## _physics_process). Runs every frame while culling is active, and again immediately on a
## spawn/teleport jump (set_local_position) so the jumped-to frame never renders stale PVS.
## No-op until the observer has a valid leaf (e.g. spawned into the void).
func _cull_local() -> void:
	var leaf: int = _vm.get_observer_leaf(_local_observer)
	if leaf < 0:
		return
	# While the observer holds its leaf, an entity's PVS answer can only change for entries
	# marked dirty — on a typical frame that is none of the several hundred tracked entities.
	var leaf_changed := leaf != _last_culled_leaf
	# GoldSrc model: the SERVER's PVS is the single relevance authority, and a remote client
	# renders exactly what the host relays (EntityBase._present) with no local PVS query, which
	# would disagree near leaf boundaries. So this local cull only runs on the authority
	# (host/offline); worldspawn leaf-sets (below) are static and culled locally everywhere.
	if NetworkManager.is_authority():
		if leaf_changed:
			for entity_id: int in _entities:
				_apply_entity_visibility(_entities[entity_id])
		else:
			for entity_id: int in _dirty:
				var entry: EntityEntry = _entities.get(entity_id)
				if entry != null:
					_apply_entity_visibility(entry)
	_dirty.clear()
	# Worldspawn leaf-sets are static geometry: their PVS visibility only changes when
	# the observer crosses into a different leaf. Skip the whole loop (and its per-node
	# extension calls) on the common frames where the leaf is unchanged.
	if not leaf_changed:
		return
	_last_culled_leaf = leaf
	for node_id: int in _leaf_sets:
		var entry: LeafEntry = _leaf_sets[node_id]
		var node := entry.node
		if not is_instance_valid(node):
			continue
		var handle: int = entry.handle
		node.visible = _vm.is_leaf_set_visible_to_observer(handle, _local_observer) if handle != -1 else true


## Push one entry's PVS ∧ game visibility onto its node. Only assigns when the value changes —
## the Node3D setter propagates to the whole subtree.
func _apply_entity_visibility(entry: EntityEntry) -> void:
	var node := entry.node
	if not is_instance_valid(node):
		return
	var handle: int = entry.handle
	var pvs_vis: bool = _vm.is_entity_visible_to_observer(handle, _local_observer) if handle != -1 else true
	var want: bool = pvs_vis and entry.game_visible
	if node.visible != want:
		node.visible = want


## One-line reason string for when PVS is disabled.
var _disabled_reason := ""

## Returns a one-line status: "ok: leaf=N ents=V/T leafsets=V/T" or "disabled: <reason>".
func get_debug_info() -> String:
	if not _vm:
		var reason := _disabled_reason if not _disabled_reason.is_empty() else "no BSP"
		return "Client PVS: disabled (%s)" % reason
	var leaf = _vm.get_observer_leaf(_local_observer)
	var ent_vis := 0
	var ent_total := _entities.size()
	for entry: EntityEntry in _entities.values():
		var n := entry.node
		if is_instance_valid(n) and n.visible:
			ent_vis += 1
	var ls_vis := 0
	var ls_total := _leaf_sets.size()
	for entry: LeafEntry in _leaf_sets.values():
		var n := entry.node
		if is_instance_valid(n) and n.visible:
			ls_vis += 1
	return "Client PVS: leaf=%d  ents=%d/%d  leafsets=%d/%d" % [leaf, ent_vis, ent_total, ls_vis, ls_total]


func _world_aabb(node: Node3D, local_aabb: AABB) -> AABB:
	if local_aabb.size == Vector3.ZERO:
		# No visual bounds → pad into a small box instead of a zero-size point (see _DEGENERATE_AABB_PAD).
		var p := node.global_position
		return AABB(p - Vector3.ONE * _DEGENERATE_AABB_PAD, Vector3.ONE * (_DEGENERATE_AABB_PAD * 2.0))
	return node.global_transform * local_aabb


## Walk the visual subtree once to build a merged AABB in the node's local space.
## Result is cached by callers — this runs at most once per entity lifetime.
func _compute_local_aabb(root: Node3D) -> AABB:
	var inv := root.global_transform.affine_inverse()
	var points := PackedVector3Array()
	_collect_local_corners(root, inv, points)
	if points.is_empty():
		return AABB()
	var result := AABB(points[0], Vector3.ZERO)
	for i in range(1, points.size()):
		result = result.expand(points[i])
	return result


func _collect_local_corners(node: Node, inv_root: Transform3D, points: PackedVector3Array) -> void:
	if node is VisualInstance3D:
		var local_aabb := (node as VisualInstance3D).get_aabb()
		var to_root := inv_root * (node as Node3D).global_transform
		for i in 8:
			points.append(to_root * local_aabb.get_endpoint(i))
	for child in node.get_children():
		_collect_local_corners(child, inv_root, points)
