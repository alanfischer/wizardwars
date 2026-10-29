class_name ResourceConverter
extends Node
## Batch resource converter — runs on host to convert all GoldSrc resources
## (MDL, SPR, WAD decals, skybox TGAs, sounds) to native Godot formats.
## Caches results in user://resources/. Only requires C++ GDExtension plugin.


signal conversion_progress(step: String, current: int, total: int)
signal conversion_complete(success: bool)

## Bump whenever the MDL pipeline's output changes, so cached models reconvert instead of
## keeping the shape an older importer built — the cache keys off this, not off the .mdl.
const MDL_CACHE_VERSION := 1
const MDL_VERSION_META := &"cache_version"
const MDL_VERSION_PROPERTY := "metadata/cache_version"  # how the meta is named in packed state


func convert_all() -> bool:
	var t0 := Time.get_ticks_msec()
	Log.info("ResourceConverter: starting batch conversion...")

	DirAccess.make_dir_recursive_absolute(AssetLoader.RESOURCE_DIR)

	var ok := true
	ok = convert_all_mdl() and ok
	ok = convert_all_spr() and ok
	ok = extract_decals() and ok
	ok = convert_all_skyboxes() and ok
	ok = copy_sounds() and ok
	ok = build_manifest() and ok

	var elapsed := Time.get_ticks_msec() - t0
	Log.info("ResourceConverter: batch conversion %s in %dms" % [
		"completed" if ok else "finished with errors", elapsed])
	conversion_complete.emit(ok)
	return ok


func convert_all_mdl() -> bool:
	if not ClassDB.class_exists(&"GoldSrcMDL"):
		push_warning("ResourceConverter: GoldSrcMDL not available, skipping MDL conversion")
		return false

	var mdl_files := _find_files_recursive("models", "*.mdl")
	Log.info("ResourceConverter: converting %d MDL files..." % mdl_files.size())
	var count := 0
	for mdl_path in mdl_files:
		var rel := mdl_path.trim_prefix("")  # e.g. "models/backpack.mdl"
		var out_path := "%s/%s" % [AssetLoader.RESOURCE_DIR, rel.get_basename() + ".scn"]
		if _cache_hit(out_path):
			count += 1
			continue
		if _convert_mdl(mdl_path, out_path):
			count += 1
		conversion_progress.emit("MDL", count, mdl_files.size())
	Log.info("ResourceConverter: converted %d/%d MDL files" % [count, mdl_files.size()])
	return true


