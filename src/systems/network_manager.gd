extends Node

const GameVersion = preload("res://src/systems/game_version.gd")
const ServerRequests = preload("res://src/systems/server_requests.gd")
const RewindGhosts = preload("res://src/systems/rewind_ghosts.gd")
const NetProfiles = preload("res://src/systems/net_profiles.gd")
# InterpolationBuffer is a goldnet global class_name (referenced directly; a local const would shadow it).
# Network-condition simulation (latency/loss/spikes) lives in the goldnet transport, driven via /sim_latency, /sim_loss, /sim_spike.

## Host-authoritative networking manager: the host is the single source of truth for all entity interactions.
## Clients send player state and +use requests to the host; the host broadcasts AnimatableBody3D transforms
## every physics frame so clients agree on door/platform/button positions. Clients never run entity tweens
## or state machines locally.
##
## This file is the wire: the @rpc endpoints, the send_request_* wrappers that route a request to
## the authority, and replication. What the server then DOES with a gameplay request — cooldown,
## mana, charge, can_fire, team validation — lives in server_requests.gd, whose rules are static
## and called as ServerRequests.<verb>(). Getting a joining client the map and the resources it
## is missing is map_transfer.gd; finding a server to join at all is server_browser.gd.

signal peer_connected(id: int)
signal peer_disconnected(id: int)
signal disconnected(reason: String)
signal map_change_requested(map_name: String)

const PORT := 9050
const MAX_CLIENTS := 8
const SETTINGS_PATH := "user://settings.cfg"  # shared with lobby_ui; we own the [net] section

var _peer: ENetMultiplayerPeer
var _disconnect_reason := ""  # set by server before kicking, or on unexpected drop
var last_join_address := ""  # last address join() accepted; where /connect with no argument goes back to


## peer_id -> Player, the one registry of who is in the game. Everything keyed by peer id resolves
## a body through here — the server's movement/broadcast loops, every @rpc that has to find whose
## puppet an event is about, and the scoreboard. Writes belong to register_player /
## unregister_player / clear_players and nowhere else; a second copy kept in step by hand is what
## test_killbots_despawn.gd exists for.
##
## Online the value is the authoritative RemotePlayer puppet, the host's own body included. Offline
## there are no puppets, so it is the LocalPlayer itself — the one asymmetry, and the reason
## main.respawn_all_players still answers for offline separately.
var _players: Dictionary = {}
# Buffered team/element/pos/yaw for puppets whose spawn hasn't registered on this client yet.
# Drained by apply_pending_team_state from _on_puppet_spawned.
var _pending_team_state: Dictionary = {}
# entity_id -> merged state dict, for state that named an id we hadn't registered yet. PVS-gated
# create and state travel in unordered streams, and one-shot state (a breakable's broken flag, a
# light's style) never repeats, so dropping one stales the replica permanently. Drained by
# _flush_pending_entity_state from _bind_synced_entity.
var _pending_entity_state: Dictionary = {}
const MAX_PENDING_ENTITY_STATE := 64


# Server-side only: peer_id -> {right, left: Vector3, flags: int}
var _vr_hand_positions: Dictionary = {}

## peer_id -> PeerRecord: the per-peer state that is not the body — name, roster team, ping, queue
## depth. The companion to _players, and deliberately a separate table: a record outlives its
## puppet (identity survives a map change, a PVS-culled bot still owes the scoreboard a row), so
## the two have different lifetimes and different owners. Reach it through the accessors below —
## peer_names / peer_teams / get_* / set_* — not by hand, so drop_peer_state stays the one teardown.
var _peers: Dictionary = {}

var _ping_table_dirty := false
var _ping_table_timer := 0.0
const PING_TABLE_INTERVAL := 1.0

var _queue_table_timer := 0.0

# Snapshot interpolation (shared by remote players and entity bodies). INTERP_DELAY is a pure jitter
# buffer (GoldSrc cl_interp); RTT is handled separately by server-time clock sync. Minimum = 2 broadcast
# intervals so the bracket always has two snapshots even with one late packet — this floor is why
# broadcast rate is a latency knob and not just a bandwidth one. It tracks each peer's actual cadence
# (see _set_tick_interval), so a client on cl_updaterate widens only its own jitter buffer.
var INTERP_DELAY_MIN := 0.033  # 2 × NET_TICK_INTERVAL
const INTERP_DELAY_MAX := 0.250  # maximum for very jittery connections
var INTERP_DELAY := INTERP_DELAY_MIN  # active delay — updated from ping jitter

# Smoothly-slewed server-clock offset (no per-packet hitches, so bracket interpolation stays exact).
# Offset math lives in goldnet's ServerClock; we feed it observations and read now().
var _server_clock := ServerClock.new()
const SNAPSHOT_BUFFER_SIZE := 64  # ~1s at 60Hz tick rate
# A jump farther than this in one tick is a teleport, not motion — snap the interp buffer instead of
# lerping across the map. Shared with GameConsts.MOVER_TELEPORT_DIST so ground-carry releases a rider
# on exactly the jumps this buffer snaps.
const ENTITY_TELEPORT_DIST := GameConsts.MOVER_TELEPORT_DIST
const ENTITY_TELEPORT_DIST_SQ := ENTITY_TELEPORT_DIST * ENTITY_TELEPORT_DIST
const EXTRAP_MAX := 0.250  # cap extrapolation past last snapshot (seconds)
## How long a dynamic entity's stream may stay silent, past the extrapolation window, before the client
## stops claiming to know where it is (see NetInterpBridge.park_if_stream_died) — clear of any normal
## jitter/loss burst so a merely stuttering entity never blinks.
const ENTITY_PARK_AFTER := 1.0

## Non-null while /interp_diag is on: per-entity accounting of how well the snapshot stream actually
## fed interp_entities. Off by default — it is a measurement, not a mechanism.
var interp_diag: InterpDiag = null
## Non-null while --view-diag is on: how smoothly the client's own camera moves, and the
## reconcile traffic behind it (see ViewDiag).
var view_diag: ViewDiag = null

# Broadcast tick rate for entity transforms + remote player state. Defaults to the physics rate: at 30
# the snapshot stream was the single largest source of visual lag (it sets both average packet age and
# the INTERP_DELAY_MIN floor). Non-interpolated per-tick work (PVS gating, VR hands) stays at 30Hz — see
# main._physics_process. Vars not consts: retunable live. Host = sv_updaterate; client = the rate the
# server GRANTED it (cl_updaterate request capped by sv_updaterate, GoldSrc semantics — never faster
# than the server ticks).
const UPDATERATE_MIN := 10.0
const UPDATERATE_MAX := 120.0
var NET_TICKRATE := 60.0
var NET_TICK_INTERVAL := 1.0 / 60.0

## Client: rate we ask to be served at. 0 = take whatever the server broadcasts. goldnet carries it
## and grants it (update_rate_granted). Loaded from settings.cfg at startup, rewritten by
## set_cl_updaterate.
var cl_updaterate := 0.0
## Client: the most bytes per second we ask the server to send us (GoldSrc `rate`); 0 = automatic
## (goldnet's auto_rate, from queueing on our downlink). Over it, the server skips our snapshots
## rather than queuing them on a slow link. Loaded from settings.cfg, rewritten by set_cl_rate.
var cl_rate := 0
## Client: the simulated connection to join through (NetProfiles), on this client alone. Loaded
## from settings.cfg, rewritten by set_net_profile.
var net_profile := NetProfiles.OFF
var _net_profile_applied := false  ## a profile set the sim, so going back to Off must clear it
const RATE_MIN := 1000
const RATE_MAX := 1000000
## Server: set by main's net tick once that tick's state is written; SnapshotSender sends it after
## every other node's physics, so each tick goes out once, with everything the tick wrote.
var snapshot_due := false


## Runs last in the physics frame (see snapshot_due). Also sends if ticks have stopped — a map
## loading, no match running — so clients' clock feed and any spawns still go out.
class SnapshotSender extends Node:
	const KEEPALIVE_MS := 100
	var _last_ms := 0

	func _physics_process(_delta: float) -> void:
		var now := Time.get_ticks_msec()
		if NetworkManager.snapshot_due or now - _last_ms >= KEEPALIVE_MS:
			NetworkManager.snapshot_due = false
			_last_ms = now
			NetworkManager.transport.send_snapshots()


## Client: input packets per second (GoldSrc cl_cmdrate); 0 = automatic (goldnet's
## auto_command_rate, from the server's measure of our uplink). Each packet carries every input
## made since the last, so a lower rate costs input latency, not inputs — and saves the per-packet
## overhead that fills a slow uplink. Loaded from settings.cfg, rewritten by set_cl_cmdrate.
var cl_cmdrate := 0.0
const CMDRATE_MIN := 10.0


func _ready() -> void:
	CommandStream.mark(self, &"submit_input", FireControl.command_field_table())
	var sender := SnapshotSender.new()
	sender.name = "SnapshotSender"
	sender.process_physics_priority = 1 << 20
	add_child(sender)
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) == OK:
		cl_updaterate = float(cfg.get_value("net", "cl_updaterate", 0.0))
		cl_rate = int(cfg.get_value("net", "rate", 0))
		cl_cmdrate = float(cfg.get_value("net", "cl_cmdrate", 0.0))
		net_profile = str(cfg.get_value("net", "sim_profile", NetProfiles.OFF))

var net_tick_timer := 0.0

# Broadcast flags packed into one byte per player: bit0=crouched, bit1=jumping
const PLAYER_FLAG_CROUCHED := 1
const PLAYER_FLAG_JUMPING := 2
# Sustained-fire (beam/ray held on), carried in the per-tick snapshot so observers re-assert it every
# broadcast — level-triggered, self-heals a dropped sync_attack/sync_stop_attack edge. Discrete shots
# stay event-driven.
const PLAYER_FLAG_FIRING := 4
# Waist-deep in water (GoldSrc waterlevel 2) — picks the swim/treadwater clips on observers.
const PLAYER_FLAG_SWIMMING := 8
# How a player looks to observers: state, not events, the way the original kept renderamt on the
# entity. A late joiner or a puppet re-entering view picks it up with no message of its own.
const PLAYER_FLAG_INVISIBLE := 16
const PLAYER_FLAG_POISON := 32
const PLAYER_FLAG_BURNING := 64
const PLAYER_FLAG_FROSTED := 128
const PLAYER_STATUS_FLAGS := {
	GameConsts.StatusType.POISON: PLAYER_FLAG_POISON,
	GameConsts.StatusType.BURNING: PLAYER_FLAG_BURNING,
	GameConsts.StatusType.FROSTED: PLAYER_FLAG_FROSTED,
}

var _synced_entities: Dictionary = {}  # id -> Node; map bodies, projectiles, corpses, creatures, etc.
# Server-side per-peer PVS visibility, pushed into each synchronizer's native peer_visibility map once
# per net tick. Replaces visibility filters, which goldnet can't read (is_visible_to isn't
# GDExtension-visible). Keyed by MultiplayerSynchronizer -> predicate Callable(peer)->bool.
var _pvs_syncs: Dictionary = {}
var _pvs_row_epoch: Dictionary = {}  # sync → Callable() -> int, its change epoch (see register_pvs_sync)
var _pvs_row_seen: Dictionary = {}   # sync → last row epoch pushed
var _pvs_peer_seen: Dictionary = {}  # peer_id → last column epoch pushed
var _entity_buffers: Dictionary = {}  # id -> InterpolationBuffer (client-side smoothing; goldnet addon helper, transport-agnostic)
var _interp_bridges: Dictionary = {}  # id -> NetInterpBridge, for the ids that have one (see register_interp_node)
var _interp_shapes: Dictionary = {}  # id -> [Shape3D, local offset, collision mask] | null (see _clamp_extrapolation)
var _extrap_query: PhysicsShapeQueryParameters3D = null  # reused; one sweep per extrapolating entity per frame
# Server-only: peer_id -> true once that peer has loaded the map (called request_player_states). Map-entity
# synchronizers must NOT send before this: their net-id resolves by node PATH, and a send landing before
# the peer's map node exists poisons the path cache permanently ("node not found").
var _map_ready_peers: Dictionary = {}
## peer_id -> OwnerState: on the server one per connected client, on a client its own.
var _owner_states: Dictionary = {}
var _next_entity_id: int = 0
var pvs_visible: int = 0  # client: tracked entities in this client's PVS (relevant set)
var pvs_total: int = 0    # client: all tracked entities the server sees
var _pvs_stats_timer := 0.0

# peer_id -> { entity_id -> true } for movers in that peer's PVS. Diffed each relevancy tick into
# explicit activate/deactivate events (sync_entity_relevance), so clients gate mover render/collision
# on real server relevancy, not guessed packet cadence.
var _peer_relevant: Dictionary = {}
var _relevancy_timer := 0.0
const RELEVANCY_INTERVAL := 0.1  # 10 Hz — PVS transitions are rare (crossing a leaf boundary)

# Server's clock on a small dedicated stream (transport header isn't portably touchable) — the only
# server-clock feed always present regardless of entity traffic, so mover shadow state can freeze
# while idle (GoldSrc idle-free) without starving the clock.
var _server_time_beacon_timer := 0.0
const SERVER_TIME_BEACON_INTERVAL := 1.0 / 15.0


var net_ping_ms := 0              # latest RTT in ms
var net_ping_avg_ms := 0          # rolling average RTT
var _ping_sent_at := 0            # ticks_msec when last ping was sent
var _ping_interval := 0.5         # send ping every N seconds
var _ping_timer := 0.0
var _ping_samples: Array[int] = []
const PING_WINDOW := 10           # rolling average over N samples

# Updated each frame by main.gd
var net_input_queue_depth := 0    # server: current queue depth for this client
var net_unacked_cmds := 0         # client: commands sent but not yet acked by server
var net_corrections := 0          # client: position corrections this session
var net_corrections_per_sec := 0.0
var _corrections_window: Array[float] = []  # timestamps of recent corrections


