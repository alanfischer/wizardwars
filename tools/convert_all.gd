extends SceneTree
## Headless batch conversion of all GoldSrc resources.
## Converts BSP maps, MDL models, SPR sprites, WAD textures, skyboxes, and sounds.
##
## Usage:
##   godot --path <project-dir> --headless --script res://tools/convert_all.gd
##
## Options (after --):
##   --maps-only     Only convert BSP maps
##   --resources-only Only convert models/sprites/decals/sky/sounds
##   --force         Delete existing caches before converting
##   --rotation-only Only convert the maps listed in maps/mapcycle.txt

const MAP_CACHE_DIR := "user://resources/maps"
const RESOURCE_CACHE_DIR := "user://resources"
const MAPCYCLE_PATH := "res://maps/mapcycle.txt"


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var maps_only := "--maps-only" in args
	var resources_only := "--resources-only" in args
	var force := "--force" in args
	var rotation_only := "--rotation-only" in args

	var ok := true
	var t0 := Time.get_ticks_msec()

	if force:
		_clean_caches(maps_only, resources_only)

	if not resources_only:
		ok = _convert_all_maps(rotation_only) and ok

	if not maps_only:
		ok = _convert_all_resources() and ok

	var elapsed := Time.get_ticks_msec() - t0
	print("\n========================================")
	print("Total time: %dms" % elapsed)
	print("Result: %s" % ("SUCCESS" if ok else "COMPLETED WITH ERRORS"))
	print("========================================")
	quit(0 if ok else 1)


func _clean_caches(maps_only: bool, resources_only: bool) -> void:
	if not maps_only:
		if DirAccess.dir_exists_absolute(RESOURCE_CACHE_DIR):
			_rm_recursive(RESOURCE_CACHE_DIR)
			print("Cleaned: %s" % RESOURCE_CACHE_DIR)

	if not resources_only:
		if DirAccess.dir_exists_absolute(MAP_CACHE_DIR):
			_rm_recursive(MAP_CACHE_DIR)
			print("Cleaned: %s" % MAP_CACHE_DIR)


func _convert_all_maps(rotation_only: bool) -> bool:
	print("\n=== Converting BSP Maps ===")

	if not ClassDB.class_exists(&"GoldSrcBSP"):
		printerr("GoldSrcBSP plugin not available — cannot convert maps")
		return false

	var map_files := _find_files("res://maps", "bsp")
	if map_files.is_empty():
		print("No BSP files found in res://maps/")
		return true
	if rotation_only:
		var cycle := _read_mapcycle()
		map_files = PackedStringArray(Array(map_files).filter(
				func(p: String) -> bool: return p.get_file().get_basename() in cycle))
		print("Rotation only: %s" % ", ".join(cycle))

	print("Found %d BSP files" % map_files.size())

	# Load MapConverter at runtime so autoloads are available
	var converter_script = load("res://src/systems/map_converter.gd")
	var converter := Node.new()
	converter.set_script(converter_script)
	root.add_child(converter)

	var count := 0
	var failed := 0

	for map_path in map_files:
		var map_name: String = map_path.get_file().get_basename()
		# No existence pre-check: convert() already skips scenes whose CACHE_VERSION
		# matches, so a pre-check here would let version bumps ship stale caches.
		print("  Converting %s ..." % map_name)
		var t := Time.get_ticks_msec()
		if converter.convert(map_name):
			print("  [ok] %s (%dms)" % [map_name, Time.get_ticks_msec() - t])
			count += 1
		else:
			printerr("  [FAIL] %s" % map_name)
			failed += 1

	converter.queue_free()
	print("Maps: %d/%d converted (%d failed)" % [count, map_files.size(), failed])
	return failed == 0


## The map names in mapcycle.txt, in MatchSystem.load_cycle's format.
func _read_mapcycle() -> PackedStringArray:
	var names := PackedStringArray()
	var f := FileAccess.open(MAPCYCLE_PATH, FileAccess.READ)
	if f == null:
		return names
	while not f.eof_reached():
		var line := f.get_line()
		var hash_pos := line.find("#")
		if hash_pos >= 0:
			line = line.substr(0, hash_pos)
		line = line.strip_edges()
		if not line.is_empty() and line not in names:
			names.append(line)
	return names


func _convert_all_resources() -> bool:
	print("\n=== Converting Resources (MDL, SPR, WAD, Sky, Sounds) ===")

	var converter_script = load("res://src/systems/resource_converter.gd")
	var converter := Node.new()
	converter.set_script(converter_script)
	root.add_child(converter)

	var ok: bool = converter.convert_all()
	converter.queue_free()
	return ok


func _find_files(dir_path: String, extension: String) -> PackedStringArray:
	var result := PackedStringArray()
	var dir := DirAccess.open(dir_path)
	if not dir:
		return result
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if not dir.current_is_dir() and file_name.get_extension().to_lower() == extension:
			result.append(dir_path.path_join(file_name))
		file_name = dir.get_next()
	dir.list_dir_end()
	return result


func _rm_recursive(path: String) -> void:
	var dir := DirAccess.open(path)
	if not dir:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		var full := path.path_join(name)
		if dir.current_is_dir():
			_rm_recursive(full)
			DirAccess.remove_absolute(full)
		else:
			DirAccess.remove_absolute(full)
		name = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(path)
