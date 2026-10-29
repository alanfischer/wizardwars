extends Node
## Scene-based test runner (godot --headless --path . res://src/tests/run_tests.tscn).
## Runs as a *scene*, not `-s` — only scene startup registers autoloads (Log, GoalSystem, NetworkManager) that tests reference.

func _ready() -> void:
	# Deferred: while _ready propagates the root is flagged busy, breaking tests that add scratch nodes to it.
	_run_all.call_deferred()


func _run_all() -> void:
	var total_pass := 0
	var total_fail := 0
	var test_dir := "res://src/tests/"
	var dir := DirAccess.open(test_dir)
	if not dir:
		printerr("Could not open test directory: %s" % test_dir)
		get_tree().quit(1)
		return

	var test_files: Array[String] = []
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		if file_name.begins_with("test_") and file_name.ends_with(".gd"):
			test_files.append(file_name)
		file_name = dir.get_next()
	dir.list_dir_end()
	test_files.sort()

	print("\n====== scene test suite ======\n")

	for tf in test_files:
		var script_path := test_dir + tf
		var script: GDScript = load(script_path)
		# can_instantiate is the check that matters: a file with a PARSE error still comes back
		# from load() as a GDScript object, and `new()` on it then returns null — so the awaited
		# _run() below never resolves and the whole suite HANGS instead of reporting. Counting it
		# as a failure keeps that loud and finite. The fixture layer in test_base.gd makes this
		# reachable: a suite whose own helper signature no longer matches the base it overrides
		# fails to parse, and that is a one-line mistake away at all times.
		if not script or not script.can_instantiate():
			printerr("Failed to load (parse error?): %s" % script_path)
			total_fail += 1
			continue
		var instance = script.new()
		instance.set_meta("script_path", script_path)
		# Awaited: physics-query suites are coroutines that let a physics frame flush new collision nodes.
		await instance._run()
		total_pass += instance._pass_count
		total_fail += instance._fail_count

	var total := total_pass + total_fail
	print("====== TOTAL: %d/%d passed ======" % [total_pass, total])
	if total_fail > 0:
		printerr("====== %d FAILED ======" % total_fail)
	get_tree().quit(1 if total_fail > 0 else 0)
