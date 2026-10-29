extends "res://src/tests/test_base.gd"
## The one rule that makes the sync wire safe to read: a client-side handler is "_on_" + the RPC's
## own name. Senders no longer carry the handler name at all (NetworkManager._handler_for derives
## it), but each @rpc stub still writes its own in its _dispatch_to_scene call, and those two halves
## can drift.
##
## They did, within an hour of the derivation landing: renaming reject_team_join's handler updated
## main.gd and missed the stub, so a client's join refusal dispatched to a method that no longer
## existed — and _dispatch_to_scene checks has_method first, so it failed in total silence. That is
## the whole failure class this file exists to make loud.
##
## Source-scanning rather than behavioural on purpose: the bug is a name that nothing answers, which
## by definition produces no call to observe. Only reading the text can see it.

const NM_PATH := "res://src/systems/network_manager.gd"
## Where handlers may live: client_sync owns the sync events, main still owns join/spawn/teleport.
const HANDLER_SOURCES: Array[String] = [
	"res://src/systems/client_sync.gd",
	"res://src/main.gd",
]


func _lines(path: String) -> PackedStringArray:
	var f := FileAccess.open(path, FileAccess.READ)
	assert_true(f != null, "could read %s" % path)
	return (f.get_as_text() if f else "").split("\n")


## Every `func _on_x` across the files allowed to answer, inner classes included (hence strip()).
func _declared_handlers() -> Dictionary:
	var out := {}
	for src in HANDLER_SOURCES:
		for raw in _lines(src):
			var l := raw.strip_edges()
			if l.begins_with("func _on_"):
				out[l.substr(5).split("(")[0]] = src
	return out


## Each @rpc stub whose body is a single _dispatch_to_scene call, as {rpc_name: handler_named}.
func _passthrough_stubs() -> Dictionary:
	var out := {}
	var lines := _lines(NM_PATH)
	for i in lines.size():
		if not lines[i].begins_with("@rpc"):
			continue
		if i + 1 >= lines.size() or not lines[i + 1].begins_with("func "):
			continue
		var rpc_name := lines[i + 1].substr(5).split("(")[0]
		var j := i + 2
		while j < lines.size() and (lines[j].begins_with("\t") or lines[j].is_empty()):
			var marker := '_dispatch_to_scene(&"'
			if lines[j].contains(marker):
				out[rpc_name] = lines[j].split(marker)[1].split('"')[0]
				break
			j += 1
	return out


func test_every_stub_dispatches_to_its_own_derived_name() -> void:
	var stubs := _passthrough_stubs()
	assert_gt(stubs.size(), 25, "found the stubs to check (guards the parser itself)")
	for rpc_name: String in stubs:
		assert_eq(stubs[rpc_name], "_on_" + rpc_name,
				"%s must dispatch to _on_%s, or senders deriving the name silently miss it"
						% [rpc_name, rpc_name])


func test_every_dispatched_handler_exists() -> void:
	var handlers := _declared_handlers()
	assert_gt(handlers.size(), 20, "found the handlers to check (guards the parser itself)")
	for rpc_name: String in _passthrough_stubs():
		var want := "_on_" + rpc_name
		assert_true(handlers.has(want),
				"%s dispatches to %s, which nothing implements — a silent no-op on every client"
						% [rpc_name, want])
