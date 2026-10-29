extends SceneTree
## Where does a player actually stop against ww_monoliths' spawn gates?
##
## The gates (func_door_rotating "gate_1", spawnflags 163 = START_OPEN|BACKWARDS|
## NO_AUTO_RETURN|ROTATE_X) are flat 256x192x16 plates authored lying down and
## rotated 90 deg to stand as a closed wall. A GoldSrc clip hull is expanded for a
## 32x32x72 box in the model's OWN frame — 16 sideways, 36 up — so rotating the
## model rotates the anisotropy with it. This measures the gap between where a
## ray hits the plate and where a player-sized capsule stops in front of it, and
## compares that against a plain world wall.

const S := 0.025


func gs_to_godot(x: float, y: float, z: float) -> Vector3:
	return Vector3(-x * S, z * S, y * S)


func _initialize() -> void:
	var root: Node3D = (load("user://resources/maps/ww_monoliths.scn") as PackedScene).instantiate()
	get_root().add_child(root)
	for i in 10:
		await physics_frame

	var gates: Array[Node3D] = []
	for n in root.find_children("*", "AnimatableBody3D", true, false):
		var e: Dictionary = n.get_meta("entity", {})
		if String(e.get("targetname", "")) == "gate_1":
			gates.append(n)
	print("gates found: ", gates.size())

	var player := CharacterBody3D.new()
	player.collision_layer = 0
	player.collision_mask = GameConsts.MASK_WORLD_AND_CLIP
	player.safe_margin = 0.01
	var shape := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.8
	shape.shape = cap
	shape.position = Vector3(0, 0.9, 0)
	player.add_child(shape)
	root.add_child(player)

	var params := PhysicsTestMotionParameters3D.new()
	params.margin = player.safe_margin
	params.recovery_as_collision = true
	params.max_collisions = 4
	var res := PhysicsTestMotionResult3D.new()
	var space := root.get_world_3d().direct_space_state

	for gate in gates:
		var ent: Dictionary = gate.get_meta("entity", {})
		print("\n=== gate ", gate.name, " origin=", ent.get("origin", ""),
			" spawnflags=", ent.get("spawnflags", ""))
		print("  node xform pos=", gate.global_position, " rot_deg=", gate.global_rotation_degrees)
		print("  has bsp_model meta: ", gate.has_meta("bsp_model"),
			" model=", gate.get_meta("bsp_model", -1), " layer=", gate.collision_layer)
		var mesh_aabb := AABB()
		var first := true
		for c in gate.get_children():
			if c is MeshInstance3D:
				var a: AABB = (c as MeshInstance3D).get_aabb()
				if first:
					mesh_aabb = a
					first = false
				else:
					mesh_aabb = mesh_aabb.merge(a)
		print("  local mesh aabb pos=", mesh_aabb.position, " size=", mesh_aabb.size)

		# Closed pose, exactly as FuncDoorRotating._ready computes it:
		# ROTATE_X -> axis (0,0,1); BACKWARDS flips it; START_OPEN swaps so the
		# spawn pose is the rotated one.
		gate.sync_to_physics = false
		var closed_rot := gate.rotation + Vector3(0, 0, deg_to_rad(-90.0))
		for pose in ["as-spawned", "closed(-90 about Z)"]:
			if pose.begins_with("closed"):
				gate.rotation = closed_rot
				PhysicsServer3D.body_set_state(gate.get_rid(),
					PhysicsServer3D.BODY_STATE_TRANSFORM, gate.global_transform)
				await physics_frame
				await physics_frame
			var g_aabb: AABB = gate.global_transform * mesh_aabb
			print("  [", pose, "] world aabb pos=", g_aabb.position, " size=", g_aabb.size,
				" center=", g_aabb.get_center())

			# Probe each horizontal face of the world AABB: shoot a ray inward from
			# 3 m out at eye height, then sweep the capsule along the same line.
			for dir_i in 4:
				var dir: Vector3 = [Vector3.RIGHT, Vector3.LEFT, Vector3.FORWARD, Vector3.BACK][dir_i]
				var c := g_aabb.get_center()
				var half := g_aabb.size * 0.5
				var face_off := Vector3(half.x * absf(dir.x), 0, half.z * absf(dir.z))
				var start: Vector3 = c - dir * (face_off.length() + 3.0)
				start.y = g_aabb.position.y + minf(1.0, g_aabb.size.y * 0.5)
				var rq := PhysicsRayQueryParameters3D.create(start, start + dir * 6.0)
				rq.collision_mask = GameConsts.MASK_WORLD_AND_CLIP
				var hit := space.intersect_ray(rq)
				if hit.is_empty():
					continue
				var ray_d: float = (hit.position - start).length()
				var who: Node = hit.collider
				# Capsule sweep from the same start, feet at the ray height minus 1.0
				player.global_position = start - Vector3(0, 1.0, 0)
				PhysicsServer3D.body_set_state(player.get_rid(),
					PhysicsServer3D.BODY_STATE_TRANSFORM, player.global_transform)
				await physics_frame
				params.from = player.global_transform
				params.motion = dir * 6.0
				PhysicsServer3D.body_test_motion(player.get_rid(), params, res)
				var travel: float = res.get_travel().length()
				var man := ""
				for i in res.get_collision_count():
					man += " n=%v d=%.3f" % [res.get_collision_normal(i), res.get_collision_depth(i)]
				print("    dir=%v ray hits %s at %.3f m | capsule stops at %.3f m -> standoff %.3f m (%.1f GS units)%s" % [
					dir, who.name if who else "?", ray_d, travel, ray_d - travel,
					(ray_d - travel) / S, man])

	# Control: the same measurement against ordinary world geometry near the gate.
	print("\n=== control: world wall sweep near team-1 base")
	var probe_start := gs_to_godot(-2600.0, 1296.0, 96.0)
	for dir in [Vector3.RIGHT, Vector3.LEFT, Vector3.FORWARD, Vector3.BACK]:
		var rq := PhysicsRayQueryParameters3D.create(probe_start, probe_start + dir * 30.0)
		rq.collision_mask = GameConsts.MASK_WORLD_AND_CLIP
		var hit := space.intersect_ray(rq)
		if hit.is_empty():
			continue
		var ray_d: float = (hit.position - probe_start).length()
		player.global_position = probe_start - Vector3(0, 1.0, 0)
		PhysicsServer3D.body_set_state(player.get_rid(),
			PhysicsServer3D.BODY_STATE_TRANSFORM, player.global_transform)
		await physics_frame
		params.from = player.global_transform
		params.motion = dir * 30.0
		PhysicsServer3D.body_test_motion(player.get_rid(), params, res)
		var travel: float = res.get_travel().length()
		print("  dir=%v ray %.3f m | capsule %.3f m -> standoff %.3f m (%.1f GS units) hit=%s" % [
			dir, ray_d, travel, ray_d - travel, (ray_d - travel) / S,
			(hit.collider as Node).name if hit.collider else "?"])

	quit(0)
