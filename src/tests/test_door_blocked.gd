extends "res://src/tests/test_base.gd"
## Blocked movers, per GoldSrc: CBaseDoor::Blocked reverses the door and its whole
## targetname gang, CFuncPlat::Blocked reverses the plat alone, a button just stalls.
## The gang case is what ww_monoliths needs (its four gate_1 doors toggle together).
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.


func _teardown_test() -> void:
	_despawn_all()
	TriggerSystem.reset()


## Untyped on purpose: an AnimatableBody3D only becomes a mover once the script
## is attached, which the static analyser can't see.
func _mover(script, keys := {}):
	var body = AnimatableBody3D.new()
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(PackedVector3Array([
		Vector3.ZERO, Vector3(2, 2, 2), Vector3(2, 0, 0),
		Vector3.ZERO, Vector3(0, 2, 2), Vector3(0, 0, 2),
	]))
	var col := CollisionShape3D.new()
	col.shape = shape
	body.add_child(col)
	var e := {"angles": "0 0 0", "speed": "100"}
	e.merge(keys, true)
	body.set_meta("entity", e)
	body.set_script(script)
	_root().add_child(body)
	_spawned.append(body)
	return body


## A ww_monoliths gate: spawnflags 163 = start open + reverse dir + no auto
## return + rotate X, and all four carry the same targetname.
func _gate(keys := {}):
	var e := {
		"classname": "func_door_rotating", "targetname": "gate_1",
		"spawnflags": "163", "wait": "70", "distance": "90",
	}
	e.merge(keys, true)
	return _mover(FuncDoorRotating, e)


## Physics frames, so a door is genuinely mid-swing before anything blocks it:
## reversing from the exact start angle finishes in the same frame.
func _swing(frames := 10) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	for _i in frames:
		await tree.physics_frame


## PUSH_GRACE_FRAMES worth of blocked reports. Damage is 0 on these movers, so
## the blocker itself is never dereferenced.
func _block(mover) -> void:
	for _i in FuncDoorBase.PUSH_GRACE_FRAMES:
		mover._handle_blocked(null)


func test_a_blocked_door_reverses() -> void:
	var d = _gate()
	d.trigger(null, TriggerSystem.Type.TOGGLE)
	await _swing()
	assert_eq(d.state, FuncDoorBase.State.GOING_UP, "the toggle starts it moving")

	_block(d)
	assert_eq(d.state, FuncDoorBase.State.GOING_DOWN, "blocking sends it back the way it came")


func test_the_whole_gang_reverses_with_it() -> void:
	var a = _gate()
	var b = _gate()
	a.trigger(null, TriggerSystem.Type.TOGGLE)
	b.trigger(null, TriggerSystem.Type.TOGGLE)
	await _swing()

	_block(a)
	assert_eq(b.state, FuncDoorBase.State.GOING_DOWN,
		"every door on the blocked door's targetname reverses, so the gang stays in phase")


func test_a_settled_sibling_is_snapped_onto_the_blocked_door() -> void:
	var a = _gate()
	var b = _gate()
	a.trigger(null, TriggerSystem.Type.TOGGLE)
	await _swing()
	assert_eq(b.state, FuncDoorBase.State.AT_BOTTOM, "b never got the toggle")

	_block(a)
	assert_vec3_almost_eq(b.rotation, a.rotation, 0.0001,
		"the SDK's realign hack drops the still sibling onto the blocked door's angles")
	assert_eq(b.state, FuncDoorBase.State.GOING_DOWN, "and reverses it from there")


func test_only_doors_join_the_gang() -> void:
	var a = _gate()
	var button = _mover(FuncRotButton, {
		"classname": "func_rot_button", "targetname": "gate_1", "spawnflags": "64",
	})
	a.trigger(null, TriggerSystem.Type.TOGGLE)
	await _swing()

	_block(a)
	assert_eq(button.state, FuncDoorBase.State.AT_BOTTOM,
		"the SDK's gang loop only picks up func_door and func_door_rotating")


func test_a_crusher_never_reverses() -> void:
	var a = _gate({"targetname": "crusher", "wait": "-1"})
	var b = _gate({"targetname": "crusher", "wait": "-1"})
	a.trigger(null, TriggerSystem.Type.TOGGLE)
	b.trigger(null, TriggerSystem.Type.TOGGLE)
	await _swing()

	_block(a)
	assert_eq(a.state, FuncDoorBase.State.GOING_UP, "a negative wait squashes instead of coming back")
	assert_eq(b.state, FuncDoorBase.State.GOING_UP, "and its gang is left alone too")


