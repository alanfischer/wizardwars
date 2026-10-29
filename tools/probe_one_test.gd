extends Node
## Run ONE suite out of src/tests. The whole suite is minutes of map conversion, which is a long
## way to go for one assertion while chasing a single bug.
##
##   godot --headless --path . tools/probe_one_test.tscn -- --test=test_liquid_face_doubling
##
## Scene-run for the same reason run_tests.tscn is: only scene startup registers the autoloads.

const DEFAULT_TEST := "test_liquid_face_doubling"


func _ready() -> void:
	# Deferred for the same reason run_tests.gd defers: the root is busy while _ready propagates.
	_run.call_deferred()


func _run() -> void:
	var name := DEFAULT_TEST
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--test="):
			name = a.substr(7)
	var path := "res://src/tests/%s.gd" % name
	var script := load(path) as GDScript
	if script == null:
		printerr("no such suite: %s" % path)
		get_tree().quit(1)
		return
	var inst = script.new()
	inst.set_meta("script_path", path)
	await inst._run()
	get_tree().quit(1 if inst._fail_count > 0 else 0)
