extends "res://src/tests/test_base.gd"
## GodotBody.has_headroom must refuse a pose already inside geometry. An upward-only sweep from
## the dropped pose is wrong: body_test_motion depenetrates before it casts, so from a start
## buried in a floor it recovers up out of the floor first and reports the space above as clear —
## this ejected riders standing up while briefly off-floor on ww_golem's bobbing deck. Needs real
## physics, so it lives here and not in netmove (StubBody.has_headroom ignores the offset).

const FLOOR_TOP := 10.0      # clear of anything else in the test scene
const CROUCH_HEIGHT := 0.9
const GROW := 0.9            # stand_height - crouch_height
const SLAB_HALF := 2.0       # deep enough that the dropped pose is well inside it


# Every node this test makes, so none of it is left in the shared scene root for the
# next suite to walk into — a 40 m slab parked at y=10 is enough to break a ramp test.


## A thick static slab with its top face at FLOOR_TOP, and a crouched body resting on it.
func _make_body() -> GodotBody:
	var slab := StaticBody3D.new()
	slab.collision_layer = GameConsts.MASK_WORLD
	var slab_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(40.0, SLAB_HALF * 2.0, 40.0)
	slab_shape.shape = box
	slab_shape.position = Vector3(0.0, -SLAB_HALF, 0.0)
	slab.add_child(slab_shape)
	slab.position = Vector3(0.0, FLOOR_TOP, 0.0)
	_root().add_child(slab)
	_spawned.append(slab)

	var player := CharacterBody3D.new()
	player.collision_layer = 0
	player.collision_mask = GameConsts.MASK_WORLD
	player.safe_margin = 0.01
	var cs := CollisionShape3D.new()
	cs.name = "CollisionShape3D"
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = CROUCH_HEIGHT
	cs.shape = cap
	cs.position = Vector3(0.0, CROUCH_HEIGHT * 0.5, 0.0)
	player.add_child(cs)
	_root().add_child(player)
	_spawned.append(player)
	player.global_position = Vector3(0.0, FLOOR_TOP, 0.0)

	var body := GodotBody.new(player)
	body.force_sync_physics()
	await (Engine.get_main_loop() as SceneTree).physics_frame
	return body


func test_clear_above_is_still_clear() -> void:
	var body: GodotBody = await _make_body()
	assert_true(body.has_headroom(GROW),
		"nothing overhead, so the grounded stand-up must be allowed")


func test_offset_into_the_floor_is_refused() -> void:
	var body: GodotBody = await _make_body()
	# Half a hull below the deck is solid slab. The space above it is wide open, which
	# is exactly why the upward sweep alone said yes.
	assert_false(body.has_headroom(GROW, Vector3.DOWN * (GROW * 0.5)),
		"a pose buried in the floor must be refused however clear the space above it is")


func test_offset_into_open_air_is_allowed() -> void:
	var body: GodotBody = await _make_body()
	# The same offset test from a genuinely free pose still passes, so the new check
	# rejects penetration rather than rejecting offsets.
	body.global_position = Vector3(0.0, FLOOR_TOP + 5.0, 0.0)
	body.force_sync_physics()
	await (Engine.get_main_loop() as SceneTree).physics_frame
	assert_true(body.has_headroom(GROW, Vector3.DOWN * (GROW * 0.5)),
		"an offset pose in open air is fine")
