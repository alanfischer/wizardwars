class_name MapConverter
extends Node
## Converts a raw .bsp file to a Godot .scn using the GoldSrcBSP C++ plugin,
## then caches the result in user://resources/maps/.

signal conversion_complete(map_name: String, success: bool)

const OVERBRIGHT := 2.0
const CACHE_DIR := "user://resources/maps"
## WW's replacements for every texture a map takes from the stock Valve WADs, decals included.
const BASE_WAD := "ww_base.wad"
# Root meta the version is stamped under. It rides INSIDE the .scn so it travels with
# the bytes — a downloaded, rsynced or hand-copied map still says what built it, which
# a sidecar file (what this replaced) could never promise.
const VERSION_META := &"cache_version"
const VERSION_PROPERTY := "metadata/cache_version"  # how the meta is named in the packed state
## The OTHER half of the cache key: which build of the GoldSrcBSP extension converted this map.
##
## CACHE_VERSION below is a number in GDScript, and most of what a .scn contains is decided in
## C++ — mesh building, materials, the baked shader source, the stripped BSP blob. A lib built
## from older source than the checkout it sits in writes a .scn stamped with the CURRENT version
## number and older contents, and nothing ever reconverts it. That is not hypothetical: it is
## what a clone-then-build-in-the-wrong-order leaves behind, and the map looks subtly wrong
## forever after.
##
## The id is a hash of the extension's own SOURCE, not of the binary (cmake/pipeline_id.cmake),
## so every platform's build of one source tree agrees — which matters because a client compares
## its id against one baked into a .scn it downloaded from a host on some other OS.
const PIPELINE_META := &"pipeline_id"
const PIPELINE_PROPERTY := "metadata/pipeline_id"
# Bump whenever the conversion pipeline's output changes, to force cached .scn maps to
# reconvert — the cache keys off this constant, not the BSP's contents.
const CACHE_VERSION := 1


