## Lightweight test harness. API mirrors Gut (assert_eq, assert_true, etc.) so migrating to Gut
## later is trivial. Run it with ./run_tests.sh, which boots run_tests.tscn as a scene — never
## `-s`, which replaces the SceneTree before the autoloads tests reference are registered.
##
## RefCounted, not SceneTree: nothing here calls SceneTree's own API on `self`, and extending it
## built one orphan SceneTree per suite file — 153 leaked Viewport/Scenario/Canvas RIDs at exit,
## which buried any real leak the report was meant to show.
extends RefCounted

var _pass_count := 0
var _fail_count := 0
var _current_test := ""

## Scratch nodes registered with _keep(), freed after each test by _teardown_test().
var _spawned: Array[Node] = []


func assert_eq(got, expected, context := "") -> void:
	if got == expected:
		_pass_count += 1
	else:
		_fail("assert_eq: got %s, expected %s%s" % [got, expected, _ctx(context)])


func assert_ne(got, not_expected, context := "") -> void:
	if got != not_expected:
		_pass_count += 1
	else:
		_fail("assert_ne: got %s, should not equal %s%s" % [got, not_expected, _ctx(context)])


func assert_true(value: bool, context := "") -> void:
	if value:
		_pass_count += 1
	else:
		_fail("assert_true: got false%s" % _ctx(context))


func assert_false(value: bool, context := "") -> void:
	if not value:
		_pass_count += 1
	else:
		_fail("assert_false: got true%s" % _ctx(context))


func assert_lt(a, b, context := "") -> void:
	if a < b:
		_pass_count += 1
	else:
		_fail("assert_lt: %s is not < %s%s" % [a, b, _ctx(context)])


func assert_gt(a, b, context := "") -> void:
	if a > b:
		_pass_count += 1
	else:
		_fail("assert_gt: %s is not > %s%s" % [a, b, _ctx(context)])


func assert_almost_eq(got: float, expected: float, tolerance: float, context := "") -> void:
	if absf(got - expected) <= tolerance:
		_pass_count += 1
	else:
		_fail("assert_almost_eq: got %f, expected %f (±%f)%s" % [got, expected, tolerance, _ctx(context)])


func assert_vec3_almost_eq(got: Vector3, expected: Vector3, tolerance: float, context := "") -> void:
	if got.distance_to(expected) <= tolerance:
		_pass_count += 1
	else:
		_fail("assert_vec3_almost_eq: got %s, expected %s (±%f)%s" % [got, expected, tolerance, _ctx(context)])


func _ctx(context: String) -> String:
	return " — %s" % context if not context.is_empty() else ""


func _fail(msg: String) -> void:
	_fail_count += 1
	printerr("  FAIL [%s] %s" % [_current_test, msg])


## Register a node for teardown after the current test. Returns it, so it can wrap the
## construction expression: `var body := _keep(StaticBody3D.new())`.
func _keep(node: Node) -> Node:
	_spawned.append(node)
	return node


## Freed immediately, not queued: a test that traces the physics space must not find the
## previous test's bodies still standing in it, and teardown never yields a frame.
func _despawn_all() -> void:
	for n in _spawned:
		if is_instance_valid(n) and not n.is_queued_for_deletion():
			n.free()
	_spawned.clear()


## Per-test hooks. Override to clear state a suite carries between tests, or to add cleanup
## beyond _spawned (a global system reset, an extra physics frame). Both are awaited, so
## either may be a coroutine.
func _setup_test(_test_name: String) -> void:
	pass


func _teardown_test() -> void:
	_despawn_all()


## Runs every `test_*` method the suite declares, in declaration order, with the hooks above
## around each. Override only for a suite that needs different enumeration — one that repeats
## its tests per map, say (test_bot_waypoints).
func _run_tests() -> void:
	for m in get_method_list():
		var n := String(m.name)
		if not n.begins_with("test_"):
			continue
		_current_test = n
		await _setup_test(n)
		await call(n)
		await _teardown_test()


func _run() -> void:
	var script_path := get_meta("script_path", "") as String
	print("\n=== %s ===" % script_path.get_file() if not script_path.is_empty() else "=== tests ===")
	# Awaited so a suite may make _run_tests a coroutine (see the systems runner);
	# suites that don't resume immediately.
	await _run_tests()
	_print_summary()


func _print_summary() -> void:
	var total := _pass_count + _fail_count
	if _fail_count == 0:
		print("  ✓ %d/%d passed\n" % [_pass_count, total])
	else:
		printerr("  ✗ %d/%d passed (%d failed)\n" % [_pass_count, total, _fail_count])


func _run_method(method_name: String) -> void:
	_current_test = method_name
	call(method_name)


## Per-bone hit volumes under `node`, counted the way AssetLoader.strip_hitboxes and
## RemotePlayer._collect_hitbox_areas_into identify them — by the hitbox_group meta.
func _count_hitboxes(node: Node) -> int:
	var n := 1 if node is Area3D and node.has_meta("hitbox_group") else 0
	for child in node.get_children():
		n += _count_hitboxes(child)
	return n


## A HUD in the live tree. Shared because four suites need one, and the layout lives in
## hud.tscn now, so a HUD is instantiated rather than `new`ed.
func _make_hud() -> HUD:
	var hud := HUD.create()
	_root().add_child(hud)
	return hud


