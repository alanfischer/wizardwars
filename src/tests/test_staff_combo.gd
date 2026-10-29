extends "res://src/tests/test_base.gd"
## Combo spells and the staff clash that earns one: two allied wizards beat their staves together
## until BOTH have landed more than Staff.COMBO_HITS, and the one who lands the winning swing
## takes the spell. Anything else the staff hits drops the charge.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.

const StaffScript = preload("res://src/weapons/staff.gd")


## A wizard puppet that records its grants rather than broadcasting them — the clash only needs
## element, team, the staff in hand, and the counter.
class _Duelist:
	extends RemotePlayer
	var granted_keys: Array[String] = []

	func grant_weapon(key: String) -> bool:
		granted_keys.append(key)
		return true


func _duelist(elem: int, team: int, with_staff := true) -> _Duelist:
	var d := _Duelist.new()
	d.element = elem
	d.team = team
	d.is_dead = false
	d.weapons = [StaffScript.new() if with_staff else MissileWeapon.new()] as Array[Weapon]
	d.current_weapon_idx = 0
	_root().add_child(d)
	_spawned.append(d)
	return d


func _staff() -> Staff:
	return StaffScript.new()


## Land `n` clashes from `a` onto `b`, reporting how many the staff actually spent.
func _clash(a: _Duelist, b: _Duelist, n: int) -> int:
	var staff := _staff()
	var spent := 0
	for i in n:
		if staff._combo_swing(a, b):
			spent += 1
	return spent


func _teardown_test() -> void:
	ServerVars.set_from_string("allow_combos", "on")
	_despawn_all()


# --- the recipe table ---

## The recipes ARE the combo spell list: what a clash can make is exactly what a spellbook can
## hold, so a new recipe needs no second edit to reach combo chaos or /spawn.
func test_recipes_are_the_combo_spell_list() -> void:
	var from_recipes := GameConsts.COMBO_RECIPES.values().duplicate()
	from_recipes.sort()
	assert_eq(from_recipes, SpawnRegistry.combo_weapon_names(),
		"the spells you can earn are the spells you can pick up")
	assert_eq(from_recipes.size(), 8, "every reachable pairing in the original mod")


func test_every_recipe_names_a_real_spell() -> void:
	for key in GameConsts.COMBO_RECIPES.values():
		assert_true(SpawnRegistry.has_weapon(key), "%s can be built" % key)


func test_combo_for_ignores_which_wizard_swung() -> void:
	var life := GameConsts.Element.LIFE
	var nature := GameConsts.Element.NATURE
	assert_eq(GameConsts.combo_for(life, nature), "spirit_wiz_weapon")
	assert_eq(GameConsts.combo_for(nature, life), "spirit_wiz_weapon", "order doesn't matter")
	assert_eq(GameConsts.combo_for(life, life), "", "a wizard makes nothing with their own kind")
	assert_eq(GameConsts.combo_for(GameConsts.Element.FIRE, GameConsts.Element.ICE), "",
		"and not every pairing is a recipe")


# --- who counts as a partner ---

func test_only_an_ally_holding_a_staff_counts() -> void:
	var blue := GameConsts.Team.BLUE
	var life := GameConsts.Element.LIFE
	var nature := GameConsts.Element.NATURE
	var staff := _staff()

	var enemy := _duelist(nature, GameConsts.Team.RED)
	assert_false(staff._combo_swing(_duelist(life, blue), enemy), "not across the line")

	var loner := _duelist(nature, GameConsts.Team.NONE)
	assert_false(staff._combo_swing(_duelist(life, GameConsts.Team.NONE), loner),
		"deathmatch has no allies to clash with")

	var unarmed := _duelist(nature, blue, false)
	assert_false(staff._combo_swing(_duelist(life, blue), unarmed), "their staff has to be out")

	var corpse := _duelist(nature, blue)
	corpse.is_dead = true
	assert_false(staff._combo_swing(_duelist(life, blue), corpse), "and they have to be alive")

	var wrong_pair := _duelist(GameConsts.Element.FIRE, blue)
	assert_false(staff._combo_swing(_duelist(GameConsts.Element.ICE, blue), wrong_pair),
		"fire and ice make nothing")


# --- earning one ---

