extends "res://src/tests/test_base.gd"
## The ServerVars change signal that reactive tunables hang off. `bsp_hulls` reconfigures physics
## collision shapes that PREDICTION runs against, so a client that misses a change mispredicts —
## the signal has to fire on the replicated path (`apply_remote`), not just the local one.
##
## References the ServerVars autoload, so it must run via the scene runner, not `-s`.

var _events: Array = []
var _saved: Dictionary = {}


func _setup_test(_test_name: String) -> void:
	_events.clear()
	# Snapshot every var we touch, so a failing test can't leak into the next one
	# (or into the rest of the suite — these are autoload globals).
	_saved = {}
	for k in ["bsp_hulls", "golem_interp"]:
		_saved[k] = ServerVars.get_value(k)
	ServerVars.value_changed.connect(_on_changed)


func _teardown_test() -> void:
	ServerVars.value_changed.disconnect(_on_changed)
	for k in _saved:
		ServerVars.apply_remote(k, _saved[k])


func _on_changed(key: String, value: Variant) -> void:
	_events.append([key, value])


func test_bsp_hulls_is_registered_and_replicated() -> void:
	assert_true(ServerVars.has_key("bsp_hulls"), "bsp_hulls not registered")
	# Must be in the join snapshot, or a client that connects mid-match keeps its
	# own default and collides against different geometry than the host.
	assert_true(ServerVars.snapshot().has("bsp_hulls"), "bsp_hulls missing from join snapshot")


func test_local_set_emits_change() -> void:
	ServerVars.set_from_string("bsp_hulls", "off")
	assert_eq(_events.size(), 1, "expected exactly one change event")
	assert_eq(_events[0][0], "bsp_hulls", "wrong key in change event")
	assert_eq(_events[0][1], false, "wrong value in change event")
	assert_eq(ServerVars.get_value("bsp_hulls"), false, "value not stored")


func test_remote_apply_emits_change() -> void:
	# The client path: the host's value arrives via NetworkManager.sync_server_var.
	# This is the one that must not be forgotten — it is how a joining client learns
	# the host is running hulls off.
	ServerVars.apply_remote("bsp_hulls", false)
	assert_eq(_events.size(), 1, "replicated apply did not emit a change")
	assert_eq(_events[0][1], false, "wrong replicated value")
	assert_eq(ServerVars.get_value("bsp_hulls"), false, "replicated value not stored")


func test_unparseable_value_emits_nothing() -> void:
	var before = ServerVars.get_value("bsp_hulls")
	var result: Dictionary = ServerVars.set_from_string("bsp_hulls", "banana")
	assert_false(result["ok"], "'banana' should not parse as a bool")
	assert_eq(_events.size(), 0, "a rejected set must not emit a change")
	assert_eq(ServerVars.get_value("bsp_hulls"), before, "a rejected set must not change the value")


func test_unknown_key_emits_nothing() -> void:
	ServerVars.apply_remote("no_such_var", 1)
	assert_eq(_events.size(), 0, "an unknown key must not emit a change")
