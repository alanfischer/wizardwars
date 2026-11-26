class_name HolidayDecor
extends Node3D
## Holiday dressing: little groups of props set down along the walls of whatever map is loaded,
## for the `holiday` server var. Looks only: nothing collides, nothing is networked. Every peer
## that draws the map places the same ones itself, seeded by the map and the holiday, on the bot
## nav's floor points.

const WaypointGraph = preload("res://src/bot/waypoint_graph.gd")
const _SHADER := preload("res://shaders/holiday_decor.gdshader")

const HOLIDAYS := {
	"thanksgiving": "pumpkins, gourds, Indian corn and cornucopias along the walls",
	"christmas": "lit trees, wrapped presents, candy canes and snowmen along the walls",
}

const MAX_GROUPS := 32
const GROUP_SPACING := 6.0
const _WALL_REACH := 2.5
const _SKIP_FLAGS := WaypointGraph.FL_PRECISE | WaypointGraph.FL_LIFT

var map_name := ""
var _material: ShaderMaterial
var _generation := 0


func _ready() -> void:
	ServerVars.value_changed.connect(_on_server_var_changed)
	_rebuild()


func _on_server_var_changed(key: String, _value: Variant) -> void:
	if key == "holiday":
		_rebuild()


static func current() -> String:
	return str(ServerVars.get_value("holiday", ""))


func _rebuild() -> void:
	_generation += 1
	var generation := _generation
	for child in get_children():
		child.queue_free()
	var holiday := current()
	if not HOLIDAYS.has(holiday):
		return
	# The map's bodies reach the physics space on the next frame.
	await get_tree().physics_frame
	await get_tree().physics_frame
	if generation != _generation or not is_inside_tree():
		return
	var space := get_world_3d().direct_space_state
	var groups := place(space, floor_points(map_name), (map_name + ":" + holiday).hash(), holiday)
	for group: MeshInstance3D in groups:
		group.mesh.surface_set_material(0, _get_material())
		add_child(group)
	Log.info("[Holiday] %s: %d groups on %s" % [holiday, groups.size(), map_name])


func _get_material() -> ShaderMaterial:
	if _material == null:
		_material = ShaderMaterial.new()
		_material.shader = _SHADER
		_material.set_shader_parameter("linear_output", EntityRender.renderer_is_linear())
		_material.set_shader_parameter("detail", HolidayProps.detail_texture())
		if AssetLoader.light_grid:
			AssetLoader.light_grid.bind(_material)
	return _material


## Where a player can stand: the baked nav, else the original's hand waypoints.
static func floor_points(map: String) -> PackedVector3Array:
	var graph := WaypointGraph.new()
	if not graph.load_generated(map) and not graph.load_map(map):
		return PackedVector3Array()
	var out := PackedVector3Array()
	for i in graph.positions.size():
		if graph.flags_of(i) & (_SKIP_FLAGS | WaypointGraph.FL_DELETED) == 0 and graph.positions[i] != Vector3.ZERO:
			out.append(graph.positions[i])
	return out


## One mesh per group, in world space, the same for the same points and seed.
static func place(space: PhysicsDirectSpaceState3D, points: PackedVector3Array, seed_value: int,
		holiday: String) -> Array[MeshInstance3D]:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var order := range(points.size())
	for i in range(order.size() - 1, 0, -1):  # Fisher-Yates on our own rng, not the global one
		var j := rng.randi_range(0, i)
		var tmp: int = order[i]
		order[i] = order[j]
		order[j] = tmp
	var out: Array[MeshInstance3D] = []
	var taken := PackedVector3Array()
	for idx: int in order:
		if out.size() >= MAX_GROUPS:
			break
		var p := points[idx]
		if _near_any(taken, p, GROUP_SPACING):
			continue
		var frame := _wall_frame(space, p, rng.randf() * TAU)
		if frame == Transform3D():
			continue
		if _near_any(taken, frame.origin, GROUP_SPACING):
			continue
		var geo := HolidayProps.Geo.new()
		if not _dress_group(geo, space, frame, rng, _recipe(holiday, rng)):
			continue
		taken.append(frame.origin)
		var mi := MeshInstance3D.new()
		mi.name = "Group%d" % out.size()
		mi.mesh = geo.to_mesh()
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		out.append(mi)
	return out


static func _near_any(pts: PackedVector3Array, p: Vector3, dist: float) -> bool:
	for q in pts:
		if q.distance_squared_to(p) < dist * dist:
			return true
	return false


