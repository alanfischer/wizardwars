extends "res://src/tests/test_base.gd"
## The per-peer records (NetworkManager._peers / PeerRecord) that replaced the four parallel
## player_names / player_teams / peer_pings / peer_queues dicts.
##
## Two things here are easy to break and invisible when broken. The first is membership: "on the
## roster" is a non-empty NAME, not a present key, because a ping can create a record before the
## peer has said who it is — and that distinction is the only thing separating a listen host's
## peer 1 (which registers a name) from a dedicated server's (which does not). The second is the
## diagnostic tables: ping and queue depth reach clients through one parameterized pair of helpers
## keyed by field NAME, so a typo in a StringName is a silent no-op rather than a parse error.
##
## References the NetworkManager autoload, so it must run via the scene runner.

var _saved_peers: Dictionary


func _setup_test(_test_name: String) -> void:
	_saved_peers = NetworkManager.swap_peer_table()


func _teardown_test() -> void:
	NetworkManager.swap_peer_table(_saved_peers)


# --- The record ------------------------------------------------------------

func test_a_peer_we_know_nothing_about_reads_as_unknown() -> void:
	assert_eq(NetworkManager.display_name(7), "Player 7", "an id is better than nothing")
	assert_false(NetworkManager.has_player_name(7), "but it is not a name")
	assert_eq(NetworkManager.get_player_team(7), GameConsts.Team.NONE, "on no team")
	assert_eq(NetworkManager.get_peer_ping(7), -1, "ping unknown")
	assert_eq(NetworkManager.get_peer_queue_depth(7), -1, "queue depth unknown")


func test_the_four_fields_are_one_record() -> void:
	NetworkManager.set_player_name(7, "Merlin")
	NetworkManager.set_player_team(7, GameConsts.Team.BLUE)
	NetworkManager.set_peer_ping(7, 42)
	assert_eq(NetworkManager.display_name(7), "Merlin", "the name reads back")
	assert_eq(NetworkManager.get_player_team(7), GameConsts.Team.BLUE, "and the team beside it")
	assert_eq(NetworkManager.get_peer_ping(7), 42, "and the ping")
	NetworkManager.drop_peer_state(7)
	assert_false(NetworkManager.has_player_name(7), "one erase takes the whole record")
	assert_eq(NetworkManager.get_player_team(7), GameConsts.Team.NONE, "")
	assert_eq(NetworkManager.get_peer_ping(7), -1, "")


# --- Membership is the name, not the key -----------------------------------

func test_a_ping_alone_does_not_put_a_peer_on_the_roster() -> void:
	# The ping table can land before sync_player_name does; that must not invent a scoreboard row.
	NetworkManager.set_peer_ping(7, 42)
	assert_eq(NetworkManager.get_peer_ping(7), 42, "the reading is kept")
	assert_false(NetworkManager.peer_names().has(7), "but the peer is not on the roster yet")
	NetworkManager.set_player_name(7, "Merlin")
	assert_true(NetworkManager.peer_names().has(7), "naming it is what puts it there")
	assert_eq(NetworkManager.get_peer_ping(7), 42, "and the early reading survived the wait")


func test_the_team_roster_counts_peers_the_name_roster_does_not() -> void:
	# GoalSystem's team counts must see a peer that holds a team but hasn't announced a name, or a
	# client at the team menu is offered a slot the host then refuses it from.
	NetworkManager.set_player_team(7, GameConsts.Team.RED)
	assert_false(NetworkManager.peer_names().has(7), "no name, so not on the name roster")
	assert_eq(NetworkManager.peer_teams().get(7), GameConsts.Team.RED, "but it holds the team")


# --- The diagnostic tables -------------------------------------------------

func test_a_table_carries_only_the_peers_the_server_has_measured() -> void:
	NetworkManager.set_player_name(7, "Merlin")  # named, but never measured
	NetworkManager.set_peer_ping(8, 42)
	var table := NetworkManager._peer_int_table(&"ping")
	assert_eq(table, {8: 42}, "an unmeasured peer is left off the wire, not sent as -1")


func test_applying_a_table_is_a_replace_not_a_merge() -> void:
	# The received table is the whole truth: a peer the server has stopped measuring has to go back
	# to unknown, or the scoreboard shows its last reading for the rest of the session.
	NetworkManager.set_peer_ping(7, 10)
	NetworkManager.set_peer_ping(8, 20)
	NetworkManager._apply_peer_int_table(&"ping", {8: 25})
	assert_eq(NetworkManager.get_peer_ping(8), 25, "the peer on the table updates")
	assert_eq(NetworkManager.get_peer_ping(7), -1, "the one left off goes back to unknown")


func test_both_diagnostics_round_trip_through_their_own_field() -> void:
	# One parameterized pair of helpers serves both numbers, so the field names have to be the
	# thing keeping them apart — a ping must never land in the queue column.
	NetworkManager.set_peer_ping(7, 42)
	NetworkManager._apply_peer_int_table(&"queue_depth", {7: 3})
	assert_eq(NetworkManager.get_peer_queue_depth(7), 3, "the queue depth applied")
	assert_eq(NetworkManager.get_peer_ping(7), 42, "and left the ping alone")
	assert_eq(NetworkManager._peer_int_table(&"queue_depth"), {7: 3}, "queue depth builds its own table")
	assert_eq(NetworkManager._peer_int_table(&"ping"), {7: 42}, "and ping its own")


func test_a_table_for_an_unknown_peer_creates_its_record() -> void:
	# Same reason set_peer_ping creates one: the tables are unreliable and unordered against the
	# name RPCs, so dropping a reading for a not-yet-named peer would strand it until the next send.
	NetworkManager._apply_peer_int_table(&"ping", {9: 15})
	assert_eq(NetworkManager.get_peer_ping(9), 15, "the reading is kept against the new record")
	assert_false(NetworkManager.peer_names().has(9), "without putting the peer on the roster")
