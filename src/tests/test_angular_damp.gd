extends "res://src/tests/test_base.gd"
## Spin damping and rolling resistance, both of which live in hop now. angular_damp used to
## be a post-step loop in hop-godot that only reached a body through set_angular_velocity —
## which activates it, so a damped body could never accumulate the still ticks it needs to
## sleep. Rolling friction is hop's answer to the one shape a contact manifold cannot hold
## still: a sphere touches the floor at a single point and would otherwise roll forever.

const SPIN := 10.0
const STONE_RADIUS := 0.2  # RollingStone's collider


func _spinner(damp: float, at: Vector3) -> RigidBody3D:
	var b := RigidBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.2, 0.1, 0.3)  # anisotropic, like a gib
	cs.shape = box
	b.add_child(cs)
	b.gravity_scale = 0.0  # free spin: the floor must not be part of the answer
	b.angular_damp = damp
	b.position = at
	_root().add_child(b)
	b.angular_velocity = Vector3(0.0, SPIN, 0.0)
	return b


func _floor(at: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(400.0, 1.0, 400.0)
	cs.shape = box
	body.add_child(cs)
	body.position = at
	_root().add_child(body)
	return body


func _steps(seconds: float) -> int:
	return int(seconds * Engine.physics_ticks_per_second)


func test_angular_damp_sheds_spin() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var damped := _spinner(3.0, Vector3(0.0, 200.0, 0.0))
	var free_body := _spinner(0.0, Vector3(0.0, 200.0, 8.0))
	for i in _steps(1.0):
		await tree.physics_frame
	# w *= (1 - 3*dt) each tick ≈ e⁻³ over a second, so 10 rad/s lands near 0.5.
	assert_lt(damped.angular_velocity.length(), 2.0,
		"angular_damp 3 sheds the spin (|w| %.2f)" % damped.angular_velocity.length())
	assert_gt(free_body.angular_velocity.length(), 8.0,
		"angular_damp 0 keeps it (|w| %.2f)" % free_body.angular_velocity.length())
	damped.queue_free()
	free_body.queue_free()


## The reason the damping moved into hop: it must not keep the body awake. hop only lets a
## body sleep while something is holding it up, so this one spins on the floor.
func test_damped_body_still_sleeps() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var ground := _floor(Vector3(0.0, 99.5, 0.0))
	var b := _spinner(3.0, Vector3(0.0, 100.05, 0.0))
	b.gravity_scale = 1.0
	var slept := false
	for i in _steps(5.0):
		await tree.physics_frame
		if b.sleeping:
			slept = true
			break
	assert_true(slept, "a damped body reaches sleep")
	b.queue_free()
	ground.queue_free()


## A sphere rolling on flat ground stops. Nothing in the contact solver can do this —
## one contact point, no lever — so this is hop's rolling friction or nothing.
func test_rolling_sphere_settles() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var floor_body := _floor(Vector3(0.0, 299.5, 0.0))

	var ball := RigidBody3D.new()
	var cs := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = STONE_RADIUS
	cs.shape = sphere
	ball.add_child(cs)
	ball.position = Vector3(0.0, 300.0 + STONE_RADIUS, 0.0)
	_root().add_child(ball)
	# Rolling, not sliding: w = v/r about the axis across the direction of travel.
	ball.linear_velocity = Vector3(5.0, 0.0, 0.0)
	ball.angular_velocity = Vector3(0.0, 0.0, -5.0 / STONE_RADIUS)

	var speed := 99.0
	for i in _steps(6.0):
		await tree.physics_frame
		speed = ball.linear_velocity.length()
		if speed < 0.5:
			break
	assert_lt(speed, 0.5, "a rolling sphere comes to rest (|v| %.2f after 6 s)" % speed)
	ball.queue_free()
	floor_body.queue_free()