func host() -> Error:
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_server(PORT, MAX_CLIENTS)
	if err != OK:
		return err
	if _net_profile_applied:
		_net_profile_applied = not NetProfiles.apply(multiplayer, NetProfiles.OFF)
	multiplayer.multiplayer_peer = _peer
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	Log.info("Hosting on port %d" % PORT)
	MapTransfer.start_http_server()
	return OK


## ERR_ALREADY_IN_USE while a connection is open or still opening: a second join would connect
## every signal again and abandon the first peer mid-handshake.
func join(ip: String) -> Error:
	if _peer != null and _peer.get_connection_status() != MultiplayerPeer.CONNECTION_DISCONNECTED:
		return ERR_ALREADY_IN_USE
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_client(ip, PORT)
	if err != OK:
		return err
	_apply_net_profile()
	multiplayer.multiplayer_peer = _peer
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	multiplayer.connection_failed.connect(_on_connection_failed)
	last_join_address = ip  # survives disconnect_from_game(), which is the point
	Log.info("Joining %s:%d" % [ip, PORT])
	return OK


func kick_peer(peer_id: int, reason: String) -> void:
	if not is_host():
		return
	if peer_id == multiplayer.get_unique_id():
		return  # can't kick yourself — rpc-to-self is invalid and the host owns the session
	if is_peer_connected(peer_id):
		receive_kick_reason.rpc_id(peer_id, reason)
	# Give the RPC a moment to arrive before the server closes the connection
	await get_tree().create_timer(0.1).timeout
	if _peer and is_peer_connected(peer_id):
		_peer.disconnect_peer(peer_id)


## Channel 2 keeps it off goldnet's netchan: it has 0.1 s to land before the disconnect and can't
## wait for a snapshot.
@rpc("authority", "call_remote", "reliable", 2)
func receive_kick_reason(reason: String) -> void:
	# Logged as well as shown: a player reporting "it just disconnected" leaves the reason in
	# client.log, where the popup they clicked through is not.
	Log.info("Kicked by server: %s" % reason)
	_disconnect_reason = reason


## A client reports its transport as its first message after connecting. A mixed session is not a
## degraded session: goldnet claims every MultiplayerSpawner spawn and every synchronizer and never
## forwards them to the inner SceneMultiplayer, so whichever side is on stock receives no entities
## at all — it connects, chats, downloads the map, draws the world, and stands alone in it. The
## @rpc path survives (goldnet delegates that to the inner), which is the only reason this call
## gets through to say so. Two goldnet wire versions drop each other's packets, so this rides channel
## 2, off goldnet's netchan, to get through either way. Refuse the join instead of letting it look
## like it worked. The argument is goldnet's wire version, 0 = none.
@rpc("any_peer", "call_remote", "reliable", 2)
func announce_transport(client_version: int) -> void:
	if not is_host():
		return
	var id := multiplayer.get_remote_sender_id()
	var host_version := transport.protocol_version()
	if client_version == host_version:
		return
	var reason := ""
	if client_version == 0:
		reason = ("This server uses the goldnet network transport, which your client is missing.\n\n"
				+ "Re-download the client — the game folder is incomplete.")
	elif host_version == 0:
		reason = ("This server is running without the goldnet network transport, so it cannot send "
				+ "players or objects to your client.")
	else:
		reason = ("This server runs a different version of the game's network code than your client "
				+ "(server %d, yours %d).\n\nUpdate the game to join." % [host_version, client_version])
	Log.warn("Kicking peer %d: transport mismatch (client goldnet v%d, host goldnet v%d)"
			% [id, client_version, host_version])
	kick_peer(id, reason)


func disconnect_from_game() -> void:
	ServerBrowser.stop_beacon()
	ServerBrowser.stop_listening()
	clear_players()  # also drops _pending_team_state and LagCompensation
	_clear_peer_state()
	net_ping_ms = 0
	net_ping_avg_ms = 0
	_ping_samples.clear()
	_ping_timer = 0.0
	net_input_queue_depth = 0
	_queue_table_timer = 0.0
	net_unacked_cmds = 0
	net_corrections = 0
	net_corrections_per_sec = 0.0
	_corrections_window.clear()
	_server_clock.reset()
	for id in _synced_entities:
		var node = _synced_entities[id]
		if is_instance_valid(node):
			node.queue_free()
	reset_entities()
	MapTransfer.reset()
	if _peer:
		if multiplayer.peer_connected.is_connected(_on_peer_connected):
			multiplayer.peer_connected.disconnect(_on_peer_connected)
		if multiplayer.peer_disconnected.is_connected(_on_peer_disconnected):
			multiplayer.peer_disconnected.disconnect(_on_peer_disconnected)
		if multiplayer.connected_to_server.is_connected(_on_connected_to_server):
			multiplayer.connected_to_server.disconnect(_on_connected_to_server)
		if multiplayer.server_disconnected.is_connected(_on_server_disconnected):
			multiplayer.server_disconnected.disconnect(_on_server_disconnected)
		if multiplayer.connection_failed.is_connected(_on_connection_failed):
			multiplayer.connection_failed.disconnect(_on_connection_failed)
		multiplayer.multiplayer_peer = null
		_peer = null
	var reason := _disconnect_reason
	_disconnect_reason = ""
	disconnected.emit(reason)


func is_online() -> bool:
	return _peer != null and _peer.get_connection_status() != MultiplayerPeer.CONNECTION_DISCONNECTED


func is_host() -> bool:
	return is_online() and multiplayer.is_server()


## Test seam: force the answer so a suite can exercise CLIENT branches without a peer. Presence,
## prediction and visibility all key off is_authority(), so a suite that can't flip this only ever
## tests the authority path. Deliberately narrower than faking is_online(), which the rest of the
## system reads as "a peer exists" and dereferences. Tests must reset it.
enum TestAuthority { REAL, CLIENT, AUTHORITY }
var test_authority := TestAuthority.REAL

## Returns true if this peer is the authority (offline or host).
func is_authority() -> bool:
	if test_authority != TestAuthority.REAL:
		return test_authority == TestAuthority.AUTHORITY
	return not is_online() or is_host()


## True when a weapon fire() on this attacker should apply real effects. fire() runs authoritative
## (a server body puppet, or the offline player) or cosmetic/predicted (a LocalPlayer view while
## online, including the host's own view — its body puppet fires the real one). Weapons must gate
## real effects on THIS, not is_authority(), or the host doubles every effect.
func is_authoritative_fire(attacker: Node3D) -> bool:
	if not is_authority():
		return false
	return not (is_online() and attacker is LocalPlayer)


## Call a method on the current scene if it exists. Used to dispatch reliable RPCs.
## The node answering the client-side sync events, registered by the scene that owns it
## (src/systems/client_sync.gd, main.gd's child). A scene that registers nothing — a tool or a
## probe harness — is dispatched to directly, exactly as before there was a handler to register.
var _sync_handler: Node = null


func register_sync_handler(node: Node) -> void:
	_sync_handler = node
	node.tree_exiting.connect(unregister_sync_handler.bind(node), CONNECT_ONE_SHOT)


func unregister_sync_handler(node: Node) -> void:
	if _sync_handler == node:
		_sync_handler = null


func _dispatch_to_scene(method: StringName, args: Array = []) -> void:
	# The sync handlers live on the registered handler; the rest of what is dispatched by name —
	# the join and spawn handlers — is still the scene's own.
	if is_instance_valid(_sync_handler) and _sync_handler.has_method(method):
		_sync_handler.callv(method, args)
		return
	var s := get_tree().current_scene
	if s != null and s.has_method(method):
		s.callv(method, args)


## The client-side handler for an authority RPC, by convention: sync_player_damage is answered by
## _on_sync_player_damage (see client_sync.gd). Derived rather than passed, because every send site
## used to name both and the pair is two StringNames with no static checking behind them — a typo in
## either was a silent no-op, damage that never lands or an icon that never clears. One name cannot
## disagree with itself.
func _handler_for(rpc_method: StringName) -> StringName:
	return StringName("_on_" + rpc_method)


## Deliver an owner-directed sync to the peer that owns a player. rpc_id to our own id silently drops
## on a call_remote RPC, so when the owner is this process the scene handler is dispatched directly.
func send_to_owner(peer_id: int, rpc_method: StringName, args: Array = []) -> void:
	if not is_online() or peer_id == multiplayer.get_unique_id():
		_dispatch_to_scene(_handler_for(rpc_method), args)
	elif is_peer_connected(peer_id):
		callv(&"rpc_id", [peer_id, rpc_method] + args)


## Tell one asker their join didn't take, so they keep the class menu instead of silently
## staying a spectator. The reason is the only explanation they get — main prints it.
func send_join_rejected_to(peer_id: int, team: int, reason: String) -> void:
	send_to_owner(peer_id, &"reject_team_join", [team, reason])


## reliable=false rides the unreliable channel instead (sustained drain — newer values supersede).
func sync_mana_to_owner(p: Player, reliable := true) -> void:
	send_to_owner(p.peer_id, &"sync_mana" if reliable else &"sync_mana_drain", [p.mana, p.satchel_pack.count])


## Broadcast an authority event to all clients AND run the matching scene handler locally —
## call_remote RPCs skip the sending process, but the host's own view needs the same handler its
## clients run.
func broadcast_and_dispatch(rpc_method: StringName, args: Array = []) -> void:
	callv(&"rpc", [rpc_method] + args)
	_dispatch_to_scene(_handler_for(rpc_method), args)


## broadcast_and_dispatch for a GoldSrc MSG_PVS temp entity: only the peers whose PVS reaches `box`
## get it. Meant for unreliable RPCs, as the original's were.
func send_to_pvs_and_dispatch(box: AABB, rpc_method: StringName, args: Array = []) -> void:
	for peer_id in VisibilitySystem.peers_seeing(box, multiplayer.get_peers()):
		callv(&"rpc_id", [peer_id, rpc_method] + args)
	_dispatch_to_scene(_handler_for(rpc_method), args)


## Bespoke rather than broadcast_and_dispatch: the RPC's client-side lambda also records the kill,
## which the server-side death path has already done directly.
func broadcast_player_death(peer_id: int, killer_peer: int) -> void:
	sync_player_death.rpc(peer_id, killer_peer)
	_dispatch_to_scene(&"_on_sync_player_death", [peer_id])


## Replicate a transient visual effect: online, it's rebuilt via the dynamic-entity spawner on host +
## every client, and the caller's local copy is swapped for the replicated one (one-frame swap).
## ONLY safe for effects that parent their visuals to the effect node itself — one that parents a
## child to the scene root (e.g. a BeamSystem beam) leaks it when the throwaway node frees, drawing a
## duplicate; such effects must spawn once directly (see SpotBoltStrike.summon).
func register_effect(effect: Node, script_path: String, extra_data := {}) -> void:
	if not is_online():
		return
	var data := extra_data.duplicate()
	data["script_path"] = script_path
	if effect is Node3D:
		data["position"] = effect.position
	effect.queue_free()
	spawn_dynamic_entity(data)


func register_player(peer_id: int, node: Node) -> void:
	_players[peer_id] = node


func unregister_player(peer_id: int) -> void:
	_players.erase(peer_id)
	_pending_team_state.erase(peer_id)
	LagCompensation.forget(peer_id)


## Host-side teardown of one player slot: the puppet, the entities it owns, and the visibility
## bookkeeping keyed by its peer id. Bots go through here too — they have no ENet peer, so
## peer_disconnected never fires for them, and the spawner's `despawned` only reaches clients.
## Anything that frees a puppet without this leaves the registry holding a freed object, and the
## next tick calls into it. False means the peer held no slot and the caller still owns the body.
func despawn_player(peer_id: int) -> bool:
	var registered := _players.has(peer_id)
	if registered:
		# Owned persistent entities (beanstalk, thornplant) are parented to the scene root, not the
		# puppet, so tear them down before freeing it or they'd live on unowned. Still registered
		# while this runs: _drop_all_items and the dragon dismount resolve an owner by peer id.
		# Read untyped, not through get_player(): the entry can already be freed, and suites
		# register light stand-ins that get_player()'s declared Player return would reject.
		var puppet = _players[peer_id]
		if puppet != null and is_instance_valid(puppet):
			puppet.cleanup_for_class_change()
			puppet.queue_free()
		unregister_player(peer_id)
	# Unconditional, unlike the registry work: a peer that dropped before its puppet registered
	# still left PVS bookkeeping behind, and both callers used to run these two by hand afterwards.
	VisibilitySystem.untrack_player(peer_id)
	VisibilitySystem.remove_peer(peer_id)
	return registered


# --- Per-peer records (see _peers) ---

## The record for `peer_id`, created empty if this is the first thing we know about the peer.
## Every setter below goes through here, so a ping or a queue depth that arrives before the name
## still lands — the record is just not on the roster yet (see peer_names). Private: a creating
## accessor handed out publicly is a second write path that can resurrect a dropped peer.
func _peer_record(peer_id: int) -> PeerRecord:
	var rec: PeerRecord = _peers.get(peer_id)
	if rec == null:
		rec = PeerRecord.new()
		_peers[peer_id] = rec
	return rec


## peer_id -> name for every peer that has told us one, as a fresh copy. The roster in the
## player-facing sense: who the scoreboard lists, who /kick can resolve, who build_status counts.
## A name is the membership test because the dedicated server's own peer 1 never registers one,
## while a listen host does — that is the only thing separating the two.
func peer_names() -> Dictionary:
	var names := {}
	for peer_id: int in _peers:
		var rec := _peers[peer_id] as PeerRecord
		if not rec.player_name.is_empty():
			names[peer_id] = rec.player_name
	return names


## peer_id -> roster team, as a fresh copy. Every record, named or not: a peer can hold a team
## before it has announced a name, and GoalSystem's team counts have to see it (a client at the
## team menu was shown a slot the host then refused it from).
func peer_teams() -> Dictionary:
	var teams := {}
	for peer_id: int in _peers:
		teams[peer_id] = (_peers[peer_id] as PeerRecord).team
	return teams


