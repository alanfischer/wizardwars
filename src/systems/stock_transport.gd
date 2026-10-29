class_name StockTransport
extends RefCounted

## What WW asks of its network transport; stock SceneMultiplayer answers no to all of it.
## GoldnetTransport is the other answer, resolved once at install.

var is_goldnet := false        ## the identity question: handshake, sim commands, clock and cadence gates
var relevance_events := false  ## also the test seam; false = relevance needs the game-level RPC


func mark_dirty(_node: Node) -> void:
	pass


func set_snapshot_rate(_hz: float) -> void:
	pass


## Client: the most bytes per second the server may send us (GoldSrc rate), or let goldnet pick it.
func set_rate(_bytes_per_sec: int, _auto: bool) -> void:
	pass


## Client: the snapshots per second we ask to be served at (GoldSrc cl_updaterate); 0 = all of them.
## Stock serves everyone at the server's rate.
func set_update_rate(_hz: int) -> void:
	pass


func send_snapshots() -> void:
	pass


## Input packets per second (GoldSrc cl_cmdrate); 0 = one per command. Stock sends each command
## RPC as it's made.
func set_command_rate(_hz: float, _auto: bool) -> void:
	pass


## The link's measures (goldnet's get_peer_stats; a client passes 1); empty without goldnet.
func link_stats(_peer := 1) -> Dictionary:
	return {}


## goldnet's wire version; 0 = no goldnet.
func protocol_version() -> int:
	return 0
