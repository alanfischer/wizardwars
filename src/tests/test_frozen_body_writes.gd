extends "res://src/tests/test_base.gd"
## A client's replica of a spawner-managed RigidBody (cocklebur, satchel, rolling stone) is
## frozen and driven purely by NetworkManager.interp_entities writing global_position each frame;
## if the physics server ignores writes to a frozen body, every replica sits where it spawned.

const STEPS := 8


func _frozen_body() -> RigidBody3D:
	var b := RigidBody3D.new()
	var cs := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.15
	cs.shape = sphere
	b.add_child(cs)
	b.position = Vector3(0.0, 60.0, 0.0)
	_root().add_child(b)
	b.freeze = true  # what _spawn_dyn_entity does to a client replica
	return b


## interp_entities runs in _process; the write lands between physics ticks.
func test_frozen_body_follows_position_writes() -> void:
	var b := _frozen_body()
	var tree := Engine.get_main_loop() as SceneTree
	var worst := 0.0
	for i in STEPS:
		var want := Vector3(0.0, 60.0 + float(i + 1), 0.0)
		b.global_position = want
		await tree.physics_frame
		worst = maxf(worst, b.global_position.distance_to(want))
	assert_lt(worst, 0.01, "frozen body follows written positions (worst drift %.4f)" % worst)
	b.queue_free()


## Same, but reading back immediately — catches a write that is silently dropped
## rather than one that is applied and then overwritten by the simulation.
func test_frozen_in_physics_process() -> void:
	var b := _frozen_body()
	await (Engine.get_main_loop() as SceneTree).physics_frame
	b.global_position = Vector3(0.0, 75.0, 0.0)
	var immediate := b.global_position.y
	await (Engine.get_main_loop() as SceneTree).physics_frame
	assert_almost_eq(immediate, 75.0, 0.01, "the write reads back immediately")
	assert_almost_eq(b.global_position.y, 75.0, 0.01, "and survives a physics step")
	b.queue_free()
