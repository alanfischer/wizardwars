class_name FuncDoorBase
extends EntityBase
# Base door logic shared by the sliding movers (func_door, func_button, func_plat)
# and the rotating ones (func_door_rotating, func_rot_button).
#
# Node structure after _ready():
#   Door (Node3D, this script) <- tween moves/rotates THIS entity root
#   +-- MeshInstance3D(s)
#   +-- CollisionShape3D(s)
#   +-- BlockedDetector (Area3D)
#   +-- TouchArea (Area3D) <- legacy activation helper; should become separate entity

enum State { AT_BOTTOM, GOING_UP, AT_TOP, GOING_DOWN }

const SF_START_OPEN := 1
const SF_NO_AUTO_RETURN := 32
const SF_USE_ONLY := 256
const SF_SILENT := 0x80000000
const TOUCH_MARGIN := 0.5
const DOOR_CLASSNAMES := ["func_door", "func_door_rotating"]  # the gang CBaseDoor::Blocked reverses
const PUSH_GRACE_FRAMES := 3
const BLOCK_SLOP_MARGINS := 2.0  # resting depth allowed, in the blocker's own safe_margins
const BLOCK_DEPTH_GROWTH := 0.002  # per-frame deepening that reads as the mover gaining

var state := State.AT_BOTTOM
var wait_time: float
var damage: float
var spawn_flags: int
var target_key: String
var req_team: int
var _has_targetname: bool

var move_speed: float
var rot_speed: float  # degrees/second (rotating movers)
var position1: Vector3
var position2: Vector3

var _blocked_area: Area3D
var _tween: Tween
var _base_position: Vector3
## The brush's extent in this node's own frame, kept from _build_body. The mover sizes its call
## volume and blocked detector from it, and bot_brain steers a rider by it — one measurement, so
## they cannot drift (see _compute_brush_aabb).
var brush_aabb: AABB
var _base_rotation: Vector3
var _touch_area: Area3D
var _push_frames := 0
var _block_depth := 0.0  # how deep _block_id was inside us last frame
var _block_id := 0
var _blocked_hold := false  # stopped on a blocker, still owes the move it was told to make
var _pending_flip := false  # a toggle that landed mid-move; applied once the door settles
var _move_sound: AudioStream
var _stop_sound: AudioStream


# --- Common setup helpers (called from subclass _ready) ---

func _parse_common_properties(p_ent: Dictionary) -> void:
	ent = p_ent
	wait_time = parse_float(ent, "wait", 3.0)
	damage = parse_float(ent, "dmg", 0.0)
	spawn_flags = parse_spawnflags(ent)
	target_key = ent.get("target", "")
	req_team = parse_int(ent, "team_no", 0)
	# EntityBase._ready already registers the targetname; re-registering would give
	# TriggerSystem.fire() two entries and call trigger() twice.
	_has_targetname = not (ent.get("targetname", "") as String).is_empty()

	var movesnd := parse_int(ent, "movesnd", 0)
	var stopsnd := parse_int(ent, "stopsnd", 0)
	if not (spawn_flags & SF_SILENT):
		if movesnd > 0 and movesnd <= 10:
			_move_sound = load("sounds/doors/doormove%d.wav" % movesnd)
		if stopsnd > 0 and stopsnd <= 8:
			_stop_sound = load("sounds/doors/doorstop%d.wav" % stopsnd)


func _exit_tree() -> void:
	super()
	if _tween:
		_tween.kill()


## The mover's extent, measured off the brush the BSP gave it. A runtime-spawned mover has no
## brush, so it falls back to a default-size box — same bargain as a trigger's volume, and for the
## same reason: a default-size door beats a zero-size one, and neither needs a list of classnames.
func _compute_brush_aabb() -> AABB:
	var aabb := _measure_brush_children()
	if aabb.size == Vector3.ZERO and has_meta("_dyn_spawner_entity"):
		GoldSrcEntity.build_brush_stand_in(self)
		aabb = _measure_brush_children()
	return aabb


