extends "res://src/tests/test_base.gd"
## Guards the spawn-guard comet de-dup contract: _target_node is assigned AFTER _ready via
## set_target(), which is where Comet._incoming registration has to happen or two overlapping
## guards could double-comet the same intruder.


class FakeTarget:
	extends Node3D
	var is_dead := false


func _make_comet(target: Node3D) -> Comet:
	var c := Comet.new()
	_root().add_child(c)  # _ready runs here; _target_node still null, no registration
	c.setup({"position": Vector3.ZERO, "target_pos": Vector3.ZERO}, true)
	c.set_target(target)
	return c


func test_set_target_registers_incoming() -> void:
	var t := FakeTarget.new()
	_root().add_child(t)
	assert_false(Comet.has_incoming(t), "no comet incoming before spawn")
	var c := _make_comet(t)
	assert_true(Comet.has_incoming(t), "set_target registers the comet as incoming on its target")
	c.queue_free()
	t.queue_free()


func test_has_incoming_false_without_target() -> void:
	assert_false(Comet.has_incoming(null), "null target is never 'incoming'")


func test_incoming_clears_on_free() -> void:
	var t := FakeTarget.new()
	_root().add_child(t)
	var c := _make_comet(t)
	assert_true(Comet.has_incoming(t), "incoming while alive")
	c._exploded = true  # suppress _exit_tree explosion effect
	c.free()            # immediate free so _exit_tree runs synchronously
	assert_false(Comet.has_incoming(t), "incoming clears when the comet leaves the tree")
	t.queue_free()
