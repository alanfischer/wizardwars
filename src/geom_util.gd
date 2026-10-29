class_name GeomUtil
extends RefCounted
## Pure geometry helpers: no world, no autoloads, no state. Split out of entity_util.gd so a
## caller that wants a frame or a distance doesn't reach through a singleton to get one.


## An up vector guaranteed not to be parallel to `dir`, so look_at / Basis.looking_at never
## get a degenerate frame. `fallback` picks the roll in the near-vertical case, which is why
## callers that care (a beam's flat side, a shadow's texture) pass their own.
static func safe_up(dir: Vector3, fallback := Vector3.FORWARD) -> Vector3:
	return Vector3.UP if absf(dir.dot(Vector3.UP)) < 0.99 else fallback


## Orthonormal [right, up] spanning the plane perpendicular to `dir` — the frame a spread cone,
## a ring burst or an off-hand spawn offset is measured in.
static func perpendicular_axes(dir: Vector3) -> Array:
	var right := dir.cross(safe_up(dir)).normalized()
	return [right, right.cross(dir).normalized()]


## Local-space AABB of a collision shape. Cheap closed forms for the common shapes so
## hot AoE loops don't allocate; exotic shapes fall back to the debug-mesh AABB.
static func shape_local_aabb(shape: Shape3D) -> AABB:
	if shape is BoxShape3D:
		var s: Vector3 = (shape as BoxShape3D).size
		return AABB(-s * 0.5, s)
	if shape is SphereShape3D:
		var r: float = (shape as SphereShape3D).radius
		return AABB(Vector3.ONE * -r, Vector3.ONE * r * 2.0)
	if shape is CapsuleShape3D:
		var cap := shape as CapsuleShape3D
		return _upright_aabb(cap.radius, cap.height)
	if shape is CylinderShape3D:
		var cyl := shape as CylinderShape3D
		return _upright_aabb(cyl.radius, cyl.height)
	return shape.get_debug_mesh().get_aabb()


## The box around an upright radius/height shape, centred on the origin. Capsule and cylinder
## bound the same way; they are separate branches above only because the typed radius/height
## reads need the concrete class.
static func _upright_aabb(radius: float, height: float) -> AABB:
	return AABB(Vector3(-radius, -height * 0.5, -radius),
			Vector3(radius * 2.0, height, radius * 2.0))


## Distance from `point` to the segment `from`-`to` — the narrow phase every caller of
## SpatialQuery.nodes_near_segment runs over the candidates it hands back.
static func dist_to_segment(point: Vector3, from: Vector3, to: Vector3) -> float:
	return point.distance_to(Geometry3D.get_closest_point_to_segment(point, from, to))
