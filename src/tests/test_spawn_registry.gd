extends "res://src/tests/test_base.gd"
## What /spawn will answer to, and the weapon half of it end to end: the registry derived from
## the scripts themselves, the spellbook pickup that hands a weapon out, and a grant surviving a
## loadout rebuild (a bear revert or a dismount rebuilds weapons[] from the Wizard, which is where
## a naive grant would evaporate).
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.

const ItemWeaponScript = preload("res://src/entities/item_weapon.gd")


func _book(weapon_key := "comet_weapon") -> ItemWeapon:
	var b := ItemWeaponScript.new()
	b.set_meta("entity", {"classname": "item_weapon", "weapon": weapon_key, "angles": "0 0 0"})
	_root().add_child(b)
	_spawned.append(b)
	return b


## An undecided book: classname combo_weapon with no weapon key, or a weapon key of "combo".
func _combo_book(weapon_key := "") -> ItemWeapon:
	var b := ItemWeaponScript.new()
	b.set_meta("entity", {"classname": "combo_weapon", "weapon": weapon_key, "angles": "0 0 0"})
	_root().add_child(b)
	_spawned.append(b)
	return b


## Stand-in for the player: _try_give only asks for grant_weapon/is_dead/peer_id.
class _Picker:
	extends CharacterBody3D
	var is_dead := false
	var peer_id := 0  # 0 keeps the pickup from trying to chat at a peer that isn't there
	var granted: Array[String] = []

	func grant_weapon(key: String) -> bool:
		if key in granted:
			return false
		granted.append(key)
		return true


func _picker() -> _Picker:
	var p := _Picker.new()
	var col := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.4
	capsule.height = 1.8
	col.shape = capsule
	col.position = Vector3(0, 0.9, 0)
	p.add_child(col)
	_root().add_child(p)
	_spawned.append(p)
	return p


# --- registry ---

func test_registry_covers_the_wizard_loadouts() -> void:
	var names := SpawnRegistry.weapon_names()
	assert_gt(names.size(), 30, "every weapon a wizard carries is registered")
	for expected in ["comet_weapon", "fireball_weapon", "missile_weapon", "fire_staff_weapon"]:
		assert_true(expected in names, "%s can be given" % expected)


## Any weapon script can be given, whether or not a wizard or recipe hands it out; bases can't.
func test_every_weapon_script_is_registered() -> void:
	var names := SpawnRegistry.weapon_names()
	for expected in ["skeleton_weapon", "dragon_breath_weapon"]:
		assert_true(expected in names, "%s can be given" % expected)
	for base in ["weapon", "staff", "ray_weapon"]:
		assert_false(base in names, "%s is a base class, not a weapon" % base)
	assert_false(SpawnRegistry.is_combo_weapon("skeleton_weapon"), "not in the combo pool")
	assert_true(SpawnRegistry.build_weapon("skeleton_weapon") != null, "and it builds")


## One name per thing, and it is the script's file name in both halves: the spell that flies is
## "comet", the spell you cast it with is "comet_weapon". No aliases to keep in step.
func test_one_name_per_thing() -> void:
	assert_true(SpawnRegistry.has_object("comet"), "the projectile")
	assert_false(SpawnRegistry.has_weapon("comet"), "which is not the weapon")
	assert_true(SpawnRegistry.has_weapon("comet_weapon"), "the weapon")
	assert_false(SpawnRegistry.has_object("comet_weapon"), "which is not a thing in the world")
	assert_false(SpawnRegistry.has_weapon("CometWeapon"), "no second spelling")
	assert_false(SpawnRegistry.has_weapon("trebuchet"), "and nothing invented")


## The split is the script's own base type, so a new spell needs no bookkeeping here.
func test_objects_and_weapons_are_told_apart_by_base_type() -> void:
	var objects := SpawnRegistry.object_names()
	for expected in ["comet", "fireball", "ice_shard", "satchel", "thornplant", "rolling_stone"]:
		assert_true(expected in objects, "%s is a thing in the world" % expected)
	for not_object in ["comet_weapon", "fire_staff_weapon", "weapon"]:
		assert_false(not_object in objects, "%s is a Resource, not a node" % not_object)
	# No setup() means the spawner has no way to configure it, so it is not offered.
	assert_false("trail_fader" in objects, "helper meshes are not spawnable")
	assert_false("comet_explosion_effect" in objects, "nor effects with no spawn contract")
	assert_ne(SpawnRegistry.object_script_path("comet"), "", "and a name resolves to its script")