func has_player_name(peer_id: int) -> bool:
	var rec: PeerRecord = _peers.get(peer_id)
	return rec != null and not rec.player_name.is_empty()


func set_player_name(peer_id: int, player_name: String) -> void:
	_peer_record(peer_id).player_name = player_name


## What to call a peer in front of players — their chosen name, else something better than a bare
## id. HUD._peer_name adds "You" on top of this for the local player's own rows.
func display_name(peer_id: int) -> String:
	var rec: PeerRecord = _peers.get(peer_id)
	if rec != null and not rec.player_name.is_empty():
		return rec.player_name
	return "Player %d" % peer_id


func get_player_team(peer_id: int) -> int:
	var rec: PeerRecord = _peers.get(peer_id)
	return rec.team if rec != null else GameConsts.Team.NONE


func set_player_team(peer_id: int, team: int) -> void:
	_peer_record(peer_id).team = team


func get_peer_ping(peer_id: int) -> int:
	var rec: PeerRecord = _peers.get(peer_id)
	return rec.ping if rec != null else -1


func set_peer_ping(peer_id: int, ms: int) -> void:
	_peer_record(peer_id).ping = ms


## Read-only to callers: queue depth is sampled from the puppets on the server
## (_sample_queue_depths) and applied from the wire on clients, never set by gameplay code.
func get_peer_queue_depth(peer_id: int) -> int:
	var rec: PeerRecord = _peers.get(peer_id)
	return rec.queue_depth if rec != null else -1


## Test seam, matching swap_roster: install `table` (default empty) and return the one it replaced.
func swap_peer_table(table: Dictionary = {}) -> Dictionary:
	var previous := _peers
	_peers = table
	return previous


## Returns the host's own LocalPlayer or a client/bot RemotePlayer puppet interchangeably — every
## member accessed on the result must be declared on the Player base class.
func get_player(peer_id: int) -> Player:
	var node = _players.get(peer_id)
	if node and is_instance_valid(node):
		return node
	return null


## Registered at all — true even for an entry whose node has since been freed, which get_player()
## reports as absent. Spawn paths ask this before creating a second puppet for a peer.
func has_player(peer_id: int) -> bool:
	return _players.has(peer_id)


func player_count() -> int:
	return _players.size()


## The registry dict itself, by reference and unfiltered — for the three per-tick server loops that
## walk every player and cannot afford a copy per frame, and for callers that need a field
## get_player()'s declared Player return does not carry (client_sync reads RemotePlayer's).
## Read-only by convention: writing through it bypasses unregister_player's companion cleanup
## (pending team state, lag-comp history). Anything colder, or that only wants live nodes, wants
## player_roster() — which is the filtered one, despite reading like the looser of the two names.
func player_table() -> Dictionary:
	return _players


## peer_id -> live player node for every registered peer, as a fresh copy. Values are untyped
## on purpose: goal/plant callers duck-type a field, which lets suites register light stand-ins.
func player_roster() -> Dictionary:
	var live := {}
	for peer_id in _players:
		var node = _players[peer_id]
		if node and is_instance_valid(node):
			live[peer_id] = node
	return live


## Test seam: swap in `roster` (default empty) and return the one it replaced. Not for
## gameplay code — register_player/unregister_player own the live roster.
func swap_roster(roster: Dictionary = {}) -> Dictionary:
	var previous := _players
	_players = roster
	return previous


func clear_players() -> void:
	_players.clear()
	_pending_team_state.clear()
	# The server-side roster carries no team across a map change: the new map re-spawns everyone as
	# a spectator on team NONE. Leaving the roster populated left peers whose body hasn't
	# replicated yet (the reload window, bodiless bots) showing their PREVIOUS map's team on the
	# scoreboard. A record's name is identity, not membership, so the record itself survives — only
	# the team resets. Each client picks a team again on the new map, which lands here through the
	# normal validated join path.
	for peer_id: int in _peers:
		(_peers[peer_id] as PeerRecord).team = GameConsts.Team.NONE
	LagCompensation.clear_all()


## Reset all entity sync state. Called on map unload so the next map starts
## with a clean slate and deterministic IDs — same as the initial load.
## Does NOT free nodes (caller is responsible) and does NOT touch the peer connection.
func reset_entities() -> void:
	_synced_entities.clear()
	_entity_buffers.clear()
	_pending_entity_state.clear()
	_peer_relevant.clear()
	# Peers must re-announce readiness (request_player_states) after loading the new map, or the
	# server streams mover baselines during their reload window and poisons their replication path
	# cache — the "no brush models after a map change" bug. Dropped on disconnect too, by _clear_peer_state.
	_map_ready_peers.clear()
	_pvs_syncs.clear()
	_pvs_row_epoch.clear()
	_pvs_row_seen.clear()
	_pvs_peer_seen.clear()
	_next_entity_id = 0


## Server: register a synchronizer for per-peer PVS gating. `predicate.call(peer_id) -> bool` decides
## whether that peer may receive this entity's state. Sets public_visibility=false and drives
## peer_visibility ourselves in push_pvs_visibility() — the replacement for add_visibility_filter,
## which goldnet can't see. Auto-unregisters when the synchronizer leaves the tree.
## `row_epoch.call() -> int` must change whenever anything the predicate depends on changes that is
## NOT the observing peer (leaf set, dead/unjoined state, etc): push_pvs_visibility skips the whole
## row while it holds steady, so a row epoch that fails to move is a stuck-visibility bug.
func register_pvs_sync(sync: MultiplayerSynchronizer, predicate: Callable, row_epoch: Callable) -> void:
	if sync == null:
		return
	sync.set_visibility_public(false)  # peer_visibility is now the sole gate
	# The registry doubles as the list of synchronizers whose rate follows sv_updaterate, so set the
	# interval here rather than at each call site — a sync created after a retune gets the live value.
	sync.replication_interval = NET_TICK_INTERVAL
	_pvs_syncs[sync] = predicate  # keyed by the sync itself — is_instance_valid() guards freed keys
	_pvs_row_epoch[sync] = row_epoch
	sync.tree_exiting.connect(unregister_pvs_sync.bind(sync), CONNECT_ONE_SHOT)


func unregister_pvs_sync(sync: MultiplayerSynchronizer) -> void:
	_pvs_syncs.erase(sync)
	_pvs_row_epoch.erase(sync)
	_pvs_row_seen.erase(sync)


## Server, once per net tick: push each registered synchronizer's per-peer visibility into its native
## peer_visibility map. Must run after peer observer positions update for the tick (see
## main._broadcast_player_states).
##
## Evaluating every (sync × peer) pair was the server's dominant cost — measured at 1.6us/pair, ~10ms
## of every 16.6ms tick at 388 syncs × 32 peers × 30Hz — almost all of it recomputing an answer that
## couldn't have changed (a PVS result only moves when the entity's leaf set moves or the peer crosses
## a leaf). So each row (sync) and column (peer) carries a change epoch, and a pair is re-evaluated
## only when one of its two epochs moved; skipping is safe because peer_visibility is persistent
## state, so an untouched pair keeps the last (still correct) value pushed.
func push_pvs_visibility() -> void:
	if not multiplayer.is_server():
		return
	# Array, not the PackedInt32Array get_peers returns, so it can share a variable with the
	# moved-peers list below and be iterated as one or the other per row.
	var peers: Array = Array(multiplayer.get_peers())
	# Column pass: which peers moved, and drop bookkeeping for any that left. A peer seen for the
	# first time has no cached epoch and so counts as moved, which is what gives a joining peer its
	# initial full evaluation.
	var moved_peers: Array = []
	for peer_id in peers:
		var e: int = _peer_pvs_epoch(peer_id)
		if e != int(_pvs_peer_seen.get(peer_id, -1)):
			_pvs_peer_seen[peer_id] = e
			moved_peers.append(peer_id)
	if _pvs_peer_seen.size() != peers.size():
		for peer_id in _pvs_peer_seen.keys():
			if not peers.has(peer_id):
				_pvs_peer_seen.erase(peer_id)

	var stale: Array = []  # rare: only a sync freed before its tree_exiting could unregister it
	for sync in _pvs_syncs:
		if not is_instance_valid(sync):
			stale.append(sync)
			continue
		var row_epoch: Callable = _pvs_row_epoch[sync]
		var row: int = row_epoch.call()
		var row_moved: bool = row != int(_pvs_row_seen.get(sync, -1))
		var targets: Array = peers if row_moved else moved_peers
		if targets.is_empty():
			continue
		if row_moved:
			_pvs_row_seen[sync] = row
		var predicate: Callable = _pvs_syncs[sync]
		for peer_id in targets:
			sync.set_visibility_for(peer_id, predicate.call(peer_id))
	for sync in stale:
		_pvs_syncs.erase(sync)
		_pvs_row_epoch.erase(sync)
		_pvs_row_seen.erase(sync)


## [sent bytes, received bytes, sent packets, received packets] on the ENet host since the last
## call — pop_statistic resets each counter, so this is a per-window rate source for the ServerPerf
## report. Measured: a 6-player ww_2fort server runs ~36 KB/s
## up / ~70 KB/s down; down > up because client input redundancy costs each player more upstream
## than the server spends on them.
func pop_bandwidth() -> Array:
	if _peer == null:
		return [0, 0, 0, 0]
	var h = _peer.get_host()
	if h == null:
		return [0, 0, 0, 0]
	var bw := [h.pop_statistic(ENetConnection.HOST_TOTAL_SENT_DATA),
		h.pop_statistic(ENetConnection.HOST_TOTAL_RECEIVED_DATA),
		h.pop_statistic(ENetConnection.HOST_TOTAL_SENT_PACKETS),
		h.pop_statistic(ENetConnection.HOST_TOTAL_RECEIVED_PACKETS)]
	return bw


## Column epoch for one peer: its BSP observer plus every peer-dependent gate a predicate consults.
## is_peer_map_ready is folded in so a peer whose map finishes loading isn't stuck invisible until it
## happens to cross a leaf.
func _peer_pvs_epoch(peer_id: int) -> int:
	return VisibilitySystem.peer_epoch(peer_id) * 2 + (1 if is_peer_map_ready(peer_id) else 0)


func _erase_entity(id: int) -> void:
	if interp_diag != null:
		interp_diag.finish(id)
	_synced_entities.erase(id)
	_entity_buffers.erase(id)
	_interp_shapes.erase(id)
	VisibilitySystem.untrack_node(id)


## Host → Clients: server is switching maps. Clients tear down the current map and
## wait for MapTransfer to hand them the new map's metadata (MapTransfer.notify_map_change).
@rpc("authority", "call_remote", "reliable")
func sync_map_change(map_name: String) -> void:
	map_change_requested.emit(map_name)


## Server-side request to change the map, emitted by the admin-gated CommandSystem
## (/changemap). main.gd connects this to the actual map load.
@warning_ignore("unused_signal")
signal map_change_server_request(map_name: String)

func _on_peer_connected(id: int) -> void:
	Log.info("Peer connected: %d" % id)
	peer_connected.emit(id)
	if is_host():
		_add_owner_state(id)
		MapTransfer.send_to_peer(id)
		var snap: Dictionary = ServerVars.snapshot()
		for key in snap:
			sync_server_var.rpc_id(id, key, snap[key])


func _on_peer_disconnected(id: int) -> void:
	Log.info("Peer disconnected: %d" % id)
	_erase_peer_state(id)
	peer_disconnected.emit(id)


## One owner for per-peer state cleanup, so a new per-peer table only needs editing here too.
func _erase_peer_state(id: int) -> void:
	_peers.erase(id)
	_vr_hand_positions.erase(id)
	_map_ready_peers.erase(id)
	_peer_relevant.erase(id)
	_free_owner_state(id)


## Whole-session counterpart to _erase_peer_state; the two lists stay in step by sitting together.
func _clear_peer_state() -> void:
	_peers.clear()
	_vr_hand_positions.clear()
	_map_ready_peers.clear()
	_peer_relevant.clear()
	for id in _owner_states.keys():
		_free_owner_state(id)


## "This peer is gone": drop its per-peer state here and on every client. What bot removal needs,
## since a bot has no ENet peer to close and so never raises peer_disconnected. Deliberately does
## NOT touch the player registry — callers still have to despawn the body, and bot_system's teardown
## runs this first and needs the body afterwards.
func drop_peer_state(id: int) -> void:
	_erase_peer_state(id)
	if is_online():
		forget_peer.rpc(id)  # bots have no ENet peer; tell clients to drop it too


## Bots have no ENet peer, so peer_disconnected never fires for them; the host broadcasts this
## instead when a bot is removed, or it lingers on the scoreboard (which reads the roster, not PVS bodies).
@rpc("authority", "call_remote", "reliable")
func forget_peer(id: int) -> void:
	_erase_peer_state(id)


func is_peer_connected(id: int) -> bool:
	if id <= 0 or not is_online():
		return false
	if id == multiplayer.get_unique_id():
		return true
	return multiplayer.get_peers().has(id)


## Server-side: has this peer activated + loaded the map? Gates map-entity synchronizer visibility so
## the first send never lands before the peer's map nodes exist (which would poison the path cache).
func is_peer_map_ready(peer_id: int) -> bool:
	return _map_ready_peers.has(peer_id)


## Client: register/unregister a spawner-managed dynamic entity (projectile, corpse, …) so its
## NetInterpBridge snapshots render through interp_entities — the same clock-synced buffer as movers.
func register_interp_node(id: int, node: Node) -> void:
	_bind_synced_entity(id, node)
	# Resolved once here rather than per frame in interp_entities, which consults it for every
	# entity whose buffer has run dry — i.e. most of them, most of the time.
	var bridge := node.get_node_or_null(^"NetInterp") as NetInterpBridge
	if bridge:
		_interp_bridges[id] = bridge


