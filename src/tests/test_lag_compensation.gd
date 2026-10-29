extends "res://src/tests/test_base.gd"
## Tests for LagCompensation.rewind(): a shot must be resolved against the pose the shooter
## actually saw — position AND yaw — at the timestamp stamped on it (one INTERP_DELAY behind
## their server-clock estimate). These feed rewind() timestamps in the past and check the
## hitboxes land on the recorded pose rather than the live one.

const ProbeScript = preload("res://src/tests/helpers/lag_comp_probe.gd")
const RigProbeScript = preload("res://src/tests/helpers/lag_comp_rig_probe.gd")

const TARGET_PEER := 7
const TARGET_POS := Vector3(0, 0, -5)
const HITBOX_OFFSET := Vector3(0, 1, 0)


func _probe(name_hint: String) -> CharacterBody3D:
	var body := CharacterBody3D.new()
	body.name = name_hint
	body.set_script(ProbeScript)
	_root().add_child(body)
	return body


func _target(hitbox_offset := HITBOX_OFFSET) -> CharacterBody3D:
	var body := _probe("LagCompTarget")
	body.peer_id = TARGET_PEER
	body.add_to_group("damageable")
	body.global_position = TARGET_POS
	body.add_hitbox(hitbox_offset)
	return body


## A target whose hitboxes hang off an animated skeleton, like the real wizard models —
## the shape that makes rewind() take its full-fidelity re-posing path.
func _rig_target() -> CharacterBody3D:
	var body := CharacterBody3D.new()
	body.name = "LagCompRigTarget"
	body.set_script(RigProbeScript)
	_root().add_child(body)
	body.peer_id = TARGET_PEER
	body.add_to_group("damageable")
	body.global_position = TARGET_POS
	body.build_rig()
	return body


func _hitbox_xform(target: CharacterBody3D) -> Transform3D:
	return PhysicsServer3D.area_get_transform(target.get_hitbox_areas()[0].get_rid())


func test_rewind_moves_hitbox_to_recorded_position() -> void:
	LagCompensation.clear_all()
	var target := _target()
	var shooter := _probe("LagCompShooter")
	await _settle()

	# The target stood 3 units right of its live position when the shot was taken.
	var now := Time.get_ticks_msec()
	LagCompensation.record(TARGET_PEER, now - 200, TARGET_POS + Vector3(3, 0, 0), 0.0)
	LagCompensation.record(TARGET_PEER, now - 100, TARGET_POS + Vector3(3, 0, 0), 0.0)
	shooter.lag_comp_shot_time_ms = now - 100

	var live := _hitbox_xform(target)
	var saved := LagCompensation.rewind(shooter)
	var rewound := _hitbox_xform(target)
	assert_vec3_almost_eq(rewound.origin, live.origin + Vector3(3, 0, 0), 0.01,
		"hitbox sits on the recorded position during the query")

	LagCompensation.restore(saved)
	assert_vec3_almost_eq(_hitbox_xform(target).origin, live.origin, 0.001,
		"restore() puts the hitbox back on the live position")
	target.free()
	shooter.free()


func test_rewind_interpolates_between_samples() -> void:
	LagCompensation.clear_all()
	var target := _target()
	var shooter := _probe("LagCompShooter")
	await _settle()

	var now := Time.get_ticks_msec()
	LagCompensation.record(TARGET_PEER, now - 200, TARGET_POS, 0.0)
	LagCompensation.record(TARGET_PEER, now - 100, TARGET_POS + Vector3(4, 0, 0), 0.0)
	shooter.lag_comp_shot_time_ms = now - 150  # halfway between the two samples

	var live := _hitbox_xform(target)
	var saved := LagCompensation.rewind(shooter)
	assert_vec3_almost_eq(_hitbox_xform(target).origin, live.origin + Vector3(2, 0, 0), 0.05,
		"a stamp between two samples lands halfway along the recorded path")
	LagCompensation.restore(saved)
	target.free()
	shooter.free()


