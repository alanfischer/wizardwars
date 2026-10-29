extends "res://src/tests/test_base.gd"
## Team chat names the sender's nearest info_areamarker, as the original's Host_Say did.


func _marker(netname: String, pos: Vector3) -> InfoAreaMarker:
	var m := InfoAreaMarker.new()
	m.set_meta("entity", {"classname": "info_areamarker", "netname": netname})
	m.position = pos
	_root().add_child(_keep(m))
	return m


func test_nearest_marker_names_the_area() -> void:
	_marker("Bridge", Vector3(0, 0, 0))
	_marker("Moat", Vector3(10, 0, 0))
	var tree := Engine.get_main_loop() as SceneTree
	assert_eq(InfoAreaMarker.nearest_name(tree, Vector3(2, 1, 0)), "Bridge")
	assert_eq(InfoAreaMarker.nearest_name(tree, Vector3(7, 0, 0)), "Moat")


func test_no_markers_no_name() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	assert_false(tree.has_group(InfoAreaMarker.GROUP), "a marker leaked in from another test")
	assert_eq(InfoAreaMarker.nearest_name(tree, Vector3.ZERO), "")