## Every id→node binding goes through here so state that arrived before the entity
## always drains. Deferred: spawner registrations run inside spawn_function, before
## the node is in the tree and _ready has built its model/AnimationPlayer.
func _bind_synced_entity(id: int, node: Node) -> void:
	_synced_entities[id] = node
	# interp_entities writes this transform every rendered frame. Godot's physics interpolation
	# assumes transforms only change on the physics tick, so leaving it on re-interpolates our
	# already-smoothed value from the previous tick's — a lag/snap that scales with speed (a corpse
	# launched at flight speed visibly falls and jerks back). Same opt-out the player puppets take.
	if node is Node3D and not is_authority():
		(node as Node3D).physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	if _pending_entity_state.has(id):
		_flush_pending_entity_state.call_deferred(id)


func unregister_interp_node(id: int) -> void:
	if interp_diag != null:
		interp_diag.finish(id)
	_synced_entities.erase(id)
	_entity_buffers.erase(id)
	_interp_bridges.erase(id)
	_interp_shapes.erase(id)


## Client: feed a map-entity mover transform (from its MultiplayerSynchronizer) into the same
## clock-synced interp buffer the entity-transform stream uses, so movers interpolate identically.
func push_mover_snapshot(id: int, server_time_ms: int, pos: Vector3, rot: Vector3, vel: Vector3, angvel := Vector3.ZERO) -> void:
	if id < 0:
		return
	# Deliberately does NOT feed the server clock: mover stamps freeze while idle and would starve/skew it.
	var buf: InterpolationBuffer = _entity_buffers.get(id)
	if buf == null:
		buf = InterpolationBuffer.new()
		buf.teleport_dist_sq = ENTITY_TELEPORT_DIST_SQ
		buf.max_size = SNAPSHOT_BUFFER_SIZE
		buf.extrap_max = EXTRAP_MAX
		_entity_buffers[id] = buf
	buf.push(server_time_ms / 1000.0, pos, rot, vel, angvel)


## Sample a dynamic entity's interp buffer at an arbitrary server time, rather than at the
## render_time interp_entities uses. For an entity whose client replica runs its own simulation
## (a corpse ragdoll), the render-time position is the WRONG reference: it is the host one
## INTERP_DELAY in the past, while the local sim is one one-way latency in the past, and
## comparing them reads their difference in time as a difference in position. Such an entity
## asks for the host's state at its OWN simulation age instead — see
## TumblingCorpse._correct_to_authority.
func sample_entity_at(id: int, server_time: float) -> Dictionary:
	var buf: InterpolationBuffer = _entity_buffers.get(id)
	if buf == null:
		return {"valid": false}
	return buf.sample(server_time)


## Discard a mover's interp history on PVS re-entry so the first fresh sample snaps to its real
## position instead of lerping across the stale gap. The buffer's teleport reset doesn't cover this:
## door travel is below teleport_dist_sq.
func clear_mover_buffer(id: int) -> void:
	var buf: InterpolationBuffer = _entity_buffers.get(id)
	if buf != null:
		buf.clear()


func _on_connected_to_server() -> void:
	Log.info("Connected to server, my ID: %d" % multiplayer.get_unique_id())
	announce_transport.rpc_id(1, transport.protocol_version())
	var own := _add_owner_state(multiplayer.get_unique_id())
	own.sync.synchronized.connect(_on_owner_state_synced.bind(own))
	_apply_rates()


func _on_server_disconnected() -> void:
	Log.info("Server disconnected")
	if _disconnect_reason.is_empty():
		_disconnect_reason = "Lost connection to server."
	disconnect_from_game()


## A join that never completed (server full, unreachable, or handshake timed out). Without this the
## peer stays assigned in a DISCONNECTED state and _process keeps asking it for is_server()/
## get_unique_id(), erroring every frame forever. ENet gives no way to tell the causes apart.
func _on_connection_failed() -> void:
	Log.info("Connection failed (server full, unreachable, or timed out)")
	if _disconnect_reason.is_empty():
		_disconnect_reason = "Could not connect — the server is full or unreachable."
	disconnect_from_game()


func _process(delta: float) -> void:
	# Session work needs a peer that can actually answer for itself: null (between disconnect and the
	# next host/join) or unconnected (still handshaking, or refused as full) both error every frame if
	# asked for is_server()/get_unique_id(). Offline and host play are unaffected — both report CONNECTED.
	var peer := multiplayer.multiplayer_peer
	if peer != null and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		_process_session(delta)


## Per-frame work that requires a live connection (see _process).
func _process_session(delta: float) -> void:
	_server_clock.advance(delta)
	# The host IS the server clock, so feed Time.get_ticks_msec() directly (no offset estimation
	# needed) — otherwise is_synced()/get_estimated_server_time() never populate on host, and
	# RemotePlayer's visual smoothing for other players' puppets needs a working render_time there.
	if is_host():
		_update_server_clock(Time.get_ticks_msec())
	_update_ping(delta)
	_update_corrections_rate()
	if multiplayer.is_server() and _ping_table_dirty:
		_ping_table_timer += delta
		if _ping_table_timer >= PING_TABLE_INTERVAL:
			_ping_table_timer = 0.0
			_ping_table_dirty = false
			_net_ping_table.rpc(_peer_int_table(&"ping"))
	if multiplayer.is_server():
		_queue_table_timer += delta
		if _queue_table_timer >= PING_TABLE_INTERVAL:
			_queue_table_timer = 0.0
			_sample_queue_depths()
			_net_queue_table.rpc(_peer_int_table(&"queue_depth"))
		# Scoreboard PVS diagnostic: per-peer visible/total tracked entities, computed on demand at ~2 Hz.
		_pvs_stats_timer += delta
		if _pvs_stats_timer >= 0.5:
			_pvs_stats_timer = 0.0
			for peer_id in multiplayer.get_peers():
				var vt: Vector2i = VisibilitySystem.count_visible_to_peer(peer_id)
				_sync_pvs_stats.rpc_id(peer_id, vt.x, vt.y)
		_relevancy_timer += delta
		if _relevancy_timer >= RELEVANCY_INTERVAL:
			_relevancy_timer = 0.0
			_update_peer_relevancy()
		# Stock transport only — under goldnet every snapshot header already carries the clock.
		if not transport.is_goldnet:
			_server_time_beacon_timer += delta
			if _server_time_beacon_timer >= SERVER_TIME_BEACON_INTERVAL:
				_server_time_beacon_timer = 0.0
				_sync_server_time.rpc(Time.get_ticks_msec())


## Public server status: what is running and who is on it. Bots hold negative synthetic peer ids.
func build_status() -> Dictionary:
	var humans: Array[String] = []
	var bots: Array[String] = []
	var names := peer_names()
	for peer_id: int in names:
		if peer_id < 0:
			bots.append(str(names[peer_id]))
		else:
			humans.append(str(names[peer_id]))
	@warning_ignore("integer_division")
	var uptime := Time.get_ticks_msec() / 1000
	var status := {
		"game": GameVersion.GAME_ID,
		"version": GameVersion.display(),
		"map": MapTransfer.host_map_name,
		"players": humans.size(),
		"bots": bots.size(),
		"max": MAX_CLIENTS,
		"port": PORT,
		"player_names": humans,
		"bot_names": bots,
		"uptime": uptime,
	}
	if MatchSystem != null:
		status["time_left"] = int(MatchSystem.time_left())
		status["intermission"] = MatchSystem.is_intermission()
	return status


# --- Network diagnostics ---

func _update_ping(delta: float) -> void:
	if not is_online() or is_host():
		return
	if _peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return
	_ping_timer += delta
	if _ping_timer >= _ping_interval:
		_ping_timer = 0.0
		_ping_sent_at = Time.get_ticks_msec()
		var sent_at := _ping_sent_at
		_net_ping.rpc_id(1, sent_at)


func _update_corrections_rate() -> void:
	var now := Time.get_ticks_msec() / 1000.0
	while not _corrections_window.is_empty() and (now - _corrections_window[0]) > 5.0:
		_corrections_window.pop_front()
	net_corrections_per_sec = _corrections_window.size() / 5.0


## Client: estimated current server time in seconds. Delegates to the ServerClock helper (a
## smoothly-slewed offset, never stepped on packet arrival, so bracket interpolation of
## constant-velocity entities is exact with no per-packet hitches).
func get_estimated_server_time() -> float:
	return _server_clock.now()


## False until the clock has an observation to work from, when get_estimated_server_time() is
## the local clock and means nothing.
func is_clock_synced() -> bool:
	return _server_clock.is_synced()


## Feed one server-time observation (ms) into the estimator. Called from the goldnet snapshot
## header (server_time_received), the stock beacon (_sync_server_time), and remote-player snapshot
## stamps. Stale/reordered observations are ignored inside the helper.
func _update_server_clock(server_time_ms: int) -> void:
	_server_clock.sample(server_time_ms)


func record_correction() -> void:
	net_corrections += 1
	_corrections_window.append(Time.get_ticks_msec() / 1000.0)


@rpc("any_peer", "call_remote", "unreliable")
func _net_ping(client_time: int) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	Log.info("[PingDiag] recv peer=%d client_time=%d server_recv=%d" % [sender, client_time, Time.get_ticks_msec()])
	_net_pong.rpc_id(sender, client_time)


@rpc("any_peer", "call_remote", "unreliable")
func _net_report_ping(ms: int) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	set_peer_ping(sender, ms)
	_ping_table_dirty = true  # broadcast batched at PING_TABLE_INTERVAL, not per pong
	Log.info("[PingDiag] rtt peer=%d ms=%d" % [sender, ms])


## Ping and queue depth are the same mechanism — a host-measured per-peer number, -1 for unknown,
## broadcast at PING_TABLE_INTERVAL — so one pair of helpers serves both, keyed by field name. A
## third such number needs no third pair.
##
## Built per send rather than kept, so the records stay the one copy; only peers the server has
## actually measured are on the wire.
func _peer_int_table(field: StringName) -> Dictionary:
	var table := {}
	for peer_id: int in _peers:
		var value: int = (_peers[peer_id] as PeerRecord).get(field)
		if value >= 0:
			table[peer_id] = value
	return table


## The received table is the whole truth, as it was when it replaced the dict wholesale: a peer the
## server no longer measures goes back to unknown rather than showing its last reading forever.
func _apply_peer_int_table(field: StringName, table: Dictionary) -> void:
	for peer_id: int in _peers:
		(_peers[peer_id] as PeerRecord).set(field, -1)
	for peer_id: int in table:
		_peer_record(peer_id).set(field, int(table[peer_id]))


## Server: read each puppet's input queue depth into its record, at the rate the number is actually
## consumed. Sampled here rather than written from the movement loop every tick — nothing reads it
## faster than this broadcast, and a value nothing caches per tick cannot go stale (the same reason
## the LAN beacon derives its player count instead of being pushed one).
func _sample_queue_depths() -> void:
	for peer_id: int in _players:
		var remote: Player = _players[peer_id]
		if remote and is_instance_valid(remote) and remote.has_server_movement():
			_peer_record(peer_id).queue_depth = remote.get_server_movement().queue_size()


@rpc("authority", "call_remote", "unreliable")
func _net_ping_table(table: Dictionary) -> void:
	_apply_peer_int_table(&"ping", table)


@rpc("authority", "call_remote", "unreliable")
func _net_queue_table(table: Dictionary) -> void:
	_apply_peer_int_table(&"queue_depth", table)


@rpc("authority", "call_remote", "unreliable")
func _net_pong(client_time: int) -> void:
	_on_pong_received(client_time)


## Server → Clients: the server's current clock (Time.get_ticks_msec). The always-on feed for the
## client server-clock estimator, independent of any entity traffic. Unreliable — a dropped beacon
## just means one fewer offset sample; the estimator ratchets/slews on the rest.
@rpc("authority", "call_remote", "unreliable")
func _sync_server_time(server_time_ms: int) -> void:
	_update_server_clock(server_time_ms)


func _on_pong_received(client_time: int) -> void:
	var rtt := Time.get_ticks_msec() - client_time
	if rtt < 0:
		return
	net_ping_ms = rtt
	_net_report_ping.rpc_id(1, rtt)
	_update_ping_stats(rtt)


## Split out from _on_pong_received so it's callable without the RPC side effect above (which requires
## a real peer). Tests use this seam to feed synthetic RTT samples directly.
func _update_ping_stats(rtt: int) -> void:
	_ping_samples.append(rtt)
	if _ping_samples.size() > PING_WINDOW:
		_ping_samples.pop_front()
	var total := 0
	for s in _ping_samples:
		total += s
	@warning_ignore("integer_division")
	net_ping_avg_ms = total / _ping_samples.size()
	# Adaptive jitter buffer: RTT variance / 2 estimates one-way jitter. Latency rides the clock sync,
	# so INTERP_DELAY only needs jitter + one broadcast interval (GoldSrc cl_interp logic).
	# NOTE: a peak-range + fast-attack/slow-release version was tried and reverted — it kept INTERP_DELAY
	# elevated much longer, fixed nothing, and made newly-spawned entities visibly hang longer at spawn
	# before render_time caught up to their first snapshot. Don't re-attempt without measuring
	# INTERP_DELAY's actual magnitude on a live jittery connection first.
	var mean_rtt := net_ping_avg_ms / 1000.0
	var variance := 0.0
	for s: int in _ping_samples:
		var d := s / 1000.0 - mean_rtt
		variance += d * d
	variance /= _ping_samples.size()
	var jitter := sqrt(variance) / 2.0  # one-way jitter estimate
	var target_delay := NET_TICK_INTERVAL + jitter + 0.016  # broadcast interval + jitter + 1 frame
	var clamped := clampf(target_delay, INTERP_DELAY_MIN, INTERP_DELAY_MAX)
	INTERP_DELAY = lerpf(INTERP_DELAY, clamped, 0.1)


# --- Update rate (GoldSrc sv_updaterate / cl_updaterate) ---

## Set the cadence this peer works at: on the host the rate we broadcast at, on a client the rate
## the server granted us. Drives the jitter-buffer floor, which is two intervals — enough that an
## interpolation bracket still holds two snapshots when one packet arrives late.
func _set_tick_interval(interval: float) -> void:
	NET_TICK_INTERVAL = interval
	NET_TICKRATE = 1.0 / interval
	INTERP_DELAY_MIN = 2.0 * interval
	INTERP_DELAY = clampf(INTERP_DELAY, INTERP_DELAY_MIN, INTERP_DELAY_MAX)