func _measure_brush_children() -> AABB:
	var aabb := AABB()
	var first := true
	for child in get_children():
		if child is MeshInstance3D:
			var child_aabb: AABB = child.get_aabb()
			if first:
				aabb = child_aabb
				first = false
			else:
				aabb = aabb.merge(child_aabb)
		elif child is CollisionShape3D and child.shape is ConcavePolygonShape3D:
			var faces: PackedVector3Array = child.shape.get_faces()
			for v: Vector3 in faces:
				var pt: Vector3 = child.position + v
				if first:
					aabb = AABB(pt, Vector3.ZERO)
					first = false
				else:
					aabb = aabb.expand(pt)
	return aabb


## Pass solid_brush false for a mover that is not a solid opaque brush — a func_water, which
## the SDK spawns SOLID_NOT. Both extras below only make sense for one that is:
##   - the blocked detector, because nothing can be caught between a non-solid brush and its
##     destination, so there is nothing to hurt or reverse for;
##   - the coplanar render fix, because _apply_depth_bias REBUILDS the ArrayMesh. Liquid
##     surfaces share one mesh with the depth-prepass twin the converter pairs them with, so
##     rebuilding it here leaves the twin holding the old mesh and the water sorts against a
##     silhouette that no longer matches. The duplicated surface override would also shadow the
##     water_alpha uniform FuncWater writes onto the mesh's own material.
func _build_body(aabb: AABB, solid_brush := true) -> void:
	brush_aabb = aabb
	_anim_body.sync_to_physics = false
	_base_position = position
	_base_rotation = rotation

	if solid_brush:
		# GoldSrc renders entity brushes after worldspawn, so coplanar entities always win.
		for child in get_children():
			if child is MeshInstance3D:
				_set_entity_render_priority(child)

		_blocked_area = Area3D.new()
		_blocked_area.name = "BlockedDetector"
		_blocked_area.collision_layer = 0
		# Players only, deliberately: _get_active_blocker wants a body that answers
		# mover_obstruction, which is netmove's own penetration probe. A monster walks on the bare
		# pmove kernel and publishes no such measurement, so it cannot hold a door open — it gets
		# shoved by one instead. Widening this would cost area pairs and change nothing.
		_blocked_area.collision_mask = GameConsts.MASK_WORLD | GameConsts.MASK_PLAYER
		_blocked_area.monitoring = true
		_blocked_area.monitorable = false
		var box := BoxShape3D.new()
		box.size = aabb.size
		var col := CollisionShape3D.new()
		col.shape = box
		col.position = aabb.get_center()
		_blocked_area.add_child(col)
		add_child(_blocked_area)

	_register_for_sync()  # sets up the transform MultiplayerSynchronizer (in EntityBase)


func _setup_touch_area(aabb: AABB, touch_offset := Vector3.ZERO) -> void:
	_touch_area = Area3D.new()
	_touch_area.name = "TouchArea"
	_touch_area.collision_layer = 0
	_touch_area.collision_mask = GameConsts.MASK_WORLD | GameConsts.MASK_DOOR_TOUCH
	_touch_area.monitoring = true
	_touch_area.monitorable = false

	var box := BoxShape3D.new()
	box.size = aabb.size + Vector3.ONE * TOUCH_MARGIN * 2.0
	var col := CollisionShape3D.new()
	col.shape = box
	col.position = touch_offset + aabb.get_center()
	_touch_area.add_child(col)

	add_child(_touch_area)
	_touch_area.body_entered.connect(_on_touch_body_entered)


func _on_touch_body_entered(body: Node3D) -> void:
	if body is CharacterBody3D:
		if _is_network_client():
			return
		if not _check_team(body):
			return
		# Deferred: moving the AnimatableBody3D inside a body_entered callback re-enters
		# the physics server mid-step and corrupts it (Linux segfault under load).
		call_deferred("_door_activate", body)


# --- Activation ---

## `team_no` on a door says whose base it guards. The rule for who gets through lives in
## Teams, because the trigger that fires a door asks the same question of the same body.
func _check_team(activator: Node) -> bool:
	return Teams.may_pass_team_gate(activator, req_team)


