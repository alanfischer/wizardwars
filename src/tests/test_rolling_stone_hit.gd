extends "res://src/tests/test_base.gd"
## A rolling stone thrown into an enemy must damage it. Guards two hop-godot bugs: a
## RigidBody3D's contact reporting ITSELF as the collider, and the reported Object coming back
## null (a raw engine pointer read as nothing through _owner). Either way
## _on_physics_collision saw no damageable target and the stone just bounced.

const StoneScript = preload("res://src/projectiles/rolling_stone.gd")

const STONE_POS := Vector3(0.0, 60.0, 0.0)   # clear of map geometry
const TARGET_OFFSET := Vector3(3.0, 0.0, 0.0)
const FLIGHT_FRAMES := 30


## Minimal stand-in for a player: damageable, on the player layer the stone masks,
## and it records what hit it.
class DummyTarget extends CharacterBody3D:
	var is_dead := false
	var team := 99            # nodes_friendly reads this; 99 is nobody's ally
	var damage_taken := 0.0
	var damage_type := -1

	func take_damage(amount: float, type: int, _attacker) -> void:
		damage_taken += amount
		damage_type = type


func _spawn_target() -> DummyTarget:
	var t := DummyTarget.new()
	t.name = "StoneTarget"
	var col := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.5
	cap.height = 1.8
	col.shape = cap
	t.add_child(col)
	t.collision_layer = GameConsts.MASK_PLAYER
	t.add_to_group("damageable")
	_root().add_child(t)
	t.global_position = STONE_POS + TARGET_OFFSET
	return t


## Mirrors main._spawn_dyn_entity: setup() first, add_child() after.
func _spawn_stone(aim: Vector3) -> RollingStone:
	var s: RollingStone = StoneScript.new()
	s.setup({"position": STONE_POS, "direction": aim, "lifetime": 2.0}, true)
	_root().add_child(s)
	return s


func _fly(frames: int) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	for i in frames:
		await tree.physics_frame


func test_stone_damages_an_enemy_it_strikes() -> void:
	var target := _spawn_target()
	var stone := _spawn_stone(Vector3.RIGHT)
	await _fly(FLIGHT_FRAMES)
	assert_gt(target.damage_taken, 0.0,
		"a stone thrown into an enemy damaged it (took %.1f)" % target.damage_taken)
	assert_eq(target.damage_type, GameConsts.DamageType.PHYSICAL, "dealt as physical damage")
	target.queue_free()
	if is_instance_valid(stone):
		stone.queue_free()


## The contact the stone reads must name the OTHER body. This is the regression itself,
## checked at its source: _on_physics_collision can only be as right as the collider the
## physics server hands it, and it used to hand back the stone (or null).
func test_a_contact_names_the_other_body() -> void:
	var floor_body := StaticBody3D.new()
	floor_body.name = "StoneTestFloor"
	var fcol := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(20.0, 1.0, 20.0)
	fcol.shape = box
	floor_body.add_child(fcol)
	floor_body.collision_layer = GameConsts.MASK_WORLD
	_root().add_child(floor_body)
	floor_body.global_position = STONE_POS + Vector3(0.0, -4.0, 0.0)

	var stone := _spawn_stone(Vector3.DOWN)
	var tree := Engine.get_main_loop() as SceneTree
	var reported: Object = null
	for i in FLIGHT_FRAMES:
		await tree.physics_frame
		if not is_instance_valid(stone):
			break
		var st := PhysicsServer3D.body_get_direct_state(stone.get_rid())
		if st and st.get_contact_count() > 0:
			reported = st.get_contact_collider_object(0)
			break

	assert_ne(reported, null, "the landing stone's contact reported a collider object")
	assert_ne(reported, stone, "and it is the floor it hit, not the stone itself")
	assert_eq(reported, floor_body, "the contact names the body that was struck")
	floor_body.queue_free()
	if is_instance_valid(stone):
		stone.queue_free()
