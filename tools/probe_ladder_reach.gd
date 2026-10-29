extends SceneTree
## Can the player, standing where the physics engine actually lets it stand, still reach
## ww_golem's leg-ladder volume? Rebuilds the leg ladder exactly as FuncGolemBody does,
## then at each height slides the player hull in against the leg from four headings and
## runs check_ladder()'s detector from that resting spot. Run under both physics engines
## and diff: a height that reads LADDER under Godot and "-" under hop is the regression.

const LADDER_MARGIN := 0.1


func _initialize() -> void:
	print("engine = %s" % ProjectSettings.get_setting("physics/3d/physics_engine"))
	var root: Node3D = (load("user://resources/maps/ww_golem.scn") as PackedScene).instantiate()
	get_root().add_child(root)
	await physics_frame

	var gs_yaw := 0.0
	var leg: AnimatableBody3D = null
	for n in root.find_children("*", "AnimatableBody3D", true, false):
		var cn: String = n.get_meta("entity", {}).get("classname", "")
		if cn == "func_golem_body":
			gs_yaw = deg_to_rad(float(String(n.get_meta("entity", {}).get("angles", "0 0 0")).split(" ")[1]))
		if "rightleg" in cn:
			leg = n
	if not leg:
		printerr("no leg"); quit(1); return

	# --- FuncGolemBody._add_leg_ladder, verbatim ---
	var pts: Array[Vector3] = []
	for child in leg.get_children():
		if child is CollisionShape3D and child.shape is ConvexPolygonShape3D:
			for pt in child.shape.get_points():
				pts.append((child as CollisionShape3D).position + pt)
	var fwd := Vector3(sin(gs_yaw), 0.0, cos(gs_yaw)).normalized()
	var lat := Vector3(cos(gs_yaw), 0.0, -sin(gs_yaw)).normalized()
	var min_f := INF; var max_f := -INF
	var min_l := INF; var max_l := -INF
	var min_y := INF; var max_y := -INF
	for p in pts:
		min_f = minf(min_f, p.dot(fwd)); max_f = maxf(max_f, p.dot(fwd))
		min_l = minf(min_l, p.dot(lat)); max_l = maxf(max_l, p.dot(lat))
		min_y = minf(min_y, p.y); max_y = maxf(max_y, p.y)
	var center_local := fwd * ((min_f + max_f) * 0.5) + lat * ((min_l + max_l) * 0.5) \
		+ Vector3(0.0, (min_y + max_y) * 0.5, 0.0)

	var area := Area3D.new()
	area.collision_layer = GameConsts.MASK_LADDER
	area.collision_mask = 0
	area.monitoring = false
	area.monitorable = true
	var box := BoxShape3D.new()
	box.size = Vector3((max_l - min_l) + LADDER_MARGIN * 2.0,
		(max_y - min_y) + LADDER_MARGIN * 2.0, (max_f - min_f) + LADDER_MARGIN * 2.0)
	var col := CollisionShape3D.new()
	col.shape = box
	col.position = center_local
	col.rotation.y = gs_yaw
	area.add_child(col)
	leg.add_child(area)
	await physics_frame
	await physics_frame

	var axis: Vector3 = col.global_transform.origin
	print("ladder box size=%s  world centre=%s  (y %.2f .. %.2f)" % [box.size, axis,
		axis.y - box.size.y * 0.5, axis.y + box.size.y * 0.5])

	var space := root.get_world_3d().direct_space_state

	# Player hull and the LadderDetector cylinder, both posed from the feet position.
	var hull := CapsuleShape3D.new()
	hull.height = 1.8
	hull.radius = 0.4
	var hq := PhysicsShapeQueryParameters3D.new()
	hq.shape = hull
	hq.collision_mask = GameConsts.MASK_WORLD_AND_CLIP | GameConsts.MASK_ENTITY
	hq.collide_with_areas = false

	var det := CylinderShape3D.new()
	det.height = 1.8
	det.radius = 0.4
	var dq := PhysicsShapeQueryParameters3D.new()
	dq.shape = det
	dq.collision_mask = GameConsts.MASK_LADDER
	dq.collide_with_areas = true
	dq.collide_with_bodies = false

	print("feet_y | per heading (0/90/180/270): standoff from box face, LADDER or -")
	var y := 2.0
	while y <= 8.6:
		var line := "%5.2f |" % y
		for a in [0, 90, 180, 270]:
			var ang := deg_to_rad(float(a))
			var dir := Vector3(cos(ang), 0.0, sin(ang))
			# Start well clear of the leg and slide in until the hull is blocked.
			var start: Vector3 = axis + dir * 4.0 + Vector3(0.0, y + 0.9 - axis.y, 0.0)
			hq.transform = Transform3D(Basis(), start)
			hq.motion = -dir * 4.0
			var frac := space.cast_motion(hq)
			var stop: Vector3 = start - dir * 4.0 * (frac[0] if frac.size() > 0 else 1.0)
			# How far the hull's near face ends up from the ladder box's own face.
			var gap: float = (stop - axis).dot(dir) - hull.radius
			dq.transform = Transform3D(Basis(), stop)
			var on: bool = not space.intersect_shape(dq, 4).is_empty()
			line += "  %6.3f %s" % [gap, "LADDER" if on else "-     "]
		print(line)
		y += 0.2
	quit(0)