## A summon's death burst is a one-shot push over sync_entity_state, and that push only leaves the
## server when the entity was given a network id at spawn. /spawn asked for none, so a /spawn'd
## skeleton died gibless everywhere but a listen host, where the death effect runs locally anyway.
func test_state_pushing_objects_are_known_from_their_scripts() -> void:
	assert_true(SpawnRegistry.object_syncs_state("skeleton"), "its death is a one-shot push")
	assert_true(SpawnRegistry.object_syncs_state("thornplant"), "so are its growth and bites")
	assert_true(SpawnRegistry.object_syncs_state("wombat"), "and the wombat's death burst")
	assert_false(SpawnRegistry.object_syncs_state("fireball"), "a fireball pushes nothing")
	assert_false(SpawnRegistry.object_syncs_state("not_a_real_object"), "an unknown name pushes nothing")


func test_built_weapon_is_dressed_like_the_wizard_dresses_it() -> void:
	var w := SpawnRegistry.build_weapon("comet_weapon")
	assert_true(w is CometWeapon, "right class")
	# The wizard, not the weapon, owns the viewmodel — a bare CometWeapon.new() has none.
	assert_eq(w.hand_model_path, "models/hands/archmage.mdl", "archmage hands, as ArchmageWizard sets")
	assert_eq(w.player_attack_prefix, "combo", "and its 3P attack animation")
	assert_gt(w.mana_cost, 0.0, "keeping the weapon's own costs")


## Fire and Nature, not Fire and Ice: Ice and Wind cast the mind missile instead, so neither has
## a magic-missile recipe to build from any more.
func test_shared_weapons_follow_the_receiver_element() -> void:
	var fire := SpawnRegistry.build_weapon("missile_weapon", GameConsts.Element.FIRE)
	var nature := SpawnRegistry.build_weapon("missile_weapon", GameConsts.Element.NATURE)
	assert_eq(fire.hand_model_path, "models/hands/fire.mdl", "fire wizard's missile")
	assert_eq(nature.hand_model_path, "models/hands/nature.mdl", "nature wizard's missile")
	assert_eq(nature.element, GameConsts.Element.NATURE, "and its element")

	var ice := SpawnRegistry.build_weapon("mind_missile_weapon", GameConsts.Element.ICE)
	assert_eq(ice.hand_model_path, "models/hands/ice.mdl", "and the ice wizard's is the mind one")


func test_each_build_is_a_fresh_weapon() -> void:
	var a := SpawnRegistry.build_weapon("comet_weapon")
	var b := SpawnRegistry.build_weapon("comet_weapon")
	assert_ne(a.get_instance_id(), b.get_instance_id(),
		"two players holding a comet must not share one Weapon's per-shot state")
	assert_eq(SpawnRegistry.build_weapon("trebuchet"), null, "unknown weapons build nothing")


# --- grant bookkeeping on the player ---

func _wizard_player(element := GameConsts.Element.FIRE) -> Player:
	# Never entered into the tree: _ready wants a live server, and none of the loadout
	# bookkeeping under test touches it.
	var p := Player.new()
	p.element = element
	p.weapons = Wizard.create(element).weapons
	return p


func test_granted_weapon_lands_in_the_loadout() -> void:
	var p := _wizard_player()
	var before := p.weapons.size()
	assert_true(p.add_granted_weapon("comet_weapon"), "granted")
	assert_eq(p.weapons.size(), before + 1, "appended, so existing slot indices don't move")
	assert_true(p.weapon_at(before) is CometWeapon, "and it's the weapon asked for")
	assert_false(p.add_granted_weapon("comet_weapon"), "granting it twice is a no-op")
	assert_eq(p.weapons.size(), before + 1, "no duplicate slot")
	p.free()


func test_grant_survives_a_loadout_rebuild() -> void:
	var p := _wizard_player()
	p.add_granted_weapon("comet_weapon")
	# What a bear revert / dragon dismount does: rebuild from the Wizard.
	p.weapons = p.with_granted(Wizard.create(p.element).weapons)
	var found := false
	for w in p.weapons:
		found = found or w is CometWeapon
	assert_true(found, "the pickup outlives the morph that rebuilt the loadout")
	p.free()


func test_unknown_grant_is_refused() -> void:
	var p := _wizard_player()
	var before := p.weapons.size()
	assert_false(p.add_granted_weapon("trebuchet"), "unknown key")
	assert_eq(p.weapons.size(), before, "loadout untouched")
	assert_true(p.granted_weapons.is_empty(), "and nothing recorded to replay later")
	p.free()


# --- the spellbook pickup ---

func test_walking_over_the_book_grants_the_weapon() -> void:
	var b := _book("comet_weapon")
	var p := _picker()
	assert_true(b._try_give(p), "picked up")
	assert_eq(p.granted, ["comet_weapon"] as Array[String], "and the weapon handed over")


