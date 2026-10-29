extends "res://src/tests/test_base.gd"
## Combo chaos: what a converted deathmatch map's leftover weapon_*/ammo_* pickups turn into.
## The map declares the style on its info_wwdetect, the server gets the last word, and the
## pickup dresses itself accordingly — a random combo spellbook, or mana.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.

const InfoTFDetectScript = preload("res://src/entities/info_tfdetect.gd")
const ItemDmPickupScript = preload("res://src/entities/item_dm_pickup.gd")
const TFGoalBaseScript = preload("res://src/entities/tf_goal_base.gd")
const PlayerScript = preload("res://src/player.gd")


func _teardown_test() -> void:
	_cleanup()


func _detect(keys: Dictionary) -> Node:
	var d := InfoTFDetectScript.new()
	d.set_meta("entity", keys)
	_root().add_child(d)
	_spawned.append(d)
	return d


func _pickup(classname := "weapon_357") -> ItemDmPickup:
	var p := ItemDmPickupScript.new()
	p.set_meta("entity", {"classname": classname, "angles": "0 0 0"})
	_root().add_child(p)
	_spawned.append(p)
	return p


## Stand-in for the player, naming its fields the way Player does: a pickup and a resupply goal
## both reach for grant_weapon/granted_weapons/add_mana/add_satchels/mana/is_dead.
class _Picker:
	extends CharacterBody3D
	var is_dead := false
	var peer_id := 0  # 0 keeps the pickup from trying to chat at a peer that isn't there
	var mana := 0.0
	var max_mana := 100.0
	var satchels := 0
	var granted_weapons: Array[String] = []

	func grant_weapon(key: String) -> bool:
		if key in granted_weapons:
			return false
		granted_weapons.append(key)
		return true

	func add_mana(amount: float) -> void:
		mana = minf(mana + amount, max_mana)

	func add_satchels(amount: int) -> void:
		satchels += amount


## A TFC resupply backpack that hands out grenades — an info_tfgoal with no_grenades_1/2, which
## tf_goal_base folds into satchel_amount. Every map but ww_varrock has a few.
func _grenade_pack(satchels := 2) -> Node:
	var g: Node3D = TFGoalBaseScript.new()
	g.satchel_amount = satchels
	_root().add_child(g)
	_spawned.append(g)
	return g


func _picker(mana := 0.0) -> _Picker:
	var p := _Picker.new()
	p.mana = mana
	_root().add_child(p)
	_spawned.append(p)
	return p


## A pickup dresses itself a frame after it spawns (see ItemDmPickup._ready), so the map has
## finished declaring its style by then.
func _frame() -> void:
	await (Engine.get_main_loop() as SceneTree).process_frame


func _style(value: String) -> void:
	var r := ServerVars.set_from_string("combo_chaos", value)
	assert_true(r["ok"], "combo_chaos accepts '%s'" % value)


func _cleanup() -> void:
	for n in _spawned:
		if is_instance_valid(n):
			n.free()
	_spawned.clear()
	GoalSystem.reset()
	ServerVars.set_from_string("combo_chaos", "auto")


# --- who decides the style ---

func test_the_map_declares_it() -> void:
	assert_false(GoalSystem.is_combo_chaos(), "off until a map asks")
	_detect({"classname": "info_wwdetect", "combo_chaos": "1"})
	assert_true(GoalSystem.map_combo_chaos, "the key read off the rules entity")
	assert_true(GoalSystem.is_combo_chaos(), "and honoured while the server says auto")


## Every other map keeps its pickups as mana — including one that spells the key out as off.
func test_maps_that_do_not_ask_get_mana() -> void:
	_detect({"classname": "info_wwdetect", "team1_name": "Blue"})
	assert_false(GoalSystem.is_combo_chaos(), "a rules entity that never mentions it")
	_cleanup()
	_detect({"classname": "info_tfdetect", "combo_chaos": "0"})
	assert_false(GoalSystem.is_combo_chaos(), "or says it outright")


func test_the_server_gets_the_last_word() -> void:
	_style("on")
	assert_true(GoalSystem.is_combo_chaos(), "forced on over a map that never asked")
	_detect({"classname": "info_wwdetect", "combo_chaos": "1"})
	_style("off")
	assert_false(GoalSystem.is_combo_chaos(), "and forced off over a map that did")
	_style("auto")
	assert_true(GoalSystem.is_combo_chaos(), "auto hands the decision back to the map")


func test_a_new_map_starts_over() -> void:
	_detect({"classname": "info_wwdetect", "combo_chaos": "1"})
	GoalSystem.reset()
	assert_false(GoalSystem.map_combo_chaos, "the flag doesn't follow us to the next map")


