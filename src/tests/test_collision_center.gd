extends "res://src/tests/test_base.gd"
## SpatialQuery.collision_center: brush entities keep their node origin at the world origin with
## geometry off in child shapes, so distance/aim must use the shape center, not global_position.

func _box_body(positions: Array) -> StaticBody3D:
	var body := StaticBody3D.new()
	for p in positions:
		var cs := CollisionShape3D.new()
		var b := BoxShape3D.new()
		b.size = Vector3(2, 2, 2)
		cs.shape = b
		cs.position = p
		body.add_child(cs)
	_root().add_child(body)
	return body


func test_offset_box_uses_shape_center_not_origin() -> void:
	# Brush-like: body sits at the world origin, its collision is off at (10,5,-3).
	var body := _box_body([Vector3(10, 5, -3)])
	assert_vec3_almost_eq(SpatialQuery.collision_center(body), Vector3(10, 5, -3), 0.001,
		"center is the box, not the node origin")
	body.free()


func test_multiple_shapes_union_center() -> void:
	var body := _box_body([Vector3(0, 0, 0), Vector3(10, 0, 0)])
	assert_vec3_almost_eq(SpatialQuery.collision_center(body), Vector3(5, 0, 0), 0.001,
		"union AABB center of the two boxes")
	body.free()


func test_capsule_matches_player_center() -> void:
	# Player-like: capsule at a feet-origin body, shape raised to y=0.9, height 1.8.
	var body := CharacterBody3D.new()
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.height = 1.8
	cap.radius = 0.4
	cs.shape = cap
	cs.position = Vector3(0, 0.9, 0)
	body.add_child(cs)
	_root().add_child(body)
	assert_vec3_almost_eq(SpatialQuery.collision_center(body), GameConsts.PLAYER_CENTER, 0.001,
		"capsule center equals the old feet+PLAYER_CENTER estimate")
	body.free()


func test_nested_child_shape() -> void:
	# Shape buried under an intermediate node (e.g. a detector Area3D) still counts.
	var body := StaticBody3D.new()
	body.position = Vector3(100, 0, 0)
	var mid := Node3D.new()
	mid.position = Vector3(0, 4, 0)
	var cs := CollisionShape3D.new()
	var b := BoxShape3D.new()
	b.size = Vector3(2, 2, 2)
	cs.shape = b
	mid.add_child(cs)
	body.add_child(mid)
	_root().add_child(body)
	assert_vec3_almost_eq(SpatialQuery.collision_center(body), Vector3(100, 4, 0), 0.001,
		"descendant shape transforms compose through parents")
	body.free()


func test_shapeless_falls_back() -> void:
	var body := Node3D.new()
	body.position = Vector3(1, 2, 3)
	_root().add_child(body)
	assert_vec3_almost_eq(SpatialQuery.collision_center(body), Vector3(1, 2, 3) + GameConsts.PLAYER_CENTER,
		0.001, "no collision shapes -> feet+PLAYER_CENTER fallback")
	body.free()
