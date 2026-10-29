extends "res://src/tests/test_base.gd"
## A map entity spawned at runtime has no brushwork, and half the entity table is built around
## some. Both places an entity asks for its brush fall back to a default box rather than handing
## back null — /spawn trigger_hurt with no size crashed on `_area.body_entered` before this.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.

const TriggerHurtScript = preload("res://src/entities/trigger_hurt.gd")
const FuncDoorScript = preload("res://src/entities/func_door.gd")


## Built the way main._spawn_dyn_entity builds one: the importer's node type, the keyvalue
## dictionary as meta, and the tag that marks it spawner-created.
func _spawn(script: GDScript, keys := {}, size := 0.0) -> Node3D:
	var node := AnimatableBody3D.new()
	node.set_script(script)
	node.sync_to_physics = false
	node.set_meta("_dyn_spawner_entity", true)
	var ent := {"classname": "test_entity", "angles": "0 0 0"}
	ent.merge(keys, true)
	node.set_meta("entity", ent)
	if size > 0.0:
		GoldSrcEntity.build_brush_stand_in(node, size)
	_root().add_child(node)
	_spawned.append(node)
	return node


func test_trigger_spawned_without_a_size_still_gets_a_volume() -> void:
	var trigger := _spawn(TriggerHurtScript, {"dmg": "10"})
	var volume := trigger.get_node_or_null("Volume") as Area3D
	assert_ne(volume, null, "the ask built the volume that wasn't there")
	assert_eq(trigger._area, volume, "and the trigger holds it, instead of null")
	assert_eq(trigger.collision_layer, 0, "a trigger is not solid")


func test_a_sized_trigger_keeps_the_size_it_was_given() -> void:
	var trigger := _spawn(TriggerHurtScript, {"dmg": "10"}, 128.0)
	var shape: CollisionShape3D = trigger.get_node("Volume").get_child(0)
	assert_almost_eq((shape.shape as BoxShape3D).size.x, 128.0 * GameConsts.SCALE_FACTOR, 0.001,
		"no fallback when the spawn asked for a size")


func test_the_default_box_is_only_for_spawned_entities() -> void:
	# A map-placed entity with no Volume is an import bug, and must keep reporting itself as one.
	var orphan := AnimatableBody3D.new()
	_root().add_child(orphan)
	_spawned.append(orphan)
	assert_eq(GoldSrcEntity.use_volume_as_trigger(orphan, GameConsts.MASK_PLAYER), null,
		"no brush conjured for something the BSP was supposed to supply")


func test_mover_spawned_without_a_size_measures_a_default_box() -> void:
	var door := _spawn(FuncDoorScript)
	var aabb: AABB = door._compute_brush_aabb()
	assert_almost_eq(aabb.size.x, GoldSrcEntity.DEFAULT_BRUSH_SIZE * GameConsts.SCALE_FACTOR, 0.001,
		"a door with no brush is a default-size door, not a zero-size one")
	assert_gt(aabb.size.y, 0.0, "with real extent to travel and to block against")
