extends "res://src/tests/test_base.gd"
## Guards that bot waypoint files actually ship: since they aren't Godot resources, they only
## reach an exported build via each preset's `include_filter` in export_presets.cfg, by
## extension — `.gen_wpt` was missing for a while, so every map's bots silently fell back to
## local steering in release.

const WAYPOINT_DIR := "res://maps/waypoints/"
const PRESETS := "res://export_presets.cfg"


func _run_tests() -> void:
	_current_test = "every waypoint extension is in every preset's include_filter"
	var exts := _waypoint_extensions()
	assert_gt(exts.size(), 0, "no waypoint files found in %s" % WAYPOINT_DIR)
	var filters := _include_filters()
	assert_gt(filters.size(), 0, "no include_filter lines found in %s" % PRESETS)
	for filter in filters:
		var patterns := filter.split(",")
		for ext in exts:
			assert_true(patterns.has("*." + ext),
				"include_filter '%s' misses *.%s — those waypoints won't export" % [filter, ext])


func _waypoint_extensions() -> Array[String]:
	var exts: Array[String] = []
	var dir := DirAccess.open(WAYPOINT_DIR)
	if dir == null:
		return exts
	for f in dir.get_files():
		var ext := f.get_extension()
		if not ext.is_empty() and not exts.has(ext):
			exts.append(ext)
	return exts


func _include_filters() -> Array[String]:
	var filters: Array[String] = []
	var f := FileAccess.open(PRESETS, FileAccess.READ)
	if f == null:
		return filters
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line.begins_with("include_filter="):
			filters.append(line.trim_prefix("include_filter=").trim_prefix("\"").trim_suffix("\""))
	return filters
