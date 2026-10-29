extends "res://src/tests/test_base.gd"
## ww_golem's two forward spawn groups sit inside breakable buildings: group 2 (team 1) inside
## house1, group 4 (team 2) inside house3, so smashing a house closes its spawns until round
## reset. These tests run the map's OWN scripts, read straight out of maps/ww_golem.bsp, so they
## check what ships rather than a copy that can drift.

const BSP_PATH := "res://maps/ww_golem.bsp"
const LUMP_ENTITIES := 0


## Golem positions in GoldSrc units, as GetEntityX/Y report them. "Deep" means past the
## gate spawncheck1 tests: far enough into a base, and north of y=-1200.
const GOLEM_START := Vector2(-64, -2576)
const GOLEM_DEEP_MINUS_X := Vector2(-1100, 200)   # attacking team 2's castle -> opens group 2
const GOLEM_DEEP_PLUS_X := Vector2(1100, 200)     # attacking team 1's castle -> opens group 4

var _interp: PotatoC
var _sg: Array = []            # ["Rem 2", "Res 1", ...] in call order
var _golem := GOLEM_START
var _scripts: Dictionary = {}  # targetname -> {code, globals}


func _setup_test(_test_name: String) -> void:
	_reset()


func _reset() -> void:
	_sg = []
	_golem = GOLEM_START
	PotatoC.global_vars.clear()
	if _scripts.is_empty():
		_scripts = _read_potatoc_scripts()
	# Every patched entity declares the globals; do it once here for all of them,
	# exactly as each entity's _ready would.
	for name in _scripts:
		var g: String = _scripts[name]["globals"]
		if not g.is_empty():
			PotatoC.parse_globals(g)


## Pull the potatoc entities out of the BSP's plain-text entity lump.
func _read_potatoc_scripts() -> Dictionary:
	var f := FileAccess.open(BSP_PATH, FileAccess.READ)
	assert_ne(f, null, "opened %s" % BSP_PATH)
	f.seek(4 + LUMP_ENTITIES * 8)
	var offset := f.get_32()
	var length := f.get_32()
	f.seek(offset)
	var text := f.get_buffer(length).get_string_from_ascii()
	f.close()

	var out: Dictionary = {}
	for raw_block in text.split("{"):
		var block := raw_block.split("}")[0]
		var kv: Dictionary = {}
		for line in block.split("\n"):
			var parts := line.strip_edges().split('" "')
			if parts.size() == 2:
				kv[parts[0].trim_prefix('"')] = parts[1].trim_suffix('"')
		if kv.get("classname", "") != "potatoc":
			continue
		var name: String = kv.get("targetname", "")
		if name.is_empty():
			continue
		# code, code1, code2 ... concatenated in the order PotatoCEntity uses.
		var code := str(kv.get("code", ""))
		var i := 1
		while kv.has("code%d" % i):
			code += str(kv["code%d" % i])
			i += 1
		out[name] = {"code": code, "globals": str(kv.get("globals", ""))}
	return out


## Stands in for PotatoCEntity's dispatch: records spawn-group calls, answers the
## golem-position queries from _golem, and lets everything else (TurnOn/Trigger/...)
## no-op — this is about spawn groups, not doors and gibs.
func _handler(app, local_vars) -> int:
	var a1: String = _interp.get_string_arg(app.app1, local_vars)
	match app.str_val:
		"RemSG":
			_sg.append("Rem %s" % a1)
		"ResSG":
			_sg.append("Res %s" % a1)
		"GetEntityIndex":
			return 1              # any non-zero handle; GetEntityX/Y ignore it here
		"GetEntityX":
			return int(_golem.x)
		"GetEntityY":
			return int(_golem.y)
		"GetEntityZ":
			return 448
	return 0


func _run_script(name: String) -> void:
	assert_true(_scripts.has(name), "map has a potatoc named '%s'" % name)
	_interp = PotatoC.new()
	_interp.function_handler = _handler
	_interp.parse_code(_scripts[name]["code"])
	_interp.execute()


func _poll(golem: Vector2) -> Array:
	_golem = golem
	_sg = []
	_run_script("spawncheck1")
	return _sg


func test_the_shipped_map_carries_the_patch() -> void:
	for name in ["house1off", "house3off", "spawncheck1", "reset2"]:
		assert_true(_scripts.has(name), "map has '%s'" % name)
		assert_true(_scripts[name]["globals"].contains("house1dead"),
			"'%s' declares the globals it touches — PotatoC drops an assignment to an "
			% name + "undeclared name into a per-run local scope, where it is lost")
	assert_true(_scripts["spawncheck1"]["code"].contains("house1dead==0"),
		"the poll gates team 1's forward group on house1 standing")
	assert_true(_scripts["spawncheck1"]["code"].contains("house3dead==0"),
		"and team 2's on house3")


func test_a_live_house_opens_its_forward_group() -> void:
	assert_eq(_poll(GOLEM_START), ["Rem 2", "Rem 4", "Res 1", "Res 3"],
		"at the golem's start position both teams sit on their home groups")
	assert_eq(_poll(GOLEM_DEEP_MINUS_X), ["Rem 2", "Rem 4", "Res 1", "Res 3", "Rem 1", "Res 2"],
		"golem deep on the -x side moves team 1 up to its house1 spawns")


func test_smashing_a_house_closes_its_group_at_once() -> void:
	_poll(GOLEM_DEEP_MINUS_X)  # group 2 is open and in use
	_sg = []
	_run_script("house1off")
	assert_eq(_sg, ["Rem 2", "Res 1"],
		"the smash closes group 2 without waiting for the 2s poll, and hands the team "
		+ "back its home group in the same breath so it is never left with none")
	assert_eq(PotatoC.global_vars.get("house1dead", -1), 1, "and records the house as dead")


func test_the_poll_will_not_reopen_a_dead_house() -> void:
	_run_script("house1off")
	# Golem still deep on the -x side: the gate that opened group 2 is still open.
	assert_eq(_poll(GOLEM_DEEP_MINUS_X), ["Rem 2", "Rem 4", "Res 1", "Res 3"],
		"group 2 stays shut and team 1 keeps its home group")
	assert_eq(_poll(GOLEM_DEEP_MINUS_X), ["Rem 2", "Rem 4", "Res 1", "Res 3"],
		"and stays shut on the next poll too")


func test_the_other_team_is_unaffected() -> void:
	_run_script("house1off")
	assert_eq(_poll(GOLEM_DEEP_PLUS_X), ["Rem 2", "Rem 4", "Res 1", "Res 3", "Rem 3", "Res 4"],
		"house3 still stands, so team 2's forward group opens as usual")


func test_round_reset_restores_the_house() -> void:
	_run_script("house1off")
	_run_script("house3off")
	assert_eq(PotatoC.global_vars.get("house1dead", -1), 1, "house1 down")
	assert_eq(PotatoC.global_vars.get("house3dead", -1), 1, "house3 down")
	_run_script("reset2")
	assert_eq(PotatoC.global_vars.get("house1dead", -1), 0, "reset rebuilt house1")
	assert_eq(PotatoC.global_vars.get("house3dead", -1), 0, "reset rebuilt house3")
	assert_eq(_poll(GOLEM_DEEP_MINUS_X), ["Rem 2", "Rem 4", "Res 1", "Res 3", "Rem 1", "Res 2"],
		"and the forward group opens again next round")
