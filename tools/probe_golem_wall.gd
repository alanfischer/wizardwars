extends SceneTree
## Where, under the BSP hull trace, does the golem's rear cockpit wall actually
## stop a standing player? Walks the hull back along the body's -x axis at the
## cockpit floor height and prints, per unit, what a small step further back and
## a zero-motion recovery report. Static geometry only — the golem never moves.

const S := 0.025

var body_node: AnimatableBody3D
var player: CharacterBody3D
var back: Vector3


func gs_to_godot(x: float, y: float, z: float) -> Vector3:
	return Vector3(-x * S, z * S, y * S)


func _initialize() -> void:
	var root: Node3D = (load("user://resources/maps/ww_golem.scn") as PackedScene).instantiate()
	get_root().add_child(root)
	for i in 20:
		await physics_frame
	for n in root.find_children("*", "AnimatableBody3D", true, false):
		if String(n.get_meta("entity", {}).get("classname", "")) == "func_golem_body":
			body_node = n

	player = CharacterBody3D.new()
	player.collision_layer = 0
	player.collision_mask = 33
	player.safe_margin = float(OS.get_environment("MARGIN")) if OS.get_environment("MARGIN") != "" else 0.01
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.8
	cs.shape = cap
	cs.position = Vector3(0, 0.9, 0)
	player.add_child(cs)
	root.add_child(player)
	back = (body_node.global_transform.basis * gs_to_godot(-1.0, 0.0, 0.0)).normalized()

	var feet_z := -112.3
	if OS.get_environment("Z") != "":
		feet_z = float(OS.get_environment("Z"))
	print("Feet at body-local GS z=%.1f, y=0. Stepping the hull back along -x." % feet_z)
	print("blocked = how much of a 0.05 m step further back the hull is allowed.\n")
	print("   x | unsafe | recovery normal        depth   | sweep normal")
	for xi in range(-10, -61, -1):
		var x := float(xi)
		player.global_position = body_node.global_transform * gs_to_godot(x, 0.0, feet_z)
		PhysicsServer3D.body_set_state(player.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, player.global_transform)
		await physics_frame
		var params := PhysicsTestMotionParameters3D.new()
		params.from = player.global_transform
		params.motion = back * (float(OS.get_environment("STEP")) if OS.get_environment("STEP") != "" else 0.05)
		params.margin = player.safe_margin
		params.recovery_as_collision = true
		params.max_collisions = 4
		var res := PhysicsTestMotionResult3D.new()
		PhysicsServer3D.body_test_motion(player.get_rid(), params, res)
		var rec := "(none)"
		var swp := "(none)"
		for i in res.get_collision_count():
			var d := res.get_collision_depth(i)
			var n := res.get_collision_normal(i)
			if d > 0.0:
				rec = "%s  %.4f" % [n, d]
			elif swp == "(none)":
				swp = str(n)
		print("%4d |  %.3f | %-30s | %s" % [xi, res.get_collision_unsafe_fraction(), rec, swp])
	quit(0)
