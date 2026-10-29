extends Node

## What /spawn can make, worked out from the scripts themselves rather than a hand-kept list.
##
## Three kinds of thing, each with exactly one name:
##
##   map entities   "item_healthkit", "func_door"  — the classnames EntityRegistry already
##                                                   binds for the BSP importer
##   world objects  "comet", "sheep"               — a Node script under one of OBJECT_DIRS with
##                                                   the spawner's setup(data, is_host) contract
##   weapons        "comet_weapon"                 — a Weapon (Resource) script in src/weapons/
##
## The split falls out of the script's own base type: Weapon extends Resource, everything that
## exists in the world extends Node. Add a new spell and both halves appear here for free.
##
## Weapons need one extra step. A weapon's presentation (hand model, anims, attack prefix) lives
## in the wizard that hands it out — CometWeapon.new() has no viewmodel, ArchmageWizard._make_comet()
## supplies it. So each wizard is built once and the configuration recorded, rather than duplicating
## that table here. Every other Weapon script in src/weapons/ is dressed the way a pickup is
## (Wizard.dress_pickup), once per element.

## Every directory a thing that exists in the world can live in. src/weapons/ is the Weapon
## resources plus the satchel; the rest are what a cast leaves behind — what flies, what it looks
## like when it lands, and what stands there afterwards.
const WEAPON_DIR := "res://src/weapons/"
const OBJECT_DIRS := [WEAPON_DIR, "res://src/projectiles/", "res://src/effects/",
	"res://src/monsters/"]

# Wizard-set knobs, copied off the harvested instance and replayed onto a fresh one. The two anim
# arrays are typed (Array[String]) and need assign() rather than a plain copy.
const _FIELDS := ["element", "hand_model_path", "hand_idle_anim", "player_attack_prefix",
	"bot_range", "bot_lead_speed", "cooldown", "mana_cost", "mana_drain", "auto_repeat",
	"weapon_name"]
const _ANIM_FIELDS := ["hand_attack_anims", "hand_hit_anims"]

var _recipes: Dictionary = {}  # weapon name -> { element -> recipe Dictionary }
var _combos: Dictionary = {}   # weapon name -> true, for the pickup-only (combo) spells
var _objects: Dictionary = {}  # object name -> script path
var _scanned := false


# --- weapons ---

func _harvest() -> void:
	if not _recipes.is_empty():
		return
	var wizards := {}  # element -> Wizard
	for element in GameConsts.ELEMENT_NAMES:
		var wizard := Wizard.create(element)
		wizards[element] = wizard
		for w in wizard.weapons:
			_record(w, element)
		# Spellbook-only spells: nobody spawns holding one, but every class can be handed one,
		# so each element contributes its own dressing (see Wizard.pickup_weapons).
		for w in wizard.pickup_weapons():
			_record(w, element)
			_combos[name_for(w.get_script())] = true
		if wizard is EarthWizard:
			for w in (wizard as EarthWizard).make_bear_loadout():
				_record(w, element)
	# Weapons nobody hands out are still giveable, in pickup dress.
	for script in _weapon_scripts():
		if _recipes.has(name_for(script)):
			continue
		for element in wizards:
			var w: Weapon = script.new()
			wizards[element].dress_pickup(w)
			_record(w, element)


## Every Weapon script in WEAPON_DIR except the bases others extend (Staff, RayWeapon).
func _weapon_scripts() -> Array[GDScript]:
	var found: Array[GDScript] = []
	var bases := {}
	for path in _script_paths(WEAPON_DIR):
		var script: GDScript = load(path)
		if script == null or not _is_weapon(script):
			continue
		found.append(script)
		var base := script.get_base_script()
		while base != null:
			bases[base.resource_path] = true
			base = base.get_base_script()
	return found.filter(func(s: GDScript) -> bool: return not bases.has(s.resource_path))


func _is_weapon(script: GDScript) -> bool:
	var base := script.get_base_script()
	while base != null:
		if base == Weapon:
			return true
		base = base.get_base_script()
	return false


func _record(w: Weapon, element: int) -> void:
	var script: GDScript = w.get_script()
	var key := name_for(script)
	if key.is_empty():
		return
	var recipe := {"script_path": script.resource_path}
	for f in _FIELDS:
		recipe[f] = w.get(f)
	for f in _ANIM_FIELDS:
		recipe[f] = (w.get(f) as Array).duplicate()
	if not _recipes.has(key):
		_recipes[key] = {}
	_recipes[key][element] = recipe


func has_weapon(weapon_name: String) -> bool:
	_harvest()
	return _recipes.has(weapon_name.to_lower())


## The combo spells: the pickup-only set, taken from Wizard.pickup_weapons() rather than a list
## of its own, so a new combo spell joins the pool by being handed out there.
func combo_weapon_names() -> Array:
	_harvest()
	var out := _combos.keys()
	out.sort()
	return out


