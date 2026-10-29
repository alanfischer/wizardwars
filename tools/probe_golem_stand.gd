extends SceneTree
## Does the crouched headroom test actually answer the standing question?
##
## update_crouch only grows the hull when has_headroom() says the space above is
## clear. That test sweeps the CROUCHED capsule upward — which under hop selects BSP
## hull 3, expanded 18 units in z — to decide whether the body will fit STANDING,
## which is hull 1, expanded 36. Those are different solids. Where they disagree,
## the player is grown into geometry and the recovery has to throw them out.
##
## Walks the cockpit deck and prints, per unit of x: what the crouched headroom sweep
## says, and what a standing hull at the very same place actually reports.
##
## Usage: [Z=-112] [BOB=<gs units the deck is raised>] tools/probe_golem_stand.gd

const S := 0.025

var body_node: AnimatableBody3D
var player: CharacterBody3D
var cs: CollisionShape3D


func gs_to_godot(x: float, y: float, z: float) -> Vector3:
	return Vector3(-x * S, z * S, y * S)


func dir_local_gs(v: Vector3) -> Vector3:
	var l: Vector3 = body_node.global_transform.basis.inverse() * v
	return Vector3(-l.x / S, l.z / S, l.y / S).normalized()


func set_height(h: float) -> void:
	cs.shape.height = h
	cs.position.y = h * 0.5


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
	player.safe_margin = 0.01
	cs = CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cs.shape = cap
	player.add_child(cs)
	root.add_child(player)

	var feet_z := float(OS.get_environment("Z")) if OS.get_environment("Z") != "" else -112.0
	var up := PhysicsTestMotionParameters3D.new()
	up.recovery_as_collision = false
	up.margin = player.safe_margin
	var here := PhysicsTestMotionParameters3D.new()
	here.motion = Vector3.ZERO
	here.recovery_as_collision = true
	here.max_collisions = 4
	here.margin = player.safe_margin
	var res := PhysicsTestMotionResult3D.new()

	var zs := [-112.0, -113.0, -114.0, -116.0, -118.0]
	if OS.get_environment("Z") != "":
		zs = [feet_z]
	print("Only spots a CROUCHED rider can actually be are considered (crouched hull not")
	print("embedded). Flags where has_headroom says clear but the STANDING hull is thrown")
	print("more than the 0.4-unit safe margin.\n")
	for fz in zs:
		var bad := 0
		var checked := 0
		var worst := 0.0
		var worst_at := ""
		for xi in range(-16, 17, 1):
			for yi in range(-16, 17, 2):
				player.global_position = body_node.global_transform * gs_to_godot(float(xi), float(yi), fz)

				# Is this a place a crouched rider can be at all?
				set_height(0.9)
				PhysicsServer3D.body_set_state(
					player.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, player.global_transform)
				await physics_frame
				here.from = player.global_transform
				PhysicsServer3D.body_test_motion(player.get_rid(), here, res)
				var crouch_push := res.get_travel().length() / S
				if crouch_push > 0.6:
					continue  # already embedded crouched — not a reachable spot
				checked += 1

				# The test update_crouch runs, on the CROUCHED hull.
				up.from = player.global_transform
				up.motion = Vector3.UP * 0.9
				PhysicsServer3D.body_test_motion(player.get_rid(), up, res)
				var clear: bool = res.get_collision_unsafe_fraction() >= 1.0
				if not clear:
					continue  # correctly refused to stand

				# What the STANDING hull says at that same spot.
				set_height(1.8)
				PhysicsServer3D.body_set_state(
					player.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, player.global_transform)
				await physics_frame
				here.from = player.global_transform
				PhysicsServer3D.body_test_motion(player.get_rid(), here, res)
				var mv := dir_local_gs(res.get_travel()) * (res.get_travel().length() / S)
				if res.get_travel().length() < 1e-9:
					mv = Vector3.ZERO
				var thrown: float = Vector3(mv.x, mv.y, 0.0).length()
				if thrown > worst:
					worst = thrown
					worst_at = "x=%d y=%d -> (%.1f,%.1f,%.1f)" % [xi, yi, mv.x, mv.y, mv.z]
				if thrown > 0.6:
					bad += 1
		print("feet z=%6.1f  %3d reachable crouched spots, %3d grow into solid   worst %s" % [
			fz, checked, bad, worst_at if worst_at != "" else "(none)"])
	quit(0)
