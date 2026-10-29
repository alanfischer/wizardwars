class_name FuncTrackTrain
extends FuncDoorBase
# func_tracktrain — vehicle that runs a path_track route, turning to face its
# direction of travel (GoldSrc CFuncTrackTrain). Unlike func_train it moves
# continuously rather than corner-to-corner, and each node it passes can change
# its speed. Riders are carried by netmove's mover carry like any brush mover.
#
# Not implemented: driver controls (func_traincontrols), track switching
# (func_trackchange / altpath) and banking. ww_shrinkspell's is the only
# tracktrain in the map set and is flagged No User Control.

const SF_NO_PITCH := 1
const SF_NO_CONTROL := 2
const SF_FORWARD_ONLY := 4
const SF_PASSABLE := 8

const BLOCK_DAMAGE_INTERVAL_MS := 500
const MIN_LOOKAHEAD := 0.5  # metres — keeps yaw steady along one long segment

var _points: Array[Vector3] = []      # route nodes, parent space
var _node_ents: Array[Dictionary] = []
var _seg_len: Array[float] = []
var _looping := false
var _seg := 0                          # segment being travelled (points[_seg] -> [_seg+1])
var _seg_dist := 0.0                   # distance travelled into that segment
var _pivot := Vector3.ZERO
var _height := 0.0
var _running := false
var _spent_messages := {}
var _last_damage_ms := 0


func _ready() -> void:
	super()
	_parse_common_properties(get_meta("entity", {}))
	move_speed = parse_float(ent, "speed", 100.0) * GameConsts.SCALE_FACTOR
	damage = parse_float(ent, "dmg", 0.0)
	_height = parse_float(ent, "height", 0.0) * GameConsts.SCALE_FACTOR

	var aabb := _compute_brush_aabb()
	# CFuncTrackTrain rides on its own origin; the importer already places an ORIGIN
	# brush there. Only a train drawn without one needs func_train's brush-centre fallback.
	_pivot = Vector3.ZERO if ent.has("origin") else aabb.get_center()
	_build_body(aabb)

	if spawn_flags & SF_PASSABLE:
		_anim_body.collision_layer = 0
		_anim_body.collision_mask = 0

	EntityRender.apply_render_properties(self, ent)
	state = State.AT_BOTTOM
	_activate.call_deferred()


func _activate() -> void:
	_build_route()
	if _points.size() < 2:
		Log.debug("func_tracktrain '%s': route from '%s' has %d node(s)" % [
			name, target_key, _points.size()])
		return
	_seg = 0
	_seg_dist = 0.0
	_apply_track_transform()
	if _is_network_client():
		return
	# GoldSrc starts a tracktrain rolling as soon as it has a path and a speed;
	# a named one can still be stopped and restarted by a trigger.
	_running = move_speed > 0.0
	state = State.GOING_UP if _running else State.AT_BOTTOM


## Walk the path_track chain from `target`, stopping at a dead end or where the
## route rejoins itself (the common case — a closed loop).
func _build_route() -> void:
	var parent := get_parent_node_3d()
	var order: Array[String] = []
	var next_name := target_key
	while not next_name.is_empty() and not order.has(next_name):
		var node := _find_track(next_name)
		if node == null:
			break
		order.append(next_name)
		var local := parent.to_local(node.global_position) if parent else node.global_position
		_points.append(local + Vector3(0.0, _height, 0.0) - _pivot)
		_node_ents.append(node.ent)
		next_name = node.ent.get("target", "")
	# Rejoined the route: close the ring at whichever node it came back to.
	if not next_name.is_empty() and order.has(next_name):
		_looping = true
		var join := order.find(next_name)
		_points.append(_points[join])
		_node_ents.append(_node_ents[join])
	for i in _points.size() - 1:
		_seg_len.append(maxf(_points[i].distance_to(_points[i + 1]), 0.0001))


## CFuncTrackTrain::ObjectCaps grants FCAP_IMPULSE_USE — riders start/stop it.
func is_player_usable() -> bool:
	return true


func trigger(_activator: Node, type: TriggerSystem.Type) -> void:
	if _is_network_client() or _points.size() < 2:
		return
	match type:
		TriggerSystem.Type.ON: _running = true
		TriggerSystem.Type.OFF: _running = false
		TriggerSystem.Type.TOGGLE: _running = not _running
	state = State.GOING_UP if _running else State.AT_BOTTOM


