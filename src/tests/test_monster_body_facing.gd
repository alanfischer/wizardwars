extends "res://src/tests/test_base.gd"
## A monster walks where it is sent and faces where it chose to face.
##
## Those are two different things for a monster and one thing for a player, which is how the bug
## got in. [MonsterBody] runs the shared pmove kernel, and simulate_tick assigns
## `body.yaw = cmd.yaw` on every tick — the player's yaw IS the command's. MonsterBody passed
## yaw 0, so the kernel pinned every skeleton facing north while it walked its route, and they
## read as walking backwards. Noticed by eye in a real game, not by any of this suite.
##
## The fix hands the kernel the host's current yaw and de-rotates the travel direction into that
## frame, so both halves are checked here: the facing survives, and the monster still goes where
## it was pointed rather than off at the yaw's angle.
##
## COVERAGE, measured by restoring `_cmd.yaw = 0.0` with the world-space move_input:
## keeps_the_facing_it_was_given fails (yaw driven to 0), and
## walks_the_world_direction_whatever_its_facing fails with the monster travelling along -Z
## instead of +X.


const SPEED := 3.75              # Skeleton.MOVE_SPEED
const HEIGHT := 1.8
const TICKS := 40
const FACING := 1.2              # an arbitrary non-zero yaw, so "unchanged" can't pass as "zero"


## Flat ground and a monster-shaped body standing on it, facing `yaw`.
func _monster(yaw: float) -> CharacterBody3D:
	var ground := StaticBody3D.new()
	var gs := CollisionShape3D.new()
	var gbox := BoxShape3D.new()
	gbox.size = Vector3(60, 1, 60)
	gs.shape = gbox
	gs.position = Vector3(0, -0.5, 0)
	ground.add_child(gs)
	_root().add_child(ground)
	_spawned.append(ground)

	var body := CharacterBody3D.new()
	var cs := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = 0.4
	cyl.height = HEIGHT
	cs.shape = cyl
	cs.position = Vector3(0, HEIGHT * 0.5, 0)
	body.add_child(cs)
	_root().add_child(body)
	_spawned.append(body)
	body.global_position = Vector3(0, 0.02, 0)
	body.rotation.y = yaw
	return body


## Free what the test built. test_base tracks _spawned but leaves the freeing to each test, the
## way test_step_slope does.
func _cleanup() -> void:
	for n in _spawned:
		if is_instance_valid(n):
			n.free()
	_spawned.clear()


func _walk(body: CharacterBody3D, dir: Vector3) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	await tree.physics_frame
	var mover := MonsterBody.new()
	mover.setup(body, SPEED, HEIGHT)
	for _i in TICKS:
		mover.walk(1.0 / 60.0, dir)
		await tree.physics_frame


func test_keeps_the_facing_it_was_given() -> void:
	var body := _monster(FACING)
	await _walk(body, Vector3(1, 0, 0))   # walking +X while facing something else entirely
	assert_almost_eq(body.rotation.y, FACING, 0.01,
		"the kernel must not steer a monster's facing — walking and looking are separate for it")
	_cleanup()


func test_walks_the_world_direction_whatever_its_facing() -> void:
	var body := _monster(FACING)
	await _walk(body, Vector3(1, 0, 0))
	var moved := body.global_position
	assert_gt(moved.x, 1.0, "asked for +X, should have travelled +X")
	assert_lt(absf(moved.z), 0.5, "asked for +X, should not have drifted along Z")
	_cleanup()


## The other half of the de-rotation: at yaw 0 the two frames coincide, so this would pass even
## with the bug in. It is here so a future "simplification" back to world-space move_input is
## caught by the pair rather than looking fine on its own.
func test_walks_the_world_direction_at_zero_yaw() -> void:
	var body := _monster(0.0)
	await _walk(body, Vector3(0, 0, 1))
	assert_gt(body.global_position.z, 1.0, "asked for +Z at yaw 0, should have travelled +Z")
	_cleanup()


## Standing on a turning deck, a monster turns with it, the way GoldSrc's SV_PushRotate turns any
## rider's angles. HullContacts measures the turn; MonsterBody must spend it, as the player does.
func test_turns_with_the_deck_it_stands_on() -> void:
	var deck := AnimatableBody3D.new()
	deck.sync_to_physics = false
	var ds := CollisionShape3D.new()
	var dbox := BoxShape3D.new()
	dbox.size = Vector3(8, 0.2, 8)
	ds.shape = dbox
	ds.position = Vector3(0, -0.1, 0)
	deck.add_child(ds)
	_root().add_child(deck)
	_spawned.append(deck)

	var body := CharacterBody3D.new()
	var cs := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = 0.4
	cyl.height = HEIGHT
	cs.shape = cyl
	cs.position = Vector3(0, HEIGHT * 0.5, 0)
	body.add_child(cs)
	_root().add_child(body)
	_spawned.append(body)
	body.global_position = Vector3(2, 0.02, 0)
	body.rotation.y = FACING

	var tree := Engine.get_main_loop() as SceneTree
	await tree.physics_frame
	var mover := MonsterBody.new()
	mover.setup(body, SPEED, HEIGHT)
	for _i in 12:
		mover.walk(1.0 / 60.0, Vector3.ZERO)
		await tree.physics_frame
	var step := deg_to_rad(0.5)
	for _i in TICKS:
		deck.rotation.y += step
		deck.force_update_transform()
		mover.walk(1.0 / 60.0, Vector3.ZERO)
		await tree.physics_frame
	assert_almost_eq(wrapf(body.rotation.y - FACING, -PI, PI), step * TICKS, deg_to_rad(1.0),
		"a monster riding a turning deck should turn with it")
	_cleanup()
