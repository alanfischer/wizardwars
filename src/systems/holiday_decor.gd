class_name HolidayDecor
extends Node
## Holiday dressing, the server's half: picks where little groups of props go along the walls of
## whatever map is loaded, for the `holiday` server var, and spawns each as a HolidayGroup entity.
## The entities do the rest (drawing, popping, coming back) through the usual entity sync.

const WaypointGraph = preload("res://src/bot/waypoint_graph.gd")
const _GROUP_SCRIPT := "res://src/systems/holiday_group.gd"

const HOLIDAYS := {
	"thanksgiving": "pumpkins, gourds, Indian corn and cornucopias along the walls",
	"christmas": "lit trees, wrapped presents, candy canes and snowmen along the walls",
}

const MAX_GROUPS := 32
const GROUP_SPACING := 6.0
const _WALL_REACH := 2.5
const _SKIP_FLAGS := WaypointGraph.FL_PRECISE | WaypointGraph.FL_LIFT

var map_name := ""
var _groups: Array[Node] = []
var _generation := 0


func _ready() -> void:
	ServerVars.value_changed.connect(_on_server_var_changed)
	_rebuild()


func _exit_tree() -> void:
	_clear()


func _on_server_var_changed(key: String, _value: Variant) -> void:
	if key == "holiday":
		_rebuild()


static func current() -> String:
	return str(ServerVars.get_value("holiday", ""))


func _rebuild() -> void:
	_clear()
	var generation := _generation
	var holiday := current()
	if not HOLIDAYS.has(holiday):
		return
	# The map's bodies reach the physics space on the next frame.
	await get_tree().physics_frame
	await get_tree().physics_frame
	if generation != _generation or not is_inside_tree():
		return
	var space := get_viewport().find_world_3d().direct_space_state
	var placed := place(space, floor_points(map_name), (map_name + ":" + holiday).hash(), holiday)
	for data in placed:
		_spawn(data)
	Log.info("[Holiday] %s: %d groups on %s" % [holiday, placed.size(), map_name])


## Kept through a round reset, which frees every other dynamic entity, as the siege altar is.
func _spawn(data: Dictionary) -> void:
	var node := NetworkManager.spawn_dynamic_entity(data)
	if node:
		node.set_meta("_persist_round", true)
		_groups.append(node)


func _clear() -> void:
	_generation += 1
	for node in _groups:
		if is_instance_valid(node):
			node.queue_free()
	_groups.clear()


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


## The groups, the same for the same points and seed, as HolidayGroup spawn data.
static func place(space: PhysicsDirectSpaceState3D, points: PackedVector3Array, seed_value: int,
		holiday: String) -> Array[Dictionary]:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var order := range(points.size())
	for i in range(order.size() - 1, 0, -1):  # Fisher-Yates on our own rng, not the global one
		var j := rng.randi_range(0, i)
		var tmp: int = order[i]
		order[i] = order[j]
		order[j] = tmp
	var out: Array[Dictionary] = []
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
		var props := _dress_group(space, frame, rng, _recipe(holiday, rng))
		if props.is_empty():
			continue
		taken.append(frame.origin)
		out.append({"script_path": _GROUP_SCRIPT, "position": frame.origin,
			"yaw": atan2(frame.basis.z.x, frame.basis.z.z), "holiday": holiday, "props": props})
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
	if hit.get("collider") is AnimatableBody3D:  # doors, plats, trains move
		return {"moving": true}
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
			match [0, 0, 1, 2][rng.randi() % 4]:  # the cornucopia leads half of them
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
## under it and nothing between it and the group's middle, as HolidayGroup records in the
## group's frame. Empty if none of the big ones fit.
static func _dress_group(space: PhysicsDirectSpaceState3D, frame: Transform3D, rng: RandomNumberGenerator,
		items: Array[Dictionary]) -> Array:
	var props := []
	var discs := []  # [Vector2 local xz, radius]
	var centrepieces := 0
	for item in items:
		if not item["big"] and centrepieces == 0:
			return []
		var kind: String = item["kind"]
		var r: float = item["r"]
		for attempt in (24 if kind == "cornucopia" else 10):  # the widest, so the hardest to fit
			var at := Vector2(rng.randf_range(-1.2, 1.2), r + 0.02 + rng.randf_range(0.0, 0.1 if item["big"] else 0.5))
			if kind in ["corn", "canes"]:
				at.y = 0.16  # stood in front of the wall to lean back on it
			if _overlaps(discs, at, r):
				continue
			var yaw := rng.randf() * TAU
			match kind:
				"cornucopia": yaw = (0.0 if rng.randf() < 0.5 else PI) + rng.randf_range(-0.5, 0.5)
				"tree", "snowman": yaw = rng.randf_range(-0.4, 0.4)  # star and face out of the wall
				"corn", "canes": yaw = 0.0  # leaning back on the wall
			var spot := _settle(space, frame, at, r, item["h"])
			if is_nan(spot):
				continue
			discs.append([at, r])
			props.append({"kind": kind, "size": item["size"], "seed": rng.randi(), "r": r, "h": item["h"],
				"at": Vector3(at.x, spot - frame.origin.y - 0.01, at.y), "yaw": yaw})
			if item["big"]:
				centrepieces += 1
			break
	return props if centrepieces > 0 else []


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