## Both partners put the work in: swinging alone gets you a counter and nothing else.
func test_one_wizard_swinging_earns_nothing() -> void:
	var a := _duelist(GameConsts.Element.LIFE, GameConsts.Team.BLUE)
	var b := _duelist(GameConsts.Element.NATURE, GameConsts.Team.BLUE)
	var spent := _clash(a, b, Staff.COMBO_HITS * 3)
	assert_eq(spent, Staff.COMBO_HITS * 3, "every clash spends its damage")
	assert_true(a.granted_keys.is_empty(), "no spell for a one-sided clash")
	assert_eq(b.combo_hits, 0, "and the partner's own counter never moved")


## The swing that completes the pair is the one that pays out, and it pays the wizard who made it.
func test_the_winning_swing_takes_the_spell() -> void:
	var a := _duelist(GameConsts.Element.LIFE, GameConsts.Team.BLUE)
	var b := _duelist(GameConsts.Element.NATURE, GameConsts.Team.BLUE)
	_clash(a, b, Staff.COMBO_HITS + 1)
	_clash(b, a, Staff.COMBO_HITS)
	assert_true(b.granted_keys.is_empty(), "one short")
	_clash(b, a, 1)
	assert_eq(b.granted_keys, ["spirit_wiz_weapon"], "b landed it, so b learns it")
	assert_true(a.granted_keys.is_empty(), "a only helped")


## One spell per life for the wizard who took it; their partner starts over and can go earn one
## with somebody else. Straight from the original's 2.8 change.
func test_the_partner_may_try_again_but_the_winner_may_not() -> void:
	var a := _duelist(GameConsts.Element.LIFE, GameConsts.Team.BLUE)
	var b := _duelist(GameConsts.Element.NATURE, GameConsts.Team.BLUE)
	_clash(a, b, Staff.COMBO_HITS + 1)
	_clash(b, a, Staff.COMBO_HITS + 1)
	assert_eq(b.combo_hits, -1, "b is spent")
	assert_eq(a.combo_hits, 0, "a is back to the start")

	var staff := _staff()
	assert_false(staff._combo_swing(a, b), "a spent partner is just a target again")
	assert_eq(a.combo_hits, 0, "and a swing at them is neither progress nor a reset")

	var c := _duelist(GameConsts.Element.EARTH, GameConsts.Team.BLUE)
	_clash(a, c, Staff.COMBO_HITS + 1)
	_clash(c, a, Staff.COMBO_HITS + 1)
	assert_eq(c.granted_keys, ["wombat_weapon"], "a found a fresh partner for them")


func test_a_stray_hit_drops_the_charge() -> void:
	var a := _duelist(GameConsts.Element.LIFE, GameConsts.Team.BLUE)
	var b := _duelist(GameConsts.Element.NATURE, GameConsts.Team.BLUE)
	_clash(a, b, 3)
	assert_eq(a.combo_hits, 3)

	var staff := _staff()
	var bystander := Node3D.new()
	_root().add_child(bystander)
	_spawned.append(bystander)
	assert_false(staff._combo_swing(a, bystander), "a wall takes the damage")
	assert_eq(a.combo_hits, 0, "and the charge with it")


func test_respawning_forgets_the_charge() -> void:
	var a := _duelist(GameConsts.Element.LIFE, GameConsts.Team.BLUE)
	var b := _duelist(GameConsts.Element.NATURE, GameConsts.Team.BLUE)
	_clash(a, b, Staff.COMBO_HITS + 1)
	_clash(b, a, Staff.COMBO_HITS + 1)
	b.reset_for_spawn(-1, false, false)
	assert_eq(b.combo_hits, 0, "a fresh life, a fresh chance")


func test_allow_combos_off_makes_it_an_ordinary_swing() -> void:
	ServerVars.set_from_string("allow_combos", "off")
	var a := _duelist(GameConsts.Element.LIFE, GameConsts.Team.BLUE)
	var b := _duelist(GameConsts.Element.NATURE, GameConsts.Team.BLUE)
	assert_eq(_clash(a, b, Staff.COMBO_HITS + 1), 0, "nothing is spent on a clash")
	assert_eq(a.combo_hits, 0, "nothing is counted")
	assert_true(a.granted_keys.is_empty(), "and nothing is learned")


# --- the glow shell ---

