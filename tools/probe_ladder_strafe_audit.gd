extends SceneTree
## At every spot a climber can actually occupy on every map ladder: with the player facing
## the face they are on, does a strafe input move them sideways, or does the movement code
## turn it into pure climb/descend? Compares the shipped render-face scan against the
## trace-based normal (and reports free-climb volumes, which keep the old behaviour).

const InputCommand = preload("res://addons/pmove/input_command.gd")
const MovementConfig = preload("res://addons/pmove/movement_config.gd")
const LadderWater = preload("res://addons/pmove/ladder_water.gd")
const FREECLIMB_THICKNESS := 3.0

var _space: PhysicsDirectSpaceState3D
var _faces := {}


func _shipped_normal(node: Node, feet: Vector3) -> Vector3:
	if not _faces.has(node):
		var tris: Array = []
		var sum := Vector3.ZERO
		for child in node.get_children():
			var mi := child as MeshInstance3D
			if not mi or not mi.mesh:
				continue
			for si in range(mi.mesh.get_surface_count()):
				var arr: Array = mi.mesh.surface_get_arrays(si)
				var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
				var idx = arr[Mesh.ARRAY_INDEX]
				if idx and idx.size() > 0:
					for i in range(0, idx.size() - 2, 3):
						tris.append([mi.global_transform * v[idx[i]], mi.global_transform * v[idx[i+1]], mi.global_transform * v[idx[i+2]]])
				else:
					for i in range(0, v.size() - 2, 3):
						tris.append([mi.global_transform * v[i], mi.global_transform * v[i+1], mi.global_transform * v[i+2]])
		var ns := PackedVector3Array()
		var cs := PackedVector3Array()
		if not tris.is_empty():
			for t in tris:
				sum += t[0] + t[1] + t[2]
			var c: Vector3 = sum / (tris.size() * 3)
			for t in tris:
				var nn: Vector3 = (t[1] - t[0]).cross(t[2] - t[0])
				if nn.length_squared() < 0.0001:
					continue
				nn = nn.normalized()
				var fc: Vector3 = (t[0] + t[1] + t[2]) / 3.0
				if (fc - c).dot(nn) < 0:
					nn = -nn
				ns.append(nn)
				cs.append(fc)
		_faces[node] = [ns, cs]
	var fd: Array = _faces[node]
	var ns2: PackedVector3Array = fd[0]
	var cs2: PackedVector3Array = fd[1]
	var best := Vector3.ZERO
	var bd := INF
	for i in ns2.size():
		var tp: Vector3 = feet - cs2[i]
		if tp.dot(ns2[i]) <= 0:
			continue
		var d: float = absf(tp.dot(ns2[i]))
		if d < bd:
			bd = d
			best = ns2[i]
	return best


## FuncLadder.get_ladder_normal as implemented.
func _traced_normal(mn: Vector3, mx: Vector3, feet: Vector3) -> Vector3:
	var mid := Vector3((mn.x + mx.x) * 0.5, 0.0, (mn.z + mx.z) * 0.5)
	var dir := Vector3(feet.x, 0.0, feet.z) - mid
	if dir.length_squared() < 0.0001:
		return Vector3.ZERO
	dir = dir.normalized()
	var n := _trace_face(mn, mx, dir, clampf(feet.y + 0.9, mn.y + 0.05, mx.y - 0.05))
	if n == Vector3.ZERO:
		n = _trace_face(mn, mx, dir, (mn.y + mx.y) * 0.5)
	return n


func _trace_face(mn: Vector3, mx: Vector3, dir: Vector3, y: float) -> Vector3:
	var axis := Vector3((mn.x + mx.x) * 0.5, y, (mn.z + mx.z) * 0.5)
	var q := PhysicsRayQueryParameters3D.create(axis + dir * (mx - mn).length(), axis)
	q.collide_with_areas = true
	q.collide_with_bodies = false
	q.collision_mask = GameConsts.MASK_LADDER
	var hit := _space.intersect_ray(q)
	return Vector3.ZERO if hit.is_empty() else hit.normal


func _strafe_is_lateral(cfg, face: Vector3, normal: Vector3) -> bool:
	var cmd = InputCommand.new()
	cmd.move_input = Vector2(1, 0)
	var flat := Vector3(-face.x, 0, -face.z).normalized()
	cmd.yaw = atan2(-flat.x, -flat.z)
	cmd.pitch = deg_to_rad(30.0)
	cmd.delta = 1.0 / 60.0
	var v: Vector3 = LadderWater.ladder_velocity(cfg, false, false, cmd, normal)
	return Vector2(v.x, v.z).length() > absf(v.y)


