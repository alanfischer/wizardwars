extends "res://src/tests/test_base.gd"
## NetworkManager._clamp_extrapolation keeps a dead-reckoned position out of the world.
##
## The interp buffer extrapolates a straight line from the last snapshot's velocity and knows
## nothing about geometry, so an entity that stopped during a packet gap keeps going — a falling
## corpse walks metres through the floor and then snaps back up when the real resting sample lands.
## The clamp sweeps the entity's own collision volume from the last real sample to the guess.

const FLOOR_TOP := 0.5


func _floor() -> StaticBody3D:
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(20.0, 1.0, 20.0)
	cs.shape = box
	body.add_child(cs)
	body.collision_layer = GameConsts.MASK_WORLD
	body.position = Vector3.ZERO  # 1m thick, centred on origin → top face at y=0.5
	_root().add_child(body)
	return body


## Shaped like a client corpse replica: capsule offset up from the node origin, frozen, layer zeroed
## so nothing can hit it, mask left as the authority's (see tumbling_corpse.gd).
func _entity(with_shape: bool, mask: int = GameConsts.MASK_WORLD) -> RigidBody3D:
	var n := RigidBody3D.new()
	if with_shape:
		var cs := CollisionShape3D.new()
		var capsule := CapsuleShape3D.new()
		capsule.radius = 0.3
		capsule.height = 1.0
		cs.shape = capsule
		cs.position = Vector3(0.0, 0.5, 0.0)
		n.add_child(cs)
	n.collision_layer = 0
	n.collision_mask = mask
	_root().add_child(n)
	n.freeze = true
	return n


func _clamp(id: int, node: RigidBody3D, anchor: Vector3, guess: Vector3) -> Vector3:
	var got: Vector3 = NetworkManager._clamp_extrapolation(id, node, anchor, Vector3.ZERO, guess)
	NetworkManager._interp_shapes.erase(id)  # don't leak the per-entity cache between tests
	return got


func test_guess_through_floor_is_stopped() -> void:
	var ground := _floor()
	var n := _entity(true)
	await (Engine.get_main_loop() as SceneTree).physics_frame
	# Falling: last real sample well clear of the floor, guess 3m underneath it.
	var got := _clamp(-9001, n, Vector3(0.0, 2.0, 0.0), Vector3(0.0, -3.0, 0.0))
	assert_gt(got.y, FLOOR_TOP, "clamped to the floor, not through it (got y=%.3f)" % got.y)
	assert_lt(got.y, 2.0, "still travelled toward the floor rather than freezing at the anchor")
	n.queue_free()
	ground.queue_free()


func test_clear_path_keeps_the_guess() -> void:
	var ground := _floor()
	var n := _entity(true)
	await (Engine.get_main_loop() as SceneTree).physics_frame
	# Falling through open air, nowhere near the floor → extrapolation is right, don't touch it.
	var guess := Vector3(0.0, 8.0, 0.0)
	var got := _clamp(-9002, n, Vector3(0.0, 10.0, 0.0), guess)
	assert_vec3_almost_eq(got, guess, 0.001, "an unobstructed guess is returned unchanged")
	n.queue_free()
	ground.queue_free()


## No collision volume means the authority doesn't stop it either, so the straight line is already
## correct — clamping one would freeze something that should have kept flying.
func test_shapeless_entity_is_left_alone() -> void:
	var ground := _floor()
	var n := _entity(false)
	await (Engine.get_main_loop() as SceneTree).physics_frame
	var guess := Vector3(0.0, -3.0, 0.0)
	var got := _clamp(-9003, n, Vector3(0.0, 2.0, 0.0), guess)
	assert_vec3_almost_eq(got, guess, 0.001, "shapeless → guess returned unchanged")
	n.queue_free()
	ground.queue_free()


## The sweep uses the replica's own mask, so an entity the authority does not stop against world
## geometry is not stopped here either — the clamp mirrors the authority, it doesn't invent collision.
func test_mask_that_excludes_the_floor_is_left_alone() -> void:
	var ground := _floor()
	var n := _entity(true, GameConsts.MASK_PLAYER)  # collides with players, not world
	await (Engine.get_main_loop() as SceneTree).physics_frame
	var guess := Vector3(0.0, -3.0, 0.0)
	var got := _clamp(-9004, n, Vector3(0.0, 2.0, 0.0), guess)
	assert_vec3_almost_eq(got, guess, 0.001, "floor is not in the entity's mask → guess unchanged")
	n.queue_free()
	ground.queue_free()
