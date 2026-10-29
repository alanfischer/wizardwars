extends "res://src/tests/test_base.gd"
## A first-person viewmodel is never a target, but MDL hand models ship 6-15 per-bone hitbox
## Area3Ds on MASK_HITBOX. Parented to the camera, they sit right on the caster's own ray, and
## a listen host's view is not in the "damageable" group that collect_hitscan_excludes() scans —
## so the host's beams landed on their own hand. take_damage() ignores a non-damageable node;
## heal() does not, which is why only the life ray showed it (as self-overheal).


## Stand-in for a loaded MDL: Skeleton3D -> BoneAttachment3D -> Area3D(hitbox) -> shape,
## which is exactly what GoldSrcMDL::build_hitboxes() produces.
func _model(hitbox_count: int) -> Node3D:
	var root := Node3D.new()
	var skel := Skeleton3D.new()
	root.add_child(skel)
	var mesh := MeshInstance3D.new()
	mesh.name = "Body"
	skel.add_child(mesh)
	for i in hitbox_count:
		var attach := BoneAttachment3D.new()
		attach.name = "Hitbox_%d" % i
		skel.add_child(attach)
		var area := Area3D.new()
		area.collision_layer = GameConsts.MASK_HITBOX
		area.set_meta("hitbox_group", 0)
		attach.add_child(area)
		var cs := CollisionShape3D.new()
		cs.shape = BoxShape3D.new()
		area.add_child(cs)
	return root


func test_hitboxes_are_stripped() -> void:
	var model := _model(14)  # models/hands/life.mdl ships exactly this many
	assert_eq(_count_hitboxes(model), 14, "the stand-in starts with the hand model's hitboxes")
	AssetLoader.strip_hitboxes(model)
	assert_eq(_count_hitboxes(model), 0, "a viewmodel keeps none of them")
	model.free()


func test_visuals_survive() -> void:
	var model := _model(3)
	AssetLoader.strip_hitboxes(model)
	assert_ne(model.find_child("Body", true, false), null, "stripping hit volumes keeps the mesh")
	model.free()


func test_empty_bone_attachments_go_with_them() -> void:
	var model := _model(3)
	AssetLoader.strip_hitboxes(model)
	assert_eq(model.find_child("Hitbox_0", true, false), null,
		"the BoneAttachment3D that only carried a hitbox costs bone updates for nothing")
	model.free()


func test_model_without_hitboxes_is_untouched() -> void:
	var model := _model(0)
	AssetLoader.strip_hitboxes(model)
	assert_ne(model.find_child("Body", true, false), null, "a hitbox-free model survives intact")
	model.free()