func test_rewind_applies_recorded_yaw() -> void:
	LagCompensation.clear_all()
	# Hitbox offset to the body's right, so a yaw rewind moves it even though the origin didn't.
	var target := _target(Vector3(0.5, 1, 0))
	var shooter := _probe("LagCompShooter")
	await _settle()

	var now := Time.get_ticks_msec()
	LagCompensation.record(TARGET_PEER, now - 200, TARGET_POS, PI / 2.0)
	LagCompensation.record(TARGET_PEER, now - 100, TARGET_POS, PI / 2.0)
	shooter.lag_comp_shot_time_ms = now - 100

	var saved := LagCompensation.rewind(shooter)
	var rewound := _hitbox_xform(target)
	# Yaw +90° about the body origin swings a +X offset onto -Z (Godot's right-handed Y-up).
	assert_vec3_almost_eq(rewound.origin, TARGET_POS + Vector3(0, 1, -0.5), 0.01,
		"the hitbox orbits the body origin by the recorded yaw delta")
	assert_vec3_almost_eq(rewound.basis.x, Vector3(0, 0, -1), 0.01,
		"the box is turned, not just translated — an oriented hitbox covers the right silhouette")
	LagCompensation.restore(saved)
	assert_vec3_almost_eq(_hitbox_xform(target).basis.x, Vector3(1, 0, 0), 0.001,
		"restore() puts the orientation back too")
	target.free()
	shooter.free()


func test_stamp_beyond_max_rewind_is_clamped() -> void:
	LagCompensation.clear_all()
	var target := _target()
	var shooter := _probe("LagCompShooter")
	await _settle()

	var now := Time.get_ticks_msec()
	var cap: int = LagCompensation.MAX_REWIND_MS
	LagCompensation.record(TARGET_PEER, now - cap - 100, TARGET_POS + Vector3(6, 0, 0), 0.0)
	LagCompensation.record(TARGET_PEER, now - cap + 100, TARGET_POS + Vector3(4, 0, 0), 0.0)
	# 300ms past the cap. Stays positive against the engine uptime clock, where <= 0 is the
	# "unstamped, don't rewind" sentinel rather than a very old shot.
	shooter.lag_comp_shot_time_ms = now - cap - 300

	var live := _hitbox_xform(target)
	var saved := LagCompensation.rewind(shooter)
	assert_vec3_almost_eq(_hitbox_xform(target).origin, live.origin + Vector3(5, 0, 0), 0.05,
		"the stamp is clamped to the cap, sampling the pose at now - MAX_REWIND_MS")
	LagCompensation.restore(saved)
	target.free()
	shooter.free()


func test_unstamped_shot_does_not_rewind() -> void:
	LagCompensation.clear_all()
	var target := _target()
	var shooter := _probe("LagCompShooter")
	await _settle()

	var now := Time.get_ticks_msec()
	LagCompensation.record(TARGET_PEER, now - 100, TARGET_POS + Vector3(3, 0, 0), 0.0)
	shooter.lag_comp_shot_time_ms = 0  # server-side attacker (bot, dragon): no latency to undo

	var live := _hitbox_xform(target)
	var saved := LagCompensation.rewind(shooter)
	assert_true(saved.is_empty(), "an unstamped shot rewinds nothing")
	assert_vec3_almost_eq(_hitbox_xform(target).origin, live.origin, 0.001,
		"hitboxes stay on the live pose")
	target.free()
	shooter.free()


## The hitboxes ride bones, so the animation frame moves them as surely as the body does.
## Position and yaw are held fixed here: the recorded frame is the ONLY thing separating the
## rewound pose from the live one.
func test_rewind_restores_recorded_animation_frame() -> void:
	LagCompensation.clear_all()
	var target := _rig_target()
	var shooter := _probe("LagCompShooter")
	await _settle()

	var now := Time.get_ticks_msec()
	target.seek_clip(0.0)
	LagCompensation.record(TARGET_PEER, now - 200, TARGET_POS, 0.0, target)
	LagCompensation.record(TARGET_PEER, now - 100, TARGET_POS, 0.0, target)
	# ...and then the clip ran on, carrying the bone — and its hitbox — 4m away.
	target.seek_clip(1.0)
	shooter.lag_comp_shot_time_ms = now - 100

	assert_vec3_almost_eq(target.lag_comp_hitbox_world_transforms()[0].origin,
		TARGET_POS + RigProbeScript.BONE_TRAVEL, 0.01,
		"the live rig really has moved the box (guards against a vacuous assertion below)")

	var saved := LagCompensation.rewind(shooter)
	assert_vec3_almost_eq(_hitbox_xform(target).origin, TARGET_POS, 0.01,
		"the query runs against the bone pose from the recorded frame, not the live one")
	LagCompensation.restore(saved)
	target.free()
	shooter.free()


