extends "res://src/tests/test_base.gd"
## /kick names a player by name, and names are neither unique nor free of spaces — so the
## resolver is the part worth pinning down. Kicking the wrong person because two names share a
## prefix is exactly the failure an admin can't undo.
##
## References the CommandSystem / NetworkManager autoloads, so it must run via the scene runner.

var _saved_peers: Dictionary


func _setup_test(_test_name: String) -> void:
	_saved_peers = NetworkManager.swap_peer_table()


func _teardown_test() -> void:
	NetworkManager.swap_peer_table(_saved_peers)


func _roster(names: Dictionary) -> void:
	NetworkManager.swap_peer_table()  # drop whatever the previous call in this test left
	for peer_id: int in names:
		NetworkManager.set_player_name(peer_id, str(names[peer_id]))


func test_matches_a_name_however_it_is_typed() -> void:
	_roster({2: "Alan", 3: "Ben"})
	assert_eq(CommandSystem.resolve_player("Alan")["id"], 2, "the name as it is written")
	assert_eq(CommandSystem.resolve_player("alan")["id"], 2, "case doesn't matter")
	assert_eq(CommandSystem.resolve_player("  Alan  ")["id"], 2, "nor does stray whitespace")
	assert_eq(CommandSystem.resolve_player("la")["id"], 2, "a substring is enough when it's unique")


func test_a_whole_name_beats_a_substring() -> void:
	# Typing a name in full has to kick that player, even when it is also inside somebody else's.
	_roster({2: "Al", 3: "Alan"})
	assert_eq(CommandSystem.resolve_player("Al")["id"], 2, "exact match wins over 'Alan' containing it")


func test_an_ambiguous_name_kicks_nobody() -> void:
	# "an" is inside both names and is neither of them, so there is no-one it plainly means.
	_roster({2: "Alan", 3: "Alanna"})
	var found := CommandSystem.resolve_player("an")
	assert_eq(found["id"], 0, "two matches, so no kick")
	assert_true(str(found["error"]).contains("#2"), "the error names the ids to choose between")
	assert_true(str(found["error"]).contains("#3"), "both of them")


func test_two_players_with_the_same_name_are_ambiguous() -> void:
	# Names aren't unique — an impostor picking a rival's name must not make the rival kickable.
	_roster({2: "Alan", 3: "Alan"})
	assert_eq(CommandSystem.resolve_player("Alan")["id"], 0, "identical names resolve to nobody")


func test_an_id_names_one_player_exactly() -> void:
	_roster({2: "Alan", 3: "Alanna", -1: "BOT fire"})
	assert_eq(CommandSystem.resolve_player("#3")["id"], 3, "the id form escapes an ambiguous name")
	assert_eq(CommandSystem.resolve_player("#-1")["id"], -1, "bots hold negative ids")
	assert_eq(CommandSystem.resolve_player("#9")["id"], 0, "an id nobody holds")
	assert_eq(CommandSystem.resolve_player("#nan")["id"], 0, "and one that isn't a number")


func test_nobody_matches_nothing() -> void:
	_roster({2: "Alan"})
	assert_eq(CommandSystem.resolve_player("Ben")["id"], 0, "a name nobody has")
	assert_eq(CommandSystem.resolve_player("")["id"], 0, "an empty query matches nobody, not everybody")


func test_the_reason_is_split_off_the_name() -> void:
	assert_eq(CommandSystem._split_target("Alan"), ["Alan", ""], "a bare name, no reason")
	assert_eq(CommandSystem._split_target("Alan spawn camping"), ["Alan", "spawn camping"],
		"the rest of the line is the reason")
	assert_eq(CommandSystem._split_target("\"Big Al\" idle"), ["Big Al", "idle"],
		"quotes hold a name with a space in it together")
	assert_eq(CommandSystem._split_target("\"Big Al\""), ["Big Al", ""], "quoted, with no reason")
	assert_eq(CommandSystem._split_target(""), ["", ""], "nothing at all")
