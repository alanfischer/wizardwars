extends "res://src/tests/test_base.gd"
## Third person moves exactly ONE thing: where the frame is drawn from. The eye keeps the aim,
## the +use ray, the audio listener, the PVS observer and the head-liquid check, and the chase
## camera sits strictly behind that eye on the same axis — which is what lets screen centre stay
## the true crosshair with no HUD parallax correction. These pin both halves of that: the view
## copy of your own wizard is inert, and the camera never leaves the aim axis however hard a
## wall pushes it in.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.

const LocalPlayerScene = preload("res://src/local_player.tscn")


## The view copy through the same factory production uses, so the test cannot drift from it.
func _avatar() -> RemotePlayer:
	var a := RemotePlayer.make_local_avatar(1)
	_root().add_child(a)
	_spawned.append(a)
	return a


## An ordinary puppet, for the comparisons that only mean something against one.
func _puppet() -> RemotePlayer:
	var p: RemotePlayer = load("res://src/remote_player.tscn").instantiate()
	var net_sync := p.get_node(^"NetSync")
	p.remove_child(net_sync)
	net_sync.free()
	_root().add_child(p)
	_spawned.append(p)
	return p


## A local player in third person, held still. Frozen because it is a live predicted body: left
## running it falls, and a wall placed at a fixed spot would be somewhere else by the trace.
func _local_player() -> LocalPlayer:
	var lp: LocalPlayer = LocalPlayerScene.instantiate()
	_root().add_child(lp)
	_spawned.append(lp)
	lp.set_third_person(false)  # _post_ready restored the developer's own saved setting
	lp.set_third_person(true)
	await _physics_tick()
	lp.set_physics_process(false)
	lp.set_process(false)
	return lp


## Straight behind the frozen eye: it looks down -Z, so +Z is the arm's direction.
func _wall_behind_eye(lp: LocalPlayer, near_face_dist: float) -> StaticBody3D:
	const HALF_DEPTH := 0.5
	var eye := lp.camera.global_transform
	var body := StaticBody3D.new()
	body.collision_layer = GameConsts.MASK_WORLD
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4.0, 4.0, HALF_DEPTH * 2.0)
	cs.shape = box
	body.add_child(cs)
	_root().add_child(body)
	body.global_position = eye.origin + eye.basis.z * (near_face_dist + HALF_DEPTH)
	_spawned.append(body)
	return body


## Bodies added this frame are not in the broad phase until the server has stepped.
func _physics_tick() -> void:
	await (Engine.get_main_loop() as SceneTree).physics_frame
	await (Engine.get_main_loop() as SceneTree).physics_frame


# --- The view copy ---

func test_the_view_copy_is_not_a_target() -> void:
	var a := _avatar()
	assert_false(a.is_in_group("damageable"),
		"Player._init() puts every player in it; a copy of ourselves has to come back out")
	a.set_damageable(true)
	assert_false(a.is_in_group("damageable"),
		"and stay out — has_body_puppet makes the base class's gate refuse to re-add it")
	assert_eq(a.collision_layer, 0, "nothing may collide with the copy")
	assert_eq(a.collision_mask, 0, "and it collides with nothing")
	var shape := a.get_node_or_null(^"CollisionShape3D") as CollisionShape3D
	assert_true(shape != null and shape.disabled,
		"the local player is already standing there — a second capsule would block them")


func test_the_view_copy_carries_no_hitboxes() -> void:
	var dressed := _puppet()
	dressed._load_player_model("fire")
	assert_gt(_count_hitboxes(dressed), 0,
		"the wizard MDL ships per-bone hitboxes — without this the next assert proves nothing")

	var a := _avatar()
	a.dress_local_avatar(GameConsts.Element.FIRE, GameConsts.Team.BLUE, false,
		([] as Array[Weapon]), 0)
	assert_ne(a._wizard_model, null, "the copy is wearing the same model")
	assert_eq(_count_hitboxes(a), 0,
		"hitboxes on a copy of ourselves sit on our own aim ray — the viewmodel-hands bug again")
	assert_true(a.get_hitbox_areas().is_empty(), "and nothing may rewind them for lag compensation")


func test_the_view_copy_has_no_class_until_one_is_picked() -> void:
	var a := _avatar()
	a.dress_local_avatar(-1, GameConsts.Team.NONE, false, ([] as Array[Weapon]), 0)
	assert_eq(a._wizard_model, null, "a spectator has no wizard to draw")


