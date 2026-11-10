extends "res://src/tests/test_base.gd"
## ClientJoin owns the class menu: it builds it for each map, frees it on unload, and is the only
## thing that opens it. Offline it also applies the pick: a first pick spawns at once, a change
## waits out a death.

const ClientJoinScript := preload("res://src/systems/client_join.gd")
const LocalPlayerScene := preload("res://src/local_player.tscn")


class FakeSpawn extends Node3D:
	var team_no := 0
	var goal_no := 0
	var group_no := 0
	var items := 0

	func get_spawn_position() -> Vector3:
		return position


var _join: Node
var _saved_player: LocalPlayer
var _spawns: Array[Node3D] = []
var _scene_children: Array[Node] = []


func _setup_test(_test_name: String) -> void:
	_saved_player = Game.local_player
	Game.local_player = null
	_join = _keep(ClientJoinScript.new())
	_root().add_child(_join)
	_scene_children = _tree().current_scene.get_children()


func _teardown_test() -> void:
	Game.local_player = _saved_player
	for sp in _spawns:
		SpawnSystem.unregister(sp)
	_spawns.clear()
	for n in _tree().current_scene.get_children():
		if not n in _scene_children:
			n.free()  # the class-change corpse
	super._teardown_test()


func _spawn_for(team: int, at: Vector3) -> FakeSpawn:
	var sp: FakeSpawn = _keep(FakeSpawn.new())
	sp.team_no = team
	sp.position = at
	_root().add_child(sp)
	SpawnSystem.register(sp, 0, 0)
	_spawns.append(sp)
	return sp


func _local_player() -> LocalPlayer:
	var lp: LocalPlayer = _keep(LocalPlayerScene.instantiate())
	_root().add_child(lp)
	await _physics_tick()
	lp.set_physics_process(false)
	lp.set_process(false)
	lp.set_spectating(true)  # as main leaves it on map load: no team picked yet
	Game.local_player = lp
	return lp


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


func test_a_first_pick_spawns_at_once() -> void:
	var lp := await _local_player()
	_spawn_for(1, Vector3(5, 0, 0))
	assert_true(lp.spectating, "precondition: never spawned")
	_join.select_team_class(1, GameConsts.Element.ICE)
	assert_eq(lp.team, 1, "on the team")
	assert_eq(lp.element, GameConsts.Element.ICE, "as the class")
	assert_false(lp.spectating, "in the world")
	assert_false(lp.is_dead, "alive")
	assert_almost_eq(lp.global_position.x, 5.0, 0.01, "at the spawn")


func test_a_first_pick_with_no_spawn_reopens_the_menu() -> void:
	var lp := await _local_player()
	var menu: TeamSelectUI = _keep(_join.build_menu())
	_root().add_child(menu)
	_join.select_team_class(3, GameConsts.Element.ICE)
	assert_true(lp.spectating, "still a spectator")
	assert_false(lp.is_dead, "and not dead: there was never a life to lose")
	assert_eq(lp.team, GameConsts.Team.NONE, "no team recorded")
	assert_true(menu.visible, "the menu is back up to pick again")


func test_a_class_change_waits_for_the_respawn() -> void:
	var lp := await _local_player()
	_spawn_for(1, Vector3.ZERO)
	_join.select_team_class(1, GameConsts.Element.FIRE)
	_join.select_team_class(1, GameConsts.Element.ICE)
	assert_true(lp.is_dead, "the change costs a life")
	assert_eq(lp.element, GameConsts.Element.FIRE, "not applied yet")
	assert_eq(lp.class_change_pending_element, GameConsts.Element.ICE, "queued for the respawn")
	assert_true(lp._respawn_timer.timeout.is_connected(lp._respawn), "the player's own respawn applies it")
	lp._respawn()
	assert_false(lp.is_dead, "respawned")
	assert_eq(lp.element, GameConsts.Element.ICE, "as the new class")
	assert_eq(lp.class_change_pending_team, -1, "nothing left queued")


func test_a_pick_while_dead_replaces_the_queued_one() -> void:
	var lp := await _local_player()
	_spawn_for(1, Vector3.ZERO)
	_spawn_for(2, Vector3.ZERO)
	_join.select_team_class(1, GameConsts.Element.FIRE)
	_join.select_team_class(2, GameConsts.Element.ICE)
	_join.select_team_class(1, GameConsts.Element.FIRE)
	assert_true(lp.is_dead, "still serving the first death")
	lp._respawn()
	assert_eq(lp.team, 1, "the last pick wins")
	assert_eq(lp.element, GameConsts.Element.FIRE, "back on the old class")


func _physics_tick() -> void:
	await _tree().physics_frame
	await _tree().physics_frame


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree
