extends "res://src/tests/test_base.gd"
## The transport is resolved once at install and never swaps, so what is worth pinning is the two
## implementations. Stock has to be INERT rather than an error: mark_dirty runs per entity per tick
## on every session without goldnet. The goldnet side is testable because the facade takes any
## MultiplayerAPI, so a fake satisfies it.


## Stands in for GoldNetMultiplayer: the members install() and the forwarders touch.
class RecordingAPI:
	extends MultiplayerAPIExtension
	signal entity_relevance_lost(sync: Object)
	signal server_time_received(server_time_ms: int)
	signal update_rate_granted(rate: int)
	var relevance_armed := false
	var dirtied: Array[Node] = []
	var snapshot_rate := 0.0
	var update_rate := 0
	var rate := 0
	var auto_rate := false
	var command_rate := 0.0
	var auto_command_rate := false
	var manual := false
	var sends := 0
	func set_relevance_events(on: bool) -> void:
		relevance_armed = on
	func mark_dirty(node: Node) -> void:
		dirtied.append(node)
	func get_peer_stats(peer: int) -> Dictionary:
		return {"peer": peer}
	func get_protocol_version() -> int:
		return 8
	func set_manual_send(on: bool) -> void:
		manual = on
	func send_snapshots() -> void:
		sends += 1


func test_stock_answers_no_and_no_ops() -> void:
	var t := StockTransport.new()
	assert_false(t.is_goldnet, "stock is not goldnet")
	assert_false(t.relevance_events, "so PVS relevance falls to the game-level RPC")
	var n := _keep(Node.new())
	_root().add_child(n)
	t.mark_dirty(n)  # must not error — this runs per entity per tick on every stock session
	t.set_snapshot_rate(30.0)
	t.set_update_rate(20)
	t.set_rate(5000, false)
	t.set_command_rate(30.0, true)
	t.send_snapshots()
	assert_eq(t.link_stats(), {}, "no link measures without goldnet")
	assert_eq(t.protocol_version(), 0, "and no wire version for the join handshake")


func test_goldnet_reports_what_it_is() -> void:
	var t := GoldnetTransport.new(RecordingAPI.new())
	assert_true(t.is_goldnet, "for the join handshake and the sim commands")
	assert_true(t.relevance_events, "relevance rides the snapshot")


## One call has to arm relevance AND wire both signals, or the transport installs half-configured.
func test_install_wires_every_goldnet_specific_member() -> void:
	var api := RecordingAPI.new()
	var t := GoldnetTransport.install(api)
	assert_true(api.relevance_armed, "install armed relevance events")
	assert_true(t.relevance_events, "and the flag agrees with what was armed")
	assert_true(api.entity_relevance_lost.is_connected(NetworkManager._on_entity_relevance_lost),
			"PVS leave markers reach NetworkManager")
	assert_true(api.server_time_received.is_connected(NetworkManager._on_goldnet_server_time),
			"and so does the server clock")
	assert_true(api.update_rate_granted.is_connected(NetworkManager._on_update_rate_granted),
			"and the update rate the server grants, for the jitter buffer")
	assert_true(api.manual, "snapshots go out per server tick, not on goldnet's timer")


func test_goldnet_forwards_every_member() -> void:
	var api := RecordingAPI.new()
	var t := GoldnetTransport.new(api)
	var n := _keep(Node.new())
	_root().add_child(n)
	t.mark_dirty(n)
	assert_eq(api.dirtied, [n] as Array[Node], "mark_dirty reached the transport with its node")
	t.set_snapshot_rate(30.0)
	assert_eq(api.snapshot_rate, 30.0, "the server's snapshot rate")
	t.set_update_rate(20)
	assert_eq(api.update_rate, 20, "the client's update rate")
	t.set_rate(5000, false)
	assert_eq([api.rate, api.auto_rate], [5000, false], "the client's rate, and whether goldnet picks it")
	t.set_command_rate(0.0, true)
	assert_eq([api.command_rate, api.auto_command_rate], [0.0, true], "and the same for its command rate")
	assert_eq(t.link_stats(), {"peer": 1}, "the link's measures, as this client sees them")
	assert_eq(t.link_stats(7), {"peer": 7}, "or as the server sees a peer's")
	assert_eq(t.protocol_version(), 8, "the wire version, for the join handshake")
	t.send_snapshots()
	assert_eq(api.sends, 1, "a send per call")


## relevance_events is a plain field, so a stock transport with it flipped exercises the relevance
## path with no production hook — and mark_dirty stays the no-op, so the flip cannot crash a caller.
func test_relevance_path_is_reachable_without_goldnet() -> void:
	var t := StockTransport.new()
	t.relevance_events = true
	assert_false(t.is_goldnet, "without claiming the transport changed")
	var n := _keep(Node.new())
	_root().add_child(n)
	t.mark_dirty(n)
