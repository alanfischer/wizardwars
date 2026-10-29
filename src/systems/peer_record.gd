class_name PeerRecord
extends RefCounted

## Everything keyed by peer id that is NOT the peer's body.
##
## The body lives in NetworkManager's registry (see player_table) and comes and goes — PVS culls it
## on clients, a despawn frees it, a map change replaces it. This is the state beside it that
## outlives all three.

## Chosen name, clamped to 24 chars by ServerRequests.set_player_name. Empty means the peer is
## connected but hasn't announced who it is — which is also the roster's membership test
## (see NetworkManager.peer_names): the scoreboard lists identities, not sockets.
var player_name := ""

## PVS-independent roster team. The authoritative team also lives on the puppet body, which is
## fresher (it carries a pending class change); this is what answers for a peer whose body isn't
## replicated here — a bot outside the local PVS, anyone inside the map-reload window.
var team: int = GameConsts.Team.NONE

var ping := -1  ## RTT in ms as the server measured it, -1 = not yet known
var queue_depth := -1  ## server-side input queue size, -1 = not yet known
