extends SceneTree
## Exact front-window aperture, and how much of it a satchel can use.
## Scans z finely at y=0 (and y finely at mid-window) for a ray (a true point) and
## for a satchel-sized body, and reports both edges of each.

const S := 0.025
const R := 0.15

var body_node: AnimatableBody3D
var map: Node3D

func gs_to_godot(x, y, z) -> Vector3: return Vector3(-x * S, z * S, y * S)
func to_world(x, y, z) -> Vector3: return body_node.global_transform * gs_to_godot(x, y, z)

func ray_clear(y: float, z: float) -> bool:
	var q := PhysicsRayQueryParameters3D.create(to_world(-28.0, y, z), to_world(400.0, y, z))
	q.collision_mask = 33
	return map.get_world_3d().direct_space_state.intersect_ray(q).is_empty()

var satchel: CharacterBody3D
func body_clear(y: float, z: float) -> bool:
	var from := Transform3D(Basis.IDENTITY, to_world(-28.0, y, z))
	satchel.global_transform = from
	var p := PhysicsTestMotionParameters3D.new()
	p.from = from
	p.motion = to_world(372.0, y, z) - to_world(-28.0, y, z)
	var r := PhysicsTestMotionResult3D.new()
	PhysicsServer3D.body_test_motion(satchel.get_rid(), p, r)
	return r.get_travel().length() / S > 300.0

## Walk `probe` from `a` to `b` in 0.5-unit steps and report the open interval.
func span(probe: Callable, fixed: float, a: float, b: float, along_z: bool) -> Vector2:
	var lo := INF; var hi := -INF; var t := a
	while t <= b:
		var ok: bool = probe.call(fixed, t) if along_z else probe.call(t, fixed)
		if ok:
			lo = minf(lo, t); hi = maxf(hi, t)
		t += 0.5
	return Vector2(lo, hi)

func _initialize() -> void:
	map = (load("user://resources/maps/ww_golem.scn") as PackedScene).instantiate()
	get_root().add_child(map)
	for i in 20: await physics_frame
	for n in map.find_children("*", "AnimatableBody3D", true, false):
		if String(n.get_meta("entity", {}).get("classname", "")) == "func_golem_body":
			body_node = n
	body_node.sync_to_physics = false

	satchel = CharacterBody3D.new()
	satchel.collision_layer = 0
	satchel.collision_mask = 33
	var cs := CollisionShape3D.new()
	var sph := SphereShape3D.new(); sph.radius = R; cs.shape = sph
	satchel.add_child(cs)
	map.add_child(satchel)
	await physics_frame

	var rz := span(ray_clear, 0.0, -70.0, -20.0, true)
	var bz := span(body_clear, 0.0, -70.0, -20.0, true)
	print("\nFront window, body-local GoldSrc (cockpit floor z=-112)")
	print("  vertical, at y=0:")
	print("    ray  (a point)   z in [%6.1f, %6.1f]  -> %.1f units tall" % [rz.x, rz.y, rz.y - rz.x])
	print("    satchel (r=%.2f) z in [%6.1f, %6.1f]  -> %.1f units usable" % [R, bz.x, bz.y, bz.y - bz.x])

	# Horizontally, a clear line is NOT evidence of a window: past the golem's own
	# silhouette every line is clear because there is no golem there. So first find
	# where the front wall exists at all, by scanning a height BELOW the window and
	# keeping only the y where something blocks — that is the hull's real width.
	var mid := (rz.x + rz.y) * 0.5
	var below := rz.x - 8.0
	var wall_lo := INF; var wall_hi := -INF; var t := -300.0
	while t <= 300.0:
		if not ray_clear(t, below):
			wall_lo = minf(wall_lo, t); wall_hi = maxf(wall_hi, t)
		t += 0.5
	print("  front wall exists over y in [%6.1f, %6.1f] (measured at z=%.1f, below the window)"
		% [wall_lo, wall_hi, below])
	var ry := span(ray_clear, mid, wall_lo, wall_hi, false)
	var by := span(body_clear, mid, wall_lo, wall_hi, false)
	print("  horizontal, at z=%.1f, within the wall:" % mid)
	print("    ray  (a point)   y in [%6.1f, %6.1f]  -> %.1f units wide" % [ry.x, ry.y, ry.y - ry.x])
	print("    satchel (r=%.2f) y in [%6.1f, %6.1f]  -> %.1f units usable" % [R, by.x, by.y, by.y - by.x])
	print("\nsatchel is %.0f units across; it loses %.1f units of height and %.1f of width" % [
		R * 2.0 / S, (rz.y - rz.x) - (bz.y - bz.x), (ry.y - ry.x) - (by.y - by.x)])
	quit(0)
