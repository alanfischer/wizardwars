extends "res://src/tests/test_base.gd"
## ClientJoin owns the class menu: it builds it for each map, frees it on unload, and is the only
## thing that opens it.

const ClientJoinScript := preload("res://src/systems/client_join.gd")

var _join: Node
var _saved_player: LocalPlayer


func _setup_test(_test_name: String) -> void:
	_saved_player = Game.local_player
	Game.local_player = null
	_join = _keep(ClientJoinScript.new())
	_root().add_child(_join)


func _teardown_test() -> void:
	Game.local_player = _saved_player
	super._teardown_test()


func test_a_built_menu_answers_into_the_join() -> void:
	var menu: TeamSelectUI = _keep(_join.build_menu())
	assert_true(menu.selection_made.is_connected(_join.select_team_class), "a pick becomes a join")
	assert_eq(String(menu.name), "TeamSelectUI", "named as main's child always was")


func test_a_rebuild_frees_the_old_menu() -> void:
	var first: TeamSelectUI = _join.build_menu()
	_root().add_child(first)
	_keep(_join.build_menu())
	assert_true(first.is_queued_for_deletion(), "one menu at a time")


func test_teardown_forgets_the_menu() -> void:
	var menu: TeamSelectUI = _join.build_menu()
	_root().add_child(menu)
	_join.teardown_menu()
	assert_true(menu.is_queued_for_deletion(), "freed with the map")
	assert_false(_join.open_team_menu(), "and nothing left to open")


func test_menus_open_only_when_there_is_one_to_open() -> void:
	assert_false(_join.open_team_menu(), "no map, no menu")
	var menu: TeamSelectUI = _keep(_join.build_menu())
	_root().add_child(menu)
	assert_true(_join.open_team_menu(), "the team menu opens")
	assert_true(menu.visible, "and shows")
	assert_false(_join.open_class_menu(), "no player, so no team to pick a class on")


func test_no_player_means_no_menu_on_start() -> void:
	var menu: TeamSelectUI = _keep(_join.build_menu())
	_root().add_child(menu)
	_join.set_auto_team(2)
	assert_false(_join.start_game(), "nothing to join or show without a local player")
	assert_false(menu.visible, "the menu stays down")
