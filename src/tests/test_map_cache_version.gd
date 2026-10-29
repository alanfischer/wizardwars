extends "res://src/tests/test_base.gd"
## The map pipeline version lives in the .scn itself (root meta "cache_version"), read
## back off the packed state without instantiating. A sidecar file used to hold it and
## could be separated from the bytes it described; these tests pin the replacement.

func _packed(stamp: bool) -> PackedScene:
	var root := Node3D.new()
	root.name = "worldspawn_map"
	if stamp:
		root.set_meta(MapConverter.VERSION_META, MapConverter.CACHE_VERSION)
	var ps := PackedScene.new()
	assert_eq(ps.pack(root), OK, "pack failed")
	root.free()
	return ps


func test_stamped_scene_reports_its_version() -> void:
	assert_eq(MapConverter.scene_cache_version(_packed(true)), MapConverter.CACHE_VERSION,
		"stamped scene must report the pipeline version")


func test_unstamped_scene_reads_as_zero() -> void:
	assert_eq(MapConverter.scene_cache_version(_packed(false)), 0,
		"a scene from before the stamp is version 0, not current")


func test_null_scene_reads_as_zero() -> void:
	assert_eq(MapConverter.scene_cache_version(null), 0, "null scene must not crash or pass")


func test_version_survives_a_save_and_load() -> void:
	# The stamp is only useful if it rides through the file the way bsp_data does.
	var path := "user://test_cache_version.scn"
	assert_eq(ResourceSaver.save(_packed(true), path), OK, "save failed")
	var loaded := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	assert_eq(MapConverter.scene_cache_version(loaded), MapConverter.CACHE_VERSION,
		"version must survive the round trip to disk")
	DirAccess.remove_absolute(path)


## The version number is only half the cache key. The other half is which build of the GoldSrcBSP
## extension did the converting, because most of what a .scn contains is decided in C++ and a
## number in GDScript cannot see that half move. A lib older than the checkout it sits in writes
## a .scn stamped with the CURRENT version and older contents, and nothing ever reconverts it —
## rebuilding the extension afterwards does not help, because the stale file is still a hit.
func _packed_pipeline(id: Variant) -> PackedScene:
	var root := Node3D.new()
	root.name = "worldspawn_map"
	root.set_meta(MapConverter.VERSION_META, MapConverter.CACHE_VERSION)
	if id != null:
		root.set_meta(MapConverter.PIPELINE_META, id)
	var ps := PackedScene.new()
	assert_eq(ps.pack(root), OK, "pack failed")
	root.free()
	return ps


func test_this_build_names_its_pipeline() -> void:
	# Empty is the honest answer only when the extension is too old to name itself; with the
	# extension present this has to be a real id, or the key silently has one half.
	if not ClassDB.class_exists(&"GoldSrcBSP"):
		return
	assert_gt(MapConverter.pipeline_id().length(), 0,
		"GoldSrcBSP must report a pipeline id — rebuild the extension if this fails")


func test_pipeline_id_is_stable_within_a_build() -> void:
	assert_eq(MapConverter.pipeline_id(), MapConverter.pipeline_id(),
		"asking twice must not give two answers, or every map reconverts on every load")


func test_stamped_scene_reports_its_pipeline() -> void:
	assert_eq(MapConverter.scene_pipeline_id(_packed_pipeline("deadbeefdeadbeef")),
		"deadbeefdeadbeef", "stamped scene must report the extension build that made it")


func test_a_scene_from_before_the_stamp_reads_as_empty() -> void:
	# Which is a MISMATCH against any real id, so every .scn on disk reconverts once. That is
	# the intended one-off cost, and the reason this is not a silent change.
	assert_eq(MapConverter.scene_pipeline_id(_packed_pipeline(null)), "",
		"an unstamped scene names no pipeline")
	assert_eq(MapConverter.scene_pipeline_id(null), "", "null scene must not crash or pass")


func test_pipeline_survives_a_save_and_load() -> void:
	var path := "user://test_pipeline_id.scn"
	assert_eq(ResourceSaver.save(_packed_pipeline("0123456789abcdef"), path), OK, "save failed")
	var loaded := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	assert_eq(MapConverter.scene_pipeline_id(loaded), "0123456789abcdef",
		"the id must ride inside the file, the way the version does")
	DirAccess.remove_absolute(path)


func test_a_converted_map_carries_both_halves() -> void:
	if not ClassDB.class_exists(&"GoldSrcBSP"):
		return
	var converter := MapConverter.new()
	_root().add_child(converter)
	_spawned.append(converter)
	assert_true(converter.convert("ww_golem"), "ww_golem converts")
	var scn := ResourceLoader.load("user://resources/maps/ww_golem.scn", "",
			ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	assert_eq(MapConverter.scene_cache_version(scn), MapConverter.CACHE_VERSION,
		"the cached map names the pipeline version")
	assert_eq(MapConverter.scene_pipeline_id(scn), MapConverter.pipeline_id(),
		"and the extension build that converted it")
