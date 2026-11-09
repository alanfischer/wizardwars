extends "res://src/tests/test_base.gd"
## What goldsrc-godot's MDL build must keep while it shrinks the scene: skins keep their mip
## chain (without one a wizard across the map is a crawl of aliased texels), and a clip whose
## keys were cut still starts on frame 0 and ends on its last frame, so nothing is truncated.
## And what build_scene() hands over: the sequences and skin families as metadata, which a
## team skin takes in the same lit material as the base skin.

const MODEL := "res://models/player/death.mdl"


func test_skins_keep_their_mip_chain() -> void:
	var root := (load(MODEL) as PackedScene).instantiate()
	var checked := 0
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		var mesh: Mesh = (mi as MeshInstance3D).mesh
		for s in mesh.get_surface_count():
			var mat := mesh.surface_get_material(s) as BaseMaterial3D
			if mat == null or mat.albedo_texture == null:
				continue
			var img := mat.albedo_texture.get_image()
			assert_true(img != null and img.has_mipmaps(), "%s surface %d skin has mipmaps" % [mi.name, s])
			checked += 1
	assert_gt(checked, 0, "the model has skinned surfaces")
	root.free()


func test_cut_clips_span_every_frame() -> void:
	var mdl := GoldSrcMDL.new()
	assert_eq(mdl.load_mdl(MODEL), OK, "model loads")
	var root := mdl.build_scene()
	var lib := (root.find_child("AnimationPlayer", false, false) as AnimationPlayer).get_animation_library(&"")
	var keys := 0
	var frames := 0
	for i in mdl.get_sequence_count():
		var anim_name := mdl.get_sequence_name(i).replace(" ", "_").replace("/", "_").to_lower()
		assert_true(lib.has_animation(anim_name), "sequence %d is clip %s" % [i, anim_name])
		if not lib.has_animation(anim_name):
			continue
		var anim := lib.get_animation(anim_name)
		var last_frame := (mdl.get_sequence_num_frames(i) - 1) / mdl.get_sequence_fps(i)
		for t in anim.get_track_count():
			var n := anim.track_get_key_count(t)
			keys += n
			frames += mdl.get_sequence_num_frames(i)
			assert_almost_eq(anim.track_get_key_time(t, 0), 0.0, 1e-5, "%s track %d starts on frame 0" % [anim_name, t])
			if n > 1:
				assert_almost_eq(anim.track_get_key_time(t, n - 1), last_frame, 1e-4,
					"%s track %d ends on its last frame" % [anim_name, t])
	@warning_ignore("integer_division")
	assert_lt(keys, frames / 2, "most per-frame keys are cut")
	root.free()


func test_scene_carries_sequences_and_skins() -> void:
	var mdl := GoldSrcMDL.new()
	assert_eq(mdl.load_mdl(MODEL), OK, "model loads")
	var root := mdl.build_scene()
	assert_almost_eq(root.rotation_degrees.y, 90.0, 1e-4, "turned to face the game's way")
	var sequences: Array = root.get_meta("sequences", [])
	assert_eq(sequences.size(), mdl.get_sequence_count(), "one entry per sequence")
	if not sequences.is_empty():
		assert_eq(sequences[0].name, mdl.get_sequence_name(0), "in the file's order")
	assert_eq(root.get_meta("skin_count", 0), 5, "the wizard's five skin families")
	var skinned := 0
	for mi: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
		if not mi.has_meta("skin_1"):
			continue
		skinned += 1
		for family in range(1, 5):
			var mats: Array = mi.get_meta("skin_%d" % family, [])
			assert_eq(mats.size(), mi.get_surface_override_material_count(), "%s skin_%d: a material per surface" % [mi.name, family])
		assert_false(mi.has_meta("skin_5"), "no family past skin_count")
	assert_gt(skinned, 0, "the skinned meshes carry the other families")
	assert_true(root.find_children("*", "", true, false).all(func(n): return n.owner == root), "owned by the root, so it packs")
	assert_true(mdl.build_scene() == null, "once per load")
	root.free()


## A team skin must be lit like the base skin: the map's ambient cube, not Godot's lights.
func test_team_skins_take_the_acube_material() -> void:
	var mdl := GoldSrcMDL.new()
	assert_eq(mdl.load_mdl(MODEL), OK, "model loads")
	var root := mdl.build_scene()
	var converted := 0
	for mi: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
		AssetLoader._convert_skin_metas(mi, 2.0)
		for family in range(1, 5):
			for mat in mi.get_meta("skin_%d" % family, []):
				if mat == null:
					continue
				assert_true(mat is ShaderMaterial, "%s skin_%d is the ambient cube material" % [mi.name, family])
				converted += 1
	assert_gt(converted, 0, "the team skins were converted")
	root.free()
