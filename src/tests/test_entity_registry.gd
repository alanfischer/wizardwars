extends "res://src/tests/test_base.gd"
## The classname table EntityRegistry builds. It used to be a member of main.gd that main._ready
## then mutated to add the deathmatch pickups, so "is the table complete?" depended on main having
## run. It is static now, built on first touch, and these are the properties that depended on that
## mutation: /spawn's list and the weapon_*/ammo_* classnames our converted DM maps still place.

const EntityRegistry = preload("res://src/entities/entity_registry.gd")


func test_brush_and_point_classnames_resolve() -> void:
	assert_true(EntityRegistry.has("func_door"), "a brush entity")
	assert_true(EntityRegistry.has("trigger_golem"), "a point entity")
	assert_false(EntityRegistry.has("worldspawn"), "worldspawn is the map, not an entity script")
	assert_eq(EntityRegistry.script_for("nonsuch_entity"), null, "an unknown classname binds nothing")


func test_deathmatch_pickups_are_folded_in() -> void:
	# ItemDmPickup owns the list; the table has to pick it up without anyone calling a setup step.
	assert_gt(ItemDmPickup.CLASSNAMES.size(), 0, "ItemDmPickup still declares its classnames")
	for cn in ItemDmPickup.CLASSNAMES:
		assert_eq(EntityRegistry.script_for(cn), ItemDmPickup, "%s binds ItemDmPickup" % cn)


func test_classnames_are_sorted_and_cover_the_table() -> void:
	var names: Array = EntityRegistry.classnames()
	assert_gt(names.size(), ItemDmPickup.CLASSNAMES.size(), "more than just the DM pickups")
	var sorted_copy := names.duplicate()
	sorted_copy.sort()
	assert_eq(names, sorted_copy, "/spawnlist shows them in order")
	assert_true(names.has("item_weapon"), "the book /spawn drops for a weapon is spawnable too")
