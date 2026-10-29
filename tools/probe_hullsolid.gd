extends SceneTree
## Is BSP-hull-backed geometry visible to intersect_shape/intersect_ray at all under hop?
## Probes worldspawn (a known-solid floor) and the golem leg, so a "leg not solid" result
## can be told apart from "hull carriers are invisible to shape queries".

func _initialize() -> void:
	var root: Node3D = (load("user://resources/maps/ww_golem.scn") as PackedScene).instantiate()
	get_root().add_child(root)
	await physics_frame
	await physics_frame

	var space := root.get_world_3d().direct_space_state
	var tiny := SphereShape3D.new()
	tiny.radius = 0.05
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = tiny
	q.collide_with_bodies = true
	q.collide_with_areas = false
	q.collision_mask = 0xFFFFFFFF

	var leg: AnimatableBody3D = null
	var world: Node3D = null
	for n in root.find_children("*", "AnimatableBody3D", true, false):
		var cn: String = n.get_meta("entity", {}).get("classname", "")
		if "rightleg" in cn:
			leg = n
		if cn == "worldspawn":
			world = n
	if not leg:
		printerr("no leg"); quit(1); return
	print("leg carrier=%s model=%s  world carrier=%s" % [
		leg.has_meta("bsp_model"), leg.get_meta("bsp_model", -1),
		world != null and world.has_meta("bsp_model")])

	# Control: find real floor under the leg with a ray, then probe just below it.
	var mn := Vector3(INF, INF, INF)
	var mx := -mn
	for c in leg.get_children():
		if c is CollisionShape3D and c.shape is ConvexPolygonShape3D:
			for p in c.shape.points:
				var w: Vector3 = c.global_transform * p
				mn = mn.min(w); mx = mx.max(w)
	var centre := (mn + mx) * 0.5
	print("leg aabb %s .. %s" % [mn, mx])

	var rp := PhysicsRayQueryParameters3D.create(centre, centre + Vector3.DOWN * 60.0)
	rp.collision_mask = 0xFFFFFFFF
	var r := space.intersect_ray(rp)
	print("ray down from leg centre -> %s" % ["MISS" if r.is_empty() else
		"%s at %s" % [r.collider.name, r.position]])
	if not r.is_empty():
		q.transform = Transform3D(Basis(), r.position + Vector3.DOWN * 0.15)
		var h := space.intersect_shape(q, 8)
		print("  sphere 0.15 below that floor -> %d hit(s) %s" % [h.size(),
			h.map(func(x): return x.collider.name)])

	# The leg itself: probe a dense grid through its AABB and report how much reads solid.
	var solid := 0
	var total := 0
	var hit_names := {}
	for ix in range(1, 6):
		for iy in range(1, 12):
			for iz in range(1, 6):
				var p := Vector3(
					lerpf(mn.x, mx.x, ix / 6.0),
					lerpf(mn.y, mx.y, iy / 12.0),
					lerpf(mn.z, mx.z, iz / 6.0))
				q.transform = Transform3D(Basis(), p)
				var hits := space.intersect_shape(q, 4)
				total += 1
				if not hits.is_empty():
					solid += 1
					for x in hits:
						hit_names[x.collider.name] = true
	print("leg AABB grid: %d/%d points read solid; colliders seen: %s" % [
		solid, total, hit_names.keys()])

	# And a ray straight through the leg, laterally.
	var a := Vector3(mn.x - 2.0, centre.y, centre.z)
	var b := Vector3(mx.x + 2.0, centre.y, centre.z)
	rp = PhysicsRayQueryParameters3D.create(a, b)
	rp.collision_mask = 0xFFFFFFFF
	r = space.intersect_ray(rp)
	print("lateral ray through leg -> %s" % ["MISS" if r.is_empty() else
		"%s at %s" % [r.collider.name, r.position]])
	quit(0)
