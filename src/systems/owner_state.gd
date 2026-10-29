class_name OwnerState
extends Node

## A player's own movement state, replicated to that player alone: the server's answer to its
## prediction (LocalPlayer._reconcile_server_state). GoldSrc's clientdata_t. It rides the snapshot
## like any entity, so it is delta-encoded against what the client acked and follows the client's
## granted update rate. Lives under NetworkManager, at the same path on the server and its client.

const FLAG_CROUCHED := 1
const FLAG_ON_FLOOR := 2
const FLAG_JUMPING := 4
const FLAG_JUMP_HELD := 8

## On GoldSrc clientdata_t's grids: origin to 1/128 unit, well under the client's 5 mm correction
## threshold, and velocity to 1/8 unit/s. Each axis travels as its step from the client's baseline.
const SPEC := {
	".:seq": {"push": true},
	".:pos": {"grid": GameConsts.SCALE_FACTOR / 128.0, "push": true},
	".:vel": {"grid": GameConsts.SCALE_FACTOR / 8.0, "push": true},
	".:flags": {"push": true},
	".:queue_depth": {"push": true},
}
## Ahead of everything else in an overflowing packet: a late correction is a rubber-band.
const PRIORITY := 100.0

var seq := -1  ## the last input command the server processed; -1 = none yet
var pos := Vector3.ZERO
var vel := Vector3.ZERO
var flags := 0
var queue_depth := 0  ## the server's input queue for this player, for the net graph

var sync: MultiplayerSynchronizer


static func node_name(peer_id: int) -> String:
	return "OwnerState_%d" % peer_id


## Hidden from everyone until show_to_owner(): a snapshot the client can't apply yet would still be
## acked, and a field that rarely changes (on_floor) would then never be sent again.
static func create(peer_id: int) -> OwnerState:
	var node := OwnerState.new()
	node.name = node_name(peer_id)
	node.sync = SyncSpec.build("Sync", SPEC, {"priority": PRIORITY})
	node.sync.public_visibility = false
	node.add_child(node.sync)
	return node


func show_to_owner(peer_id: int) -> void:
	sync.set_visibility_for(peer_id, true)


func write(p_seq: int, p_pos: Vector3, p_vel: Vector3, crouched: bool, on_floor: bool,
		jumping: bool, jump_held: bool, p_queue_depth: int) -> void:
	seq = p_seq
	pos = p_pos
	vel = p_vel
	flags = ((FLAG_CROUCHED if crouched else 0) | (FLAG_ON_FLOOR if on_floor else 0)
			| (FLAG_JUMPING if jumping else 0) | (FLAG_JUMP_HELD if jump_held else 0))
	queue_depth = p_queue_depth
	NetworkManager.mark_entity_dirty(self)