func _physics_process(delta: float) -> void:
	if not _is_network_client() and _running:
		_advance(delta)
	# The base pass decides whether we are Blocked; it reads the blocker's penetration, so
	# it needs nothing from us about where the track is headed.
	super(delta)


func _advance(delta: float) -> void:
	var remaining := move_speed * delta
	while remaining > 0.0:
		var left: float = _seg_len[_seg] - _seg_dist
		if remaining < left:
			_seg_dist += remaining
			break
		remaining -= left
		_seg += 1
		_seg_dist = 0.0
		if _seg >= _seg_len.size():
			if _looping:
				_seg = 0
			else:
				# Dead end: settle on the last node and stop.
				_seg = _seg_len.size() - 1
				_seg_dist = _seg_len[_seg]
				_running = false
				state = State.AT_BOTTOM
				break
		_reach_node(_seg)
	_apply_track_transform()
	flush_mover_transform()


## Passing a path_track: it can hand the train a new speed and fire a message.
func _reach_node(idx: int) -> void:
	if idx < 0 or idx >= _node_ents.size():
		return
	var e: Dictionary = _node_ents[idx]
	var node_speed := parse_float(e, "speed", 0.0)
	if node_speed != 0.0:
		move_speed = node_speed * GameConsts.SCALE_FACTOR
	var msg: String = e.get("message", "")
	if msg.is_empty() or _spent_messages.has(idx):
		return
	if parse_spawnflags(e) & FuncTrain.SF_CORNER_FIRE_ONCE:
		_spent_messages[idx] = true
	TriggerSystem.fire(msg, self, TriggerSystem.Type.TOGGLE)


func _apply_track_transform() -> void:
	var pos := _point_at(_seg, _seg_dist)
	position = pos
	var dir := (_point_at_ahead(maxf(MIN_LOOKAHEAD, _wheelbase())) - pos)
	if dir.length_squared() < 1e-8:
		return
	dir = dir.normalized()
	# Brush entities are drawn facing GoldSrc +X, which the importer mirrors to -X.
	var yaw := atan2(dir.z, -dir.x)
	var pitch := 0.0
	if not (spawn_flags & SF_NO_PITCH):
		pitch = asin(clampf(dir.y, -1.0, 1.0))
	rotation = Vector3(pitch, yaw, 0.0)


func _wheelbase() -> float:
	return parse_float(ent, "wheels", 0.0) * GameConsts.SCALE_FACTOR


func _point_at(seg: int, dist: float) -> Vector3:
	if _points.is_empty():
		return position
	if seg >= _seg_len.size():
		return _points[_points.size() - 1]
	return _points[seg].lerp(_points[seg + 1], clampf(dist / _seg_len[seg], 0.0, 1.0))


## The point `ahead` metres further along the route, walking segment boundaries so the
## train aims through a corner instead of snapping its yaw at each node.
func _point_at_ahead(ahead: float) -> Vector3:
	var seg := _seg
	var dist := _seg_dist + ahead
	while seg < _seg_len.size() and dist > _seg_len[seg]:
		dist -= _seg_len[seg]
		seg += 1
		if seg >= _seg_len.size():
			if not _looping:
				return _points[_points.size() - 1]
			seg = 0
	return _point_at(seg, dist)


func _find_track(track_name: String) -> EntityBase:
	if track_name.is_empty():
		return null
	for node in TriggerSystem.get_nodes(track_name):
		if node is EntityBase and node is Node3D:
			return node
	return null


## Tracktrains crush what they hit; they don't reverse like a door.
func _handle_blocked(blocker: CharacterBody3D) -> void:
	_push_frames = 0
	if damage <= 0.0 or not blocker.has_method("take_damage"):
		return
	var now := Time.get_ticks_msec()
	if now - _last_damage_ms < BLOCK_DAMAGE_INTERVAL_MS:
		return
	_last_damage_ms = now
	blocker.take_damage(damage)


func _get_sync_state() -> Dictionary:
	var s := super._get_sync_state()
	s["entity_pos"] = position
	s["entity_rot"] = rotation
	return s
