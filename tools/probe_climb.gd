extends SceneTree
## Where does the player hull actually fit around the golem's leg? Sweeps a standing
## capsule around the leg at each height and reports the free ring — if the channel
## pinches shut below the top of the ladder volume, that's what stops the climb.

func _initialize() -> void:
	var root: Node3D = (load("user://resources/maps/ww_golem.scn") as PackedScene).instantiate()
	get_root().add_child(root)
	await physics_frame
	await physics_frame

	var leg: AnimatableBody3D = null
	for n in root.find_children("*", "AnimatableBody3D", true, false):
		if "rightleg" in String(n.get_meta("entity", {}).get("classname", "")):
			leg = n
	if not leg:
		printerr("no leg")
		quit(1)
		return

	var mn := Vector3(INF, INF, INF)
	var mx := -mn
	for c in leg.get_children():
		if c is CollisionShape3D and c.shape is ConvexPolygonShape3D:
			for p in c.shape.points:
				var w: Vector3 = c.global_transform * p
				mn = mn.min(w)
				mx = mx.max(w)
	var axis := Vector3((mn.x + mx.x) * 0.5, 0.0, (mn.z + mx.z) * 0.5)
	print("leg world aabb %s .. %s" % [mn, mx])

	var cap := CapsuleShape3D.new()
	cap.height = 1.8
	cap.radius = 0.4
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = cap
	q.collide_with_bodies = true
	q.collide_with_areas = false
	q.collision_mask = GameConsts.MASK_WORLD_AND_CLIP | GameConsts.MASK_ENTITY

	var space := root.get_world_3d().direct_space_state
	# Sweep a ring around the leg axis at each height; a climber needs one free spot.
	print("feet_y | min free radius by heading (0/90/180/270)")
	var y := 1.5
	while y <= 9.0:
		var line := "%5.2f  |" % y
		for a in [0, 90, 180, 270]:
			var ang := deg_to_rad(float(a))
			var best := INF
			var r := 0.5
			while r <= 2.6:
				var p := axis + Vector3(cos(ang) * r, y + 0.9, sin(ang) * r)
				q.transform = Transform3D(Basis(), p)
				if space.intersect_shape(q, 1).is_empty():
					best = r
					break
				r += 0.05
			line += ("  none" if best == INF else "  %.2f" % best)
		print(line)
		y += 0.25
	quit(0)