## Server: retune the broadcast rate (sv_updaterate). The synchronizers' replication_interval drives
## stock, and goldnet's snapshot_rate caps every client's grant, which goldnet re-derives itself.
func apply_sv_updaterate(rate: float) -> void:
	_set_tick_interval(1.0 / clampf(rate, UPDATERATE_MIN, UPDATERATE_MAX))
	for sync in _pvs_syncs:
		if is_instance_valid(sync):
			sync.replication_interval = NET_TICK_INTERVAL
	for own: OwnerState in _owner_states.values():
		own.sync.replication_interval = NET_TICK_INTERVAL
	transport.set_snapshot_rate(NET_TICKRATE)
	Log.info("sv_updaterate: %.0f Hz" % NET_TICKRATE)


## Client: set (and persist) the simulated connection. Takes effect at once when connected, since
## goldnet's sims apply live, and at the next join otherwise.
func set_net_profile(id: String) -> void:
	net_profile = id if NetProfiles.PROFILES.has(id) else NetProfiles.OFF
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)  # load existing; OK if missing
	cfg.set_value("net", "sim_profile", net_profile)
	cfg.save(SETTINGS_PATH)
	if is_online() and not is_host():
		_apply_net_profile()


## Off leaves the sim alone unless a profile set it, so GOLDNET_* and /sim_* still work.
func _apply_net_profile() -> void:
	if net_profile == NetProfiles.OFF and not _net_profile_applied:
		return
	if not NetProfiles.apply(multiplayer, net_profile):
		Log.warn("Netsim profile %s needs goldnet with recv_sim_config; joining without it" % net_profile)
		return
	_net_profile_applied = net_profile != NetProfiles.OFF
	Log.info("Netsim: %s (simulated on this client)" % NetProfiles.display_name(net_profile))


## Client: set (and persist) the rate we ask to be served at. 0 = no preference, take the server's
## full rate. Takes effect immediately when connected, and rides _on_connected_to_server otherwise.
func set_cl_updaterate(rate: float) -> void:
	cl_updaterate = clampf(rate, UPDATERATE_MIN, UPDATERATE_MAX) if rate > 0.0 else 0.0
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)  # load existing; OK if missing
	cfg.set_value("net", "cl_updaterate", cl_updaterate)
	cfg.save(SETTINGS_PATH)
	_apply_rates()


## Reply to the server-side /cl_updaterate command: client stores the preference locally so it
## persists across sessions, and asks for it (answered by update_rate_granted).
@rpc("authority", "reliable")
func sync_set_cl_updaterate(rate: float) -> void:
	set_cl_updaterate(rate)


## Client: the rate goldnet's server grants us. Sizes the jitter buffer from OUR interval, not the
## server's — a throttled client that kept the server's floor would starve its own interpolation
## bracket and extrapolate through every gap. 0 = a server that doesn't know its own rate.
func _on_update_rate_granted(rate: int) -> void:
	if rate <= 0:
		return
	_set_tick_interval(1.0 / clampf(rate, UPDATERATE_MIN, UPDATERATE_MAX))
	Log.info("cl_updaterate: granted %.0f Hz (interp floor %d ms)" % [NET_TICKRATE, roundi(INTERP_DELAY_MIN * 1000.0)])


# --- Rate (GoldSrc rate) ---

## Client: set (and persist) the rate we ask to be served at, in bytes/sec. 0 = automatic.
func set_cl_rate(rate: int) -> void:
	cl_rate = clampi(rate, RATE_MIN, RATE_MAX) if rate > 0 else 0
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	cfg.set_value("net", "rate", cl_rate)
	cfg.save(SETTINGS_PATH)
	_apply_rates()


## Client: hand the transport our update rate, rate and command rate; 0 = let goldnet pick it.
func _apply_rates() -> void:
	transport.set_update_rate(roundi(cl_updaterate))
	transport.set_rate(cl_rate, cl_rate == 0)
	transport.set_command_rate(cl_cmdrate, cl_cmdrate == 0.0)


## Client: set (and persist) how many input packets we send per second. 0 = automatic.
func set_cl_cmdrate(rate: float) -> void:
	cl_cmdrate = maxf(rate, CMDRATE_MIN) if rate > 0.0 else 0.0
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	cfg.set_value("net", "cl_cmdrate", cl_cmdrate)
	cfg.save(SETTINGS_PATH)
	_apply_rates()


## Reply to the server-side /cl_cmdrate command: it's purely the client's own pacing.
@rpc("authority", "reliable")
func sync_set_cl_cmdrate(rate: float) -> void:
	set_cl_cmdrate(rate)


## Reply to the server-side /rate command: the client stores the preference so it persists across
## sessions, then requests it back.
@rpc("authority", "reliable")
func sync_set_cl_rate(rate: int) -> void:
	set_cl_rate(rate)


# --- Client → Server send wrappers ---
## All client-to-server gameplay sends go through these wrappers. Never call .rpc_id(1, ...) directly
## from game code.

func send_input_cmd(cmd) -> void:
	submit_input.rpc_id(1, FireControl.command_fields(cmd))

## The lag-comp stamp is the shooter's RENDER time, not their clock estimate: what they were aiming at
## is what RemotePlayer drew, one INTERP_DELAY behind get_estimated_server_time(). Stamping the clock
## estimate under-rewound every shot by the whole jitter buffer, so targets had to be led even with
## unlag on. The server clamps the stamp to MAX_REWIND_MS, so a lying client gains nothing. The host's
## own body is exempt (never rendered), but every other puppet the host shoots at renders through the
## same INTERP_DELAY-behind buffer as any other observer, so its shots need the same rewind too.
## A firing command carries it (FireControl.TriggerInput.shot_ms).
func shot_time_ms() -> int:
	if is_host():
		return Time.get_ticks_msec() - int(round(INTERP_DELAY * 1000.0))
	return int((get_estimated_server_time() - INTERP_DELAY) * 1000.0)

func send_request_use(target_path: NodePath) -> void:
	# is_authority(), not is_host(): offline there's no peer to route through, but this machine is the server.
	if is_authority():
		ServerRequests.use(multiplayer.get_unique_id(), target_path)
	else:
		request_use.rpc_id(1, target_path)

func send_request_prime_satchel() -> void:
	if is_host():
		ServerRequests.prime_satchel(multiplayer.get_unique_id())
	else:
		request_prime_satchel.rpc_id(1)

func send_request_throw_satchel(aim_dir: Vector3) -> void:
	if is_host():
		ServerRequests.throw_satchel(multiplayer.get_unique_id(), aim_dir)
	else:
		request_throw_satchel.rpc_id(1, aim_dir)

func send_request_help_call() -> void:
	if is_authority():
		ServerRequests.help_call(multiplayer.get_unique_id())
	else:
		request_help_call.rpc_id(1)


## Logged on both sides (here and at ServerRequests.join_team) because a join that goes missing
## leaves no other trace: the class menu is already dismissed and the server answers nothing it
## never received. One line each says which side dropped it.
func send_request_join_team(team: int, element: int = GameConsts.Element.FIRE) -> void:
	if is_host():
		ServerRequests.join_team(multiplayer.get_unique_id(), team, element)
	else:
		Log.info("[Join] sending request_join_team team=%d element=%d" % [team, element])
		request_join_team.rpc_id(1, team, element)

func send_request_player_states() -> void:
	if is_host():
		_send_player_states_to(multiplayer.get_unique_id())
	else:
		request_player_states.rpc_id(1)

func send_request_player_name(player_name: String) -> void:
	if is_host():
		ServerRequests.set_player_name(multiplayer.get_unique_id(), player_name)
	else:
		request_player_name.rpc_id(1, player_name)

func send_request_chat(message: String, team_only: bool) -> void:
	if is_host():
		ServerRequests.chat(multiplayer.get_unique_id(), message, team_only)
	else:
		request_chat.rpc_id(1, message, team_only)


# --- Player state sync (unreliable, every physics frame) ---

# --- Server-authoritative movement RPCs ---

## One input command, as FireControl.command_fields(); one missing a field rebuilds as null. A command
## stream (CommandStream): each call arrives once, in order. goldnet carries it over its uplink,
## sending only the fields that changed since the last; stock, as the reliable RPC it is.
@rpc("any_peer", "call_remote", "reliable")
func submit_input(fields: Dictionary) -> void:
	if not multiplayer.is_server():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	var remote := get_player(sender_id)
	if not remote or not remote.has_server_movement():
		return
	if remote.is_dead:
		return
	var cmd = FireControl.command_from_fields(fields)
	if cmd != null:
		remote.get_server_movement().enqueue(cmd)


# --- Own movement state (see OwnerState) ---

func _add_owner_state(peer_id: int) -> OwnerState:
	_free_owner_state(peer_id)
	var node := OwnerState.create(peer_id)
	node.sync.replication_interval = NET_TICK_INTERVAL  # stock would otherwise send every frame
	add_child(node)
	_owner_states[peer_id] = node
	return node


## Out of the tree now rather than at queue_free, so a reconnect can take the same path (the path
## is the replication identity).
func _free_owner_state(peer_id: int) -> void:
	var node: OwnerState = _owner_states.get(peer_id)
	_owner_states.erase(peer_id)
	if is_instance_valid(node):
		remove_child(node)
		node.queue_free()


## Server: this tick's state for a client, to go out in its snapshot.
func publish_owner_state(peer_id: int, seq: int, pos: Vector3, vel: Vector3, crouched: bool,
		on_floor: bool, jumping: bool, jump_held: bool, queue_depth: int) -> void:
	var node: OwnerState = _owner_states.get(peer_id)
	if node != null:
		node.write(seq, pos, vel, crouched, on_floor, jumping, jump_held, queue_depth)


## Client: the snapshot changed our own state. Fires only on a change, which a new input seq always is.
func _on_owner_state_synced(node: OwnerState) -> void:
	if view_diag != null:
		view_diag.note_state(Time.get_ticks_usec())
		var stats := transport.link_stats()
		view_diag.note_uplink(stats.get("uplink_lag_ms", 0), stats.get("uplink_pps", 0), stats.get("command_rate", 0.0))
	net_input_queue_depth = node.queue_depth
	if node.seq >= 0:
		_dispatch_to_scene(&"_on_owner_state", [node.seq, node.pos, node.vel,
				(node.flags & OwnerState.FLAG_CROUCHED) != 0, (node.flags & OwnerState.FLAG_ON_FLOOR) != 0,
				(node.flags & OwnerState.FLAG_JUMPING) != 0, (node.flags & OwnerState.FLAG_JUMP_HELD) != 0])


# --- Client -> Host: +use request ---

@rpc("any_peer", "reliable")
func request_use(target_path: NodePath) -> void:
	if not multiplayer.is_server():
		return
	ServerRequests.use(multiplayer.get_remote_sender_id(), target_path)


# --- Attack sync ---
# A player's fire rides their input commands (FireControl); these are what the server tells others.

## Attack visuals are cosmetic, so this is UNRELIABLE + PVS-filtered rather than reliable
## broadcast-to-everyone (which inflated ping under heavy combat); a dropped flash self-heals on the
## next shot. The shooter's own peer is skipped — it fired locally already.
func broadcast_attack(shooter_id: int, weapon_idx: int, aim_dir: Vector3, secondary: bool) -> void:
	_send_to_observers(shooter_id, func(peer_id: int) -> void:
		sync_attack.rpc_id(peer_id, shooter_id, weapon_idx, aim_dir, secondary))


## Shared PVS-filter loop for the cosmetic attack broadcasts below.
func _send_to_observers(shooter_id: int, send: Callable) -> void:
	for peer_id in multiplayer.get_peers():
		if peer_id == shooter_id:
			continue
		if not VisibilitySystem.is_player_visible_to_peer(shooter_id, peer_id):
			continue
		send.call(peer_id)


## Never call .rpc() on this directly; go through broadcast_attack() so the visibility filter applies.
@rpc("authority", "call_remote", "unreliable")
func sync_attack(peer_id: int, weapon_idx: int = 0, aim_dir: Vector3 = Vector3.ZERO, secondary: bool = false) -> void:
	_dispatch_to_scene(&"_on_sync_attack", [peer_id, weapon_idx, aim_dir, secondary])


## `weapon` is the one that just stopped. Sustained weapons skip this event: their observers are
## driven level-triggered by the snapshot's PLAYER_FLAG_FIRING instead, so sending it would be pure
## wire traffic that does nothing. Pass null when the weapon isn't known (fail open, sends it).
## Discrete weapons that hold state between shots with no snapshot bit to heal from (beanstalk's
## in-progress build, double missile's fire-state counter) still depend on this to clear it.
func broadcast_stop_attack(shooter_id: int, weapon: Weapon = null) -> void:
	if weapon != null and weapon.sustained:
		return
	_send_to_observers(shooter_id, func(peer_id: int) -> void:
		sync_stop_attack.rpc_id(peer_id, shooter_id))


## Never call .rpc() directly, go through broadcast_stop_attack(). Unreliable and PVS-filtered, so
## it's a hint not a guarantee — a discrete weapon relying on it alone can have state stranded by one
## lost packet. Anything user-visible should use `sustained` + PLAYER_FLAG_FIRING instead.
@rpc("authority", "call_remote", "unreliable")
func sync_stop_attack(peer_id: int) -> void:
	_dispatch_to_scene(&"_on_sync_stop_attack", [peer_id])


## Client → Server: prime a satchel (start fuse countdown).
@rpc("any_peer", "reliable")
func request_prime_satchel() -> void:
	if not multiplayer.is_server():
		return
	ServerRequests.prime_satchel(multiplayer.get_remote_sender_id())


## Client → Server: throw a primed satchel.
@rpc("any_peer", "reliable")
func request_throw_satchel(aim_dir: Vector3) -> void:
	if not multiplayer.is_server():
		return
	ServerRequests.throw_satchel(multiplayer.get_remote_sender_id(), aim_dir)


