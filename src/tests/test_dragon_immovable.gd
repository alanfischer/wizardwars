extends "res://src/tests/test_base.gd"
## An unmounted dragon is scenery. Fireballs, tornadoes and push triggers all shove things by
## writing velocity; a parked dragon drops what they wrote and only ever falls, so it is still
## where the mapper put it when someone comes to mount it.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.

const DragonScript = preload("res://src/monsters/dragon.gd")

const ARENA := Vector3(500.0, 400.0, 500.0)  # clear of map geometry, and of the other suites'


func _floor_under(pos: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(20.0, 1.0, 20.0)
	col.shape = box
	body.add_child(col)
	body.collision_layer = GameConsts.MASK_WORLD
	_root().add_child(body)
	body.global_position = pos + Vector3(0.0, -0.5, 0.0)
	return _keep(body) as StaticBody3D


func _dragon_at(pos: Vector3) -> Dragon:
	var d: Dragon = DragonScript.new()
	d.setup({"team_no": 0}, true)
	_root().add_child(d)
	d.global_position = pos
	return _keep(d) as Dragon


func _space() -> PhysicsDirectSpaceState3D:
	return (_root() as Window).get_world_3d().direct_space_state


func test_a_blast_does_not_shove_a_parked_dragon() -> void:
	_floor_under(ARENA)
	var d := _dragon_at(ARENA)
	await _tick(2)
	var parked := d.global_position

	Combat.apply_aoe_knockback(_space(), ARENA + Vector3(2.0, 0.0, 0.0),
		Fireball.FIREBALL_KNOCKBACK, Fireball.FIREBALL_RADIUS)
	await _tick(10)

	assert_vec3_almost_eq(d.global_position, parked, 0.01, "the blast leaves the dragon parked")


func test_an_upward_shove_does_not_launch_it() -> void:
	_floor_under(ARENA)
	var d := _dragon_at(ARENA)
	await _tick(2)
	var parked := d.global_position

	# What an updraft or a wind satchel writes.
	d.velocity = Vector3(3.0, 20.0, 0.0)
	await _tick(10)

	assert_vec3_almost_eq(d.global_position, parked, 0.01, "lift can't get it off the ground either")


func test_it_still_falls() -> void:
	_floor_under(ARENA)
	var d := _dragon_at(ARENA + Vector3(0.0, 6.0, 0.0))
	await _tick(10)

	assert_lt(d.global_position.y, ARENA.y + 6.0, "gravity is the one thing that still moves it")


func test_a_rider_moves_it_again() -> void:
	_floor_under(ARENA)
	var d := _dragon_at(ARENA)
	var rider := Node3D.new()
	_root().add_child(rider)
	_keep(rider)
	rider.global_position = ARENA + Vector3(5.0, 3.0, 0.0)
	d._rider = rider
	await _tick(2)

	assert_vec3_almost_eq(d.global_position, rider.global_position, 0.01, "a mounted dragon follows its rider")
