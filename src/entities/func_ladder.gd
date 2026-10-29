class_name FuncLadder
extends EntityBase
# Climbable brush — configures the Volume Area3D as a monitorable ladder volume
# so the player's LadderDetector shape cast can find it.

# A ladder brush is a thin panel you climb the face of. WW's mappers also used func_ladder
# for whole rock faces — volumes metres thick in both horizontal axes, wrapping broken
# terrain. Those have no single climbing plane (opposite sides of one blob face opposite
# ways), so they keep the free-climb fallback: a zero normal makes the movement code fly
# the player where they look, which is what makes ww_chasm's cliffs climbable.
const FREECLIMB_THICKNESS := 3.0

var _volume: Area3D
var _mins: Vector3
var _maxs: Vector3
var _is_face := false  # thin panel: climbs as a plane


func _ready() -> void:
	super()
	if _anim_body:
		_anim_body.collision_layer = 0
	_volume = get_node("Volume") as Area3D
	_volume.collision_layer = GameConsts.MASK_LADDER
	_volume.collision_mask = 0
	_volume.monitorable = true
	for child in get_children():
		if child is MeshInstance3D:
			child.visible = false
	_measure_volume()


func _measure_volume() -> void:
	var mn := Vector3(INF, INF, INF)
	var mx := -mn
	for c in _volume.get_children():
		var col := c as CollisionShape3D
		if not col or not col.shape is ConvexPolygonShape3D:
			continue
		for p in (col.shape as ConvexPolygonShape3D).points:
			var w: Vector3 = col.global_transform * p
			mn = mn.min(w)
			mx = mx.max(w)
	if mn.x == INF:
		return
	_mins = mn
	_maxs = mx
	var size := mx - mn
	_is_face = minf(size.x, size.z) <= FREECLIMB_THICKNESS and size.y > 0.0


## Mirrors HL's PM_TraceModel: the outward normal of the ladder face being climbed, or
## zero for a free-climb volume (and when the trace finds nothing — the caller keeps the
## last normal it got).
func get_ladder_normal(player_pos: Vector3) -> Vector3:
	if not _is_face:
		return Vector3.ZERO
	var dir := Vector3(player_pos.x - (_mins.x + _maxs.x) * 0.5, 0.0,
			player_pos.z - (_mins.z + _maxs.z) * 0.5)
	if dir.length_squared() < 0.0001:
		return Vector3.ZERO
	dir = dir.normalized()
	# The climber's own chest height picks the face they are actually on; a panel that
	# steps or leans can be missing at that height, so fall back to its waist.
	var n := _trace_face(dir, clampf(player_pos.y + 0.9, _mins.y + 0.05, _maxs.y - 0.05))
	if n == Vector3.ZERO:
		n = _trace_face(dir, (_mins.y + _maxs.y) * 0.5)
	return n


## Trace inbound from outside the brush rather than out from the player: ladder brushes are
## non-solid, so a climber usually stands inside one, and a ray started in there hits
## nothing. Horizontal, so it can never pick up the panel's end caps.
func _trace_face(dir: Vector3, y: float) -> Vector3:
	var axis := Vector3((_mins.x + _maxs.x) * 0.5, y, (_mins.z + _maxs.z) * 0.5)
	var q := PhysicsRayQueryParameters3D.create(axis + dir * (_maxs - _mins).length(), axis)
	q.collide_with_areas = true
	q.collide_with_bodies = false
	q.collision_mask = GameConsts.MASK_LADDER
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	return Vector3.ZERO if hit.is_empty() else hit.normal