# --- what the pickup becomes ---

func test_a_gun_pours_mana_when_chaos_is_off() -> void:
	var p := _picker(20.0)
	var gun := _pickup("weapon_357")
	await _frame()
	assert_true(gun._try_give(p), "taken")
	assert_eq(p.mana, 20.0 + ItemDmPickupScript.WEAPON_MANA, "a gun is the big prize")
	assert_true(p.granted_weapons.is_empty(), "and no spell changes hands")


func test_an_ammo_box_is_a_sip() -> void:
	var p := _picker(20.0)
	var box := _pickup("ammo_buckshot")
	await _frame()
	assert_true(box._try_give(p), "taken")
	assert_eq(p.mana, 20.0 + ItemDmPickupScript.AMMO_MANA, "less than a gun")


## GoldSrc's rule for health, applied to mana: no room means the pickup isn't consumed.
func test_a_full_wizard_leaves_it_standing() -> void:
	var p := _picker(100.0)
	var gun := _pickup("weapon_357")
	await _frame()
	assert_false(gun._try_give(p), "nothing to take")


func test_chaos_turns_it_into_a_spellbook() -> void:
	_style("on")
	var combos := SpawnRegistry.combo_weapon_names()
	var seen := {}
	for i in 30:
		var p := _picker(0.0)
		var book := _pickup("ammo_buckshot")
		await _frame()
		assert_true(book._try_give(p), "taken")
		assert_eq(p.mana, 0.0, "a book is not mana")
		assert_eq(p.granted_weapons.size(), 1, "one spell handed over")
		assert_true(p.granted_weapons[0] in combos, "and it's a combo spell, got '%s'" % p.granted_weapons[0])
		seen[p.granted_weapons[0]] = true
	assert_gt(seen.size(), 1, "not the same spell every time")


func test_a_dead_body_takes_nothing() -> void:
	var p := _picker(0.0)
	p.is_dead = true
	var gun := _pickup("weapon_357")
	await _frame()
	assert_false(gun._try_give(p), "a corpse sliding over it")
	assert_eq(p.mana, 0.0, "and no mana either")


## Flipping the style mid-map re-dresses what's already lying on the ground.
func test_flipping_the_style_redresses_a_live_pickup() -> void:
	var book := _pickup("weapon_357")
	await _frame()
	assert_false(book._chaos, "starts as mana")
	_style("on")
	assert_true(book._chaos, "and became a spellbook without respawning")
	var p := _picker(0.0)
	assert_true(book._try_give(p), "taken")
	assert_eq(p.granted_weapons.size(), 1, "as a spell, not mana")


## Respawning is where the spell is rolled again, so a map doesn't settle into one spell.
func test_respawning_rolls_again() -> void:
	_style("on")
	var book := _pickup("weapon_357")
	await _frame()
	var seen := {}
	for i in 30:
		book._touch.available = false
		book._touch._respawn()
		seen[book._weapon_key] = true
	assert_true(book._touch.available, "back on the ground")
	assert_gt(seen.size(), 1, "and not always holding the same spell")


## The rules entity is a node like any other, and in ww_varrock it is the last one on the map —
## a pickup that dressed itself in its own _ready would be mana on a map that asked for chaos.
func test_a_pickup_waits_for_the_map_to_declare_its_style() -> void:
	var book := _pickup("ammo_buckshot")  # spawns first, like varrock's 84 pickups
	_detect({"classname": "info_wwdetect", "combo_chaos": "1"})  # the map speaks up afterwards
	await _frame()
	assert_true(book._chaos, "dressed against the style the map actually asked for")


# --- resupply backpacks ---

func test_a_grenade_pack_is_grenades_when_chaos_is_off() -> void:
	var p := _picker()
	_grenade_pack(2)._apply_mana_and_satchels(p)
	assert_eq(p.satchels, 2, "the backpack's grenades, as satchels")
	assert_true(p.granted_weapons.is_empty(), "and no spell")


func test_chaos_turns_a_grenade_pack_into_a_spell() -> void:
	_style("on")
	var combos := SpawnRegistry.combo_weapon_names()
	var seen := {}
	for i in 30:
		var p := _picker()
		_grenade_pack(2)._apply_mana_and_satchels(p)
		assert_eq(p.satchels, 0, "grenades traded away, not handed over as well")
		assert_eq(p.granted_weapons.size(), 1, "one spell handed over")
		assert_true(p.granted_weapons[0] in combos, "a combo spell, got '%s'" % p.granted_weapons[0])
		seen[p.granted_weapons[0]] = true
	assert_gt(seen.size(), 1, "not the same spell every time")


