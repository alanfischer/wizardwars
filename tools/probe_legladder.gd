extends SceneTree
## Reproduce ww_golem's per-leg ladder volume exactly as FuncGolemBody._add_leg_ladder
## builds it, then walk the player's LadderDetector cylinder up it and compare what the
## physics server reports against the analytic box. Isolates the ladder volume from the
## rest of the map.

const LADDER_MARGIN := 0.0


func _initialize() -> void:
	var root: Node3D = (load("user://resources/maps/ww_golem.scn") as PackedScene).instantiate()
	get_root().add_child(root)
	await physics_frame

	# The golem body's yaw, and the leg brush entities, straight out of the scene.
	var gs_yaw := 0.0
	var legs: Array = []
	for n in root.find_children("*", "AnimatableBody3D", true, false):
		var cn: String = n.get_meta("entity", {}).get("classname", "")
		if cn == "func_golem_body":
			var angles: String = n.get_meta("entity", {}).get("angles", "0 0 0")
			gs_yaw = deg_to_rad(float(angles.split(" ")[1]))
		if "leg" in cn:
			legs.append(n)
	print("golem yaw = %.1f°, legs found: %d" % [rad_to_deg(gs_yaw), legs.size()])
	if legs.is_empty():
		quit(1)
		return

	var leg: AnimatableBody3D = legs[0]
	print("leg: %s  global_origin=%s" % [leg.get_meta("entity", {}).get("classname", "?"),
		leg.global_transform.origin])

	# --- _add_leg_ladder, verbatim ---
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
		var f := p.dot(fwd); var l := p.dot(lat)
		min_f = minf(min_f, f); max_f = maxf(max_f, f)
		min_l = minf(min_l, l); max_l = maxf(max_l, l)
		min_y = minf(min_y, p.y); max_y = maxf(max_y, p.y)
	var depth := (max_f - min_f) + LADDER_MARGIN * 2.0
	var center_local := fwd * ((min_f + max_f) * 0.5) + lat * ((min_l + max_l) * 0.5) \
		+ Vector3(0.0, (min_y + max_y) * 0.5, 0.0)

	# Build the volume IN the map, next to everything else on the ladder layer.
	var bare := root
	var area := Area3D.new()
	area.name = "GolemLadder"
	area.collision_layer = GameConsts.MASK_LADDER
	area.collision_mask = 0
	area.monitoring = false
	area.monitorable = true
	var box := BoxShape3D.new()
	box.size = Vector3((max_l - min_l) + LADDER_MARGIN * 2.0,
		(max_y - min_y) + LADDER_MARGIN * 2.0, depth)
	var col := CollisionShape3D.new()
	col.shape = box
	col.position = center_local
	col.rotation.y = gs_yaw
	area.add_child(col)
	var wrapper := Node3D.new()
	wrapper.name = "GolemLadderWrapper"
	wrapper.set_script(load("res://src/entities/golem_ladder.gd"))
	wrapper.add_child(area)
	leg.add_child(wrapper)

	# The map's own func_ladder volumes, switched on the way FuncLadder._ready does.
	for n in root.find_children("*", "AnimatableBody3D", true, false):
		if n.get_meta("entity", {}).get("classname", "") == "func_ladder":
			n.collision_layer = 0
			var v := n.get_node("Volume") as Area3D
			v.collision_layer = GameConsts.MASK_LADDER
			v.collision_mask = 0
			v.monitorable = true
	await physics_frame
	await physics_frame

	print("box size=%s  centre(local)=%s  yaw=%.1f°" % [box.size, center_local, rad_to_deg(gs_yaw)])
	print("box world centre=%s" % [col.global_transform.origin])

	# The player's LadderDetector: cylinder h=1.8 r=0.4, its origin 0.9 above the feet.
	var det := CylinderShape3D.new()
	det.height = 1.8
	det.radius = 0.4
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = det
	q.collide_with_areas = true
	q.collide_with_bodies = false
	q.collision_mask = GameConsts.MASK_LADDER

	var space := bare.get_world_3d().direct_space_state
	var inv := col.global_transform.affine_inverse()
	var half := box.size * 0.5
	# Climb straight up the box's own centre line, feet from below the bottom to above
	# the top, and record where the server stops seeing the volume.
	var base: Vector3 = col.global_transform.origin
	var y0: float = base.y - half.y - 1.0
	var y1: float = base.y + half.y + 1.0
	var step := 0.05
	var y := y0
	var last_hit := -INF
	var first_hit := INF
	var gaps: Array = []
	var prev_hit := false
	var wrong_first: Array = []
	while y <= y1:
		var centre := Vector3(base.x, y + 0.9, base.z)   # detector centre for feet at y
		q.transform = Transform3D(Basis(), centre)
		var hits := space.intersect_shape(q, 4)
		var hit := not hits.is_empty()
		# check_ladder() reads hits[0] ONLY — if the first hit isn't a ladder node the
		# whole check returns false, so record when the first hit is the wrong one.
		if hit:
			var first: Node = hits[0].collider.get_parent()
			if not first.has_method("get_ladder_normal"):
				wrong_first.append(y)
		# Analytic: does the upright cylinder's AABB overlap the box? (cheap proxy —
		# exact enough on the centre line, where the cylinder is inside in XZ)
		var lo: Vector3 = inv * Vector3(centre.x, centre.y - 0.9, centre.z)
		var hi: Vector3 = inv * Vector3(centre.x, centre.y + 0.9, centre.z)
		var truth: bool = absf(lo.x) <= half.x + 0.4 and absf(lo.z) <= half.z + 0.4 \
			and lo.y <= half.y and hi.y >= -half.y
		if hit:
			first_hit = minf(first_hit, y)
			last_hit = maxf(last_hit, y)
		if truth and not hit:
			gaps.append(y)
		prev_hit = hit
		y += step

	print("feet range where the server reports the ladder: %.2f .. %.2f" % [first_hit, last_hit])
	print("box bottom=%.2f  top=%.2f  (feet can stand this high and still touch: %.2f)" % [
		base.y - half.y, base.y + half.y, base.y + half.y])
	print("heights where hits[0] is NOT a ladder node (check_ladder bails): %d" % wrong_first.size())
	if not wrong_first.is_empty():
		print("  from feet-y=%.2f to %.2f" % [wrong_first[0], wrong_first[wrong_first.size() - 1]])
	print("heights inside the volume the server MISSED: %d" % gaps.size())
	if not gaps.is_empty():
		print("  first missed feet-y=%.2f  last=%.2f" % [gaps[0], gaps[gaps.size() - 1]])
	quit(0)