func test_a_blocked_plat_reverses_whatever_its_wait_says() -> void:
	var p = _mover(FuncPlat, {
		"classname": "func_plat", "targetname": "lift1", "wait": "-1", "height": "64",
	})
	p.trigger(null, TriggerSystem.Type.TOGGLE)
	await _swing()
	assert_eq(p.state, FuncDoorBase.State.GOING_DOWN, "a targetnamed plat starts up top")

	_block(p)
	assert_eq(p.state, FuncDoorBase.State.GOING_UP,
		"CFuncPlat::Blocked has no wait check — it always goes back")


func test_a_blocked_button_stalls_instead_of_reversing() -> void:
	var b = _mover(FuncRotButton, {
		"classname": "func_rot_button", "spawnflags": "64", "distance": "90", "wait": "3",
	})
	b.trigger(null, TriggerSystem.Type.TOGGLE)
	await _swing()
	var held_at: Vector3 = b.rotation

	_block(b)
	assert_true(b._blocked_hold, "CBaseButton has no Blocked handler: the engine just stops the push")
	assert_eq(b.state, FuncDoorBase.State.GOING_UP, "so the button still owes its move")
	assert_vec3_almost_eq(b.rotation, held_at, 0.0001, "and holds where it stopped")

	b._resume_after_block()
	assert_false(b._blocked_hold, "clearing the way lets it carry on")


## Stands in for a netmove player: a mover asks its blocker how deep inside it the blocker is,
## so one scripted number is the whole contract — no movement rig needed.
class DepthProbe extends CharacterBody3D:
	var base := 0.0       # depth on the first frame the mover asks
	var per_frame := 0.0  # how much deeper each frame after that
	var _first := -1

	func mover_obstruction(_mover: Object) -> float:
		var frame := Engine.get_physics_frames()
		if _first < 0:
			_first = frame
		return base + per_frame * float(frame - _first)


## Inside the gate's BlockedDetector for the WHOLE swing: that box has one corner on the gate's
## rotation pivot, so only a cube straddling the pivot overlaps it at every angle. A small body
## at the brush centre drifts in partway through, reading as "no blocker" until it does.
func _blocker_body(node: CharacterBody3D) -> CharacterBody3D:
	node.safe_margin = 0.01  # what RemotePlayer/LocalPlayer set; the door reads it for its slop
	node.collision_layer = GameConsts.MASK_PLAYER
	node.collision_mask = 0
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(3, 3, 3)
	cs.shape = box
	node.add_child(cs)
	_root().add_child(node)
	node.global_position = Vector3.ZERO
	_spawned.append(node)
	return node


func _probe(base: float, per_frame: float) -> DepthProbe:
	var p := DepthProbe.new()
	p.base = base
	p.per_frame = per_frame
	_blocker_body(p)
	return p


func test_a_blocker_getting_deeper_every_frame_blocks_the_door() -> void:
	var d = _gate()
	var p := _probe(0.05, 0.02)  # well past the slop, and the gate is gaining on it
	d.trigger(null, TriggerSystem.Type.TOGGLE)

	# Watched per frame, not sampled at the end: this probe deepens forever where a real
	# blocker stops once the door turns around, so it bounces instead of settling.
	var reversed := false
	for _i in 20:
		await _swing(1)
		if d.state == FuncDoorBase.State.GOING_DOWN:
			reversed = true
			break

	assert_eq(p, d._get_active_blocker(), "the probe is the blocker the gate sees")
	assert_true(reversed,
		"a blocker the door keeps gaining on is CBaseDoor::Blocked, so the door reverses")


func test_a_blocker_resting_within_the_slop_is_not_blocking() -> void:
	var d = _gate()
	var p := _probe(0.005, 0.0)  # inside safe_margin: touching, being carried along
	d.trigger(null, TriggerSystem.Type.TOGGLE)
	await _swing(20)

	assert_eq(p, d._get_active_blocker(), "still overlapping the detector")
	assert_eq(d.state, FuncDoorBase.State.GOING_UP,
		"netmove's pusher is keeping ahead of the door, so nothing is blocked")


func test_a_deep_but_steady_blocker_is_not_blocking() -> void:
	# The state a stalled button sits in: already embedded, but the mover has stopped, so it
	# is not gaining. Re-reporting blocked here is what would make a held button oscillate.
	var d = _gate()
	_probe(0.08, 0.0)
	d.trigger(null, TriggerSystem.Type.TOGGLE)
	await _swing(20)

	assert_eq(d.state, FuncDoorBase.State.GOING_UP,
		"depth past the slop only blocks while it is still growing")


func test_a_blocker_that_cannot_measure_is_not_a_blocker() -> void:
	var d = _gate()
	_blocker_body(CharacterBody3D.new())

	d.trigger(null, TriggerSystem.Type.TOGGLE)
	await _swing(20)

	assert_eq(d._get_active_blocker(), null, "a body with no mover_obstruction is skipped")
	assert_eq(d.state, FuncDoorBase.State.GOING_UP, "so the door is never blocked on it")