## A backpack can't leave the book on the ground for someone else the way item_dm_pickup can, so
## the roll has to skip what the toucher is already carrying rather than come up empty.
func test_a_grenade_pack_never_rolls_what_you_already_hold() -> void:
	_style("on")
	var combos := SpawnRegistry.combo_weapon_names()
	for i in 30:
		var p := _picker()
		p.granted_weapons.append(combos[0])
		_grenade_pack(2)._apply_mana_and_satchels(p)
		assert_eq(p.granted_weapons.size(), 2, "a second, different spell")
		assert_ne(p.granted_weapons[1], combos[0], "never the one already held")


## Once every combo spell is spoken for there is nothing left to roll, and the backpack goes back
## to being a backpack rather than silently giving nothing.
func test_a_grenade_pack_falls_back_to_grenades_when_the_pool_is_spent() -> void:
	_style("on")
	var p := _picker()
	for name in SpawnRegistry.combo_weapon_names():
		p.granted_weapons.append(name)
	_grenade_pack(2)._apply_mana_and_satchels(p)
	assert_eq(p.satchels, 2, "grenades after all")


## A backpack that resupplies both keeps pouring mana; only the grenade half is traded.
func test_only_the_grenade_half_is_traded() -> void:
	_style("on")
	var p := _picker()
	var pack := _grenade_pack(2)
	pack.mana_amount = 30
	pack._apply_mana_and_satchels(p)
	assert_eq(p.mana, 30.0, "mana still pours")
	assert_eq(p.granted_weapons.size(), 1, "and the grenades became a spell")


# --- one combo spell at a time ---

func test_a_second_book_displaces_the_first() -> void:
	var combos := SpawnRegistry.combo_weapon_names()
	assert_gt(combos.size(), 1, "there are at least two combo spells to swap between")
	var p := _wizard()
	var base := p.weapons.size()
	assert_true(p.add_granted_weapon(combos[0]), "first book")
	assert_true(p.add_granted_weapon(combos[1]), "second book")
	assert_eq(p.granted_weapons, [combos[1]], "only the newer one is still carried")
	assert_eq(p.weapons.size(), base + 1, "and it holds a single grant slot")
	assert_eq(p.combo_weapons_held(), [combos[1]], "which is what the player is holding")


## The displaced book only takes its own slot with it — a spell picked up some other way stays.
func test_displacing_a_book_leaves_other_grants_alone() -> void:
	var combos := SpawnRegistry.combo_weapon_names()
	var p := _wizard()
	var base := p.weapons.size()
	p.add_granted_weapon("comet_weapon")  # not a combo spell: nobody displaces it
	p.add_granted_weapon(combos[0])
	p.add_granted_weapon(combos[1])
	assert_eq(p.granted_weapons, ["comet_weapon", combos[1]], "the plain grant survives the swap")
	assert_eq(p.weapons.size(), base + 2, "two grant slots, not three")


## Picking up the book you are already holding is still the no-op it was, not a swap for itself.
func test_the_same_book_twice_is_a_no_op() -> void:
	var combos := SpawnRegistry.combo_weapon_names()
	var p := _wizard()
	assert_true(p.add_granted_weapon(combos[0]), "first time")
	assert_false(p.add_granted_weapon(combos[0]), "second time changes nothing")
	assert_eq(p.granted_weapons, [combos[0]], "still the one book")


# --- the arsenal it answers for ---

func test_the_arsenal_covers_what_our_maps_place() -> void:
	var names: Array = ItemDmPickupScript.CLASSNAMES
	# Every weapon_/ammo_ classname across our 30 maps, mixed case and all.
	for placed in ["weapon_357", "weapon_9mmAR", "weapon_crossbow", "weapon_egon", "weapon_gauss",
			"weapon_handgrenade", "weapon_rpg", "weapon_satchel", "weapon_shotgun", "weapon_snark",
			"weapon_tripmine", "ammo_357", "ammo_9mmAR", "ammo_9mmbox", "ammo_9mmclip",
			"ammo_ARgrenades", "ammo_buckshot", "ammo_crossbow", "ammo_gaussclip", "ammo_rpgclip"]:
		assert_true(placed in names, "%s is answered for" % placed)
	assert_eq(names.size(), _unique(names).size(), "and listed once each")


func _unique(names: Array) -> Array:
	var out := {}
	for n in names:
		out[n] = true
	return out.keys()