## Client -> Server: call for help.
@rpc("any_peer", "reliable")
func request_help_call() -> void:
	if not multiplayer.is_server():
		return
	ServerRequests.help_call(multiplayer.get_remote_sender_id())


@rpc("authority", "call_remote", "unreliable")
func sync_player_help_call(peer_id: int, sprite_path: String, sound_path: String) -> void:
	_dispatch_to_scene(&"_on_sync_player_help_call", [peer_id, sprite_path, sound_path])


@rpc("authority", "call_remote", "reliable")
func sync_player_heal(amount: float, allow_overheal := false) -> void:
	_dispatch_to_scene(&"_on_sync_player_heal", [amount, allow_overheal])


@rpc("authority", "call_remote", "reliable")
func sync_mana(new_mana: float, new_satchels: int) -> void:
	_dispatch_to_scene(&"_on_sync_mana", [new_mana, new_satchels])


## Unreliable — newer values supersede, throttled mana update during sustained drain.
@rpc("authority", "call_remote", "unreliable_ordered")
func sync_mana_drain(new_mana: float, new_satchels: int) -> void:
	_dispatch_to_scene(&"_on_sync_mana_drain", [new_mana, new_satchels])


## Fire was a warning-only press (can_fire returned false); resets the client's cooldown so the
## confirmation press can follow immediately.
@rpc("authority", "call_remote", "reliable")
func sync_fire_warning() -> void:
	_dispatch_to_scene(&"_on_sync_fire_warning")


@rpc("authority", "call_remote", "reliable")
func sync_player_damage(amount: float, type: int = 0) -> void:
	_dispatch_to_scene(&"_on_sync_player_damage", [amount, type])


@rpc("authority", "call_remote", "reliable")
func sync_player_status(status_type: int) -> void:
	_dispatch_to_scene(&"_on_sync_player_status", [status_type])


@rpc("authority", "call_remote", "reliable")
func sync_player_clear_status(status_type: int) -> void:
	_dispatch_to_scene(&"_on_sync_player_clear_status", [status_type])


## A puppet's status sprite changed in its snapshot flags (RemotePlayer.apply_render_flags).
func show_status_visual(peer_id: int, status_type: int, active: bool) -> void:
	_dispatch_to_scene(&"_on_status_visual", [peer_id, status_type, active])


@rpc("authority", "call_remote", "reliable")
func sync_plant_indicator(kind: String, active: bool, hp: float, max_hp: float) -> void:
	_dispatch_to_scene(&"_on_sync_plant_indicator", [kind, active, hp, max_hp])


@rpc("authority", "call_remote", "reliable")
func sync_player_frost(duration: float) -> void:
	_dispatch_to_scene(&"_on_sync_player_frost", [duration])


## lethal=true when the hit killed the target — distinct kill confirm.
@rpc("authority", "call_remote", "reliable")
func sync_hit_confirmed(lethal := false) -> void:
	_dispatch_to_scene(&"_on_sync_hit_confirmed", [lethal])


## Who this peer's crosshair is on. relation: 1 ally, -1 enemy, 0 neither; health_pct -1 when
## they may not read it. An empty label clears the line. Sent only when it changes, so holding
## a target on screen costs nothing (RemotePlayer.tick_target_id).
@rpc("authority", "call_remote", "reliable")
func sync_target_id(label: String, relation: int, health_pct: int) -> void:
	_dispatch_to_scene(&"_on_sync_target_id", [label, relation, health_pct])


func send_target_id_to(peer_id: int, label: String, relation: int, health_pct: int) -> void:
	send_to_owner(peer_id, &"sync_target_id", [label, relation, health_pct])


## Routes locally when the attacker is the host's own player (LocalPlayer or its HostBody server
## puppet) since rpc_id on yourself errors for a call_remote RPC.
func send_hit_confirmed_to(attacker: Node, lethal := false) -> void:
	if not attacker:
		return
	var local_player = Game.local_player
	if attacker == local_player:
		_dispatch_to_scene(&"_on_sync_hit_confirmed", [lethal])
		return
	# A non-player attacker (a dragon, a summon) has no peer_id at all, and int(null) is not a
	# conversion — it's a runtime error. Read it before converting.
	var pid: Variant = attacker.get("peer_id")
	if pid == null or int(pid) <= 0:
		return  # bots (negative synthetic ids) and non-players get no hit feedback
	var peer_id := int(pid)
	send_to_owner(peer_id, &"sync_hit_confirmed", [lethal])


## GoldSrc pev->punchangle: the jolt a mind missile leaves in the view of whoever it hit. Goes
## to that one peer, since nobody else's view moved. Unreliable: the original's punchangle rode
## clientdata, never a reliable message.
@rpc("authority", "call_remote", "unreliable")
func sync_view_punch(roll_degrees: float) -> void:
	_dispatch_to_scene(&"_on_sync_view_punch", [roll_degrees])


func send_view_punch(target: Node, roll_degrees: float) -> void:
	if not target or not ("peer_id" in target):
		return
	var peer_id: int = int(target.get("peer_id"))
	if peer_id <= 0:
		return  # bots (negative synthetic ids) and summons have no view to rock
	send_to_owner(peer_id, &"sync_view_punch", [roll_degrees])


## Mirrors HUD.show_fade() — reverse=true is an instant flash that fades out.
@rpc("authority", "call_remote", "reliable")
func sync_screen_fade(color: Color, duration: float, holdtime: float, reverse: bool) -> void:
	_dispatch_to_scene(&"_on_sync_screen_fade", [color, duration, holdtime, reverse])


## target=null broadcasts to everyone. The host always sees its own copy since sync_screen_fade is
## call_remote and wouldn't otherwise fire on the authority.
func send_screen_fade(color: Color, duration: float, holdtime: float, reverse: bool, target: Node = null) -> void:
	if target == null:
		sync_screen_fade.rpc(color, duration, holdtime, reverse)
		_dispatch_to_scene(&"_on_sync_screen_fade", [color, duration, holdtime, reverse])
		return
	var peer_id: int = int(target.get("peer_id"))
	if peer_id == multiplayer.get_unique_id():
		_dispatch_to_scene(&"_on_sync_screen_fade", [color, duration, holdtime, reverse])
	elif is_peer_connected(peer_id):
		sync_screen_fade.rpc_id(peer_id, color, duration, holdtime, reverse)


## GoldSrc gmsgShake: reliable, and only to the players UTIL_ScreenShake picked (see shakes).
@rpc("authority", "call_remote", "reliable")
func sync_screen_shake(amplitude: float, duration: float, frequency: float) -> void:
	_dispatch_to_scene(&"_on_sync_screen_shake", [amplitude, duration, frequency])


## UTIL_ScreenShake: each player on the ground within `radius` (<= 0 is everyone) shakes at the full
## amplitude. The original had a distance falloff and took it out ("it didn't work well").
func shakes(pos: Vector3, on_floor: bool, origin: Vector3, radius: float) -> bool:
	return on_floor and (radius <= 0.0 or pos.distance_to(origin) < radius)


func send_screen_shake(origin: Vector3, amplitude: float, radius: float, duration: float,
		frequency: float) -> void:
	if not is_online():
		Game.shake_view_local(origin, amplitude, radius, duration, frequency)
		return
	for peer_id: int in _players:
		var p = get_player(peer_id)
		if peer_id > 0 and p and shakes(p.global_position, p.get("grounded") == true, origin, radius):
			send_to_owner(peer_id, &"sync_screen_shake", [amplitude, duration, frequency])


@rpc("authority", "call_remote", "reliable")
func sync_player_death(peer_id: int, killer_peer: int = 0) -> void:
	GoalSystem.record_kill(killer_peer, peer_id)
	_dispatch_to_scene(&"_on_sync_player_death", [peer_id])


## Something coming apart — a wizard, a bird shot out of the air, a breakable. One-shot and
## cosmetic: nothing survives it, so it is an unreliable PVS send (the original's TE_BREAKMODEL)
## rather than a replicated entity. The burst's whole shape rides along because the caller owns
## it, not this handler (see GibEffect.burst).
@rpc("authority", "call_remote", "unreliable")
func sync_gib_burst(pos: Vector3, material: int, extent: Vector3, count: int,
		sound: String, gibmodel: String) -> void:
	_dispatch_to_scene(&"_on_sync_gib_burst", [pos, material, extent, count, sound, gibmodel])


@rpc("authority", "call_remote", "reliable")
func sync_player_respawn(peer_id: int) -> void:
	_dispatch_to_scene(&"_on_sync_player_respawn", [peer_id])


# --- Invisibility sync ---

## To the invisible player alone: observers read it from the snapshot (PLAYER_FLAG_INVISIBLE).
@rpc("authority", "call_remote", "reliable")
func sync_player_invis(peer_id: int, active: bool) -> void:
	_dispatch_to_scene(&"_on_sync_player_invis", [peer_id, active])


# --- Bear morph sync ---

@rpc("authority", "call_remote", "reliable")
func sync_bear_morph(peer_id: int, is_bear: bool, new_health: float, new_max_health: float) -> void:
	_dispatch_to_scene(&"_on_sync_bear_morph", [peer_id, is_bear, new_health, new_max_health])


# --- Runtime weapon grants (item_weapon pickups, /give) ---

## Every peer has to apply the grant, not just the owner: sync_attack replays a shot by weapon
## index against the observer's own replica of the shooter.
@rpc("authority", "call_remote", "reliable")
func sync_grant_weapon(peer_id: int, key: String) -> void:
	_dispatch_to_scene(&"_on_sync_grant_weapon", [peer_id, key])


func broadcast_grant_weapon(peer_id: int, key: String) -> void:
	if is_online():
		broadcast_and_dispatch(&"sync_grant_weapon", [peer_id, key])
	else:
		_dispatch_to_scene(&"_on_sync_grant_weapon", [peer_id, key])


## The other half of a grant: a one-shot spell takes itself back after it's cast. Every peer has
## to apply it for the same reason, and because removing a slot shifts every index after it.
@rpc("authority", "call_remote", "reliable")
func sync_revoke_weapon(peer_id: int, key: String) -> void:
	_dispatch_to_scene(&"_on_sync_revoke_weapon", [peer_id, key])


func broadcast_revoke_weapon(peer_id: int, key: String) -> void:
	if is_online():
		broadcast_and_dispatch(&"sync_revoke_weapon", [peer_id, key])
	else:
		_dispatch_to_scene(&"_on_sync_revoke_weapon", [peer_id, key])


# --- Dragon mount sync ---

@rpc("authority", "call_local", "reliable")
func sync_dragon_mount(peer_id: int, entity_id: int, mounted: bool) -> void:
	_dispatch_to_scene(&"_on_sync_dragon_mount", [peer_id, entity_id, mounted])


## Dragon.MAX_FLAME is a const the client already has, so only the count goes on the wire.
@rpc("authority", "call_remote", "reliable")
func sync_dragon_flame(flame: int) -> void:
	_dispatch_to_scene(&"_on_sync_dragon_flame", [flame])


@rpc("authority", "call_remote", "unreliable_ordered")
func sync_dragon_flame_drain(flame: int) -> void:
	_dispatch_to_scene(&"_on_sync_dragon_flame_drain", [flame])


func get_synced_entity(entity_id: int) -> Node:
	return _synced_entities.get(entity_id)


# --- Entity sync ---

## For nodes that already exist on both sides (e.g. map body); no create RPC is sent.
func register_synced_entity(node: Node, vis_node: Node3D = null) -> int:
	var id := _next_entity_id
	_next_entity_id += 1
	_bind_synced_entity(id, node)
	var track := vis_node if vis_node != null else node as Node3D
	if track != null:
		VisibilitySystem.track_node(id, track)
	return id


## Ensures a late joiner's _next_entity_id doesn't collide with entities created while it was
## downloading the map.
@rpc("authority", "call_remote", "reliable")
func _sync_entity_id_base(id_base: int) -> void:
	if _next_entity_id < id_base:
		Log.info("Entity ID base synced: %d -> %d" % [_next_entity_id, id_base])
		_next_entity_id = id_base


func spawn_dynamic_entity(data: Dictionary) -> Node:
	var main := get_tree().current_scene
	if main and main.has_method("spawn_dynamic_entity"):
		return main.spawn_dynamic_entity(data)
	return null


## Allocate the network id for one dynamic entity. Server-only; the id rides the spawn data, so
## both peers name the node from it (goldnet keys a replicated node by its scene path) and the
## state-sync ones (dragon mount state, plant grow/attack) look each other up by it.
func alloc_dyn_entity_id() -> int:
	var id := _next_entity_id
	_next_entity_id += 1
	return id


## Register a spawner-managed entity for state sync (sync_entity_state lookup by id). Its transform
## rides its MultiplayerSynchronizer, so it's flagged to be skipped by send_entity_transforms.
func register_dyn_state_entity(id: int, node: Node) -> void:
	_bind_synced_entity(id, node)
	node.set_meta("_dyn_state_managed", true)


func unregister_dyn_state_entity(id: int) -> void:
	_synced_entities.erase(id)
	_entity_buffers.erase(id)


## Host: spawn a Projectile-type dynamic entity through the spawner. `data` holds only serializable
## setup fields (position, direction, speed, …) — NOT RIDs or node refs. owner_node + exclude_rid are
## non-serializable and get set on the returned server node after the spawn. Returns null off-host.
func spawn_projectile(script_path: String, data: Dictionary, owner_node: Node3D, exclude_rid: RID = RID()) -> Node:
	data = data.duplicate()
	data["script_path"] = script_path
	var node := spawn_dynamic_entity(data)
	if node:
		if "owner_node" in node:
			node.owner_node = owner_node
		if exclude_rid.is_valid() and "exclude_rid" in node:
			node.exclude_rid = exclude_rid
	return node


