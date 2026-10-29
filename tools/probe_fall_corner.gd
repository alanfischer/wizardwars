extends SceneTree
## Reproduce the tick that loses a falling rider, with the golem STANDING STILL.
##
## At t79 of the walk+jump repro the rider is at body-local GS (-15.80, -80, -110)
## after the carry, falling 4.49 units and backpedalling 1.99 into the rear wall, and
## they end up at -114.5 — straight through a deck whose top is at -112.
##
## Everything about that tick except the query is circumstantial. A stationary golem has
## the same local geometry as a walking one, so if the query is wrong it is wrong here
## too, in seconds rather than two minutes — and if it is RIGHT here, the fault is in the
## motion/ordering rather than in the trace, which is just as useful to know.

const S := 0.025

var body_node: AnimatableBody3D
var player: CharacterBody3D


func gs_to_godot(x: float, y: float, z: float) -> Vector3:
	return Vector3(-x * S, z * S, y * S)


func local_gs(p: Vector3) -> Vector3:
	var l: Vector3 = body_node.global_transform.affine_inverse() * p
	return Vector3(-l.x / S, l.z / S, l.y / S)


## One body_test_motion at a body-local pose, with a body-local motion.
func shot(label: String, at: Vector3, motion_gs: Vector3) -> void:
	var xform := Transform3D(Basis.IDENTITY,
		body_node.global_transform * gs_to_godot(at.x, at.y, at.z))
	var motion: Vector3 = body_node.global_transform.basis * gs_to_godot(
		motion_gs.x, motion_gs.y, motion_gs.z)
	var p := PhysicsTestMotionParameters3D.new()
	p.from = xform
	p.motion = motion
	p.margin = player.safe_margin
	p.recovery_as_collision = true
	p.max_collisions = 4
	var r := PhysicsTestMotionResult3D.new()
	player.global_transform = xform
	PhysicsServer3D.body_test_motion(player.get_rid(), p, r)
	var travel: Vector3 = body_node.global_transform.basis.inverse() * r.get_travel()
	var msg := "%-34s unsafe=%.3f travel GS=(%6.2f,%6.2f,%7.2f)" % [
		label, r.get_collision_unsafe_fraction(),
		-travel.x / S, travel.z / S, travel.y / S]
	for i in r.get_collision_count():
		var n: Vector3 = body_node.global_transform.basis.inverse() * r.get_collision_normal(i)
		msg += " | n=(%.2f,%.2f,%.2f) d=%.2f" % [
			-n.x, n.z, n.y, r.get_collision_depth(i) / S]
	print(msg)


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
	player.collision_mask = GameConsts.MASK_WORLD_AND_CLIP | GameConsts.MASK_ENTITY
	player.safe_margin = 0.01
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.8
	cs.shape = cap
	cs.position = Vector3(0, 0.9, 0)
	player.add_child(cs)
	root.add_child(player)
	await physics_frame

	if OS.get_environment("DOOR") != "":
		# Is the left side of the cockpit open, and where? Rays only — hull-0, raw
		# brush planes, nothing that depends on the machinery under test.
		var sp := body_node.get_world_3d().direct_space_state
		print("\nLeft wall, shooting +y from the cockpit centre (x=-14):\n")
		print("      z |    y of wall")
		for zi in range(-110, -40, 4):
			var q := PhysicsRayQueryParameters3D.create(
				body_node.global_transform * gs_to_godot(-14.0, 0.0, float(zi)),
				body_node.global_transform * gs_to_godot(-14.0, 300.0, float(zi)))
			q.collision_mask = GameConsts.MASK_WORLD_AND_CLIP | GameConsts.MASK_ENTITY
			var hit := sp.intersect_ray(q)
			print("%7d | %s" % [zi,
				"OPEN — no wall" if hit.is_empty() else "%.2f" % local_gs(hit["position"]).y])

		print("\nRear wall, shooting -x at deck height (z=-100), across y:\n")
		print("      y |    x of wall")
		for yi in range(-92, 96, 8):
			var q := PhysicsRayQueryParameters3D.create(
				body_node.global_transform * gs_to_godot(-4.0, float(yi), -100.0),
				body_node.global_transform * gs_to_godot(-80.0, float(yi), -100.0))
			q.collision_mask = GameConsts.MASK_WORLD_AND_CLIP | GameConsts.MASK_ENTITY
			var hit2 := sp.intersect_ray(q)
			print("%7d | %s" % [yi,
				"OPEN — no wall" if hit2.is_empty() else "%.2f" % local_gs(hit2["position"]).x])
		quit(0)
		return

	if OS.get_environment("TWO") != "":
		# The t86 pose of the JUMP=8 repro: embedded 0.55 in the rear wall (where the
		# golem's advance leaves a rider every tick) and backpedalling into it. Good
		# ticks answer unsafe=0.11; bad ticks answer 1.00 and hand over the whole step.
		print("\n--- t86 start pose, backpedal 3.8 ---")
		shot("  as it happened", Vector3(-16.5457, -80.0152, -92.6117), Vector3(-3.8, 0, 0))
		print("\n--- swept across the embed depth (wall face is -16.0) ---")
		for xi in [-16.1, -16.3, -16.45, -16.5457, -16.6, -16.8, -17.2]:
			shot("  x=%7.3f" % xi, Vector3(xi, -80.0152, -92.6117), Vector3(-3.8, 0, 0))
		print("\n--- and across y, off the side wall seam at -80.0 ---")
		for yi in [-70.0, -78.0, -79.6, -79.9, -80.0152, -80.2]:
			shot("  y=%7.3f" % yi, Vector3(-16.5457, yi, -92.6117), Vector3(-3.8, 0, 0))
		quit(0)
		return

	if OS.get_environment("ONE") != "":
		# Just the one query that misbehaves, so hop's own tracing is readable.
		print("\n--- fall only at y=-75 (works) ---")
		shot("  y=-75.00", Vector3(-15.80, -75.00, -110.01), Vector3(0, 0, -4.493))
		print("\n--- fall only at y=-80.03 (falls through) ---")
		shot("  y=-80.03", Vector3(-15.80, -80.03, -110.01), Vector3(0, 0, -4.493))
		quit(0)
		return

	# The failing tick, exactly: the post-carry pose and the per-tick velocity.
	print("\nThe t79 tick (deck top is GS z = -112, wall expanded face is GS x = -16):\n")
	shot("t79 as it happened", Vector3(-15.80, -80.03, -110.01), Vector3(-1.985, -1.985, -4.493))

	print("\nDecomposed — which component loses it?\n")
	shot("  fall only", Vector3(-15.80, -80.03, -110.01), Vector3(0, 0, -4.493))
	shot("  backpedal only", Vector3(-15.80, -80.03, -110.01), Vector3(-1.985, 0, 0))
	shot("  back+fall, no strafe", Vector3(-15.80, -80.03, -110.01), Vector3(-1.985, 0, -4.493))

	print("\nSame motion, swept across the starting x (the wall face is -16.0):\n")
	for xi in [-15.2, -15.6, -15.8, -16.0, -16.2, -16.4, -16.6, -17.0]:
		shot("  x=%6.2f" % xi, Vector3(xi, -80.03, -110.01), Vector3(-1.985, -1.985, -4.493))

	print("\nSame motion, swept across the starting height (deck top -112):\n")
	for zi in [-104.0, -108.0, -110.0, -111.0, -111.9, -112.0]:
		shot("  z=%7.1f" % zi, Vector3(-15.80, -80.03, zi), Vector3(-1.985, -1.985, -4.493))

	# Rays first: never trust a hull query about geometry while hull queries are the
	# thing under test. Where are the cockpit's side walls at this x and height?
	print("\nRays sideways from the cockpit centre at x=-15.8, z=-100:\n")
	var space := body_node.get_world_3d().direct_space_state
	for target in [-200.0, 200.0]:
		var q := PhysicsRayQueryParameters3D.create(
			body_node.global_transform * gs_to_godot(-15.8, 0.0, -100.0),
			body_node.global_transform * gs_to_godot(-15.8, target, -100.0))
		q.collision_mask = GameConsts.MASK_WORLD_AND_CLIP | GameConsts.MASK_ENTITY
		var hit := space.intersect_ray(q)
		print("  toward y=%+7.1f -> %s" % [target,
			"MISS" if hit.is_empty() else "%.2f" % local_gs(hit["position"]).y])

	print("\nFALL ONLY, swept across y (is the pose inside a side wall?):\n")
	for yi in [0.0, -20.0, -40.0, -55.0, -60.0, -65.0, -70.0, -75.0, -80.03]:
		shot("  y=%6.1f" % yi, Vector3(-15.80, yi, -110.01), Vector3(0, 0, -4.493))

	print("\nFALL ONLY at cockpit centre, swept across x:\n")
	for xi in [-8.0, -12.0, -14.0, -15.8, -16.4, -20.0]:
		shot("  x=%6.1f" % xi, Vector3(xi, -40.0, -110.01), Vector3(0, 0, -4.493))
	quit(0)