func test_a_dead_body_takes_nothing() -> void:
	var b := _book()
	var p := _picker()
	p.is_dead = true
	assert_false(b._try_give(p), "a corpse sliding over the book leaves it")


func test_book_stays_for_someone_who_needs_it() -> void:
	var b := _book("comet_weapon")
	var p := _picker()
	p.granted.append("comet_weapon")  # already carries it
	assert_false(b._try_give(p), "no second copy, and the book isn't consumed")


func test_unknown_weapon_key_frees_the_book() -> void:
	var b := _book("trebuchet")
	assert_true(b.is_queued_for_deletion(), "a book with no spell in it doesn't linger")


## The tests above call _try_give directly; this one goes through the real Area3D so the
## collision mask and box size are covered too.
func test_the_touch_area_sees_a_player_standing_on_the_book() -> void:
	var b := _book("comet_weapon")
	b.global_position = Vector3.ZERO
	var p := _picker()
	p.collision_layer = GameConsts.MASK_PLAYER
	p.global_position = Vector3(0, 0.2, 0)
	var tree := Engine.get_main_loop() as SceneTree
	await tree.physics_frame
	await tree.physics_frame
	b._touch.drops_to_floor = false  # no world geometry in the test scene to drop onto
	b._touch._poll_accum = TouchBehavior.POLL_INTERVAL
	b._physics_process(0.0)
	assert_eq(p.granted, ["comet_weapon"] as Array[String], "the touch area saw the player")


# --- the combo book ---

## The pool is derived from Wizard.pickup_weapons(), so it is exactly the spells no class is
## born with — never a class spell, and never a name the registry can't build.
func test_combo_pool_is_the_pickup_only_spells() -> void:
	var combos := SpawnRegistry.combo_weapon_names()
	for expected in ["giant_plant_weapon", "tornado_weapon", "ball_lightning_weapon",
			"lightning_cloud_weapon", "spirit_wiz_weapon", "meteor_weapon", "wombat_weapon",
			"raise_dead_weapon"]:
		assert_true(expected in combos, "%s is a combo spell" % expected)
	for class_spell in ["comet_weapon", "fireball_weapon", "missile_weapon", "fire_staff_weapon"]:
		assert_false(class_spell in combos, "%s is a class spell, not a combo" % class_spell)
	for combo in combos:
		assert_true(SpawnRegistry.has_weapon(combo), "%s is a weapon that can be built" % combo)


## The book decides what it is when it spawns, and it is always something real.
func test_combo_book_rolls_a_real_combo_spell() -> void:
	var combos := SpawnRegistry.combo_weapon_names()
	var seen := {}
	for i in 40:
		var b := _combo_book("combo" if i % 2 else "")  # both spellings of "undecided"
		assert_true(b._weapon_key in combos, "rolled a combo spell, got '%s'" % b._weapon_key)
		assert_false(b.is_queued_for_deletion(), "and the book kept it")
		seen[b._weapon_key] = true
	assert_gt(seen.size(), 1, "and not the same spell every time")


func test_combo_book_grants_what_it_rolled() -> void:
	var b := _combo_book()
	var p := _picker()
	assert_true(b._try_give(p), "picked up")
	assert_eq(p.granted, [b._weapon_key] as Array[String], "handed over the spell it rolled")


# --- command-line keyvalues ---

## /spawn hands an object's setup() its keyvalues, and setup() assigns them into typed fields.
func test_keyvalues_come_back_typed() -> void:
	var typed: Variant = CommandSystem._typed_keyvalues({"dmg": "10", "speed": "12.5", "model": "x.mdl"})
	assert_true(typed is Dictionary, "parsed")
	assert_eq(typeof(typed["dmg"]), TYPE_INT, "a whole number is an int, not 10.0")
	assert_eq(typeof(typed["speed"]), TYPE_FLOAT, "a decimal stays a float")
	assert_eq(typed["model"], "x.mdl", "anything else is left alone")


## The teleport satchel is the ice one, and "ice" is how /addbot spells it too.
func test_element_takes_a_name_or_a_number() -> void:
	var by_name: Variant = CommandSystem._typed_keyvalues({"element": "ice"})
	assert_eq(by_name["element"], GameConsts.Element.ICE, "named element resolves")
	var by_id: Variant = CommandSystem._typed_keyvalues({"element": "5"})
	assert_eq(by_id["element"], GameConsts.Element.ICE, "and the raw id still works")
	assert_true(CommandSystem._typed_keyvalues({"element": "banana"}) is String,
		"a bad element name is reported, not passed into a typed int field")
