extends "res://src/tests/test_base.gd"
## What a third-person wizard's body does with the state the netcode hands it: the legs point
## along the run while the torso stays on the aim (GoldSrc's gait), water picks the swim clips,
## and a swing restarts on every shot instead of resuming the one already in flight.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.


## A dressed puppet, out of the stream — the model half is all these tests touch.
## A REMOTE player with a model loaded, which is what gait lives on — not the base _remote_wizard's
## bare Player. NetSync is torn out because nothing here replicates.
func _remote_wizard() -> RemotePlayer:
	var p: RemotePlayer = load("res://src/remote_player.tscn").instantiate()
	var net_sync := p.get_node(^"NetSync")
	p.remove_child(net_sync)
	net_sync.free()
	_root().add_child(p)
	_spawned.append(p)
	p._load_player_model("fire")
	return p


## Where the top of the spine — and so the head and both arms, which hang off it — is pointing
## in the world, which is the thing the gait twist has to leave alone.
func _chest_world_basis(p: RemotePlayer) -> Basis:
	var idx: int = p._gait_bone_indices[p._gait_bone_indices.size() - 1]
	return (p._skeleton.global_transform * p._skeleton.get_bone_global_pose(idx)).basis


func _yaw_between(a: Basis, b: Basis) -> float:
	return wrapf((a.inverse() * b).get_euler().y, -PI, PI)


# --- The gait ---

func test_the_legs_turn_to_the_direction_of_travel() -> void:
	var p := _remote_wizard()
	assert_eq(p._gait_bone_indices.size(), 4,
		"the wizard MDL's four spine controllers are what the twist is spread over")
	p.rotation.y = 0.0  # aiming down -Z
	p.set_sync_velocity(Vector3(-4.0, 0.0, 0.0))  # strafing left, a quarter turn off the aim
	p._update_gait(0.016)
	assert_almost_eq(p._gait_offset, PI / 2.0, 0.001, "the legs point along the strafe")
	assert_false(p._gait_reversed, "a quarter turn is well inside the spine's range")
	p._apply_gait_rotation()
	assert_almost_eq(p._wizard_model.rotation.y, deg_to_rad(90.0) + PI / 2.0, 0.001,
		"the model carries the gait on top of its baked 90 degrees")
	assert_almost_eq(p.rotation.y, 0.0, 0.0001,
		"and the body itself does not turn — it is the aim, the hull and the yaw we broadcast")


func test_the_torso_stays_on_the_aim_while_the_legs_are_turned() -> void:
	var p := _remote_wizard()
	p.rotation.y = 0.0
	p._apply_gait_rotation()
	p._apply_spine_pose()
	var straight := _chest_world_basis(p)

	p.set_sync_velocity(Vector3(-4.0, 0.0, 0.0))
	p._update_gait(0.016)
	p._apply_gait_rotation()
	p._apply_spine_pose()
	assert_almost_eq(_yaw_between(straight, _chest_world_basis(p)), 0.0, 0.02,
		"the spine twists back by exactly what the model was turned by, so the chest, head and "
		+ "both arms end up facing where the wizard is aiming")


func test_standing_still_walks_the_legs_back_under_the_view() -> void:
	var p := _remote_wizard()
	p.rotation.y = 0.0
	p.set_sync_velocity(Vector3(-4.0, 0.0, 0.0))
	p._update_gait(0.016)
	var turned: float = absf(p._gait_offset)
	p.set_sync_velocity(Vector3.ZERO)
	p._update_gait(0.1)
	assert_lt(absf(p._gait_offset), turned, "the legs come back toward the aim")
	assert_gt(absf(p._gait_offset), 0.0, "over about a quarter second, not in one frame")
	for i in 20:
		p._update_gait(0.1)
	assert_almost_eq(p._gait_offset, 0.0, 0.01, "and settle square under it")


func test_a_backpedal_turns_the_legs_around_and_runs_the_cycle_backwards() -> void:
	var p := _remote_wizard()
	p.rotation.y = 0.0  # aiming down -Z
	p.set_sync_velocity(Vector3(0.0, 0.0, 4.0))  # running the other way
	p._update_gait(0.016)
	assert_true(p._gait_reversed,
		"half a turn is past the spine's 120 degrees — GoldSrc spins the legs instead")
	assert_almost_eq(p._gait_offset, 0.0, 0.001, "so the legs end up back under the aim")
	p._update_animation(true)
	assert_eq(p._anim_player.current_animation, "run2", "still the run cycle")
	assert_almost_eq(p._anim_player.speed_scale, -1.0, 0.001, "played backwards — a backpedal")
	p.set_sync_velocity(Vector3(0.0, 0.0, -4.0))
	p._update_gait(0.016)
	p._update_animation(true)
	assert_almost_eq(p._anim_player.speed_scale, 1.0, 0.001, "running forward again")


func test_only_the_locomotion_cycle_ever_runs_backwards() -> void:
	var p := _remote_wizard()
	p.rotation.y = 0.0
	p.set_sync_velocity(Vector3(0.0, 0.0, 4.0))
	p._update_gait(0.016)
	p.sync_jumping = true
	p._update_animation(true)
	assert_eq(p._anim_player.current_animation, "jump")
	assert_almost_eq(p._anim_player.speed_scale, 1.0, 0.001,
		"a jump is a one-shot pose, not a cycle — backwards it would land before it took off")


# --- Water ---

func test_a_swimmer_swims() -> void:
	var p := _remote_wizard()
	assert_true(p._anim_player.has_animation("swim"), "the player MDL ships both water clips")
	assert_true(p._anim_player.has_animation("treadwater"))
	p.sync_swimming = true
	p._update_animation(true)
	assert_eq(p._anim_player.current_animation, "swim", "moving through water")
	p._update_animation(false)
	assert_eq(p._anim_player.current_animation, "treadwater", "holding station in it")


func test_water_outranks_the_jump_pose() -> void:
	var p := _remote_wizard()
	p.sync_swimming = true
	p.sync_jumping = true  # a swimmer is in the air-move state as far as the sim is concerned
	p._update_animation(true)
	assert_eq(p._anim_player.current_animation, "swim",
		"or a swimmer bobbing over the surface flickers between the two clips")
	p.sync_swimming = false
	p._update_animation(true)
	assert_eq(p._anim_player.current_animation, "jump", "and out of the water it is a jump again")


func test_the_swim_flag_rides_the_broadcast() -> void:
	var flags := NetworkManager.PLAYER_FLAG_SWIMMING | NetworkManager.PLAYER_FLAG_JUMPING
	assert_eq(flags & NetworkManager.PLAYER_FLAG_CROUCHED, 0,
		"the swim bit has to be its own — sharing one would swap a crouch for a swim")
	assert_eq(flags & NetworkManager.PLAYER_FLAG_FIRING, 0)


# --- The swing ---

func test_a_second_swing_restarts_the_animation() -> void:
	var p := _remote_wizard()
	assert_ne(p._attack_player, null, "the upper-body attack player is what plays a swing")
	assert_true(p._attack_player.has_animation("ref_shoot_staff"))
	p.play_attack()
	assert_eq(p._attack_player.current_animation, "ref_shoot_staff")
	var length: float = p._attack_player.get_animation("ref_shoot_staff").length
	assert_gt(length, 0.5,
		"ref_shoot_staff outlasts the staff's 0.5s cooldown — which is what made this a bug")
	p._attack_player.seek(length * 0.5, true)
	p.play_attack()
	assert_almost_eq(p._attack_player.current_animation_position, 0.0, 0.001,
		"the next shot starts a new swing; resuming the one in flight halved the visible rate")
