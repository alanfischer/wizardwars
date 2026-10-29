extends "res://src/tests/test_base.gd"
## A raycast that STARTS inside one body must still report a farther body: hit_from_inside=false
## means "don't report a shape the ray starts inside", not "abandon the ray" — hop discarded the
## whole query, so every +use ray from inside your own puppet capsule returned nothing.


## Capsule body matching the shapes involved: a player-ish capsule and a dragon-ish one.
func _capsule_body(pos: Vector3, radius: float, height: float) -> StaticBody3D:
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = radius
	cap.height = height
	cs.shape = cap
	body.add_child(cs)
	_root().add_child(body)
	body.global_position = pos
	return body


func test_ray_starting_inside_a_body_still_reports_the_next_one() -> void:
	# "Dragon" 1.2 m ahead; "own puppet" wrapped around the ray's start point.
	var target := _capsule_body(Vector3(1.2, 0.0, 0.0), 0.6, 1.8)
	var around_start := _capsule_body(Vector3.ZERO, 0.4, 1.8)
	await _physics_tick()

	var q := PhysicsRayQueryParameters3D.create(Vector3.ZERO, Vector3(1.6, 0.0, 0.0))
	var hit: Dictionary = _root().get_world_3d().direct_space_state.intersect_ray(q)
	assert_false(hit.is_empty(), "a ray starting inside a body still finds the body beyond it")
	assert_eq(hit.get("collider"), target, "and reports that farther body, not the enclosing one")

	target.queue_free()
	around_start.queue_free()


## The complement: from outside, the near body is the hit — so the skip above cannot be
## mistaken for "bodies at the start are invisible".
func test_ray_starting_outside_reports_the_nearest_body() -> void:
	var near := _capsule_body(Vector3(0.8, 0.0, 0.0), 0.4, 1.8)
	var far := _capsule_body(Vector3(2.0, 0.0, 0.0), 0.6, 1.8)
	await _physics_tick()

	var q := PhysicsRayQueryParameters3D.create(Vector3.ZERO, Vector3(3.0, 0.0, 0.0))
	var hit: Dictionary = _root().get_world_3d().direct_space_state.intersect_ray(q)
	assert_eq(hit.get("collider"), near, "the nearest body along the ray wins")

	near.queue_free()
	far.queue_free()


## Bodies added this frame are not in the broad phase until the server has stepped.
func _physics_tick() -> void:
	await (Engine.get_main_loop() as SceneTree).physics_frame
	await (Engine.get_main_loop() as SceneTree).physics_frame
