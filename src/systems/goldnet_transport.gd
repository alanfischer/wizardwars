class_name GoldnetTransport
extends StockTransport

## goldnet's answers, wrapping the installed GoldNetMultiplayer. Never names it as a type —
## libgoldnet is optional, and an unresolved type would fail to parse instead of falling back.

var _mp: MultiplayerAPI


func _init(mp: MultiplayerAPI) -> void:
	_mp = mp
	is_goldnet = true
	relevance_events = true


## Every goldnet-specific wire in one place, so none can be left half-done. Call BEFORE
## set_multiplayer: a binary too old to answer one leaves the tree on stock.
static func install(mp: MultiplayerAPI) -> GoldnetTransport:
	mp.set_relevance_events(true)
	mp.set_manual_send(true)  # snapshots go out per server tick (NetworkManager.snapshot_due), not on a timer
	mp.entity_relevance_lost.connect(NetworkManager._on_entity_relevance_lost)
	mp.server_time_received.connect(NetworkManager._on_goldnet_server_time)
	mp.update_rate_granted.connect(NetworkManager._on_update_rate_granted)
	return GoldnetTransport.new(mp)


func mark_dirty(node: Node) -> void:
	_mp.mark_dirty(node)


func set_snapshot_rate(hz: float) -> void:
	_mp.snapshot_rate = hz


func send_snapshots() -> void:
	_mp.send_snapshots()


func set_rate(bytes_per_sec: int, auto: bool) -> void:
	_mp.rate = bytes_per_sec
	_mp.auto_rate = auto


func set_update_rate(hz: int) -> void:
	_mp.update_rate = hz


func set_command_rate(hz: float, auto: bool) -> void:
	_mp.command_rate = hz
	_mp.auto_command_rate = auto


func link_stats(peer := 1) -> Dictionary:
	return _mp.get_peer_stats(peer)


func protocol_version() -> int:
	return _mp.get_protocol_version()
