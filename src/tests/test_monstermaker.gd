extends "res://src/tests/test_base.gd"
## ww_monstermaker population maintenance: the maker keeps a target number of monsters alive and
## respawns `delay` seconds after one dies. Drives the spawn *decision* through a spy that records
## spawns and holds fake children, so no network/asset machinery is needed.

const MonsterMakerScript = preload("res://src/entities/monstermaker.gd")

const ARENA := Vector3(-400.0, 150.0, -400.0)  # clear of map geometry, and of the other suites'


## Spy: records spawns and hands back a real (freeable) node as the live child, so the maker's
## own bookkeeping and is_instance_valid pruning run for real and only the network spawn is faked.
class SpyMaker:
	extends MonsterMakerScript
	var spawn_count := 0
	func _spawn_child() -> Node:
		spawn_count += 1
		return Node.new()


func _make(max_live: int, delay: float, remaining: int) -> SpyMaker:
	var m := SpyMaker.new()
	m._active = true
	m._max_live = max_live
	m._delay = delay
	m._remaining = remaining
	m._cooldown = MonsterMakerScript.INITIAL_DELAY
	return m


## Free every live child (simulate them all dying).
func _kill_all(m: SpyMaker) -> void:
	for c in m._children:
		c.free()
	# _process prunes freed children on its next tick.


func test_spawns_initial_after_short_delay() -> void:
	var m := _make(1, 5.0, -1)
	m._process(0.1)
	assert_eq(m.spawn_count, 0, "nothing spawns before the initial delay elapses")
	m._process(MonsterMakerScript.INITIAL_DELAY)
	assert_eq(m.spawn_count, 1, "first monster spawns shortly after start")
	m.free()


func test_holds_at_target_population() -> void:
	var m := _make(1, 5.0, -1)
	m._process(1.0)          # initial spawn
	m._process(100.0)        # long time passes, child still alive
	assert_eq(m.spawn_count, 1, "a live target population is never over-spawned")
	m.free()


func test_respawns_after_death() -> void:
	var m := _make(1, 5.0, -1)
	m._process(1.0)
	assert_eq(m.spawn_count, 1, "spawned the first")
	_kill_all(m)
	m._process(1.0)          # death registered; still inside the respawn delay
	assert_eq(m.spawn_count, 1, "respawn waits out the delay, doesn't fire instantly")
	m._process(5.0)          # delay elapses
	assert_eq(m.spawn_count, 2, "a new monster spawns after the dead one's delay")
	m.free()


func test_stops_at_monstercount() -> void:
	var m := _make(1, 1.0, 2)  # only two total, ever
	m._process(1.0); _kill_all(m)
	m._process(2.0); _kill_all(m)
	m._process(2.0); _kill_all(m)
	m._process(2.0)
	assert_eq(m.spawn_count, 2, "a finite monstercount stops after its budget")
	m.free()


func test_maintains_multiple() -> void:
	var m := _make(2, 1.0, -1)
	m._process(1.0)          # first
	m._process(1.0)          # second (still under target)
	assert_eq(m.spawn_count, 2, "fills up to the target live count")
	m._process(50.0)
	assert_eq(m.spawn_count, 2, "then holds at the target")
	m.free()


## Built the way the importer builds one: keyvalues on the node, then into the tree, so _ready
## reads them and the targetname registers with TriggerSystem.
func _placed(keys: Dictionary) -> SpyMaker:
	var m := SpyMaker.new()
	m.set_meta("entity", keys)
	_root().add_child(m)
	_keep(m)
	return m


func _matrox_keys(spawnflags: String) -> Dictionary:
	return {
		"classname": "ww_monstermaker", "monstertype": "monster_skeleton",
		"targetname": "m1", "spawnflags": spawnflags, "team_no": "0",
		"m_imaxlivechildren": "1", "delay": "5", "monstercount": "-1",
	}


func test_a_skeleton_maker_has_something_to_make() -> void:
	assert_eq(MonsterMakerScript.MONSTER_SCRIPTS.get("monster_skeleton", ""),
		"res://src/monsters/skeleton.gd", "a map's skeleton is the one raise dead makes")


## ww_matrox's own keys: named, START_ON|CYCLIC, one live at a time. Each firing of the
## trigger_multiple at the approach drops one skeleton, and the clock never runs.
func test_a_cyclic_maker_drops_one_per_firing() -> void:
	var m := _placed(_matrox_keys("5"))
	m._process(100.0)
	assert_eq(m.spawn_count, 0, "a cyclic maker's own clock never runs")

	m.trigger(null, TriggerSystem.Type.TOGGLE)
	assert_eq(m.spawn_count, 1, "one skeleton per firing")
	m.trigger(null, TriggerSystem.Type.TOGGLE)
	assert_eq(m.spawn_count, 1, "and no second one while the first is alive")

	_kill_all(m)
	m.trigger(null, TriggerSystem.Type.TOGGLE)
	assert_eq(m.spawn_count, 2, "the firing after it dies makes another")


func test_a_named_maker_waits_to_be_switched_on() -> void:
	var m := _placed(_matrox_keys("0"))
	m._process(100.0)
	assert_eq(m.spawn_count, 0, "no START_ON, so it starts off")

	m.trigger(null, TriggerSystem.Type.TOGGLE)
	m._process(0.1)
	assert_eq(m.spawn_count, 1, "switched on, it makes monsters")

	_kill_all(m)
	m.trigger(null, TriggerSystem.Type.TOGGLE)
	m._process(100.0)
	assert_eq(m.spawn_count, 1, "switched off again, it stops")


## The dragons: no targetname, so nothing has to fire them.
func test_an_unnamed_maker_still_free_runs() -> void:
	var keys := _matrox_keys("0")
	keys.erase("targetname")
	var m := _placed(keys)
	m._process(MonsterMakerScript.INITIAL_DELAY)
	assert_eq(m.spawn_count, 1, "an unnamed maker starts on its own")


## "don't build a stack of monsters!" — ww_feudal asks one maker for ten sheep, so the spawn
## point has to be checked before each one or the flock comes out inside itself.
func test_it_will_not_build_a_stack_on_an_occupied_spawn_point() -> void:
	var keys := _matrox_keys("0")
	keys.erase("targetname")
	var m := _placed(keys)
	m.global_position = ARENA

	var blocker := CharacterBody3D.new()
	var col := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.8
	col.shape = cap
	col.position.y = 0.9
	blocker.add_child(col)
	blocker.collision_layer = GameConsts.MASK_PLAYER
	_root().add_child(blocker)
	_keep(blocker)
	blocker.global_position = ARENA
	await _physics_frame()

	m._process(MonsterMakerScript.INITIAL_DELAY)
	assert_eq(m.spawn_count, 0, "somebody is standing on it, so nothing is made")

	blocker.global_position = ARENA + Vector3(5.0, 0.0, 0.0)
	await _physics_frame()
	m._process(m._delay)
	assert_eq(m.spawn_count, 1, "they move, and the next turn makes one")