## Crouching shifts the whole rig down a model offset, and the clip changes with it. That's a
## step change rather than a smooth wobble, so an unrewound crouch can move the head box far
## enough to flip a headshot.
func test_rewind_restores_recorded_crouch_offset() -> void:
	LagCompensation.clear_all()
	var target := _rig_target()
	var shooter := _probe("LagCompShooter")
	await _settle()

	var now := Time.get_ticks_msec()
	target.seek_clip(0.0)
	target.set_crouched(false)
	LagCompensation.record(TARGET_PEER, now - 200, TARGET_POS, 0.0, target)
	LagCompensation.record(TARGET_PEER, now - 100, TARGET_POS, 0.0, target)
	target.set_crouched(true)  # ducked after the shot was fired
	shooter.lag_comp_shot_time_ms = now - 100

	var saved := LagCompensation.rewind(shooter)
	assert_vec3_almost_eq(_hitbox_xform(target).origin, TARGET_POS, 0.01,
		"the boxes sit at standing height, where the shooter saw them")
	LagCompensation.restore(saved)
	target.free()
	shooter.free()


## A rewind now moves the body node and re-poses the rig, not just the collider transforms.
## Anything it leaves behind is a server-visible desync, so restore() has to put all of it back.
func test_restore_returns_the_rig_to_its_live_pose() -> void:
	LagCompensation.clear_all()
	var target := _rig_target()
	var shooter := _probe("LagCompShooter")
	await _settle()

	var now := Time.get_ticks_msec()
	target.seek_clip(0.0)
	target.set_crouched(false)
	LagCompensation.record(TARGET_PEER, now - 200, TARGET_POS + Vector3(3, 0, 1), 1.2, target)
	LagCompensation.record(TARGET_PEER, now - 100, TARGET_POS + Vector3(3, 0, 1), 1.2, target)
	target.seek_clip(0.75)
	target.set_crouched(true)
	shooter.lag_comp_shot_time_ms = now - 100

	var live_pose: Array = target.lag_comp_capture_pose()
	var live_xform := target.global_transform
	var live_box: Transform3D = target.lag_comp_hitbox_world_transforms()[0]
	var live_area := _hitbox_xform(target)

	LagCompensation.restore(LagCompensation.rewind(shooter))

	assert_eq(target.lag_comp_capture_pose()[0], live_pose[0], "crouch state is back")
	assert_eq(target.lag_comp_capture_pose()[1], live_pose[1], "the clip is back")
	assert_almost_eq(target.lag_comp_capture_pose()[2], live_pose[2], 0.001,
		"the animation frame is back where the sim left it")
	assert_vec3_almost_eq(target.global_position, live_xform.origin, 0.001,
		"the body node is back too")
	assert_vec3_almost_eq(target.lag_comp_hitbox_world_transforms()[0].origin, live_box.origin,
		0.001, "...so the rig puts its boxes back where they were")
	assert_vec3_almost_eq(_hitbox_xform(target).origin, live_area.origin, 0.001,
		"and the physics server holds exactly the transforms rewind() took from it")
	target.free()
	shooter.free()


## Every damageable player rewinds on every shot; ghosting all of them buries the one being
## aimed at. Only targets near the shot ray are sent.
func test_ghosts_filtered_to_targets_near_the_shot() -> void:
	var from := Vector3.ZERO
	assert_true(LagCompensation._near_ray(Vector3(50, 0, 0), from, Vector3.FORWARD, 0.0),
		"callers with no ray (tests, non-hitscan damage) ghost everything")
	assert_true(LagCompensation._near_ray(Vector3(0, 0, -10), from, Vector3.FORWARD, 30.0),
		"a target sitting on the shot ray is ghosted")
	assert_true(LagCompensation._near_ray(Vector3(1.0, 0, -10), from, Vector3.FORWARD, 30.0),
		"so is a near miss inside the radius — those are the shots worth inspecting")
	assert_false(LagCompensation._near_ray(Vector3(8, 0, -10), from, Vector3.FORWARD, 30.0),
		"a bystander well off to the side is not")
	assert_false(LagCompensation._near_ray(Vector3(0, 0, -50), from, Vector3.FORWARD, 30.0),
		"neither is one past the end of the ray")
