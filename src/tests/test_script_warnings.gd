extends "res://src/tests/test_base.gd"
## Every script in the project loads. Under run_tests.sh warnings are errors, so a script with a
## warning fails here even when no test uses it.


func test_every_script_loads() -> void:
	var files: Array[String] = []
	for root in ["res://src", "res://tools"]:
		_collect(root, files)
	assert_gt(files.size(), 100, "found the project's scripts")
	for f in files:
		# A script that fails to parse still loads, as one that cannot be instantiated.
		var script := load(f) as Script
		assert_true(script != null and (script.can_instantiate() or script.is_abstract()), f)


func _collect(dir: String, out: Array[String]) -> void:
	for d in DirAccess.get_directories_at(dir):
		_collect(dir.path_join(d), out)
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".gd"):
			out.append(dir.path_join(f))
