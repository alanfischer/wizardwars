extends "res://src/tests/test_base.gd"
## A point query must see world geometry it is inside. hop answered a zero-length segment with
## Quake's hull walk, which reports a trace that never leaves solid as `allsolid` with no impact
## plane — indistinguishable from a clear path. So `intersect_point`, whose whole job is "is this
## point inside something", answered "no" for every point inside the world.
##
## Found in play: a siege monster placed inside ww_2fort's spawn-room wall was point-tested,
## cleared, and fell through to the room below. Shapes are covered in C++
## (extern/hop-godot/tests/test_bsp_traceable.cpp); this holds the Godot-level contract, and it is
## the only coverage of the plane traceable at all — that one is godot-cpp coupled, so it cannot
## live in hop-godot's standalone test suite.
##
## Scene-run only (needs the physics world): res://src/tests/run_tests.tscn.

const LAYER := 1 << 7   # a layer of our own, so nothing else in the scene answers these queries


func _body(shape: Shape3D, pos := Vector3.ZERO) -> StaticBody3D:
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	body.collision_layer = LAYER
	_root().add_child(_keep(body))
	body.global_position = pos
	return body


## Two frames, so a body added this frame is in the physics space before it is queried.
func _physics_tick() -> void:
	await (Engine.get_main_loop() as SceneTree).physics_frame
	await (Engine.get_main_loop() as SceneTree).physics_frame


func _inside(p: Vector3) -> bool:
	var q := PhysicsPointQueryParameters3D.new()
	q.position = p
	q.collision_mask = LAYER
	return not _root().get_world_3d().direct_space_state.intersect_point(q, 1).is_empty()


## A box is the control: hop's primitives have always reported an interior point, which is why
## this bug only ever showed on world geometry.
func test_a_point_inside_a_box_is_inside_it() -> void:
	var box := BoxShape3D.new()
	box.size = Vector3(2, 2, 2)
	_body(box)
	await _physics_tick()

	assert_true(_inside(Vector3(0, 0.5, 0)), "a point in the box is inside it")
	assert_false(_inside(Vector3(0, 4.0, 0)), "and a point well outside is not")


## The plane traceable — an infinite half-space, the plainest interior there is, and it reported
## nothing in every direction. A zero-length segment has denom 0, so the sweep's "moving away or
## parallel" guard returned before the interior was ever considered.
func test_a_point_below_a_world_boundary_is_inside_it() -> void:
	var plane := WorldBoundaryShape3D.new()
	plane.plane = Plane(Vector3.UP, 0.0)
	_body(plane)
	await _physics_tick()

	assert_true(_inside(Vector3(0, -0.5, 0)), "below the plane is inside the solid half-space")
	assert_false(_inside(Vector3(0, 0.5, 0)), "above it is open space")
