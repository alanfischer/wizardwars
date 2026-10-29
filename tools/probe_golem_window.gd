extends SceneTree
## Does a satchel fit through the golem cockpit's front window?
##
## Two separate questions, and they are not the same question:
##   1. how big is the aperture, measured by ray (hull 0, a true point)?
##   2. does a satchel-sized BODY get through it, swept as the game sweeps it?
##
## (1) is the geometry. (2) is what the hull trace makes of it, which is the thing
## that changed when small movers moved to hull 0 inflated by their own radius.
##
## Body-local GoldSrc: golem forward is +x, up is +z, its RIGHT is -y. Cockpit floor
## is z = -112 and the rear wall is x = -32.
##
## Usage: tools/probe_golem_window.gd

const S := 0.025
const SATCHEL_RADIUS := 0.15   # src/weapons/satchel.gd COLLISION_RADIUS

var body_node: AnimatableBody3D
var map: Node3D


func gs_to_godot(x: float, y: float, z: float) -> Vector3:
	return Vector3(-x * S, z * S, y * S)


func to_world(x: float, y: float, z: float) -> Vector3:
	return body_node.global_transform * gs_to_godot(x, y, z)


## Cast a ray in body-local +x at (y, z) and return the GoldSrc x it first hits,
## or INF for a clear line all the way through.
func ray_x(y: float, z: float, x0: float, x1: float) -> float:
	var q := PhysicsRayQueryParameters3D.create(to_world(x0, y, z), to_world(x1, y, z))
	q.collision_mask = 33
	var hit := map.get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return INF
	var local: Vector3 = body_node.global_transform.affine_inverse() * (hit["position"] as Vector3)
	return -local.x / S


func _initialize() -> void:
	map = (load("user://resources/maps/ww_golem.scn") as PackedScene).instantiate()
	get_root().add_child(map)
	for i in 20:
		await physics_frame

	for n in map.find_children("*", "AnimatableBody3D", true, false):
		if String(n.get_meta("entity", {}).get("classname", "")) == "func_golem_body":
			body_node = n
	body_node.sync_to_physics = false

	# ---- 1. Where is the front wall, and where is the hole in it? -------------
	# Fire forward from just inside the cockpit and see how far each line gets.
	print("\nRAY MAP — forward (+x) from x=-28, body-local GoldSrc")
	print("rows are z (height above cockpit floor at -112), cols are y (right is -y)")
	var zs: Array[float] = []
	for i in 17:
		zs.append(-112.0 + i * 8.0)
	var ys: Array[float] = []
	for i in 17:
		ys.append(-64.0 + i * 8.0)

	var header := "   z\\y "
	for y in ys:
		header += "%5.0f" % y
	print(header)
	for z in zs:
		var row := "%6.0f" % z
		for y in ys:
			var x := ray_x(y, z, -28.0, 400.0)
			row += "    ." if x == INF else "%5.0f" % x
		print(row)
	print("  '.' = clear line all the way out; a number is the GoldSrc x it stopped at")

	# ---- 2. Does a satchel-sized body actually pass? -------------------------
	# Find the clear column band first, so the sweep is aimed at the hole rather
	# than at wherever I guessed it was.
	var open: Array = []
	for z in zs:
		for y in ys:
			if ray_x(y, z, -28.0, 400.0) == INF:
				open.append(Vector2(y, z))
	if open.is_empty():
		print("\nNo clear line forward at all — no window on this sampling grid.")
		quit(0)

	var ymin := INF; var ymax := -INF; var zmin := INF; var zmax := -INF
	for p in open:
		ymin = minf(ymin, p.x); ymax = maxf(ymax, p.x)
		zmin = minf(zmin, p.y); zmax = maxf(zmax, p.y)
	print("\nClear band spans y [%.0f, %.0f], z [%.0f, %.0f] on an 8-unit grid" % [
		ymin, ymax, zmin, zmax])

	print("\nSATCHEL SWEEP — sphere r=%.2f m (%.0f GoldSrc units across)" % [
		SATCHEL_RADIUS, SATCHEL_RADIUS * 2.0 / S])
	print("%-8s %-8s %s" % ["y", "z", "forward travel from x=-28 (GoldSrc units)"])
	var best := -INF
	for z in zs:
		for y in ys:
			if z < zmin - 8 or z > zmax + 8 or y < ymin - 8 or y > ymax + 8:
				continue
			var travel := sweep_satchel(y, z)
			best = maxf(best, travel)
			var verdict := "THROUGH" if travel > 300.0 else "blocked"
			print("%-8.0f %-8.0f %10.1f   %s" % [y, z, travel, verdict])
	print("\nbest forward travel: %.1f units (a clear pass is ~400)" % best)
	quit(0)


## Fly a satchel-sized sphere forward from x=-28 at (y, z) and report how far it got.
func sweep_satchel(y: float, z: float) -> float:
	var body := CharacterBody3D.new()
	body.collision_layer = 0
	body.collision_mask = 33
	var cs := CollisionShape3D.new()
	var sph := SphereShape3D.new()
	sph.radius = SATCHEL_RADIUS
	cs.shape = sph
	body.add_child(cs)
	map.add_child(body)

	var from := Transform3D(Basis.IDENTITY, to_world(-28.0, y, z))
	body.global_transform = from
	var p := PhysicsTestMotionParameters3D.new()
	p.from = from
	p.motion = to_world(372.0, y, z) - to_world(-28.0, y, z)
	var r := PhysicsTestMotionResult3D.new()
	PhysicsServer3D.body_test_motion(body.get_rid(), p, r)
	var travel: float = r.get_travel().length() / S
	body.free()
	return travel