## The live SceneTree's root. A suite instance is not a Node and has no tree of its own, so the
## root everything is parented to comes from the main loop.
func _root() -> Node:
	return _tree().root


## The live SceneTree, for group lookups and `await _tree().physics_frame`. Same reason as
## _root(): the running tree is reachable only through the main loop.
func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


# ---------------------------------------------------------------------------
# World fixtures.
#
# These were rebuilt by hand in every suite that needed them — 14 copies of
# _tick, 11 of the static box, 10 of the damageable capsule, 9 of _wizard —
# the copies had drifted in ways that matter: two different conventions for
# where a capsule sits relative to its position, and eight of the nine _wizard
# copies registered the Player they built with neither _keep nor _spawned, so
# it outlived the test. The shared fixtures register everything they create.
# ---------------------------------------------------------------------------

## One physics step on the live tree.
func _physics_frame() -> void:
	await _tree().physics_frame


## `frames` physics steps — the suite's unit of "let the simulation run".
func _tick(frames: int) -> void:
	var tree := _tree()
	for _i in frames:
		await tree.physics_frame


## Two physics steps: long enough for a body added this frame to be in the physics space AND for
## the first query against it to see it there. One is not enough, which is why this has a name.
func _settle() -> void:
	await _tick(2)


## A static box on MASK_WORLD centred on `pos`. Floor and wall differ only in size, so the two
## named helpers below are both this body.
func _static_box_at(pos: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	col.shape = box
	body.add_child(col)
	body.collision_layer = GameConsts.MASK_WORLD
	_root().add_child(body)
	body.global_position = pos
	return _keep(body) as StaticBody3D


## Ground to stand monsters and corpses on. The default is wide enough that nothing walks off it
## during a test; pass a size when the test is about an edge.
func _floor_at(pos: Vector3, size := Vector3(60.0, 1.0, 60.0)) -> StaticBody3D:
	return _static_box_at(pos, size)


## Geometry to block a spell, a beam or a trace. Always sized by the caller — a wall's extent IS
## the test.
func _wall_at(pos: Vector3, size: Vector3) -> StaticBody3D:
	return _static_box_at(pos, size)


## A damageable capsule body of `target_class` at `pos` — the stand-in for a player in the spell
## and monster suites. Each suite declares its own DummyTarget inner class, because which fields a
## given spell reads off its victim differs, so the class comes in as an argument and only the
## body is shared.
##
## `capsule_base` puts `pos` at the body's FEET instead of its middle. Both conventions are in
## use and the difference is a metre of height, so it is spelled out rather than guessed: a test
## that drops a meteor on a target's head and one that measures knockback off its centre of mass
## want different answers.
##
## Team is deliberately not set: not every DummyTarget has one, and those that do default it.
func _damageable_at(target_class: GDScript, pos: Vector3, radius := 0.4,
		capsule_base := false, height := 1.8) -> CharacterBody3D:
	var t: CharacterBody3D = target_class.new()
	var col := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = radius
	cap.height = height
	col.shape = cap
	if capsule_base:
		col.position.y = height * 0.5
	t.add_child(col)
	t.collision_layer = GameConsts.MASK_PLAYER
	t.add_to_group("damageable")
	_root().add_child(t)
	t.global_position = pos
	return _keep(t) as CharacterBody3D


## A Player carrying `element`'s weapon set. Deliberately not added to the tree: the suites that
## want one read the weapon list, the element and the cast hooks off it, and a Player in the tree
## starts wanting a camera and a NetSync.
func _wizard(element := GameConsts.Element.FIRE) -> Player:
	var p := Player.new()
	p.element = element
	p.weapons = Wizard.create(element).weapons
	return _keep(p) as Player


## A CharacterBody3D shaped the way netmove drives a player: a capsule of `stand_height` with its
## base at the body's origin, and the four CharacterBody3D knobs pmove needs turned off (see
## RemotePlayer.setup_server_movement). Returned bare — unparented, with the engine's default
## collision_mask — because the mover suites each place and mask it differently, and the mask IS
## what some of them are testing.
func _pmove_body(stand_height: float) -> CharacterBody3D:
	var p := CharacterBody3D.new()
	var cs := CollisionShape3D.new()
	cs.name = "CollisionShape3D"
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = stand_height
	cs.shape = cap
	cs.position.y = stand_height * 0.5
	p.add_child(cs)
	p.floor_block_on_wall = false
	p.safe_margin = 0.01
	p.platform_floor_layers = 0
	p.platform_wall_layers = 0
	return p


## A TriggerSystem target that records being fired, appending `probe_name` to `sink`. Three mover
## suites each wrote this same probe to prove a button, door or train really reached its target;
## the sink stays a parameter because each suite's `_fired` list is cleared in its own
## _setup_test and compared against its own expected order.
func _target_probe_into(sink: Array, probe_name: String) -> void:
	var probe := _TriggerProbe.new(sink, probe_name)
	_root().add_child(probe)
	_keep(probe)
	TriggerSystem.register(probe_name, probe)


class _TriggerProbe:
	extends Node
	var _sink: Array
	var _probe_name: String

	func _init(sink: Array, probe_name: String) -> void:
		_sink = sink
		_probe_name = probe_name

	func trigger(_activator: Node, _type: TriggerSystem.Type) -> void:
		_sink.append(_probe_name)