func destroy_all_dynamic_entities() -> void:
	# The server free replicates a despawn to clients via the MultiplayerSpawner; offline it just
	# frees the local node.
	if not is_authority():
		return
	var scene := get_tree().current_scene
	if not scene:
		return
	for child in scene.get_children():
		if child.has_meta("_dyn_spawner_entity"):
			# Something a round outlives. A siege altar is the case this exists for: the wipe is
			# how a wave break clears leftover monsters, and the thing they were attacking must
			# still be standing — with its damage — on the other side of it.
			if child.has_meta("_persist_round"):
				continue
			if "_exploded" in child:
				child._exploded = true  # suppress _exit_tree explosion effects on reset
			child.queue_free()


func _resolve_transform_node(node) -> Node3D:
	return (node._transform_node if "_transform_node" in node and node._transform_node else node) as Node3D


## The entity's MoverNetPublisher, or null — the opt-in flag and the protocol in one property.
const _MOVER_NET_PROP := &"_mover_net"  # cached StringName, avoids re-hashing per entity per tick


func send_entity_transforms() -> void:
	# Each mover streams its transform through its own MultiplayerSynchronizer; this just writes the
	# authoritative shadow state for the synchronizer to ship.
	var stale: Array[int] = []
	for id in _synced_entities:
		var node = _synced_entities[id]
		if not (node and is_instance_valid(node)):
			stale.append(id)
			continue
		var pub = node.get(_MOVER_NET_PROP)
		if pub:
			pub.publish()
	for id in stale:
		_erase_entity(id)


## A dry buffer dead-reckons a straight line knowing nothing of the world, so an entity that stopped
## mid-gap keeps going — a falling corpse walks metres through the floor, then snaps back when the real
## resting sample lands. Sweep the entity's own collision volume from the last real sample to the guess.
##
## cast_motion is the generic space-state call, so this holds on any physics backend (against GoldSrc
## hulls the shape is approximated to a hull size, which costs accuracy and not the point). An entity
## with no collision volume isn't stopped on the authority either, so its straight line is already
## right and is left alone. The guess is never authoritative — the real sample overwrites it a tick or
## two later — so it only has to be roughly right to turn a visible snap into nothing.
func _clamp_extrapolation(id: int, tnode: Node3D, anchor: Vector3, rot: Vector3, guess: Vector3) -> Vector3:
	var motion := guess - anchor
	if motion.is_zero_approx():
		return guess
	if not _interp_shapes.has(id):
		# Resolved on first use, not at registration: the bridge registers from its own _ready, which
		# runs before the parent entity's _ready has built the CollisionShape3D. By the time anything
		# extrapolates, two snapshots have arrived and the entity is long since built.
		_interp_shapes[id] = _resolve_interp_shape(tnode)
	var entry = _interp_shapes[id]
	if entry == null:
		return guess
	var world := tnode.get_world_3d()
	if world == null:
		return guess
	if _extrap_query == null:
		_extrap_query = PhysicsShapeQueryParameters3D.new()
		_extrap_query.collide_with_areas = false
		_extrap_query.collide_with_bodies = true
	var basis := Basis.from_euler(rot)
	# The replica's own mask — the authority's answer to what this stops against (corpse: world only;
	# rolling stone: world + entities + players). Replicas zero their layer but keep the mask.
	_extrap_query.collision_mask = entry[2]
	_extrap_query.shape = entry[0]
	_extrap_query.transform = Transform3D(basis, anchor + basis * (entry[1] as Vector3))
	_extrap_query.motion = motion
	var hit := world.direct_space_state.cast_motion(_extrap_query)
	# [safe_fraction, unsafe_fraction] in [0,1]; safe == 1.0 means the whole sweep is clear.
	if hit.is_empty() or hit[0] >= 1.0:
		return guess
	return anchor + motion * hit[0]


## The entity's collision volume as [shape, local offset, collision mask], or null if it has none.
func _resolve_interp_shape(tnode: Node3D) -> Variant:
	for child in tnode.get_children():
		var cs := child as CollisionShape3D
		if cs != null and cs.shape != null:
			var body := tnode as CollisionObject3D
			return [cs.shape, cs.position,
					body.collision_mask if body != null else GameConsts.MASK_WORLD]
	return null


func interp_entities() -> void:
	if not _server_clock.is_synced():
		return
	var render_time := get_estimated_server_time() - INTERP_DELAY
	var stale_ids: Array[int] = []

	for id in _entity_buffers:
		var node = _synced_entities.get(id)
		if not node or not is_instance_valid(node):
			stale_ids.append(id)
			continue
		var pub = node.get(_MOVER_NET_PROP)
		if pub and pub.interp_skip:
			continue  # a parent contraption (golem) owns this transform in the current mode
		var buf: InterpolationBuffer = _entity_buffers[id]
		var tnode: Node3D = _resolve_transform_node(node)
		if not tnode:
			continue
		var s := buf.sample(render_time)
		if interp_diag != null and s.valid:
			interp_diag.note_frame(id, tnode, buf.last_time(), render_time - buf.last_time(),
				s.extrapolated, s.holding)
		# Skip once the buffer is in a static hold: re-stamping the frozen position would clobber an
		# out-of-band reposition (e.g. item_tfgoal's reliable RETURN/DROP teleport).
		if s.valid and not s.holding:
			var pos: Vector3 = s.position
			if s.extrapolated:
				var guess: Vector3 = pos
				pos = _clamp_extrapolation(id, tnode, s.anchor, s.rotation, pos)
				# Only once the guess actually moved — _clamp_extrapolation early-outs before it
				# resolves a shape when it didn't, and _interp_shapes would read as "no shape".
				if interp_diag != null and guess != s.anchor:
					interp_diag.note_extrap(id, s.anchor, guess, pos, _interp_shapes.get(id) != null)
			tnode.global_position = pos
			tnode.global_rotation = s.rotation
		elif s.holding and render_time - buf.last_time() > ENTITY_PARK_AFTER:
			var bridge = _interp_bridges.get(id)
			if bridge:
				bridge.park_if_stream_died()

	for id in stale_ids:
		_erase_entity(id)


# --- Team sync ---

## Includes spawn position so remote players appear at the correct location immediately.
@rpc("authority", "call_remote", "reliable")
func sync_team_for_peer(peer_id: int, team: int, element: int = GameConsts.Element.FIRE, pos: Vector3 = Vector3.ZERO, yaw: float = 0.0) -> void:
	# PVS-independent roster: record team even when the body isn't (yet) replicated.
	set_player_team(peer_id, team)
	var remote := get_player(peer_id)
	if remote:
		_apply_team_state(remote, team, element, pos, yaw)
		Log.info("Peer %d joined team %d (element=%d) at %s" % [peer_id, team, element, pos])
	else:
		# Puppet not registered on this client yet (common for bots: spawn + this RPC share a tick, so
		# appearance can beat the spawner's `spawned` signal). Buffer it; _on_puppet_spawned drains it.
		_pending_team_state[peer_id] = [team, element, pos, yaw]


## Shared by the immediate and deferred (buffered) paths so both behave identically.
func _apply_team_state(remote: Player, team: int, element: int, pos: Vector3, yaw: float) -> void:
	remote.team = team
	remote.set_element(element)
	if pos != Vector3.ZERO:
		remote.global_position = pos
		remote.rotation.y = yaw
	remote.visible = true
	# Prevents a player spawning as a non-ice wizard staying transparent from a prior ice wizard spell.
	remote.is_invisible = false
	remote._invis_alpha = 1.0


## Applies any team appearance that arrived before the spawn (see sync_team_for_peer).
func apply_pending_team_state(peer_id: int, remote: Player) -> void:
	if not _pending_team_state.has(peer_id):
		return
	var s: Array = _pending_team_state[peer_id]
	_pending_team_state.erase(peer_id)
	_apply_team_state(remote, s[0], s[1], s[2], s[3])
	Log.info("Peer %d joined team %d (element=%d) [deferred to spawn]" % [peer_id, s[0], s[1]])


@rpc("any_peer", "reliable")
func request_join_team(team: int, element: int = GameConsts.Element.FIRE) -> void:
	if not multiplayer.is_server():
		return
	ServerRequests.join_team(multiplayer.get_remote_sender_id(), team, element)


@rpc("any_peer", "reliable")
func request_player_name(player_name: String) -> void:
	if not multiplayer.is_server():
		return
	ServerRequests.set_player_name(multiplayer.get_remote_sender_id(), player_name)


@rpc("authority", "call_remote", "reliable")
func sync_player_name(peer_id: int, player_name: String) -> void:
	set_player_name(peer_id, player_name)


## Called after the game becomes active so remote players exist to receive updates.
@rpc("any_peer", "reliable")
func request_player_states() -> void:
	if not multiplayer.is_server():
		return
	_send_player_states_to(multiplayer.get_remote_sender_id())


## The late joiner's baseline: every team/class already taken, each puppet's state, every known
## name. Marking the peer map-ready is part of the same handshake — it gates map-entity
## synchronizer visibility (see is_peer_map_ready), so it has to land before the first send.
func _send_player_states_to(peer_id: int) -> void:
	if peer_id == multiplayer.get_unique_id():
		return
	_map_ready_peers[peer_id] = true
	var own: OwnerState = _owner_states.get(peer_id)
	if own != null:
		own.show_to_owner(peer_id)
	var roster := player_roster()
	for other_id in roster:
		var remote: Player = roster[other_id]
		if remote.team != GameConsts.Team.NONE:
			sync_team_for_peer.rpc_id(peer_id, other_id, remote.team, remote.element, remote.global_position, remote.rotation.y)
			remote.sync_state_to_peer(peer_id)
	var names := peer_names()
	for other_id: int in names:
		sync_player_name.rpc_id(peer_id, other_id, str(names[other_id]))


## Host → Client: team join was rejected (team full, no active spawn, class not allowed). The
## host's own rejection reaches the same handler through send_to_owner's local branch, which is
## why the message itself lives in main and not here.
@rpc("authority", "call_remote", "reliable")
func reject_team_join(team: int, reason: String) -> void:
	_dispatch_to_scene(&"_on_reject_team_join", [team, reason])


@rpc("authority", "call_remote", "reliable")
func assign_spawn(pos: Vector3, yaw: float, team: int, element: int = GameConsts.Element.FIRE) -> void:
	_dispatch_to_scene(&"_on_assign_spawn", [pos, yaw, team, element])


## Teleport without resetting stats — ice satchel teleport and similar non-respawn position changes.
@rpc("authority", "call_remote", "reliable")
func teleport_player(pos: Vector3, yaw: float) -> void:
	_dispatch_to_scene(&"_on_teleport_player", [pos, yaw])


@rpc("any_peer", "reliable")
func _request_entity_state() -> void:
	if not multiplayer.is_server():
		return
	var peer_id := multiplayer.get_remote_sender_id()
	var main_scene = get_tree().current_scene
	if not main_scene:
		return

	# Static (map) entities only; dynamic entities are handled after their creation is sent below.
	for id in _synced_entities:
		var node = _synced_entities[id]
		if not node or not is_instance_valid(node):
			continue
		if node.has_meta("_net_create_data"):
			continue  # handled in the dynamic entity loop below
		if node.has_method("_get_sync_state"):
			var state: Dictionary = node._get_sync_state()
			if not state.is_empty():
				sync_entity_state.rpc_id(peer_id, id, state)

	if Game.weather_system:
		Game.weather_system.send_state_to(peer_id)
	for team in GoalSystem.team_scores.size():  # announce=false: a join snapshot, not a live score event
		if GoalSystem.team_scores[team] != 0:
			GoalSystem.sync_score.rpc_id(peer_id, team, GoalSystem.team_scores[team], false)
	MatchSystem.apply_remote.rpc_id(peer_id, int(MatchSystem.state), MatchSystem.match_end_ms,
		MatchSystem.intermission_end_ms, MatchSystem.winner_team, MatchSystem.winner_name,
		MatchSystem.end_reason, MatchSystem.next_map)
	if SiegeSystem.active:  # joined mid-siege: tell them which wave they walked into
		SiegeSystem.apply_remote.rpc_id(peer_id, int(SiegeSystem.phase), SiegeSystem.wave,
			SiegeSystem.WAVE_COUNT, SiegeSystem.phase_end_ms)
	if not MatchSystem.vote_candidates.is_empty():  # joined mid-intermission: hand them the ballot
		MatchSystem.apply_remote_vote.rpc_id(peer_id, MatchSystem.vote_candidates,
			MatchSystem.vote_tallies(), MatchSystem.next_map)
	for pid in GoalSystem.player_kills:
		GoalSystem.sync_player_stats.rpc_id(peer_id, pid, GoalSystem.player_kills[pid],
			GoalSystem.player_deaths.get(pid, 0))
	for pid in GoalSystem.player_deaths:
		if not GoalSystem.player_kills.has(pid):
			GoalSystem.sync_player_stats.rpc_id(peer_id, pid, 0, GoalSystem.player_deaths[pid])

	_sync_entity_id_base.rpc_id(peer_id, _next_entity_id)

	# Dynamic entities (projectiles, etc.) are NOT replayed here — create-on-PVS-enter delivers each
	# to this peer the first time it can see it, so a joiner only receives entities that reach its view.


@rpc("authority", "call_remote", "reliable")
func sync_entity_state(entity_id: int, state: Dictionary) -> void:
	_apply_entity_state_local(entity_id, state)


## sync_entity_state for a one-shot effect, which the original sent as a temp entity: unreliable,
## and dropped rather than parked when this client doesn't have the entity — it couldn't see it,
## and a late zap is worse than none.
@rpc("authority", "call_remote", "unreliable")
func sync_entity_event(entity_id: int, event: Dictionary) -> void:
	var node = _synced_entities.get(entity_id)
	if node and is_instance_valid(node) and node.has_method("_apply_sync_state"):
		node._apply_sync_state(event)


## sync_entity_event to the peers whose PVS reaches `near`, or to everyone when it is INF.
func send_entity_event(entity_id: int, event: Dictionary, near := Vector3.INF) -> void:
	if not near.is_finite():
		sync_entity_event.rpc(entity_id, event)
		return
	for peer_id in VisibilitySystem.peers_seeing(AABB(near, Vector3.ZERO), multiplayer.get_peers()):
		sync_entity_event.rpc_id(peer_id, entity_id, event)


