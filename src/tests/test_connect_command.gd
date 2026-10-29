extends "res://src/tests/test_base.gd"
## /connect switches servers from the chat line. The command's own job is only resolving which
## address to use — the disconnect-then-join behind it is main's, on the lobby's join path — so
## what is worth pinning here is that an address reaches main intact and that a /connect with
## nothing to go back to connects to nothing at all.
##
## Reads the ClientCommandSystem and NetworkManager autoloads, so it runs via the scene runner.

# Stands in for Main: _cmd_connect reaches it through get_tree().current_scene.
class StubMain:
	extends Node
	var connected_to := ""
	var calls := 0

	func connect_to_server(ip: String) -> void:
		connected_to = ip
		calls += 1


var _saved_scene: Node
var _saved_address := ""
var _main: StubMain


func _setup_test(test_name: String) -> void:
	super._setup_test(test_name)
	var tree := Engine.get_main_loop() as SceneTree
	_saved_scene = tree.current_scene
	_saved_address = NetworkManager.last_join_address
	_main = StubMain.new()
	_root().add_child(_main)
	_keep(_main)
	tree.current_scene = _main
	NetworkManager.last_join_address = ""


func _teardown_test() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	tree.current_scene = _saved_scene
	NetworkManager.last_join_address = _saved_address
	super._teardown_test()


func test_an_address_is_handed_to_main() -> void:
	assert_true(ClientCommandSystem.dispatch("/connect game.example.com"),
		"/connect is not registered")
	assert_eq(_main.connected_to, "game.example.com", "the address did not reach main")


func test_padding_is_trimmed_off_the_address() -> void:
	ClientCommandSystem.dispatch("/connect   10.0.0.5  ")
	assert_eq(_main.connected_to, "10.0.0.5", "the address was passed on with its padding")


func test_no_argument_goes_back_to_the_last_server() -> void:
	NetworkManager.last_join_address = "game.example.com"
	ClientCommandSystem.dispatch("/connect")
	assert_eq(_main.connected_to, "game.example.com",
		"/connect did not return to the address join() last took")


## Nothing to go back to — a first session that has only ever hosted. Refuse, rather than hand
## main an empty address and take the player's map down for a connection that cannot happen.
func test_no_argument_and_no_history_connects_to_nothing() -> void:
	ClientCommandSystem.dispatch("/connect")
	assert_eq(_main.calls, 0, "/connect with no address anywhere still tried to connect")