## CBaseDoor::ObjectCaps — only a "use only" door answers +use; the rest open
## on touch or on being triggered.
func is_player_usable() -> bool:
	return (spawn_flags & SF_USE_ONLY) != 0


func trigger(_activator: Node, _type: TriggerSystem.Type) -> void:
	if _is_network_client():  # body transforms come from host sync; no local state machine
		return
	if not _check_team(_activator):
		return
	if state == State.AT_BOTTOM:
		_door_go_up(_activator)
	elif state == State.AT_TOP and (spawn_flags & SF_NO_AUTO_RETURN):
		_door_go_down()
	elif _is_scripted_mover():
		# Mid-move. CBaseDoor::Use drops this, which is right for a player leaning on +use but
		# wrong for a mover whose position IS the parity of the toggles it was sent. ww_monoliths'
		# cap-point covers get one from each of two managers in the same frame when a point is
		# retaken the instant its lockout expires; swallowing one leaves the cover inverted —
		# raised over a point that is cappable — for the rest of the map. Remember the flip and
		# apply it on settle. Two mid-move toggles cancel, exactly as they would have.
		_pending_flip = not _pending_flip


## A mover no player can work by hand: its state only ever changes through the trigger chain,
## so the toggles it is sent are a sequence that has to balance.
func _is_scripted_mover() -> bool:
	return _touch_area == null and not is_player_usable()


func _door_activate(activator: Node3D = null) -> void:
	if _is_network_client():
		return
	if state == State.AT_TOP and (spawn_flags & SF_NO_AUTO_RETURN):
		_door_go_down()
	elif state == State.AT_BOTTOM:
		_door_go_up(activator)


# --- State machine ---

func _door_go_up(_activator: Node3D = null) -> void:
	_blocked_hold = false
	state = State.GOING_UP
	_play_door_sound(_move_sound)
	_move_open(_door_hit_top)


func _door_hit_top() -> void:
	state = State.AT_TOP
	_play_door_sound(_stop_sound)
	_fire_target()

	if _pending_flip:
		_pending_flip = false
		_door_go_down()
		return

	if wait_time == -1.0:
		pass  # stay open forever
	elif wait_time >= 0.0 and not (spawn_flags & SF_NO_AUTO_RETURN):
		get_tree().create_timer(wait_time).timeout.connect(
			func():
				if is_instance_valid(self) and state == State.AT_TOP:
					_door_go_down(),
			CONNECT_ONE_SHOT)


func _door_go_down() -> void:
	_blocked_hold = false
	state = State.GOING_DOWN
	_play_door_sound(_move_sound)
	_move_closed(_door_hit_bottom)


func _door_hit_bottom() -> void:
	state = State.AT_BOTTOM
	_play_door_sound(_stop_sound)
	# GoldSrc DoorHitBottom fires no target — the state machine handles re-triggering.
	if _pending_flip:
		_pending_flip = false
		_door_go_up()


# --- Virtual methods (override in subclass) ---

func _move_open(_callback: Callable) -> void:
	push_error("_move_open not implemented")


func _move_closed(_callback: Callable) -> void:
	push_error("_move_closed not implemented")


# --- Blocked detection helpers ---

## Only a netmove player can be blocked ON, since the depth comes from the blocker's own hull
## probe. Narrower than it looks: skeletons, tornadoes and a ridden dragon are CharacterBody3D
## too, and like every prop they ride the mover's published kinematic velocity instead.
func _get_active_blocker() -> CharacterBody3D:
	if state != State.GOING_UP and state != State.GOING_DOWN:
		_push_frames = 0
		return null
	if not _blocked_area:
		return null
	for body in _blocked_area.get_overlapping_bodies():
		if body is CharacterBody3D and body.has_method("mover_obstruction"):
			return body
	_push_frames = 0
	return null


