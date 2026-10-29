extends SceneTree
## Two-dimensional scan of the golem's rear cockpit wall for a CROUCHED rider (BSP
## hull 3). For each (x, feet z) in body-local GoldSrc units it prints the direction
## and depth the zero-motion recovery wants to push the hull, expressed back in the
## body's own frame. A recovery that points DOWN (-z) where the rider is only in the
## wall is the ejection-through-the-deck signature.
##
## Usage: [H=0.9] tools/probe_golem_crouch_wall.gd

const S := 0.025

var body_node: AnimatableBody3D
var player: CharacterBody3D


func gs_to_godot(x: float, y: float, z: float) -> Vector3:
	return Vector3(-x * S, z * S, y * S)


## A world-space direction back into the body's own GoldSrc axes.
func dir_local_gs(v: Vector3) -> Vector3:
	var l: Vector3 = body_node.global_transform.basis.inverse() * v
	return Vector3(-l.x / S, l.z / S, l.y / S).normalized()


func _initialize() -> void:
	var root: Node3D = (load("user://resources/maps/ww_golem.scn") as PackedScene).instantiate()
	get_root().add_child(root)
	for i in 20:
		await physics_frame
	for n in root.find_children("*", "AnimatableBody3D", true, false):
		if String(n.get_meta("entity", {}).get("classname", "")) == "func_golem_body":
			body_node = n

	var h := float(OS.get_environment("H")) if OS.get_environment("H") != "" else 0.9
	player = CharacterBody3D.new()
	player.collision_layer = 0
	player.collision_mask = 33
	player.safe_margin = 0.01
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = h
	cs.shape = cap
	cs.position = Vector3(0, h * 0.5, 0)
	player.add_child(cs)
	root.add_child(player)

	var params := PhysicsTestMotionParameters3D.new()
	params.motion = Vector3.ZERO
	params.margin = player.safe_margin
	params.recovery_as_collision = true
	params.max_collisions = 4
	var res := PhysicsTestMotionResult3D.new()
	var rest_query := PhysicsShapeQueryParameters3D.new()
	rest_query.collision_mask = 417
	rest_query.exclude = [player.get_rid()]

	var xs := range(-10, -25, -1)
	if OS.get_environment("X") != "":
		xs = [int(OS.get_environment("X"))]
	print("hull height %.2f m (%.0f units).\n" % [h, h / S])
	for zi in range(-118, -104, 1):
		var line := "%6d |" % zi
		for xi in xs:
			player.global_position = body_node.global_transform * gs_to_godot(float(xi), 0.0, float(zi))
			PhysicsServer3D.body_set_state(
				player.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, player.global_transform)
			await physics_frame
			params.from = player.global_transform
			PhysicsServer3D.body_test_motion(player.get_rid(), params, res)
			# The recovery translation is what actually moves the body; travel is it
			# exactly, because the motion is zero.
			var mv := dir_local_gs(res.get_travel()) * (res.get_travel().length() / S)
			if res.get_travel().length() < 1e-9:
				mv = Vector3.ZERO
			line += "  moves (%5.1f,%5.1f,%5.1f) |" % [mv.x, mv.y, mv.z]
			for i in res.get_collision_count():
				line += " [%d] n=%s d=%.1f |" % [
					i, dir_local_gs(res.get_collision_normal(i)),
					res.get_collision_depth(i) / S]
			# What _apply_hull_corrections actually reads. normal.y > 0.7 makes it
			# treat the contact as ground and skip both the pusher and depenetration.
			rest_query.shape = cs.shape
			rest_query.transform = cs.global_transform
			var rest: Dictionary = player.get_world_3d().direct_space_state.get_rest_info(rest_query)
			if rest.is_empty():
				line += " rest: none"
			else:
				var rn: Vector3 = rest["normal"]
				line += " rest n=%s (world y=%+.2f) -> %s" % [
					dir_local_gs(rn), rn.y,
					"SKIPPED as ground" if rn.y > 0.7 else "pusher+depen run"]
		print(line)
	quit(0)