func is_combo_weapon(weapon_name: String) -> bool:
	_harvest()
	return _combos.has(weapon_name.to_lower())


## One combo spell at random — what a combo_weapon book turns out to be. `exclude` drops names
## the roll should not land on, so a pickup that grants on touch can avoid handing over a spell
## the toucher already carries. Empty if there are none, or none left once `exclude` is spent.
func random_combo_weapon(exclude: Array = []) -> String:
	var names := combo_weapon_names()
	if not exclude.is_empty():
		names = names.filter(func(n): return not n in exclude)
	return names.pick_random() if not names.is_empty() else ""


func weapon_names() -> Array:
	_harvest()
	var out := _recipes.keys()
	out.sort()
	return out


## A fresh, fully configured weapon. `prefer_element` picks between per-element variants of a
## weapon several wizards carry (every wizard's magic missile); one only a single wizard carries
## comes back dressed the way that wizard dresses it. Null if the name is unknown.
func build_weapon(weapon_name: String, prefer_element: int = -1) -> Weapon:
	_harvest()
	var variants: Dictionary = _recipes.get(weapon_name.to_lower(), {})
	if variants.is_empty():
		return null
	var recipe: Dictionary = variants.get(prefer_element, variants.values()[0])
	var script: GDScript = load(recipe["script_path"])
	if script == null:
		return null
	var w: Weapon = script.new()
	for f in _FIELDS:
		w.set(f, recipe[f])
	for f in _ANIM_FIELDS:
		(w.get(f) as Array).assign(recipe[f])
	return w


# --- world objects ---

## One pass over each OBJECT_DIRS entry, keeping the Node scripts that implement the spawner's
## contract. That drops the two helpers with no setup() (trail_fader, comet_explosion_effect)
## without naming them, and keeps every projectile, plant, effect and monster.
func _scan_objects() -> void:
	if _scanned:
		return
	_scanned = true
	for object_dir in OBJECT_DIRS:
		_scan_dir(object_dir)


func _scan_dir(object_dir: String) -> void:
	for path in _script_paths(object_dir):
		var script: GDScript = load(path)
		if script != null and ClassDB.is_parent_class(script.get_instance_base_type(), &"Node") \
				and _has_setup(script):
			_objects[name_for(script)] = script.resource_path


## The .gd path of every script in `dir`.
func _script_paths(dir_path: String) -> PackedStringArray:
	var out := PackedStringArray()
	var dir := DirAccess.open(dir_path)
	if dir == null:
		push_warning("spawn_registry: cannot read %s" % dir_path)
		return out
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		# An exported build may store a script as .gd, .gdc or a .remap stub; load() takes the
		# .gd path in every case. (.gd.uid sidecars are not scripts and fall through.)
		if file_name.ends_with(".gd") or file_name.ends_with(".gdc") or file_name.ends_with(".gd.remap"):
			out.append(dir_path + file_name.trim_suffix(".remap").trim_suffix(".gdc").trim_suffix(".gd") + ".gd")
		file_name = dir.get_next()
	dir.list_dir_end()
	return out


## setup(data, is_host) is how the dynamic-entity spawner configures what it builds, so a Node
## script without one (inherited or its own) isn't something /spawn can hand parameters to.
func _has_setup(script: GDScript) -> bool:
	return _implements(script, "setup")


## Does this script, or one it extends, define this method?
func _implements(script: GDScript, method: String) -> bool:
	var s := script
	while s != null:
		for m in s.get_script_method_list():
			if m.name == method:
				return true
		s = s.get_base_script()
	return false


func has_object(object_name: String) -> bool:
	_scan_objects()
	return _objects.has(object_name.to_lower())


func object_names() -> Array:
	_scan_objects()
	var out := _objects.keys()
	out.sort()
	return out


func object_script_path(object_name: String) -> String:
	_scan_objects()
	return _objects.get(object_name.to_lower(), "")


## Does this object push one-shot state to clients (a death burst, a bite, a growth level)? Those
## rides need a network id allocated with the spawn — see main.spawn_dynamic_entity — and _apply_sync_state
## is the receiving half, so a script that has one is a script that needs the id. Derived, like the rest.
func object_syncs_state(object_name: String) -> bool:
	var path := object_script_path(object_name)
	if path.is_empty():
		return false
	return _implements(load(path), "_apply_sync_state")


# --- shared ---

## "res://src/weapons/comet_weapon.gd" -> "comet_weapon". The file name IS the spawn name, in
## both directions, so there's nothing to keep in sync.
func name_for(script: GDScript) -> String:
	return script.resource_path.get_file().trim_suffix(".gd")