@rpc("authority", "call_remote", "unreliable")
func _sync_pvs_stats(visible: int, total: int) -> void:
	pvs_visible = visible
	pvs_total = total


# --- Transport ---

## What the live transport can do. Stock until main._install_goldnet swaps in GoldnetTransport,
## which is the one decision there is — it never swaps again. Assign a stub to exercise a path.
var transport := StockTransport.new()


## Tell goldnet an entity's replicated state just changed, so the next snapshot reads it. Otherwise
## goldnet has to read every owned entity every tick to discover which moved (~390 to find ~25 on
## ww_2fort). Call right after writing the replicated vars.
##
## Only affects the slots that sync declared in its "gn_push" meta; every other slot is polled
## every tick regardless. So a missed call costs the read this exists to avoid — it cannot silently
## stale a property nobody promised to announce, which is why there's no audit mode to run.
## No-ops on the stock transport and off-server.
func mark_entity_dirty(node: Node) -> void:
	transport.mark_dirty(node)


## Deferred to the physics step like the stock time beacon so all unreliable clock samples land in one place.
func _on_goldnet_server_time(server_time_ms: int) -> void:
	_update_server_clock(server_time_ms)
	if view_diag != null:
		var stats := transport.link_stats()
		view_diag.note_downlink(stats.get("downlink_lag_ms", 0), stats.get("rate", 0))


## An owned sync left our PVS: deactivate its entity (the parent EntityBase). Players and other syncs
## (no set_present_from_server) run their own presence and are ignored. Enter is handled by
## _on_mover_synchronized, so no matching "gained" handler is needed.
func _on_entity_relevance_lost(sync: Object) -> void:
	if not is_instance_valid(sync):
		return
	var entity := (sync as Node).get_parent()
	if entity and entity.has_method(&"set_present_from_server"):
		entity.set_present_from_server(false)


func _update_peer_relevancy() -> void:
	if transport.relevance_events:
		return  # goldnet delivers PVS relevance through its snapshot; this reliable RPC is stock-only
	# Collect movers once (peer-independent) rather than probing every synced entity per-peer.
	var movers: Array[int] = []
	for id in _synced_entities:
		var node = _synced_entities[id]
		if node and is_instance_valid(node) and node.get(_MOVER_NET_PROP):
			movers.append(id)
	for peer_id in multiplayer.get_peers():
		if not is_peer_map_ready(peer_id):
			continue
		var cur := {}
		for id in movers:
			if VisibilitySystem.is_entity_visible_to_peer(id, peer_id):
				cur[id] = true
		# First pass seeds prev to the FULL mover set: EntityBase._present defaults true on the client,
		# so diffing against "all present" makes the first pass emit an explicit leave for everything
		# out of PVS. (Only computed on the first pass; a .get() default would rebuild it every tick.)
		var prev: Dictionary = _peer_relevant[peer_id] if _peer_relevant.has(peer_id) else _all_present(movers)
		# Batch the crossings into one reliable RPC. Enters carry a baseline transform; leaves are id-only.
		var enter_ids := PackedInt32Array()
		var enter_pos := PackedVector3Array()
		var enter_rot := PackedVector3Array()
		var enter_stamps := PackedInt32Array()
		var leave_ids := PackedInt32Array()
		for id in cur:
			if not prev.has(id):
				var node = _synced_entities.get(id)
				var tn: Node3D = _resolve_transform_node(node) if node else null
				var pub = node.get(_MOVER_NET_PROP) if node else null
				enter_ids.append(id)
				if tn:
					enter_pos.append(tn.global_position)
					enter_rot.append(tn.global_rotation)
					enter_stamps.append(pub.mover_net_stamp if pub else Time.get_ticks_msec())
				else:
					enter_pos.append(Vector3.ZERO)
					enter_rot.append(Vector3.ZERO)
					enter_stamps.append(0)
		for id in prev:
			if not cur.has(id):
				leave_ids.append(id)
		if enter_ids.size() > 0 or leave_ids.size() > 0:
			sync_entity_relevance.rpc_id(peer_id, enter_ids, enter_pos, enter_rot, enter_stamps, leave_ids)
		_peer_relevant[peer_id] = cur


## First-pass baseline: every mover present, so the initial diff emits an explicit leave for
## everything the peer can't see (client defaults to present).
func _all_present(movers: Array[int]) -> Dictionary:
	var d := {}
	for id in movers:
		d[id] = true
	return d


## Enters carry a baseline transform (pos/rot/stamp) so the client renders at the correct position
## the instant it becomes relevant. Single render authority (drives EntityBase._present); reliable so
## it can't drift.
@rpc("authority", "call_remote", "reliable")
func sync_entity_relevance(enter_ids: PackedInt32Array, enter_pos: PackedVector3Array,
		enter_rot: PackedVector3Array, enter_stamps: PackedInt32Array, leave_ids: PackedInt32Array) -> void:
	_apply_entity_relevance_local(enter_ids, enter_pos, enter_rot, enter_stamps, leave_ids)


func _apply_entity_relevance_local(enter_ids: PackedInt32Array, enter_pos: PackedVector3Array,
		enter_rot: PackedVector3Array, enter_stamps: PackedInt32Array, leave_ids: PackedInt32Array) -> void:
	for i in enter_ids.size():
		var node = _synced_entities.get(enter_ids[i])
		if not node or not is_instance_valid(node):
			# Safe to drop, unlike entity state: _present defaults true and the create is
			# itself PVS-gated, so an unknown id has nothing to stale — and the next
			# transform batch reseeds anything that did miss.
			continue
		# Seed the interp buffer with the reliable baseline BEFORE flipping present on, so the first
		# rendered frame is at the correct position (not one held stale from before it left our PVS).
		if enter_stamps[i] != 0:
			push_mover_snapshot(enter_ids[i], enter_stamps[i], enter_pos[i], enter_rot[i], Vector3.ZERO)
		if node.has_method("set_present_from_server"):
			node.set_present_from_server(true)
	for id in leave_ids:
		var node = _synced_entities.get(id)
		if node and is_instance_valid(node) and node.has_method("set_present_from_server"):
			node.set_present_from_server(false)


func _apply_entity_state_local(entity_id: int, state: Dictionary) -> void:
	var node = _synced_entities.get(entity_id)
	if not node or not is_instance_valid(node):
		_park_entity_state(entity_id, state)
		return
	if node.has_method("_apply_sync_state"):
		node._apply_sync_state(state)


## Hold state for an entity we don't have yet, newest value per key winning. Bounded because
## sync_entity_state is an unfiltered broadcast: entities that never enter this client's PVS park an
## entry nothing will ever drain, so eviction trades a possible dropped one-shot state for a hard cap.
func _park_entity_state(entity_id: int, state: Dictionary) -> void:
	if _pending_entity_state.has(entity_id):
		_pending_entity_state[entity_id].merge(state, true)
		return
	if _pending_entity_state.size() >= MAX_PENDING_ENTITY_STATE:
		for oldest in _pending_entity_state:  # insertion-ordered; first key is the oldest
			_pending_entity_state.erase(oldest)
			break
	_pending_entity_state[entity_id] = state.duplicate()


func _flush_pending_entity_state(entity_id: int) -> void:
	if not _pending_entity_state.has(entity_id):
		return
	var state: Dictionary = _pending_entity_state[entity_id]
	_pending_entity_state.erase(entity_id)
	_apply_entity_state_local(entity_id, state)  # re-parks if the node died in between


# --- Chat RPCs ---

@rpc("any_peer", "call_remote", "reliable")
func request_chat(message: String, team_only: bool) -> void:
	if not is_host():
		return
	ServerRequests.chat(multiplayer.get_remote_sender_id(), message, team_only)


## call_local: the listen host is the sender, and a call_remote broadcast skips the sending
## process, so its own line never reached its own chat log. sync_hud_text is the same shape.
@rpc("authority", "call_local", "reliable")
func sync_chat(sender_peer: int, message: String, team_only: bool) -> void:
	if not Game.hud:
		return
	var sender_name := display_name(sender_peer)
	var sender_player := get_player(sender_peer)
	var sender_team: int = sender_player.team if sender_player else GameConsts.Team.NONE
	var tc: Color = GameConsts.TEAM_COLORS.get(sender_team, Color.WHITE)
	Game.hud.add_chat_message(sender_name, message, team_only, tc)


# --- Voice chat RPCs ---

## Voice rides the unreliable channel on purpose: a lost frame is a click in a word, not
## retransmit pressure on the stream goldnet exists to keep clear. `kind` is VoiceChat.Kind — one
## Opus frame, or the JSON marker that opens or closes a stream — carried on the wire so a
## receiver never has to guess which it holds. VoiceChat owns the audio and the channel latch;
## ServerRequests.voice owns who hears it.
func send_voice_packet(kind: int, packet: PackedByteArray, team_only: bool) -> void:
	if is_host():
		ServerRequests.voice(multiplayer.get_unique_id(), kind, packet, team_only)
	else:
		request_voice.rpc_id(1, kind, packet, team_only)


## Voice is on channel 1, off goldnet's netchan, so it doesn't compete with the snapshot for the
## packet budget.
@rpc("any_peer", "call_remote", "unreliable", 1)
func request_voice(kind: int, packet: PackedByteArray, team_only: bool) -> void:
	if not is_host():
		return
	ServerRequests.voice(multiplayer.get_remote_sender_id(), kind, packet, team_only)


## Not call_local, and never broadcast: ServerRequests.voice sends one rpc_id per listener and
## hands a listen host its copy by calling VoiceChat directly, so the question of what an rpc_id
## to your own peer does never comes up (see test_chat_echo.gd for the version of that question
## chat had to answer).
@rpc("authority", "call_remote", "unreliable", 1)
func sync_voice(sender_peer: int, kind: int, packet: PackedByteArray) -> void:
	VoiceChat.receive(sender_peer, kind, packet)


# --- Admin command RPCs ---

func send_request_command(text: String) -> void:
	if is_host():
		CommandSystem.dispatch(multiplayer.get_unique_id(), text)
	else:
		request_command.rpc_id(1, text)


@rpc("any_peer", "call_remote", "reliable")
func request_command(text: String) -> void:
	if not is_host():
		return
	CommandSystem.dispatch(multiplayer.get_remote_sender_id(), text.left(256))


## Routes the geometry to the shooter's client, which draws it (see RewindGhosts).
func send_debug_rewind_ghosts(attacker_peer: int, origins: PackedVector3Array,
		xforms: PackedVector3Array, sizes: PackedVector3Array, groups: PackedInt32Array) -> void:
	if attacker_peer <= 0:
		return  # bots hold negative ids and have no client to draw on
	if attacker_peer == multiplayer.get_unique_id():
		RewindGhosts.spawn(get_tree().get_root(), origins, xforms, sizes, groups)
	else:
		sync_debug_rewind_ghosts.rpc_id(attacker_peer, origins, xforms, sizes, groups)


@rpc("authority", "call_remote", "unreliable")
func sync_debug_rewind_ghosts(origins: PackedVector3Array, xforms: PackedVector3Array,
		sizes: PackedVector3Array, groups: PackedInt32Array) -> void:
	RewindGhosts.spawn(get_tree().get_root(), origins, xforms, sizes, groups)


@rpc("authority", "call_remote", "reliable")
func sync_command_reply(message: String, color_r: float, color_g: float, color_b: float) -> void:
	if not Game.hud:
		return
	Game.hud.add_chat_message("Server", message, false, Color(color_r, color_g, color_b))


@rpc("authority", "call_remote", "reliable")
func sync_noclip(enabled: bool) -> void:
	if Game.local_player:
		Game.local_player.noclip = enabled


@rpc("authority", "call_remote", "reliable")
func sync_server_var(key: String, value: Variant) -> void:
	ServerVars.apply_remote(key, value)


const HUD_CENTER := -1

@rpc("authority", "call_local", "reliable")
func sync_hud_text(message: String, channel: int, color_r: float, color_g: float, color_b: float,
		holdtime: float, sound: bool = true, x: float = -1.0, y: float = -1.0,
		fadein: float = 0.0, fadeout: float = 0.0, effect: int = 0) -> void:
	if not Game.hud:
		return
	if channel == HUD_CENTER:
		Game.hud.show_center_message(message, Color(color_r, color_g, color_b), holdtime, sound)
	else:
		Game.hud.show_message(message, channel, x, y,
			Color(color_r, color_g, color_b), fadein, fadeout, holdtime, effect)


## flags bit 0: left_handed (dominant casting hand is left).
@rpc("any_peer", "call_remote", "unreliable_ordered")
func report_vr_hands(right_pos: Vector3, left_pos: Vector3, flags: int) -> void:
	if multiplayer.is_server():
		_vr_hand_positions[multiplayer.get_remote_sender_id()] = {"right": right_pos, "left": left_pos, "flags": flags}


## flags per player: bit 0 = left_handed.
@rpc("authority", "call_remote", "unreliable")
func sync_vr_hand_states(peer_ids: PackedInt32Array, right_positions: PackedVector3Array, left_positions: PackedVector3Array, hand_flags: PackedByteArray) -> void:
	_dispatch_to_scene(&"_on_sync_vr_hand_states", [peer_ids, right_positions, left_positions, hand_flags])


## action: 0=grab (carrier_peer_id), 1=drop (pos), 2=return, 3=remove, 4=restore
@rpc("authority", "call_remote", "reliable")
func sync_goal_item(goal_no: int, action: int, carrier_peer_id: int, pos: Vector3) -> void:
	Log.info("[NetworkManager] sync_goal_item RPC received: goal=%d action=%d peer=%d" % [goal_no, action, carrier_peer_id])
	var item = GoalSystem.get_goal(goal_no)
	if not item or not item.has_method("_local_sync"):
		Log.info("[NetworkManager] sync_goal_item: goal %d not found or no _local_sync" % goal_no)
		return
	item._local_sync(action, carrier_peer_id, pos)
