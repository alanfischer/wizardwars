extends "res://src/tests/test_base.gd"
## What a dying wizard leaves behind. The rule gameplay depends on is the threshold: under
## GameConsts.GIB_DAMAGE there is a body in the "corpses" group for Grimfeast to eat and Raise Dead
## to take, and over it there is nothing where the wizard was standing. This covers the OFFLINE
## branch, where the corpse is built on this peer rather than replicated.


func _corpse_count() -> int:
	return (Engine.get_main_loop() as SceneTree).get_nodes_in_group("corpses").size()


func test_a_normal_death_leaves_a_body_in_the_corpses_group() -> void:
	var root := _keep(Node3D.new())
	_root().add_child(root)
	var before := _corpse_count()
	TumblingCorpse.spawn_wizard_remains(root, Vector3.ZERO, 0.0, GameConsts.Element.FIRE,
		Vector3.ZERO, PackedFloat32Array(), 10.0)
	assert_eq(_corpse_count(), before + 1, "one corpse, raisable")
	assert_eq(root.get_child_count(), 1, "parented to the root it was handed")


func test_a_bursting_death_leaves_nothing_to_raise() -> void:
	var root := _keep(Node3D.new())
	_root().add_child(root)
	var before := _corpse_count()
	TumblingCorpse.spawn_wizard_remains(root, Vector3.ZERO, 0.0, GameConsts.Element.FIRE,
		Vector3.ZERO, PackedFloat32Array(), GameConsts.GIB_DAMAGE + 50.0)
	assert_eq(_corpse_count(), before, "gibs are not a corpse")
	assert_eq(root.get_child_count(), 0, "and nothing was parented")


func test_no_scene_to_build_in_is_survivable() -> void:
	# A death during a map teardown has nowhere to put a body; it must not take the frame with it.
	TumblingCorpse.spawn_wizard_remains(null, Vector3.ZERO, 0.0, GameConsts.Element.FIRE,
		Vector3.ZERO, PackedFloat32Array(), 10.0)
	assert_true(true, "returned instead of erroring")