## A cached model counts only when the pipeline that wrote it stamped this version. Reading
## the stamp is cheap: a PackedScene's sub-resources aren't built until instantiate().
func _cache_hit(scn_path: String) -> bool:
	if not FileAccess.file_exists(scn_path):
		return false
	var cached := ResourceLoader.load(scn_path, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	return scene_cache_version(cached) == MDL_CACHE_VERSION


static func scene_cache_version(scene: PackedScene) -> int:
	if scene == null:
		return 0
	var state := scene.get_state()
	if state == null or state.get_node_count() == 0:
		return 0
	for i in state.get_node_property_count(0):
		if state.get_node_property_name(0, i) == MDL_VERSION_PROPERTY:
			return int(state.get_node_property_value(0, i))
	return 0


func _convert_mdl(mdl_path: String, out_path: String) -> bool:
	var mdl = ClassDB.instantiate(&"GoldSrcMDL")
	mdl.set_scale_factor(GameConsts.SCALE_FACTOR)
	if mdl.load_mdl(mdl_path) != OK:
		push_warning("ResourceConverter: failed to load %s" % mdl_path)
		mdl.free()
		return false
	mdl.build_model()

	# Reparent children to a plain Node3D (no GDExtension dependency)
	var root := Node3D.new()
	root.name = mdl_path.get_file().get_basename()
	# GoldSrc models face -Z after axis swizzle; rotate to match old .scn orientation
	root.rotation_degrees.y = 90.0

	# Copy sequence metadata if available
	if mdl.has_method("get_sequence_count"):
		var seq_count: int = mdl.get_sequence_count()
		var sequences := []
		for i in seq_count:
			sequences.append({
				"name": mdl.get_sequence_name(i),
				"fps": mdl.get_sequence_fps(i),
				"num_frames": mdl.get_sequence_num_frames(i),
			})
		root.set_meta("sequences", sequences)

	# Capture skin materials before reparenting (while mdl still owns meshes)
	var skin_count: int = mdl.get_skin_count() if mdl.has_method("get_skin_count") else 0
	if skin_count > 1 and mdl.has_method("get_skin_info"):
		Log.info("ResourceConverter: %s skin info:\n%s" % [mdl_path.get_file(), mdl.get_skin_info()])
	if skin_count > 1:
		for family in range(1, skin_count):
			mdl.set_skin(family)
			_store_skin_on_meshes(mdl, family)
		mdl.set_skin(0)
		# Clear surface overrides left by set_skin(0) — base mesh materials are correct
		_clear_skin_overrides(mdl)

	for child in mdl.get_children().duplicate():
		mdl.remove_child(child)
		root.add_child(child)
		_set_owner_recursive(child, root)

	root.set_meta("skin_count", skin_count)
	root.set_meta(MDL_VERSION_META, MDL_CACHE_VERSION)

	DirAccess.make_dir_recursive_absolute(out_path.get_base_dir())
	var scene := PackedScene.new()
	if scene.pack(root) != OK:
		push_warning("ResourceConverter: failed to pack %s" % out_path)
		root.free()
		mdl.free()
		return false
	if ResourceSaver.save(scene, out_path) != OK:
		push_warning("ResourceConverter: failed to save %s" % out_path)
		root.free()
		mdl.free()
		return false

	root.free()
	mdl.free()
	return true


func convert_all_spr() -> bool:
	if not ClassDB.class_exists(&"GoldSrcSPR"):
		push_warning("ResourceConverter: GoldSrcSPR not available, skipping SPR conversion")
		return false

	var spr_files := _find_files_recursive("sprites", "*.spr")
	Log.info("ResourceConverter: converting %d SPR files..." % spr_files.size())
	var count := 0
	for spr_path in spr_files:
		var rel := spr_path.trim_prefix("")  # e.g. "sprites/fire.spr"
		var base_dir := "%s/%s" % [AssetLoader.RESOURCE_DIR, rel.get_basename()]
		var source_md5 := FileAccess.get_md5(spr_path)
		if _spr_cache_hit(base_dir, source_md5):
			count += 1
			continue
		if _convert_spr(spr_path, base_dir, source_md5):
			count += 1
		conversion_progress.emit("SPR", count, spr_files.size())
	Log.info("ResourceConverter: converted %d/%d SPR files" % [count, spr_files.size()])
	_prune_spr(spr_files)
	return true


## Drops converted sprites whose .spr was deleted, which would otherwise stay in the manifest and
## keep shipping. Only from source: an exported build can't list its .spr files (just .import
## remaps), so there every converted sprite would look orphaned.
func _prune_spr(spr_files: PackedStringArray) -> void:
	if not OS.has_feature("editor"):
		return
	var keep := {}
	for p in spr_files:
		keep[p.get_basename()] = true
	var out_root := AssetLoader.RESOURCE_DIR + "/sprites"
	for scn in _find_files_recursive(out_root, "*.scn"):
		var rel := "sprites/" + scn.trim_prefix(out_root + "/").get_basename()
		if keep.has(rel):
			continue
		var frames := scn.get_basename()
		for f in DirAccess.get_files_at(frames):
			DirAccess.remove_absolute(frames.path_join(f))
		DirAccess.remove_absolute(frames)
		DirAccess.remove_absolute(scn)
		Log.info("ResourceConverter: removed %s, its .spr is gone" % rel)


## A converted sprite counts only while it was made from the same .spr bytes, so replacing a
## sprite's art reconverts it. An unreadable source (empty md5) trusts whatever is cached.
func _spr_cache_hit(base_dir: String, source_md5: String) -> bool:
	var meta_path := base_dir + "/meta.json"
	if not FileAccess.file_exists(meta_path) or not FileAccess.file_exists(base_dir + ".scn"):
		return false
	if source_md5.is_empty():
		return true
	var meta = JSON.parse_string(FileAccess.get_file_as_string(meta_path))
	return meta is Dictionary and meta.get("source_md5", "") == source_md5


func _convert_spr(spr_path: String, base_dir: String, source_md5: String) -> bool:
	var spr = ClassDB.instantiate(&"GoldSrcSPR")
	if spr.load_spr(spr_path) != OK:
		push_warning("ResourceConverter: failed to load %s" % spr_path)
		spr.free()
		return false

	DirAccess.make_dir_recursive_absolute(base_dir)
	for old in DirAccess.get_files_at(base_dir):  # a shorter replacement leaves no stale frames
		DirAccess.remove_absolute(base_dir.path_join(old))

	var frame_count: int = spr.get_frame_count()
	var width := 0
	var height := 0
	var origins: Array = []

	for i in frame_count:
		var tex: Texture2D = spr.get_frame_texture(i)
		if tex == null:
			continue
		var img := tex.get_image()
		if img == null:
			continue
		if i == 0:
			width = img.get_width()
			height = img.get_height()
		img.save_png("%s/%d.png" % [base_dir, i])
		var origin: Vector2i = spr.get_frame_origin(i)
		origins.append([origin.x, origin.y])

	# Save metadata (used by load_sprite() dict interface)
	var meta := {
		"frame_count": frame_count,
		"width": width,
		"height": height,
		"origins": origins,
		"source_md5": source_md5,
	}
	var f := FileAccess.open("%s/meta.json" % base_dir, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(meta, "  "))
		f.close()

	# Build and save .scn (self-animating Sprite3D; GoldSrcSPR.build_scene() owns the logic)
	var sprite_node = spr.build_scene()
	if sprite_node:
		var scene := PackedScene.new()
		if scene.pack(sprite_node) == OK:
			ResourceSaver.save(scene, base_dir + ".scn")
		sprite_node.free()
	return true


func extract_decals() -> bool:
	if not ClassDB.class_exists(&"GoldSrcWAD"):
		push_warning("ResourceConverter: GoldSrcWAD not available, skipping decal extraction")
		return false

	# res://-relative, not cwd-relative: a dedicated server runs from its own directory.
	var wad_path := MapConverter._resolve_res_file(MapConverter.BASE_WAD)
	if not FileAccess.file_exists(wad_path):
		# Nothing to do, not a failure: a deployed server ships the converted decals and no
		# source WAD, the same way it ships sky and sounds. Reporting it as an error had every
		# dedicated server logging "batch conversion finished with errors" on boot.
		Log.info("ResourceConverter: no %s source — using the converted decals as shipped" % MapConverter.BASE_WAD)
		return true

	var out_dir := "%s/decals" % AssetLoader.RESOURCE_DIR
	DirAccess.make_dir_recursive_absolute(out_dir)

	var wad = ClassDB.instantiate(&"GoldSrcWAD")
	wad.load_wad(wad_path)

	# Decals share the WAD with world textures. Every decal is a { texture; the few hole
	# textures that come along are small and never asked for.
	var tex_names := PackedStringArray()
	for tex_name: String in wad.get_texture_names():
		if tex_name.begins_with("{"):
			tex_names.append(tex_name)
	Log.info("ResourceConverter: extracting %d decal textures..." % tex_names.size())
	var count := 0
	for tex_name in tex_names:
		var out_path := "%s/%s.png" % [out_dir, tex_name]
		if FileAccess.file_exists(out_path):
			count += 1
			continue
		var tex: Texture2D = wad.get_texture(tex_name)
		if tex == null:
			continue
		var img := tex.get_image()
		if img == null:
			continue
		img.save_png(out_path)
		count += 1
	Log.info("ResourceConverter: extracted %d/%d decal textures" % [count, tex_names.size()])
	return true


func convert_all_skyboxes() -> bool:
	var sky_dir := "sky"
	if not DirAccess.dir_exists_absolute(sky_dir):
		Log.info("ResourceConverter: no sky directory found, skipping")
		return true

	var suffixes := ["rt", "lf", "up", "dn", "bk", "ft"]
	var sky_names := {}
	var dir := DirAccess.open(sky_dir)
	if dir == null:
		return true
	dir.list_dir_begin()
	var fname := dir.get_next()
	while not fname.is_empty():
		if fname.ends_with(".tga"):
			for suffix in suffixes:
				if fname.ends_with(suffix + ".tga"):
					var sky_name := fname.substr(0, fname.length() - suffix.length() - 4)
					sky_names[sky_name] = true
					break
		fname = dir.get_next()
	dir.list_dir_end()

	Log.info("ResourceConverter: converting %d skyboxes..." % sky_names.size())
	var count := 0
	for sky_name in sky_names:
		if _convert_skybox(sky_name):
			count += 1
	Log.info("ResourceConverter: converted %d/%d skyboxes" % [count, sky_names.size()])
	return true


func _convert_skybox(sky_name: String) -> bool:
	var out_dir := "%s/sky/%s" % [AssetLoader.RESOURCE_DIR, sky_name]
	var suffixes := ["rt", "lf", "up", "dn", "bk", "ft"]

	var all_exist := true
	for suffix in suffixes:
		if not FileAccess.file_exists("%s/%s.png" % [out_dir, suffix]):
			all_exist = false
			break
	if all_exist:
		return true

	DirAccess.make_dir_recursive_absolute(out_dir)

	for suffix in suffixes:
		var tga_path := "sky/%s%s.tga" % [sky_name, suffix]
		var tex := load(tga_path) as Texture2D
		if tex == null:
			push_warning("ResourceConverter: sky texture not found: %s" % tga_path)
			return false
		var img := tex.get_image()
		img.save_png("%s/%s.png" % [out_dir, suffix])
	return true


func copy_sounds() -> bool:
	var sound_dir := "sounds"
	if not DirAccess.dir_exists_absolute(sound_dir):
		Log.info("ResourceConverter: no sounds directory found, skipping")
		return true

	var wav_files := _find_files_recursive(sound_dir, "*.wav")
	Log.info("ResourceConverter: copying %d sound files..." % wav_files.size())
	var count := 0
	for wav_path in wav_files:
		var rel := wav_path.trim_prefix("")  # e.g. "sounds/ambience/drip1.wav"
		var out_path := "%s/%s" % [AssetLoader.RESOURCE_DIR, rel]
		# By content, not presence: a replaced sound must not leave the old bytes behind.
		if FileAccess.file_exists(out_path) and FileAccess.get_md5(out_path) == FileAccess.get_md5(wav_path):
			count += 1
			continue
		DirAccess.make_dir_recursive_absolute(out_path.get_base_dir())
		var data := FileAccess.get_file_as_bytes(wav_path)
		if data.is_empty():
			continue
		var f := FileAccess.open(out_path, FileAccess.WRITE)
		if f:
			f.store_buffer(data)
			f.close()
			count += 1
	Log.info("ResourceConverter: copied %d/%d sound files" % [count, wav_files.size()])
	_prune_sounds(wav_files)
	return true


## Drops copied sounds whose source was deleted, which would otherwise stay in the manifest and
## keep shipping. Source-only, like _prune_spr: an export lists .import remaps, not .wav files.
func _prune_sounds(wav_files: PackedStringArray) -> void:
	if not OS.has_feature("editor"):
		return
	var keep := {}
	for p in wav_files:
		keep[p] = true
	var out_root := AssetLoader.RESOURCE_DIR + "/sounds"
	for wav in _find_files_recursive(out_root, "*.wav"):
		var rel := "sounds/" + wav.trim_prefix(out_root + "/")
		if not keep.has(rel):
			DirAccess.remove_absolute(wav)
			Log.info("ResourceConverter: removed %s, its source is gone" % rel)


func build_manifest() -> bool:
	Log.info("ResourceConverter: building manifest...")
	var manifest := {}  # path -> {size, hash}
	var all_files := _find_files_recursive(AssetLoader.RESOURCE_DIR, "*")
	for file_path in all_files:
		if file_path.ends_with("manifest.json"):
			continue
		var rel := file_path.trim_prefix(AssetLoader.RESOURCE_DIR + "/")
		# Maps download on-demand via MapTransfer, not the manifest.
		if rel.begins_with("maps/"):
			continue
		if _shipped_in_pack(rel):
			continue
		var f_size := FileAccess.open(file_path, FileAccess.READ)
		var size := int(f_size.get_length()) if f_size else 0
		if f_size:
			f_size.close()
		var file_hash := FileAccess.get_md5(file_path)
		manifest[rel] = {"size": size, "hash": file_hash}

	var manifest_path := "%s/manifest.json" % AssetLoader.RESOURCE_DIR
	var f := FileAccess.open(manifest_path, FileAccess.WRITE)
	if f == null:
		push_warning("ResourceConverter: failed to write manifest")
		return false
	f.store_string(JSON.stringify(manifest, "  "))
	f.close()
	Log.info("ResourceConverter: manifest has %d entries" % manifest.size())
	return true


## A converted copy of a model, sprite scene or sound the exported pck already carries.
## AssetLoader loads res:// first, so a peer downloading it would never use it.
static func _shipped_in_pack(rel: String) -> bool:
	var source := ""
	if rel.begins_with("models/") and rel.ends_with(".scn"):
		source = rel.get_basename() + ".mdl"
	elif rel.begins_with("sprites/"):
		# Both the .scn and the frame folder (N.png, meta.json) are made from one .spr.
		source = (rel.get_basename() if rel.ends_with(".scn") else rel.get_base_dir()) + ".spr"
	elif rel.begins_with("sounds/"):
		source = rel
	return not source.is_empty() and ResourceLoader.exists("res://" + source)


func _find_files_recursive(base_path: String, pattern: String) -> PackedStringArray:
	var results := PackedStringArray()
	var dir := DirAccess.open(base_path)
	if dir == null:
		return results
	_scan_dir(dir, base_path, pattern, results)
	return results


func _scan_dir(dir: DirAccess, base_path: String, pattern: String, results: PackedStringArray) -> void:
	dir.list_dir_begin()
	var fname := dir.get_next()
	while not fname.is_empty():
		var full_path := base_path.path_join(fname)
		if dir.current_is_dir():
			if not fname.begins_with("."):
				var sub_dir := DirAccess.open(full_path)
				if sub_dir:
					_scan_dir(sub_dir, full_path, pattern, results)
		else:
			if fname.match(pattern) and not fname.ends_with(".import"):
				results.append(full_path)
		fname = dir.get_next()
	dir.list_dir_end()


func _set_owner_recursive(node: Node, p_owner: Node) -> void:
	node.owner = p_owner
	for child in node.get_children():
		_set_owner_recursive(child, p_owner)


## One material per surface: a bodypart's meshes are its surfaces, and each carries its own
## skin_ref into the family's row of the skin table.
func _store_skin_on_meshes(node: Node, family: int) -> void:
	if node is MeshInstance3D:
		var mats := []
		var any := false
		for surf_idx in (node as MeshInstance3D).get_surface_override_material_count():
			var mat = node.get_surface_override_material(surf_idx)
			# Duplicated so it's independent of the live override
			mats.append(mat.duplicate() if mat else null)
			any = any or mat != null
		if any:
			node.set_meta("skin_%d" % family, mats)
	for child in node.get_children():
		_store_skin_on_meshes(child, family)


func _clear_skin_overrides(node: Node) -> void:
	if node is MeshInstance3D:
		for surf_idx in (node as MeshInstance3D).get_surface_override_material_count():
			node.set_surface_override_material(surf_idx, null)
	for child in node.get_children():
		_clear_skin_overrides(child)
