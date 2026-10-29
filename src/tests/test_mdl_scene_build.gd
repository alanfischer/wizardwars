extends "res://src/tests/test_base.gd"
## What goldsrc-godot's MDL build must keep while it shrinks the scene: skins keep their mip
## chain (without one a wizard across the map is a crawl of aliased texels), and a clip whose
## keys were cut still starts on frame 0 and ends on its last frame, so nothing is truncated.

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
	mdl.build_model()
	var lib := (mdl.find_child("AnimationPlayer", false, false) as AnimationPlayer).get_animation_library(&"")
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
	assert_lt(keys, frames / 2, "most per-frame keys are cut")
	mdl.free()