## The shader carries the shell, so there is no second skinned pass to draw. Both variants get
## it: a wizard mid-fade is still a wizard carrying a spell.
func test_both_model_shaders_take_a_glow() -> void:
	for path in ["res://shaders/mdl_ambient_cube.gdshader",
			"res://shaders/mdl_ambient_cube_fade.gdshader"]:
		var shader: Shader = load(path)
		assert_true(shader != null, "%s loads" % path)
		var names := []
		for u in shader.get_shader_uniform_list():
			names.append(u["name"])
		assert_true("glow_color" in names, "%s exposes glow_color" % path)
		assert_true("glow_strength" in names, "%s exposes glow_strength" % path)


## Fading and glowing are set by different callers that don't know about each other, so the model
## has to remember both — an invisibility fade ending must not take the shell with it.
func test_a_model_remembers_its_fade_and_its_glow_separately() -> void:
	var model := Node3D.new()
	_root().add_child(model)
	_spawned.append(model)

	AssetLoader.set_model_glow(model, Color.WHITE, 0.55)
	AssetLoader.set_model_alpha(model, 0.3)
	assert_eq(model.get_meta("mdl_glow"), [Color.WHITE, 0.55], "the fade left the glow alone")
	assert_eq(model.get_meta("mdl_alpha"), 0.3)

	AssetLoader.set_model_alpha(model, 1.0)
	assert_eq(model.get_meta("mdl_glow"), [Color.WHITE, 0.55], "and so did the fade ending")


func test_carrying_a_combo_spell_is_what_lights_a_wizard_up() -> void:
	var a := _duelist(GameConsts.Element.LIFE, GameConsts.Team.BLUE)
	assert_false(a.has_combo_weapon(), "an ordinary loadout doesn't glow")
	a.granted_weapons.append("comet_weapon")
	assert_false(a.has_combo_weapon(), "and neither does a plain granted spell")
	a.granted_weapons.append("wombat_weapon")
	assert_true(a.has_combo_weapon())


## The glow is pushed at the materials only when something about it changed — every frame
## otherwise would re-walk every surface of every player on screen.
func test_the_glow_is_only_pushed_when_it_changes() -> void:
	var a := _duelist(GameConsts.Element.LIFE, GameConsts.Team.BLUE)
	a._update_combo_glow()
	var dark := a._glow_signature.duplicate()
	a._update_combo_glow()
	assert_eq(a._glow_signature, dark, "a settled wizard re-pushes nothing")

	a.granted_weapons.append("wombat_weapon")
	a._update_combo_glow()
	assert_eq(a._glow_signature[0], 1, "picking the spell up lights them")

	a.is_invisible = true
	a._update_combo_glow()
	assert_eq(a._glow_signature[0], 0, "but not while they're invisible")
	a.is_invisible = false

	# set_element builds a new model, which arrives with none of the old one's materials.
	a._wizard_model = Node3D.new()
	_spawned.append(a._wizard_model)
	a._update_combo_glow()
	assert_eq(a._glow_signature[1], a._wizard_model.get_instance_id(),
		"a fresh model has to be lit again")


## The other half of the shell: everyone else sees the wizard and the staff glow, and the wizard
## carrying it sees their own hands — which is the only part of themselves they can see. Built
## without entering the tree, since the glow needs no scene, only the models and the grant.
func test_the_carriers_own_hands_light_up_too() -> void:
	var p := LocalPlayer.new()
	_spawned.append(p)
	p._hand_model = Node3D.new()
	_spawned.append(p._hand_model)

	p._update_combo_glow()
	assert_eq(p._glow_signature[0], 0, "an ordinary loadout leaves the hands dark")

	p.granted_weapons.append("wombat_weapon")
	p._update_combo_glow()
	assert_eq(p._glow_signature[0], 1, "the book lights them")
	assert_eq(p._hand_model.get_meta("mdl_glow"),
		[Player.COMBO_GLOW_COLOR, Player.COMBO_GLOW_STRENGTH],
		"in the same white the wizard everyone else sees is wearing")

	p.is_invisible = true
	p._update_combo_glow()
	assert_eq(p._glow_signature[0], 0, "and an invisible wizard's hands go dark, as their body does")
	p.is_invisible = false
	p._update_combo_glow()

	# set_weapon rebuilds the hands on every switch, and a fresh model wears no glow.
	p._hand_model = Node3D.new()
	_spawned.append(p._hand_model)
	p._update_combo_glow()
	assert_eq(p._hand_model.get_meta("mdl_glow", []),
		[Player.COMBO_GLOW_COLOR, Player.COMBO_GLOW_STRENGTH],
		"the hands the next spell brought are lit too")
