extends "res://src/tests/test_base.gd"
## Converted sprites are keyed on the source .spr's md5, so replacing a sprite's art reconverts it
## instead of serving the cached frames of the old one.

const DIR := "user://test_spr_cache"

var _conv: ResourceConverter


func _setup_test(_test_name: String) -> void:
	_conv = ResourceConverter.new()


func _teardown_test() -> void:
	_conv.free()
	_remove_tree(DIR)


func _remove_tree(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	for d in DirAccess.get_directories_at(path):
		_remove_tree(path.path_join(d))
	for f in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(f))
	DirAccess.remove_absolute(path)


func test_cache_follows_source_bytes() -> void:
	var base := DIR + "/glow01"
	var md5 := FileAccess.get_md5("res://sprites/glow01.spr")
	assert_true(_conv._convert_spr("res://sprites/glow01.spr", base, md5), "converts")
	assert_true(_conv._spr_cache_hit(base, md5), "same source is a hit")
	assert_false(_conv._spr_cache_hit(base, FileAccess.get_md5("res://sprites/flare6.spr")),
		"changed source is a miss")
	assert_true(_conv._spr_cache_hit(base, ""), "unreadable source trusts the cache")


func test_meta_without_md5_is_a_miss() -> void:
	var base := DIR + "/old"
	DirAccess.make_dir_recursive_absolute(base)
	var f := FileAccess.open(base + "/meta.json", FileAccess.WRITE)
	f.store_string(JSON.stringify({"frame_count": 1}))
	f.close()
	f = FileAccess.open(base + ".scn", FileAccess.WRITE)
	f.close()
	assert_false(_conv._spr_cache_hit(base, "abc"), "pre-md5 cache reconverts")


func test_shorter_replacement_leaves_no_stale_frames() -> void:
	var base := DIR + "/swap"
	assert_true(_conv._convert_spr("res://sprites/flare6.spr", base, "a"), "20-frame sprite")
	assert_eq(DirAccess.get_files_at(base).size(), 21, "20 frames + meta")
	assert_true(_conv._convert_spr("res://sprites/glow01.spr", base, "b"), "1-frame sprite")
	assert_eq(Array(DirAccess.get_files_at(base)), ["0.png", "meta.json"], "old frames gone")


func test_manifest_leaves_out_frames_the_pck_has() -> void:
	for rel in ["sprites/glow01.scn", "sprites/glow01/0.png", "sprites/glow01/meta.json",
			"sprites/effects/updraft/0.png"]:
		assert_true(ResourceConverter._shipped_in_pack(rel), "%s ships in the pck" % rel)
	assert_false(ResourceConverter._shipped_in_pack("sprites/not_a_sprite/0.png"),
		"a drop-in sprite's frames still go in the manifest")


func test_pck_frames_beat_a_stale_cache() -> void:
	# A host on an older build hands its frames down into user://; this build's art must win.
	var dir := AssetLoader.RESOURCE_DIR + "/sprites/glow01"
	var saved := {}
	for fname in ["0.png", "meta.json"]:
		if FileAccess.file_exists(dir.path_join(fname)):
			saved[fname] = FileAccess.get_file_as_bytes(dir.path_join(fname))
	DirAccess.make_dir_recursive_absolute(dir)
	var decoy := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	decoy.fill(Color.RED)
	decoy.save_png(dir.path_join("0.png"))
	var f := FileAccess.open(dir.path_join("meta.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify({"frame_count": 1, "width": 64, "height": 64, "origins": [[-32, 32]]}))
	f.close()

	var data := AssetLoader.load_sprite("sprites/glow01.spr")
	var textures: Array = data.get("textures", [])
	assert_eq(textures.size(), 1, "one frame")
	if not textures.is_empty():
		assert_ne(textures[0].get_image().get_pixel(0, 0), Color.RED, "not the cached decoy")
	assert_eq(data.get("origins", []), [[-32, 32]], "origins come along")

	for fname in ["0.png", "meta.json"]:
		if saved.has(fname):
			var w := FileAccess.open(dir.path_join(fname), FileAccess.WRITE)
			w.store_buffer(saved[fname])
			w.close()
		else:
			DirAccess.remove_absolute(dir.path_join(fname))


func test_prune_drops_sprites_whose_source_is_gone() -> void:
	var gone := AssetLoader.RESOURCE_DIR + "/sprites/zz_test_gone"
	DirAccess.make_dir_recursive_absolute(gone)
	FileAccess.open(gone + "/0.png", FileAccess.WRITE).close()
	FileAccess.open(gone + ".scn", FileAccess.WRITE).close()
	var kept_scn := AssetLoader.RESOURCE_DIR + "/sprites/glow01.scn"
	var had_kept := FileAccess.file_exists(kept_scn)
	# The real source list, so only the planted orphan goes from the real cache.
	_conv._prune_spr(_conv._find_files_recursive("sprites", "*.spr"))
	assert_false(FileAccess.file_exists(gone + ".scn"), "orphaned .scn removed")
	assert_false(DirAccess.dir_exists_absolute(gone), "orphaned frame folder removed")
	assert_eq(FileAccess.file_exists(kept_scn), had_kept, "a sprite with a source is left alone")


func test_prune_drops_sounds_whose_source_is_gone() -> void:
	var gone := AssetLoader.RESOURCE_DIR + "/sounds/zz_test_gone.wav"
	DirAccess.make_dir_recursive_absolute(gone.get_base_dir())
	FileAccess.open(gone, FileAccess.WRITE).close()
	var kept := AssetLoader.RESOURCE_DIR + "/sounds/vox/flag.wav"
	var had_kept := FileAccess.file_exists(kept)
	# The real source list, so only the planted orphan goes from the real cache.
	_conv._prune_sounds(_conv._find_files_recursive("sounds", "*.wav"))
	assert_false(FileAccess.file_exists(gone), "orphaned sound removed")
	assert_eq(FileAccess.file_exists(kept), had_kept, "a sound with a source is left alone")