## The nearest wall to `p`: its foot on the floor, +Z out of the wall, or an empty transform.
static func _wall_frame(space: PhysicsDirectSpaceState3D, p: Vector3, turn: float) -> Transform3D:
	var from := p + Vector3(0, 0.4, 0)
	var best := {}
	var best_d := INF
	for k in 8:
		var dir := Vector3(0, 0, 1).rotated(Vector3.UP, turn + TAU * k / 8)
		var hit := _ray(space, from, from + dir * _WALL_REACH)
		if not hit.has("normal") or absf((hit["normal"] as Vector3).y) > 0.3:
			continue
		var d := from.distance_to(hit["position"])
		if d < best_d:
			best_d = d
			best = hit
	if best.is_empty():
		return Transform3D()
	var n := Vector3((best["normal"] as Vector3).x, 0, (best["normal"] as Vector3).z).normalized()
	var wall: Vector3 = best["position"]
	var ground := _floor_at(space, wall + n * 0.3, p.y)
	if is_nan(ground) or _wet(space, Vector3(wall.x, ground + 0.15, wall.z) + n * 0.3):
		return Transform3D()
	return Transform3D(Basis(Vector3.UP.cross(n), Vector3.UP, n), Vector3(wall.x, ground, wall.z))


static func _ray(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(from, to, GameConsts.MASK_WORLD)
	var hit := space.intersect_ray(q)
	if hit.is_empty() or hit.get("collider") is AnimatableBody3D:  # doors, plats, trains move
		return {} if hit.is_empty() else {"moving": true}
	return hit


## The floor under `at` within a step of `near_y`, NAN for none (a ledge, a mover, a slope).
static func _floor_at(space: PhysicsDirectSpaceState3D, at: Vector3, near_y: float) -> float:
	var hit := _ray(space, Vector3(at.x, near_y + 0.6, at.z), Vector3(at.x, near_y - 0.6, at.z))
	if not hit.has("normal") or (hit["normal"] as Vector3).y < 0.8:
		return NAN
	return (hit["position"] as Vector3).y


static func _wet(space: PhysicsDirectSpaceState3D, at: Vector3) -> bool:
	var q := PhysicsPointQueryParameters3D.new()
	q.position = at
	q.collision_mask = GameConsts.MASK_WATER | GameConsts.MASK_HAZARD
	q.collide_with_areas = true
	q.collide_with_bodies = false
	return not space.intersect_point(q, 1).is_empty()


## What goes in one group, biggest first: {kind, r (footprint), size, h (height), big}. A group
## whose big pieces all fail to fit is dropped rather than left as a few small ones.
static func _recipe(holiday: String, rng: RandomNumberGenerator) -> Array[Dictionary]:
	var items: Array[Dictionary] = []
	var add := func(kind: String, r: float, size: float, h: float, big: bool) -> void:
		items.append({"kind": kind, "r": r, "size": size, "h": h, "big": big})
	match holiday:
		"thanksgiving":
			match rng.randi() % 3:
				0:
					add.call("cornucopia", 0.6, rng.randf_range(0.85, 1.15), 0.6, true)
					var p := rng.randf_range(0.2, 0.32)
					add.call("pumpkin", p, p, p * 1.6, true)
				1:
					for k in rng.randi_range(2, 3):
						var p := rng.randf_range(0.2, 0.4)
						add.call("pumpkin", p, p, p * 1.6, true)
				2:
					add.call("corn", 0.2, rng.randf_range(0.19, 0.24), 0.35, true)
					var p := rng.randf_range(0.22, 0.36)
					add.call("pumpkin", p, p, p * 1.6, true)
			for k in rng.randi_range(2, 5):
				var g := rng.randf_range(0.08, 0.14)
				add.call("gourd", g * 0.6, g, g * 2.0, false)
		"christmas":
			var presents := 0
			match rng.randi() % 3:
				0:
					var h := rng.randf_range(1.5, 2.1)
					add.call("tree", h * 0.38, h, h * 1.05, true)
					presents = rng.randi_range(2, 5)
				1:
					var b := rng.randf_range(0.32, 0.42)
					add.call("present", b * 0.75, b, b * 1.4, true)
					add.call("canes", 0.2, rng.randf_range(0.5, 0.75), 0.8, true)
					presents = rng.randi_range(2, 4)
				2:
					var m := rng.randf_range(0.22, 0.3)
					add.call("snowman", m, m, m * 5.0, true)
					presents = rng.randi_range(1, 3)
			for k in presents:
				var b := rng.randf_range(0.16, 0.34)
				add.call("present", b * 0.75, b, b * 1.4, false)
	return items


## The props of `items` against the wall at `frame`, each kept only where all of it has floor
## under it and nothing between it and the group's middle. False if none of the big ones fit.
static func _dress_group(geo: HolidayProps.Geo, space: PhysicsDirectSpaceState3D, frame: Transform3D,
		rng: RandomNumberGenerator, items: Array[Dictionary]) -> bool:
	var discs := []  # [Vector2 local xz, radius]
	var centrepieces := 0
	for item in items:
		if not item["big"] and centrepieces == 0:
			return false
		var kind: String = item["kind"]
		var size: float = item["size"]
		var r: float = item["r"]
		var leans := kind in ["corn", "canes"]
		for attempt in 10:
			var at := Vector2(rng.randf_range(-1.2, 1.2), r + 0.02 + rng.randf_range(0.0, 0.1 if item["big"] else 0.5))
			if leans:
				at.y = 0.16
			if _overlaps(discs, at, r):
				continue
			var yaw := rng.randf() * TAU
			if kind == "cornucopia":
				yaw = (0.0 if rng.randf() < 0.5 else PI) + rng.randf_range(-0.5, 0.5)
			elif kind in ["tree", "snowman"]:
				yaw = rng.randf_range(-0.4, 0.4)  # star and face out of the wall
			var spot := _settle(space, frame, at, r, item["h"])
			if is_nan(spot):
				continue
			var xf := frame * Transform3D(Basis(Vector3.UP, yaw), Vector3(at.x, spot - frame.origin.y - 0.01, at.y))
			var foot := frame * Transform3D(Basis.IDENTITY, Vector3(at.x, spot - frame.origin.y, at.y))
			match kind:
				"pumpkin": HolidayProps.pumpkin(geo, xf, rng, size)
				"gourd": HolidayProps.gourd(geo, xf, rng, size)
				"cornucopia": HolidayProps.cornucopia(geo, xf, rng, size)
				"corn": _leaning(geo, foot, rng, size, 3, 0.28, HolidayProps.corn_ear)
				"tree": HolidayProps.tree(geo, xf, rng, size)
				"present": HolidayProps.present(geo, xf, rng, size)
				"snowman": HolidayProps.snowman(geo, xf, rng, size)
				"canes": _leaning(geo, foot, rng, size, 2, 0.6, HolidayProps.candy_cane)
			discs.append([at, r])
			if item["big"]:
				centrepieces += 1
			break
	return centrepieces > 0


static func _overlaps(discs: Array, at: Vector2, r: float) -> bool:
	for d: Array in discs:
		if (d[0] as Vector2).distance_to(at) < (d[1] as float) + r - 0.03:
			return true
	return false


## The floor height for a prop of radius `r` at `at` in the group's frame, NAN if any of it would
## hang off an edge, the way back to the wall is blocked, or it would not fit under what is above.
static func _settle(space: PhysicsDirectSpaceState3D, frame: Transform3D, at: Vector2, r: float, height: float) -> float:
	var centre := frame * Vector3(at.x, 0, at.y)
	var mid := frame * Vector3(0, 0.25, 0.3)
	if not _ray(space, mid, centre + Vector3(0, 0.25, 0)).is_empty():
		return NAN
	var y := _floor_at(space, centre, frame.origin.y)
	if is_nan(y) or absf(y - frame.origin.y) > 0.3:
		return NAN
	for k in 4:
		var edge := centre + frame.basis * Vector3(cos(k * PI * 0.5), 0, sin(k * PI * 0.5)) * r * 0.7
		var ey := _floor_at(space, edge, y)
		if is_nan(ey) or absf(ey - y) > 0.08:
			return NAN
	if not _ray(space, centre + Vector3(0, 0.05, 0), centre + Vector3(0, height + 0.1, 0)).is_empty():
		return NAN
	return y


## `count` of something long (an ear of corn, a candy cane) standing on its end in front of the
## wall and leaning back against it, fanned `spread` radians apart.
static func _leaning(geo: HolidayProps.Geo, foot: Transform3D, rng: RandomNumberGenerator, length: float,
		count: int, spread: float, build: Callable) -> void:
	var lean := atan2(0.16, length * 0.95)
	for k in count:
		var fan := (k - (count - 1) * 0.5) * spread + rng.randf_range(-0.08, 0.08)
		var spin := rng.randf() * TAU if count > 2 else rng.randf_range(-0.4, 0.4) + PI * k  # canes hook apart
		var b := Basis(Vector3.RIGHT, -lean) * Basis(Vector3.BACK, fan * 0.5) * Basis(Vector3.UP, spin)
		build.call(geo, foot * Transform3D(b, Vector3((k - (count - 1) * 0.5) * 0.05, 0, rng.randf_range(-0.02, 0.02))),
				rng, length * rng.randf_range(0.9, 1.05))