## CBaseDoor::Blocked. Hurt the blocker, reverse (a negative wait means the door
## would never come back, so it stays a crusher instead), then reverse every
## other door sharing this targetname so a gang stays in phase.
func _handle_blocked(blocker: CharacterBody3D) -> void:
	_push_frames += 1
	if _push_frames < PUSH_GRACE_FRAMES:
		return
	_push_frames = 0
	if damage > 0.0 and blocker.has_method("take_damage"):
		blocker.take_damage(damage)
	if wait_time < 0:
		return
	_blocked_reverse()
	_blocked_reverse_gang()


func _blocked_reverse() -> void:
	if state == State.GOING_DOWN:
		_door_go_up()
	else:
		_door_go_down()


## The SDK walks every entity with the blocked door's targetname and reverses
## the func_door/func_door_rotating ones — settled or not, which for a door
## already sitting at the end of its travel is a no-op move.
func _blocked_reverse_gang() -> void:
	var group_name: String = ent.get("targetname", "")
	if group_name.is_empty():
		return
	for node in TriggerSystem.get_nodes(group_name):
		if node == self or not (node is FuncDoorBase):
			continue
		var sibling: FuncDoorBase = node
		if not (sibling.ent.get("classname", "") in DOOR_CLASSNAMES):
			continue
		if sibling.wait_time < 0:
			continue
		_blocked_realign(sibling)
		sibling._blocked_reverse()


## The SDK's realign hack ("the most hacked, evil, bastardized thing I've ever
## seen. kjb") snaps a sibling onto the blocked door's position first. Its
## velocity compare reads avelocity against *linear* velocity, so a sliding
## door never passes it — see FuncDoorRotating for the case that does.
func _blocked_realign(_sibling: FuncDoorBase) -> void:
	pass


## What a blocked mover does when its class has no Blocked handler: the engine
## reverts the push and calls it again next frame, so the mover stalls against
## the blocker and carries on once the way is clear (buttons).
func _hold_for_blocker() -> void:
	if _blocked_hold:
		return
	_blocked_hold = true
	if _tween:
		_tween.kill()


func _resume_after_block() -> void:
	if not _blocked_hold:
		return
	_blocked_hold = false
	if state == State.GOING_DOWN:
		_door_go_down()
	elif state == State.GOING_UP:
		_door_go_up()


# --- Late-join state sync ---

func _get_sync_state() -> Dictionary:
	var s := super._get_sync_state()
	# AT_BOTTOM == position1/angle1, which the client already initializes to in _ready().
	if state != State.AT_BOTTOM:
		s["entity_pos"] = position
		s["entity_rot"] = rotation
	return s


func _apply_sync_state(s: Dictionary) -> void:
	super._apply_sync_state(s)
	if "entity_pos" in s:
		position = s["entity_pos"]
	if "entity_rot" in s:
		rotation = s["entity_rot"]


# --- Helpers ---

## GoldSrc applies glPolygonOffset to entity brush models so they render on top
## of coplanar worldspawn faces. render_priority alone doesn't fix opaque
## z-fighting (depth test is strict LESS), so we also push vertices along their
## surface normals by a sub-pixel amount — the Godot equivalent of glPolygonOffset.
func _set_entity_render_priority(mesh_child: MeshInstance3D) -> void:
	_apply_depth_bias(mesh_child, 0.001)
	for i in mesh_child.get_surface_override_material_count():
		var mat := mesh_child.get_active_material(i)
		if mat:
			var dup := mat.duplicate()
			dup.render_priority = 1
			mesh_child.set_surface_override_material(i, dup)


func _apply_depth_bias(mesh_inst: MeshInstance3D, bias: float) -> void:
	var src := mesh_inst.mesh
	if not src is ArrayMesh:
		return
	var arr_mesh: ArrayMesh = src
	var new_mesh := ArrayMesh.new()
	for surf_idx in arr_mesh.get_surface_count():
		var arrays := arr_mesh.surface_get_arrays(surf_idx)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var norms = arrays[Mesh.ARRAY_NORMAL]
		if norms is PackedVector3Array and norms.size() == verts.size():
			for i in verts.size():
				verts[i] += norms[i] * bias
			arrays[Mesh.ARRAY_VERTEX] = verts
		var prim := arr_mesh.surface_get_primitive_type(surf_idx)
		var mat := arr_mesh.surface_get_material(surf_idx)
		new_mesh.add_surface_from_arrays(prim, arrays)
		if mat:
			new_mesh.surface_set_material(surf_idx, mat)
	mesh_inst.mesh = new_mesh


