extends SceneTree
## Follow-up to probe_monolith_gate.gd: WHY is a closed ww_monoliths gate lopsided?
##
## The closed gate stops a player 72 GS units short on one side and lets the
## capsule reach the surface on the other. 72 = 36 + 36 and 0 = 36 - 36, which is
## the standing hull's Z offset (mins.z - clip_mins.z = 0 - -36) applied along the
## WRONG axis: hop adds it in the model's local frame, after rotating the trace
## into it, where GoldSrc subtracts it in world space first.
##
## Three movers make that testable without touching the engine:
##   standing (origin at feet)  offset 36 -> expect 72 / 0
##   crouched (origin at feet)  offset 18 -> expect 36 / 0
##   standing, origin centred   offset  0 -> expect 36 / 36  (symmetric)

const S := 0.025


func _initialize() -> void:
	var root: Node3D = (load("user://resources/maps/ww_monoliths.scn") as PackedScene).instantiate()
	get_root().add_child(root)
	for i in 10:
		await physics_frame

	var want_model := 25
	var yaw := -90.0
	for a in OS.get_cmdline_user_args():
		if a.begins_with("model="): want_model = int(a.substr(6))
		if a.begins_with("rot="): yaw = float(a.substr(4))
	var gate: Node3D = null
	for n in root.find_children("*", "AnimatableBody3D", true, false):
		var e: Dictionary = n.get_meta("entity", {})
		if String(e.get("targetname", "")) == "gate_1" and int(n.get_meta("bsp_model", -1)) == want_model:
			gate = n
	gate.sync_to_physics = false
	gate.rotation += Vector3(0, 0, deg_to_rad(yaw))
	PhysicsServer3D.body_set_state(gate.get_rid(),
		PhysicsServer3D.BODY_STATE_TRANSFORM, gate.global_transform)
	await physics_frame
	await physics_frame

	var player := CharacterBody3D.new()
	player.collision_layer = 0
	player.collision_mask = GameConsts.MASK_WORLD_AND_CLIP
	player.safe_margin = 0.01
	var shape := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	shape.shape = cap
	player.add_child(shape)
	root.add_child(player)

	var params := PhysicsTestMotionParameters3D.new()
	params.margin = player.safe_margin
	params.recovery_as_collision = true
	params.max_collisions = 4
	var res := PhysicsTestMotionResult3D.new()
	var space := root.get_world_3d().direct_space_state

	# name, capsule height, shape y offset, feet-to-eye of the probe line
	var cases := [
		["standing, origin at feet", 1.8, 0.9],
		["crouched, origin at feet", 0.9, 0.45],
		["standing, origin centred", 1.8, 0.0],
	]
	print("\ngate ", want_model, " rot ", yaw, ", closed." , " standoff = distance from the capsule axis to the surface")
	print("the ray hit. 16 GS units is what a plain world wall gives.\n")
	for case in cases:
		var label: String = case[0]
		cap.height = case[1]
		cap.radius = 0.4
		shape.position = Vector3(0, case[2], 0)
		for dir: Vector3 in [Vector3.RIGHT, Vector3.LEFT]:
			var probe_h := 2.0
			var start: Vector3 = Vector3(gate.global_position.x, probe_h, gate.global_position.z) - dir * 3.0
			var rq := PhysicsRayQueryParameters3D.create(start, start + dir * 6.0)
			rq.collision_mask = GameConsts.MASK_WORLD_AND_CLIP
			var hit := space.intersect_ray(rq)
			if hit.is_empty():
				print("  %-26s dir=%v  no ray hit" % [label, dir])
				continue
			var ray_d: float = (hit.position - start).length()
			player.global_position = start - Vector3(0, case[2], 0)
			PhysicsServer3D.body_set_state(player.get_rid(),
				PhysicsServer3D.BODY_STATE_TRANSFORM, player.global_transform)
			await physics_frame
			params.from = player.global_transform
			params.motion = dir * 6.0
			PhysicsServer3D.body_test_motion(player.get_rid(), params, res)
			var travel: float = res.get_travel().length()
			print("  %-26s dir=%+d  ray %.3f  stop %.3f  standoff %.3f m (%.1f GS units)" % [
				label, int(dir.x), ray_d, travel, ray_d - travel, (ray_d - travel) / S])
		print("")

	quit(0)
