class_name FuncTrain
extends FuncDoorBase
# func_train — brush that rides a chain of path_corner entities (GoldSrc CFuncTrain).
# Each corner names the next one and supplies the wait on arrival, the speed of the
# leg leaving it, and an optional "message" target fired when the train gets there.
# Untargeted trains run from map load; named ones start on their first trigger and
# toggle stop/go after that.

const SF_TRAIN_WAIT_RETRIGGER := 1
const SF_TRAIN_START_ON := 4
const SF_TRAIN_PASSABLE := 8

const SF_CORNER_WAIT_RETRIGGER := 1
const SF_CORNER_TELEPORT := 2
const SF_CORNER_FIRE_ONCE := 4

const BLOCK_DAMAGE_INTERVAL_MS := 500

var _pivot: Vector3          # brush centre in local space — a corner positions THIS point
var _corner: EntityBase      # corner the train is at, or heading for
var _next_corner_name: String
var _corner_wait := 0.0
var _spent_messages := {}    # corners whose SF_CORNER_FIRE_ONCE message is used up
var _last_damage_ms := 0


func _ready() -> void:
	super()
	_parse_common_properties(get_meta("entity", {}))
	move_speed = parse_float(ent, "speed", 100.0) * GameConsts.SCALE_FACTOR
	damage = parse_float(ent, "dmg", 2.0)

	var aabb := _compute_brush_aabb()
	_pivot = aabb.get_center()
	_build_body(aabb)

	if spawn_flags & SF_TRAIN_PASSABLE:
		_anim_body.collision_layer = 0
		_anim_body.collision_mask = 0

	# GoldSrc leaves the retrigger bit clear here, so a named train would need firing
	# twice before it moves; every WW map that names one expects a single fire.
	if _has_targetname and not (spawn_flags & SF_TRAIN_START_ON):
		spawn_flags |= SF_TRAIN_WAIT_RETRIGGER

	_next_corner_name = target_key
	state = State.AT_BOTTOM
	EntityRender.apply_render_properties(self, ent)
	# Corners register their targetnames in their own _ready, so resolve ours after.
	_activate.call_deferred()


## Snap onto the first corner (both server and client — it's pure map data), then
## start rolling if nothing has to trigger us first.
func _activate() -> void:
	_corner = _find_corner(_next_corner_name)
	if _corner == null:
		Log.debug("func_train '%s': first corner '%s' not found" % [name, _next_corner_name])
		return
	_next_corner_name = _corner.ent.get("target", "")
	position = _base_position + _dest_offset(_corner)
	if _is_network_client():
		return
	if not (spawn_flags & SF_TRAIN_WAIT_RETRIGGER):
		_advance()


func trigger(_activator: Node, type: TriggerSystem.Type) -> void:
	if _is_network_client():
		return
	var go := (spawn_flags & SF_TRAIN_WAIT_RETRIGGER) != 0
	if type == TriggerSystem.Type.ON:
		go = true
	elif type == TriggerSystem.Type.OFF:
		go = false
	if go:
		if state == State.GOING_UP:
			return  # already rolling
		spawn_flags &= ~SF_TRAIN_WAIT_RETRIGGER
		_advance()
	else:
		spawn_flags |= SF_TRAIN_WAIT_RETRIGGER
		_stop()


# --- Path following ---

## CFuncTrain::Next — head for the next corner.
func _advance() -> void:
	if _is_network_client() or (spawn_flags & SF_TRAIN_WAIT_RETRIGGER):
		return
	var next := _find_corner(_next_corner_name)
	if next == null:
		_stop()
		return
	_next_corner_name = next.ent.get("target", "")
	_corner_wait = parse_float(next.ent, "wait", 0.0)
	# The leg's speed comes from the corner being LEFT, not the one being entered.
	if _corner:
		var leg_speed := parse_float(_corner.ent, "speed", 0.0)
		if leg_speed != 0.0:
			move_speed = leg_speed * GameConsts.SCALE_FACTOR
	_corner = next

	var dest := _dest_offset(next)
	if parse_spawnflags(next.ent) & SF_CORNER_TELEPORT:
		position = _base_position + dest
		_arrive(false)
	else:
		state = State.GOING_UP  # "moving" — drives the base class's blocked/push pass
		_play_door_sound(_move_sound)
		_linear_move(dest, _arrive.bind(true))


## CFuncTrain::Wait — arrived at a corner: fire its message, then wait or roll on.
func _arrive(was_sliding: bool) -> void:
	state = State.AT_BOTTOM
	_fire_corner_message()
	var corner_flags := parse_spawnflags(_corner.ent) if _corner else 0
	if (corner_flags & SF_CORNER_WAIT_RETRIGGER) or (spawn_flags & SF_TRAIN_WAIT_RETRIGGER):
		spawn_flags |= SF_TRAIN_WAIT_RETRIGGER
		if was_sliding:
			_play_door_sound(_stop_sound)
		return
	if _corner_wait > 0.0:
		if was_sliding:
			_play_door_sound(_stop_sound)
		get_tree().create_timer(_corner_wait).timeout.connect(
			func():
				if is_instance_valid(self):
					_advance(),
			CONNECT_ONE_SHOT)
	else:
		_advance()


func _stop() -> void:
	if _tween:
		_tween.kill()
	if state == State.GOING_UP and _corner:
		# Stopped mid-leg: re-target the corner we were heading for so a later
		# trigger resumes toward it instead of skipping it (GoldSrc's pev->enemy).
		_next_corner_name = _corner.ent.get("targetname", "")
		_play_door_sound(_stop_sound)
	state = State.AT_BOTTOM


func _fire_corner_message() -> void:
	if _corner == null or _spent_messages.has(_corner):
		return
	var msg: String = _corner.ent.get("message", "")
	if msg.is_empty():
		return
	if parse_spawnflags(_corner.ent) & SF_CORNER_FIRE_ONCE:
		_spent_messages[_corner] = true
	TriggerSystem.fire(msg, self, TriggerSystem.Type.TOGGLE)


func _find_corner(corner_name: String) -> EntityBase:
	if corner_name.is_empty():
		return null
	for node in TriggerSystem.get_nodes(corner_name):
		if node is EntityBase and node is Node3D:
			return node
	return null


## Destination as an offset from _base_position (what _linear_move takes). GoldSrc puts
## the brush's bbox centre on the corner (origin - (mins+maxs)*0.5); for an ORIGIN-brush
## train the importer already placed the node at its pivot, so _pivot comes out ~zero.
func _dest_offset(corner: Node3D) -> Vector3:
	var parent := get_parent_node_3d()
	var local := parent.to_local(corner.global_position) if parent else corner.global_position
	return local - _pivot - _base_position


# --- Blocking ---

## Trains crush; they don't reverse like a door.
func _handle_blocked(blocker: CharacterBody3D) -> void:
	_push_frames = 0
	if damage <= 0.0 or not blocker.has_method("take_damage"):
		return
	var now := Time.get_ticks_msec()
	if now - _last_damage_ms < BLOCK_DAMAGE_INTERVAL_MS:
		return
	_last_damage_ms = now
	blocker.take_damage(damage)


# --- Late-join sync ---

func _get_sync_state() -> Dictionary:
	var s := super._get_sync_state()
	# A train is rarely at its spawn spot, and it parks between legs (AT_BOTTOM),
	# so always ship the position rather than only while moving.
	s["entity_pos"] = position
	return s
