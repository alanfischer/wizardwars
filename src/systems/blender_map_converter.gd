class_name BlenderMapConverter
extends Node
# Converts a Blender .glb under res://maps/ into a Godot .scn cached at user://resources/maps/,
# so Blender and BSP maps share the same transfer/cache/load path. Bump ADAPTER_VERSION when
# BlenderMapAdapter's behavior changes, to force stale cached `.scn`/`.hash` to reconvert.

const ADAPTER_VERSION := 1
const CACHE_DIR := "user://resources/maps"
const BlenderMapAdapterScript = preload("res://src/systems/blender_map_adapter.gd")


func convert(map_name: String) -> bool:
	var glb_path := "res://maps/%s.glb" % map_name
	var abs_glb := ProjectSettings.globalize_path(glb_path)
	if not FileAccess.file_exists(abs_glb):
		push_warning("Blender map source not found: %s" % glb_path)
		return false

	var source_hash := _sha256_file(abs_glb)
	var expected_hash := "%s-v%d" % [source_hash, ADAPTER_VERSION]

	DirAccess.make_dir_recursive_absolute(CACHE_DIR)
	var scn_path := "%s/%s.scn" % [CACHE_DIR, map_name]
	var hash_path := "%s/%s.hash" % [CACHE_DIR, map_name]

	if FileAccess.file_exists(scn_path) and FileAccess.file_exists(hash_path):
		var f := FileAccess.open(hash_path, FileAccess.READ)
		var cached_hash := f.get_as_text().strip_edges() if f != null else ""
		if f != null:
			f.close()
		if cached_hash == expected_hash:
			Log.info("[BlenderMap] %s up-to-date" % map_name)
			return true

	Log.info("[BlenderMap] Converting %s.glb → %s.scn" % [map_name, map_name])
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_file(abs_glb, state)
	if err != OK:
		push_error("GLTF parse failed: %s (%s)" % [glb_path, error_string(err)])
		return false

	var scene := doc.generate_scene(state) as Node3D
	if scene == null:
		push_error("GLTF generate_scene returned null: %s" % glb_path)
		return false

	BlenderMapAdapterScript.adapt(scene)
	# Nodes added by the adapter have no owner, and pack() silently drops unowned nodes.
	_assign_ownership(scene, scene)

	var packed := PackedScene.new()
	var pack_err := packed.pack(scene)
	if pack_err != OK:
		push_error("PackedScene.pack failed: %s (%s)" % [glb_path, error_string(pack_err)])
		scene.queue_free()
		return false

	var save_err := ResourceSaver.save(packed, scn_path)
	scene.queue_free()
	if save_err != OK:
		push_error("ResourceSaver.save failed: %s (%s)" % [scn_path, error_string(save_err)])
		return false

	var hf := FileAccess.open(hash_path, FileAccess.WRITE)
	if hf != null:
		hf.store_string(expected_hash)
		hf.close()
	Log.info("[BlenderMap] Saved %s.scn" % map_name)
	return true


static func _assign_ownership(node: Node, scene_owner: Node) -> void:
	for child in node.get_children():
		if child != scene_owner:
			child.owner = scene_owner
		_assign_ownership(child, scene_owner)


static func _sha256_file(abs_path: String) -> String:
	var f := FileAccess.open(abs_path, FileAccess.READ)
	if f == null:
		return ""
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	const CHUNK := 1 << 20
	while not f.eof_reached():
		ctx.update(f.get_buffer(CHUNK))
	f.close()
	return ctx.finish().hex_encode()