func _initialize() -> void:
	var cfg := MovementConfig.new()
	var maps: Array = OS.get_cmdline_user_args()
	if maps.is_empty():
		var d := DirAccess.open("user://resources/maps")
		for f in d.get_files():
			if f.ends_with(".scn"):
				maps.append(f.get_basename())
		maps.sort()
	print("map                 cells  freeclimb | strafe sideways: shipped -> traced")
	for map in maps:
		var ps: PackedScene = load("user://resources/maps/%s.scn" % map)
		if not ps:
			continue
		var root: Node3D = ps.instantiate()
		get_root().add_child(root)
		await physics_frame
		var ladders: Array = []
		for n in root.find_children("*", "", true, false):
			if String(n.get_meta("entity", {}).get("classname", "")) != "func_ladder":
				continue
			if n is AnimatableBody3D:
				(n as AnimatableBody3D).collision_layer = 0
			var vol := n.get_node_or_null("Volume") as Area3D
			if not vol:
				continue
			vol.collision_layer = GameConsts.MASK_LADDER
			vol.collision_mask = 0
			vol.monitorable = true
			ladders.append([n, vol])
		if ladders.is_empty():
			root.queue_free()
			await process_frame
			continue
		await physics_frame
		await physics_frame
		_space = root.get_world_3d().direct_space_state
		_faces.clear()

		var cap := CapsuleShape3D.new(); cap.height = 1.8; cap.radius = 0.4
		var bq := PhysicsShapeQueryParameters3D.new()
		bq.shape = cap
		bq.collision_mask = GameConsts.MASK_WORLD_AND_CLIP | GameConsts.MASK_ENTITY
		var cyl := CylinderShape3D.new(); cyl.height = 1.8; cyl.radius = 0.4
		var lq := PhysicsShapeQueryParameters3D.new()
		lq.shape = cyl
		lq.collide_with_bodies = false
		lq.collide_with_areas = true
		lq.collision_mask = GameConsts.MASK_LADDER

		var cells := 0
		var freeclimb := 0
		var ship_ok := 0
		var trace_ok := 0
		for entry in ladders:
			var node: Node3D = entry[0]
			var vol: Area3D = entry[1]
			var mn := Vector3(INF, INF, INF); var mx := -mn
			for c in vol.get_children():
				var cs := c as CollisionShape3D
				if cs and cs.shape is ConvexPolygonShape3D:
					for p in (cs.shape as ConvexPolygonShape3D).points:
						var w: Vector3 = cs.global_transform * p
						mn = mn.min(w); mx = mx.max(w)
			if mn.x == INF:
				continue
			var size: Vector3 = mx - mn
			var is_face: bool = minf(size.x, size.z) <= FREECLIMB_THICKNESS
			var mid: Vector3 = (mn + mx) * 0.5
			var span := mini(24, int(maxf(size.x, size.z) / 0.1) + 12)
			for hf in [0.25, 0.5, 0.75]:
				var y: float = lerpf(mn.y, mx.y, hf)
				for iz in range(-span, span + 1):
					for ix in range(-span, span + 1):
						var p: Vector3 = Vector3(mid.x + ix * 0.1, y, mid.z + iz * 0.1)
						bq.transform = Transform3D(Basis(), p + Vector3(0, 0.9, 0))
						if not _space.intersect_shape(bq, 1).is_empty():
							continue
						lq.transform = Transform3D(Basis(), p + Vector3(0, 0.9, 0))
						if _space.intersect_shape(lq, 1).is_empty():
							continue
						cells += 1
						if not is_face:
							freeclimb += 1
							continue
						var traced := _traced_normal(mn, mx, p)
						if traced == Vector3.ZERO:
							continue  # no face found: caller keeps its last normal
						if _strafe_is_lateral(cfg, traced, _shipped_normal(node, p)):
							ship_ok += 1
						if _strafe_is_lateral(cfg, traced, traced):
							trace_ok += 1
		print("%-18s %5d  %8d | %6d -> %6d" % [map, cells, freeclimb, ship_ok, trace_ok])
		root.queue_free()
		await process_frame
	quit(0)
