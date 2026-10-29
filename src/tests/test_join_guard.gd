extends "res://src/tests/test_base.gd"
## A second join while one is open or still opening is refused, not stacked: stacking connected
## every signal twice and abandoned the first peer mid-handshake (--connect plus a Join click on a
## slow link). Once disconnected, joining works again.


func _teardown_test() -> void:
	NetworkManager.disconnect_from_game()
	super()


func test_a_second_join_is_refused_while_the_first_is_opening() -> void:
	assert_eq(NetworkManager.join("127.0.0.1"), OK, "the first join starts")
	assert_eq(NetworkManager.join("127.0.0.1"), ERR_ALREADY_IN_USE, "a second one is refused")
	assert_true(NetworkManager.multiplayer.connected_to_server.is_connected(NetworkManager._on_connected_to_server),
			"the first join's handlers are still wired")


func test_joining_again_after_disconnecting_works() -> void:
	NetworkManager.join("127.0.0.1")
	NetworkManager.disconnect_from_game()
	assert_eq(NetworkManager.join("127.0.0.1"), OK, "a fresh join after a disconnect")
