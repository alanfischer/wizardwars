extends SceneTree
func _initialize() -> void:
	var root: Node3D = (load("user://resources/maps/ww_golem.scn") as PackedScene).instantiate()
	get_root().add_child(root)
	await physics_frame
	await physics_frame
	var leg: AnimatableBody3D = null
	for n in root.find_children("*", "AnimatableBody3D", true, false):
		if "rightleg" in String(n.get_meta("entity", {}).get("classname", "")):
			leg = n
	print("leg layer=%d mask=%d  shapes=%d  meta=%s" % [leg.collision_layer, leg.collision_mask,
		leg.get_child_count(), leg.get_meta_list()])
	print("MASK_WORLD_AND_CLIP=%d MASK_ENTITY=%d MASK_WORLD=%d" % [
		GameConsts.MASK_WORLD_AND_CLIP, GameConsts.MASK_ENTITY, GameConsts.MASK_WORLD])
	var pts := PackedVector3Array()
	for c in leg.get_children():
		if c is CollisionShape3D and c.shape is ConvexPolygonShape3D:
			print("  shape %s: %d pts" % [c.name, c.shape.points.size()])
			for p in c.shape.points:
				pts.append(c.global_transform * p)
	var centre := Vector3.ZERO
	for p in pts:
		centre += p
	centre /= pts.size()
	print("leg hull centroid = %s" % centre)
	# Per-cell centroids: a multi-cell leg can have its overall centroid in a hollow.
	var cell_centres: Array = []
	for c in leg.get_children():
		if c is CollisionShape3D and c.shape is ConvexPolygonShape3D:
			var cc := Vector3.ZERO
			for p in c.shape.points:
				cc += c.global_transform * p
			cc /= c.shape.points.size()
			cell_centres.append(cc)
			print("  cell %s centroid %s" % [c.name, cc])

	var space := root.get_world_3d().direct_space_state
	# A tiny sphere dead in the middle of the leg hull: must report the leg.
	var tiny := SphereShape3D.new()
	tiny.radius = 0.05
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = tiny
	q.collide_with_bodies = true
	q.collide_with_areas = false
	for m in [GameConsts.MASK_WORLD, GameConsts.MASK_ENTITY, GameConsts.MASK_WORLD_AND_CLIP, 0xFFFFFFFF]:
		q.collision_mask = m
		q.transform = Transform3D(Basis(), centre)
		var hits := space.intersect_shape(q, 8)
		var names := []
		for h in hits:
			names.append(str(h.collider.name) if h.collider else "<null>")
		print("  centroid probe mask=%-10d -> %d %s" % [m, hits.size(), names])
	# And the player capsule at the centroid.
	var cap := CapsuleShape3D.new()
	cap.height = 1.8
	cap.radius = 0.4
	q.shape = cap
	q.collision_mask = 0xFFFFFFFF
	q.transform = Transform3D(Basis(), centre)
	print("  capsule at centroid -> %d hit(s)" % space.intersect_shape(q, 8).size())

	q.shape = tiny
	q.collision_mask = 0xFFFFFFFF
	for cc in cell_centres:
		q.transform = Transform3D(Basis(), cc)
		print("  cell centroid %s -> %d hit(s)" % [cc, space.intersect_shape(q, 8).size()])

	# Control: is ANY body solid to this query? Probe straight down from the leg to the
	# floor and report what the ray finds, then probe just inside that surface.
	var rp := PhysicsRayQueryParameters3D.create(centre, centre + Vector3.DOWN * 50.0)
	rp.collision_mask = 0xFFFFFFFF
	var r := space.intersect_ray(rp)
	print("  ray down from leg centroid -> %s" % ["MISS" if r.is_empty() else "%s at %s" % [r.collider.name if r.collider else "<null>", r.position]])
	if not r.is_empty():
		q.transform = Transform3D(Basis(), r.position + Vector3.DOWN * 0.2)
		print("  sphere 0.2 below that surface -> %d hit(s)" % space.intersect_shape(q, 8).size())
	quit(0)
