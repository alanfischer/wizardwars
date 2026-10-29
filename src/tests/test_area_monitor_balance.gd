extends "res://src/tests/test_base.gd"
## An Area3D's enter/exit reports have to stay balanced across the area's own lifecycle, not just
## across body movement. hop reports overlaps by diffing "who is inside now" against "who was inside
## last tick", and it can only run that diff while the area has a space, a callback and shapes — so
## every way of losing one of those used to drop the overlap on the floor: the listener never heard
## the body leave, and if the area came back with the body still standing there, the diff saw no
## change and never reported it again. That is a trigger that silently stops working.
##
## Scene-run only (needs the physics server + a live SceneTree): res://src/tests/run_tests.tscn.

var _entered: Array[Node] = []
var _exited: Array[Node] = []


func _make_area(shape_size: Vector3) -> Area3D:
	var area := Area3D.new()
	area.collision_layer = 0
	area.collision_mask = 0xFFFFFFFF
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = shape_size
	cs.shape = box
	cs.name = "Shape"
	area.add_child(cs)
	area.body_entered.connect(func(b): _entered.append(b))
	area.body_exited.connect(func(b): _exited.append(b))
	_root().add_child(area)
	_keep(area)
	return area


func _make_body() -> StaticBody3D:
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.5, 0.5, 0.5)
	cs.shape = box
	body.add_child(cs)
	_root().add_child(body)
	_keep(body)
	return body


func _setup_test(_name: String) -> void:
	super._setup_test(_name)
	_entered.clear()
	_exited.clear()


func test_a_body_inside_is_reported_entered() -> void:
	var area := _make_area(Vector3(4, 4, 4))
	var body := _make_body()
	await _tick(3)
	assert_eq(_entered.size(), 1, "precondition: the overlap is detected at all")
	assert_eq(_entered[0], body, "and it is the body we put there")


func test_losing_its_shape_reports_the_body_out() -> void:
	var area := _make_area(Vector3(4, 4, 4))
	var body := _make_body()
	await _tick(3)
	assert_eq(_entered.size(), 1, "precondition: inside")
	# The area keeps its space and its callback — it just has nothing to overlap with any more.
	(area.get_node(^"Shape") as CollisionShape3D).shape = null
	await _tick(3)
	assert_eq(_exited.size(), 1, "an area that can no longer test overlap still owes the exit")
	assert_eq(_exited[0], body, "for the body it was holding")


func test_the_shape_coming_back_re_reports_a_body_that_never_moved() -> void:
	var area := _make_area(Vector3(4, 4, 4))
	var body := _make_body()
	var box := BoxShape3D.new()
	box.size = Vector3(4, 4, 4)
	await _tick(3)
	var cs := area.get_node(^"Shape") as CollisionShape3D
	cs.shape = null
	await _tick(3)
	_entered.clear()
	cs.shape = box
	await _tick(3)
	assert_eq(_entered.size(), 1,
		"the body never moved, so only a balanced exit/enter pair keeps the trigger working")
	assert_eq(_entered[0], body, "and it is the same body")


func test_leaving_the_world_reports_the_body_out() -> void:
	var area := _make_area(Vector3(4, 4, 4))
	var body := _make_body()
	await _tick(3)
	assert_eq(_entered.size(), 1, "precondition: inside")
	body.queue_free()
	await _tick(3)
	assert_eq(_exited.size(), 1, "a body that leaves the world is reported out, not just forgotten")


func test_a_freed_body_does_not_come_back_when_a_new_one_arrives() -> void:
	var area := _make_area(Vector3(4, 4, 4))
	var first := _make_body()
	await _tick(3)
	first.queue_free()
	await _tick(3)
	_entered.clear()
	_exited.clear()
	var second := _make_body()
	await _tick(3)
	assert_eq(_entered.size(), 1, "the replacement is reported once")
	assert_eq(_entered[0], second, "as itself")
	assert_eq(_exited.size(), 0, "and nothing stale is reported out alongside it")