func test_driving_the_view_copy_sets_the_pose_the_animation_reads() -> void:
	var a := _avatar()
	a.drive_local_avatar(Vector3(3.0, 1.0, -2.0), 0.75, -0.25, true, Vector3(0.0, 0.0, -4.5),
		false, false, false, false)
	assert_eq(a.global_position, Vector3(3.0, 1.0, -2.0), "feet go where the driver says")
	assert_almost_eq(a.global_rotation.y, 0.75, 0.0001, "yaw follows the local player")
	assert_almost_eq(a.sync_pitch, -0.25, 0.0001, "pitch is what bends the spine")
	assert_true(a.sync_crouched, "crouch picks the crawl/crouch_idle clips")
	assert_almost_eq(a.sync_speed, 4.5, 0.0001, "speed is what picks run2 over idle")
	assert_false(a.is_dragon_mounted, "not riding")
	a.drive_local_avatar(Vector3.ZERO, 0.0, 0.0, false, Vector3.ZERO, false, false, true, false)
	assert_true(a.is_dragon_mounted, "riding selects the dragon-breath clip")


## The copy hangs UNDER the local player, who is themselves turned to the yaw being passed in.
## A local rotation.y would land on top of the parent's and the model would spin twice for every
## turn of the view — top_level is what makes the parent transform unable to reach it at all.
func test_the_view_copy_does_not_inherit_the_yaw_it_is_given() -> void:
	var turned := Node3D.new()
	_root().add_child(turned)
	_spawned.append(turned)
	turned.rotation.y = 1.0
	var a := _avatar()
	a.reparent(turned)

	a.drive_local_avatar(Vector3.ZERO, 1.0, 0.0, false, Vector3.ZERO, false, false, false, false)
	assert_almost_eq(a.global_rotation.y, 1.0, 0.0001,
		"the yaw is the world yaw, applied once — not once more for the parent already at it")


# --- The chase camera ---

func test_the_eye_still_owns_the_aim_in_third_person() -> void:
	var lp := await _local_player()
	assert_eq(lp._active_camera(), lp.camera,
		"aim, +use, the audio listener and the head-liquid check all read this one")
	assert_ne(lp._render_camera(), lp.camera, "only the drawing moved")
	assert_false(lp.camera.current, "the chase camera is the one drawing")
	assert_true(lp._render_camera().current, "")


func test_the_chase_camera_sits_straight_behind_the_eye() -> void:
	var lp := await _local_player()
	lp._update_chase_camera()

	var eye := lp.camera.global_transform
	var chase := lp._chase_camera.global_transform
	var offset := chase.origin - eye.origin
	assert_almost_eq(offset.cross(eye.basis.z).length(), 0.0, 0.0001,
		"any sideways component and screen centre stops being where the shot goes")
	assert_gt(offset.dot(eye.basis.z), 0.0, "behind the eye, not in front of it")
	assert_almost_eq(offset.length(), LocalPlayer.CHASE_DISTANCE, 0.01, "in open air, the full arm")
	assert_almost_eq((chase.basis.z - eye.basis.z).length(), 0.0, 0.0001,
		"and looking the same way, so the two views share a forward")


func test_a_wall_shortens_the_arm_without_moving_it_off_the_axis() -> void:
	var lp := await _local_player()
	_wall_behind_eye(lp, 1.5)
	await _physics_tick()
	lp._update_chase_camera()

	var eye := lp.camera.global_transform
	var offset := lp._chase_camera.global_position - eye.origin
	assert_lt(offset.length(), LocalPlayer.CHASE_DISTANCE, "the wall pulled the camera in")
	assert_gt(offset.length(), LocalPlayer.CHASE_MIN_DISTANCE, "but not all the way to the eye")
	assert_almost_eq(offset.length(), 1.5 - LocalPlayer.CHASE_RADIUS, 0.05,
		"stopping a sphere-radius clear of the surface, which is the camera's wall clearance")
	assert_almost_eq(offset.cross(eye.basis.z).length(), 0.0, 0.0001,
		"shortening the arm is the ONLY thing a wall is allowed to do to it")


func test_backed_against_a_wall_the_body_gets_out_of_the_lens() -> void:
	var lp := await _local_player()
	lp._local_avatar.visible = true
	_wall_behind_eye(lp, 0.1)
	await _physics_tick()
	lp._update_chase_camera()

	assert_lt((lp._chase_camera.global_position - lp.camera.global_position).length(),
		LocalPlayer.CHASE_MIN_DISTANCE, "the camera has nowhere to go")
	assert_false(lp._local_avatar.visible,
		"drawing our own head from inside it is worse than showing no body at all")


func test_turning_third_person_off_puts_everything_back() -> void:
	var lp := await _local_player()
	var avatar := lp._local_avatar
	assert_ne(avatar, null, "the copy exists while it is being drawn")
	lp.set_third_person(false)
	assert_eq(lp._chase_camera, null, "the chase camera is gone")
	assert_eq(lp._local_avatar, null, "and so is the copy")
	assert_true(lp.camera.current, "the eye is drawing again")
	assert_eq(lp._render_camera(), lp.camera, "")