## GoldSrc's Touch fires every frame a body is in contact; an Area3D only reports the crossing. A
## plat that comes to rest UNDER somebody already standing in its call volume therefore never hears
## from them again — so whoever rode it down, or was waiting where it lands, is left on a deck that
## will not move for them. Re-offer the touch to whoever is already inside. (CPlatTrigger::Touch.)
func _retouch() -> void:
	if _touch_area == null:
		return
	for body in _touch_area.get_overlapping_bodies():
		_on_touch_body_entered(body)   # same admission rules as the crossing itself


func _disable_touch() -> void:
	pass  # monitoring stays on; state machine guards prevent spurious re-triggers


func _enable_touch() -> void:
	pass  # monitoring stays on; state machine guards prevent spurious re-triggers


func _fire_target() -> void:
	if not target_key.is_empty():
		TriggerSystem.fire(target_key, self, TriggerSystem.Type.TOGGLE)


func _play_door_sound(stream: AudioStream) -> void:
	if not stream:
		return
	SoundSystem.play_3d(stream.resource_path, global_position)


## CBaseDoor::Blocked fires when the pushed entity couldn't be moved, which netmove already
## measures: its pusher ejects a blocker that has anywhere to go, so one that keeps getting
## DEEPER has run out of room. Read rather than re-simulated, so it costs no query and holds
## for linear, rotating and both-at-once (func_platrot, func_tracktrain) movers alike.
func _physics_process(_delta: float) -> void:
	var blocker := _get_active_blocker()
	if not blocker:
		_block_id = 0
		_block_depth = 0.0
		_resume_after_block()
		return

	var depth := _blocker_depth(blocker)
	if depth < 0.0:
		return  # no measurement this frame; hold whatever we decided last

	var id := blocker.get_instance_id()
	# A first sighting is only a baseline — growth needs two samples of the same blocker.
	var deeper: bool = id == _block_id and depth > _block_depth + BLOCK_DEPTH_GROWTH
	_block_id = id
	_block_depth = depth

	if depth <= blocker.safe_margin * BLOCK_SLOP_MARGINS:
		# Resting contact, not a trap: riding the mover, or being pushed along by it.
		_push_frames = 0
		_resume_after_block()
		return

	if deeper:
		_handle_blocked(blocker)


## -1.0 when the blocker can't tell us: not a netmove player, or it ran no tick recently.
func _blocker_depth(blocker: CharacterBody3D) -> float:
	if not blocker.has_method("mover_obstruction"):
		return -1.0
	return blocker.mover_obstruction(_anim_body)


func _linear_move(dest: Vector3, done_callback: Callable) -> void:
	var target_pos := _base_position + dest
	var dist := (target_pos - position).length()
	if dist < 0.001:
		done_callback.call()
		return

	var duration := dist / move_speed
	if _tween:
		_tween.kill()
	_tween = create_tween()
	_tween.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	_tween.tween_property(self, "position", target_pos, duration)
	var d := target_pos  # capture for lambda
	_tween.tween_callback(func(): position = d; done_callback.call())


func _angular_move(dest: Vector3, done_callback: Callable) -> void:
	var target_rot := _base_rotation + dest
	var delta := target_rot - rotation
	var angle_delta := rad_to_deg(delta.length())
	if angle_delta < 0.001:
		done_callback.call()
		return

	var duration := angle_delta / rot_speed
	if _tween:
		_tween.kill()
	_tween = create_tween()
	_tween.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	_tween.tween_property(self, "rotation", target_rot, duration)
	var d := target_rot  # capture for lambda
	_tween.tween_callback(func(): rotation = d; done_callback.call())
