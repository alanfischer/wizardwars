extends "res://src/tests/test_base.gd"
## Combat.hitscan excludes every damageable CharacterBody3D capsule and relies entirely on
## the MASK_HITBOX Area3Ds a model carries, so a physics backend that ignores areas in
## intersect_ray/cast_motion makes bolts pass straight through enemies with no other symptom.

const HITBOX_SIZE := Vector3(1, 1, 1)


## Damageable stand-in: a body with one hitbox Area3D, like a wizard model's bones.
func _target(pos: Vector3, group := 0) -> CharacterBody3D:
	var body := CharacterBody3D.new()
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.height = 1.8
	cap.radius = 0.4
	cs.shape = cap
	body.add_child(cs)
	body.set_script(preload("res://src/tests/helpers/damage_probe.gd"))
	body.add_to_group("damageable")

	var area := Area3D.new()
	area.collision_layer = GameConsts.MASK_HITBOX
	area.collision_mask = 0
	area.monitoring = false
	area.monitorable = true
	area.set_meta("hitbox_group", group)
	var acs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = HITBOX_SIZE
	acs.shape = box
	area.add_child(acs)
	body.add_child(area)

	_root().add_child(body)
	body.global_position = pos
	return body


func _wall(pos: Vector3) -> StaticBody3D:
	var wall := StaticBody3D.new()
	wall.collision_layer = GameConsts.MASK_WORLD
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4, 4, 0.5)
	cs.shape = box
	wall.add_child(cs)
	_root().add_child(wall)
	wall.global_position = pos
	return wall


func _shooter() -> Node3D:
	var n := Node3D.new()
	_root().add_child(n)
	return n


func _fire(shooter: Node3D, target_body: Node3D = null) -> Dictionary:
	var excludes: Array[RID] = Combat.collect_hitscan_excludes(shooter)
	if target_body:
		# Whole-tree exclusion, the way a shooter's own bodies are excluded.
		Combat._collect_collision_rids(target_body, excludes)
	return Combat.hitscan(shooter, Vector3.ZERO, Vector3.FORWARD, 20.0, RID(),
		GameConsts.MASK_HITSCAN, true, excludes)


func test_hitscan_hits_hitbox_area() -> void:
	var shooter := _shooter()
	var target := _target(Vector3(0, 0, -5))
	await _settle()
	var ray := _fire(shooter)
	assert_false(ray.result.is_empty(), "hitscan must report a hit on the hitbox Area3D")
	if not ray.result.is_empty():
		assert_true(ray.result.collider is Area3D, "collider is the hitbox area, not the capsule")
		assert_almost_eq(ray.impact_pos.z, -4.5, 0.2, "impact lands on the near face of the hitbox")
	target.free()
	shooter.free()


func test_hitscan_applies_damage() -> void:
	var shooter := _shooter()
	var target := _target(Vector3(0, 0, -5))
	await _settle()
	var applied := Combat.apply_hitscan_damage(_fire(shooter), 10.0,
		GameConsts.DamageType.LIGHTNING, shooter)
	assert_true(applied, "damage reaches the body that owns the hitbox")
	assert_almost_eq(target.damage_taken, 10.0, 0.001, "full damage on a body hit")
	target.free()
	shooter.free()


func test_headshot_multiplier() -> void:
	var shooter := _shooter()
	var target := _target(Vector3(0, 0, -5), GameConsts.HITBOX_GROUP_HEAD)
	await _settle()
	Combat.apply_hitscan_damage(_fire(shooter), 10.0, GameConsts.DamageType.LIGHTNING, shooter)
	assert_almost_eq(target.damage_taken, 10.0 * GameConsts.HEADSHOT_MULT, 0.001,
		"head-group hitbox multiplies damage")
	target.free()
	shooter.free()


func test_excluded_hitbox_is_not_hit() -> void:
	# The shooter's own hitboxes are excluded by RID — a bolt never hits its owner.
	var shooter := _shooter()
	var target := _target(Vector3(0, 0, -5))
	await _settle()
	var ray := _fire(shooter, target)
	assert_true(ray.result.is_empty(), "an excluded hitbox area must not register")
	target.free()
	shooter.free()


func test_wall_occludes_hitbox() -> void:
	var shooter := _shooter()
	var wall := _wall(Vector3(0, 0, -2))
	var target := _target(Vector3(0, 0, -5))
	await _settle()
	var ray := _fire(shooter)
	assert_false(ray.result.is_empty(), "the wall itself is hit")
	if not ray.result.is_empty():
		assert_false(ray.result.collider is Area3D, "the wall wins over the hitbox behind it")
		assert_almost_eq(ray.impact_pos.z, -1.75, 0.3, "impact is at the wall, not past it")
	assert_almost_eq(target.damage_taken, 0.0, 0.001, "no damage through a wall")
	target.free()
	wall.free()
	shooter.free()