func convert(bsp_name: String) -> bool:
	var scn_path := "%s/%s.scn" % [CACHE_DIR, bsp_name]
	if FileAccess.file_exists(scn_path):
		# Loading the PackedScene to read the stamp is cheap — the sub-resources aren't
		# built until instantiate() (177 MB ww_chasm loads in ~50ms) — so this asks the
		# file itself rather than trusting anything alongside it.
		var cached := ResourceLoader.load(scn_path, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
		var cached_version := scene_cache_version(cached)
		var cached_pipeline := scene_pipeline_id(cached)
		var pipeline := pipeline_id()
		if cached_version == CACHE_VERSION and cached_pipeline == pipeline:
			Log.info("MapConverter: cache hit for %s (v%d, pipeline %s)" % [
					bsp_name, cached_version, pipeline])
			conversion_complete.emit(bsp_name, true)
			return true
		if cached_version != CACHE_VERSION:
			Log.info("MapConverter: %s cached at v%d, pipeline is v%d — reconverting" % [
					bsp_name, cached_version, CACHE_VERSION])
		else:
			# Worth its own line: the version matched, so the thing that moved was the extension,
			# and a reader who only knows about CACHE_VERSION would call this cache hit a bug.
			Log.info("MapConverter: %s was converted by extension build %s, this is %s — reconverting" % [
					bsp_name, cached_pipeline if cached_pipeline else "<unstamped>", pipeline])

	DirAccess.make_dir_recursive_absolute(CACHE_DIR)

	var bsp_path := _find_res_file("maps/%s.bsp" % bsp_name)
	if not FileAccess.file_exists(bsp_path):
		push_warning("MapConverter: BSP not found: %s" % bsp_path)
		conversion_complete.emit(bsp_name, false)
		return false

	if not ClassDB.class_exists(&"GoldSrcBSP"):
		push_warning("MapConverter: GoldSrcBSP plugin not available")
		conversion_complete.emit(bsp_name, false)
		return false

	Log.info("MapConverter: converting %s ..." % bsp_name)
	var t0 := Time.get_ticks_msec()

	var bsp = ClassDB.instantiate(&"GoldSrcBSP")
	bsp.set_scale_factor(GameConsts.SCALE_FACTOR)
	bsp.shader_lightstyles = true
	bsp.load_bsp(bsp_path)

	for wad in _load_wads(bsp):
		bsp.add_wad(wad)

	bsp.build_mesh()
	EntityRender.apply_overbright(bsp, OVERBRIGHT)

	# Reparent children to a plain Node3D (GDExtension-independent)
	var root := Node3D.new()
	root.name = bsp_name

	if bsp.has_method("get_lightstyle_image"):
		var ls_image = bsp.get_lightstyle_image()
		var ls_texture = bsp.get_lightstyle_texture()
		if ls_image and ls_texture:
			root.set_meta("lightstyle_image", ls_image)
			root.set_meta("lightstyle_texture", ls_texture)

	if bsp.has_method("bake_light_grid"):
		var light_grid: Dictionary = bsp.bake_light_grid(32.0)
		if not light_grid.is_empty():
			root.set_meta("light_grid", light_grid)

	# Bake the stripped BSP (PLANES/NODES/CLIPNODES/LEAFS/VISIBILITY/MODELS) so
	# both VisibilityManager (PVS) and hop's hull collision can run from the .scn
	# without the original .bsp — clients only ever receive the .scn. Collision
	# bodies carry just a "bsp_model" index and find this by walking up the tree.
	# build_mesh() already parked the blob on the BSP node; read it back rather than
	# calling get_bsp_blob() again, which would rebuild the whole multi-MB payload.
	# PackedByteArray is copy-on-write, so this is a refcount.
	var bsp_blob: PackedByteArray = bsp.get_meta("bsp_data", PackedByteArray())
	if not bsp_blob.is_empty():
		root.set_meta("bsp_data", bsp_blob)

	# Bake the map's sidecar text files into the scene so clients never need to
	# fetch maps/<name>.txt / _readme.txt / .ww separately — they ride inside
	# the .scn like everything else above and are read back via get_meta().
	var description := _read_sidecar_text("maps/%s.txt" % bsp_name)
	if not description.is_empty():
		root.set_meta("map_description", description)
	var readme := _read_sidecar_text("maps/%s_readme.txt" % bsp_name)
	if not readme.is_empty():
		root.set_meta("map_readme", readme)
	var world_info := _read_sidecar_text("maps/%s.ww" % bsp_name)
	if not world_info.is_empty():
		root.set_meta("map_world_info", world_info)

	root.set_meta(VERSION_META, CACHE_VERSION)
	root.set_meta(PIPELINE_META, pipeline_id())

	var children = bsp.get_children()
	for child in children:
		bsp.remove_child(child)
		root.add_child(child)
	bsp.free()
	_set_owner_recursive(root, root)

	# Save .scn — entity nodes (both brush and point) are included in the scene
	var scene := PackedScene.new()
	var pack_err := scene.pack(root)
	if pack_err != OK:
		push_warning("MapConverter: failed to pack %s: %s" % [bsp_name, error_string(pack_err)])
		root.free()
		conversion_complete.emit(bsp_name, false)
		return false

	var save_err := ResourceSaver.save(scene, scn_path)
	if save_err != OK:
		push_warning("MapConverter: failed to save %s: %s" % [scn_path, error_string(save_err)])
		root.free()
		conversion_complete.emit(bsp_name, false)
		return false
	root.free()

	var hash_val := FileAccess.get_md5(scn_path)
	var hash_path := "%s/%s.hash" % [CACHE_DIR, bsp_name]
	var hash_file := FileAccess.open(hash_path, FileAccess.WRITE)
	if hash_file:
		hash_file.store_string(hash_val)
		hash_file.close()
	DirAccess.remove_absolute("%s/%s.version" % [CACHE_DIR, bsp_name])  # legacy sidecar

	var elapsed := Time.get_ticks_msec() - t0
	Log.info("MapConverter: converted %s in %dms" % [bsp_name, elapsed])
	conversion_complete.emit(bsp_name, true)
	return true


func get_map_hash(map_name: String) -> String:
	var hash_path := "%s/%s.hash" % [CACHE_DIR, map_name]
	if not FileAccess.file_exists(hash_path):
		return ""
	var f := FileAccess.open(hash_path, FileAccess.READ)
	if f == null:
		return ""
	var h := f.get_as_text().strip_edges()
	f.close()
	return h


## The pipeline version a packed map was built by, read off the scene state without
## instantiating it. 0 when the scene predates the stamp (or isn't one).
static func scene_cache_version(scene: PackedScene) -> int:
	return int(_scene_root_meta(scene, VERSION_PROPERTY, 0))


## Which build of the extension converted a packed map. Empty when the scene predates the stamp,
## which every .scn on disk does the first time this ships — and which counts as a mismatch, so
## they all reconvert once, the same way a CACHE_VERSION bump makes them.
static func scene_pipeline_id(scene: PackedScene) -> String:
	return str(_scene_root_meta(scene, PIPELINE_PROPERTY, ""))


## This build's conversion-pipeline id, or "" where the extension is too old to name itself (in
## which case every stamp is "" and the id half of the key simply never fires).
static func pipeline_id() -> String:
	if not ClassDB.class_exists(&"GoldSrcBSP"):
		return ""
	if not ClassDB.class_has_method(&"GoldSrcBSP", &"get_pipeline_id", true):
		return ""
	return str(ClassDB.class_call_static(&"GoldSrcBSP", &"get_pipeline_id"))


## Read one root-node property off a packed scene without instantiating it — the sub-resources
## aren't built until instantiate(), so this stays cheap on a 177 MB map.
static func _scene_root_meta(scene: PackedScene, property: String, fallback: Variant) -> Variant:
	if scene == null:
		return fallback
	var state := scene.get_state()
	if state == null or state.get_node_count() == 0:
		return fallback
	for i in state.get_node_property_count(0):
		if state.get_node_property_name(0, i) == property:
			return state.get_node_property_value(0, i)
	return fallback


## Load WAD files referenced by a BSP's worldspawn entity.
## Requires C++ GDExtension plugin (GoldSrcBSP, GoldSrcWAD).
func _load_wads(bsp) -> Array:
	var wads: Array = []
	if not ClassDB.class_exists(&"GoldSrcWAD"):
		push_warning("load_wads: GoldSrcWAD not available")
		return wads
	var loaded_names := {}

	var wad_string := ""
	for ent in bsp.get_entities():
		if ent.get("classname", "") == "worldspawn":
			wad_string = ent.get("wad", "")
			break

	# The stock Valve WADs the maps declare aren't shipped. Any that are present (a real
	# halflife.wad beside a server, say) still win; BASE_WAD comes last and covers the rest.
	var stand_ins: Array[String] = []
	var wad_names: Array[String] = []
	for wad_path in wad_string.split(";", false):
		wad_names.append(wad_path.replace("\\", "/").get_file().to_lower())
	wad_names.append(BASE_WAD)
	for wad_name in wad_names:
		if wad_name.is_empty() or loaded_names.has(wad_name):
			continue
		var full_path := _find_res_file(wad_name)
		if not FileAccess.file_exists(full_path):
			if wad_name == BASE_WAD:
				push_warning("WAD not found: %s" % full_path)
			else:
				stand_ins.append(wad_name)
			continue
		var wad = ClassDB.instantiate(&"GoldSrcWAD")
		if wad.load_wad(full_path) != OK:
			push_warning("Failed to load WAD: %s" % full_path)
			wad.free()
			continue
		wads.append(wad)
		loaded_names[wad_name] = true

	Log.info("Loaded %d WADs from BSP: %s%s" % [wads.size(), ", ".join(loaded_names.keys()),
			"" if stand_ins.is_empty() else " (%s stands in for %s)" % [BASE_WAD, ", ".join(stand_ins)]])
	return wads


## Returns the filesystem path for a res/-relative file.
## On a deployed server, checks beside the executable first so maps/WADs can be
## supplied as a plain directory without packaging into a .pck.
func _find_res_file(rel_path: String) -> String:
	return _resolve_res_file(rel_path)


static func _resolve_res_file(rel_path: String) -> String:
	var beside := OS.get_executable_path().get_base_dir().path_join(rel_path)
	if FileAccess.file_exists(beside):
		return beside
	return "res://" + rel_path


## Read a sidecar text file (map description/readme/world-map sheet), or "" if
## it doesn't exist. Called at convert time only — the result is baked into
## scene metadata, not read again at load time.
static func _read_sidecar_text(rel_path: String) -> String:
	var path := _resolve_res_file(rel_path)
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var text := f.get_as_text()
	f.close()
	return text.strip_edges()


## Every map this peer can load, sorted: .bsp/.glb sources beside the game plus anything already
## converted or downloaded into the cache. The lobby dropdown, /maplist and the map cycle all read
## this one list, so they can never disagree about what is installed.
static func list_maps() -> Array[String]:
	var names: Array[String] = []
	var dir := DirAccess.open("maps/")
	if dir:
		dir.list_dir_begin()
		var file_name := dir.get_next()
		while file_name != "":
			if file_name.ends_with(".bsp") or file_name.ends_with(".glb"):
				var basename := file_name.get_basename()
				if basename not in names:
					names.append(basename)
			file_name = dir.get_next()
	var cache_dir := DirAccess.open(CACHE_DIR)
	if cache_dir:
		cache_dir.list_dir_begin()
		var file_name := cache_dir.get_next()
		while file_name != "":
			if file_name.ends_with(".scn"):
				var map_name := file_name.get_basename()
				if map_name not in names:
					names.append(map_name)
			file_name = cache_dir.get_next()
	names.sort()
	return names


## True if the given map can be loaded — a cached .scn, or a source this build converts. The .glb
## arm is what main._is_blender_map loads; without it a Blender map the lobby offers reads as
## missing to /map and the rotation.
static func map_exists(map_name: String) -> bool:
	if map_name.is_empty():
		return false
	if FileAccess.file_exists("%s/%s.scn" % [CACHE_DIR, map_name]):
		return true
	if FileAccess.file_exists(_resolve_res_file("maps/%s.bsp" % map_name)):
		return true
	return FileAccess.file_exists(_resolve_res_file("maps/%s.glb" % map_name))


func _set_owner_recursive(node: Node, p_owner: Node) -> void:
	for child in node.get_children():
		child.owner = p_owner
		_set_owner_recursive(child, p_owner)
