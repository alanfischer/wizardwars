extends "res://src/tests/test_base.gd"
## Running down a ramp must keep the player on the ground, so jump works. GoldSrc's PM_WalkMove
## ends with a downward trace of sv_stepsize, re-attaching a player to ground that fell away
## underneath; Godot's move_and_slide only snaps floor_snap_length (0.1 m), too little at running
## speed, so without an equivalent step_down trace descent went mostly airborne, silently eating
## jump presses. The complement matters too: the down trace must not glue a player to a real
## ledge or haul them up a step they never climbed.

const Movement = preload("res://addons/pmove/movement.gd")
const InputCommand = preload("res://addons/pmove/input_command.gd")
const MovementConfig = preload("res://addons/pmove/movement_config.gd")
const GodotBodyC = preload("res://addons/pmove/godot_body.gd")

const TICK := 1.0 / 60.0

var _cfg: MovementConfig
var _sim: Movement.Simulation


func _setup_test(_test_name: String) -> void:
	_cfg = MovementConfig.new()
	_sim = Movement.Simulation.new(_cfg)


## A 40x40 slab tilted about X so that +Z is downhill. Its top surface passes
## through the origin, so surface height at z is -z * tan(angle).
func _make_ramp(angle_deg: float) -> StaticBody3D:
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(40, 1, 40)
	cs.shape = box
	body.add_child(cs)
	_root().add_child(body)
	body.global_position = Vector3(0, -0.5, 0)
	body.rotation.x = deg_to_rad(angle_deg)
	return body


## Flat slab whose top surface is y=0 and which ends at z = +z_edge.
func _make_ledge(z_edge: float) -> StaticBody3D:
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(40, 1, 40)
	cs.shape = box
	body.add_child(cs)
	_root().add_child(body)
	body.global_position = Vector3(0, -0.5, z_edge - 20.0)
	return body


func _make_player(pos: Vector3) -> CharacterBody3D:
	var p := _pmove_body(_cfg.stand_height)
	_root().add_child(p)
	p.global_position = pos
	return p


func _bind(player: CharacterBody3D) -> Array:
	var state := Movement.MovementState.new()
	var body = GodotBodyC.new(player)
	state.bind_body(body)
	state.on_floor = true
	return [body, state]


func _cmd(seq: int, forward := false, jump := false) -> InputCommand:
	var c := InputCommand.new()
	c.seq = seq
	c.delta = TICK
	c.move_input = Vector2(0, 1) if forward else Vector2.ZERO
	c.jump = jump
	return c


## Drive `ticks` netmove ticks so the capsule settles onto whatever it was spawned above.
## Not the base _settle, which only waits.
func _run_ticks(body, state, ticks := 30) -> void:
	for i in ticks:
		_sim.simulate_tick(body, state, _cmd(i))
		await _physics_frame()


func test_stays_grounded_running_down_a_ramp() -> void:
	for angle in [10.0, 20.0, 30.0, 40.0]:
		var ramp := _make_ramp(angle)
		var z0 := -8.0
		var player := _make_player(Vector3(0, -z0 * tan(deg_to_rad(angle)) + 0.05, z0))
		await _settle()
		var bound := _bind(player)
		await _run_ticks(bound[0], bound[1])

		var grounded := 0
		var total := 90
		for i in total:
			_sim.simulate_tick(bound[0], bound[1], _cmd(100 + i, true))
			if bound[1].on_floor:
				grounded += 1
			await _physics_frame()

		assert_eq(grounded, total, "on the ground every tick running down a %d° ramp" % int(angle))
		player.queue_free()
		ramp.queue_free()
		await _settle()


func test_can_jump_while_running_down_a_ramp() -> void:
	# 30° is where the old behaviour ate ~92% of jump presses. Press jump on a
	# different tick of the descent each run: every one of them must launch.
	for press_tick in [12, 17, 23, 31, 40]:
		var ramp := _make_ramp(30.0)
		var z0 := -8.0
		var player := _make_player(Vector3(0, -z0 * tan(deg_to_rad(30.0)) + 0.05, z0))
		await _settle()
		var bound := _bind(player)
		await _run_ticks(bound[0], bound[1])

		var launched := false
		for i in 50:
			_sim.simulate_tick(bound[0], bound[1], _cmd(200 + i, true, i == press_tick))
			if i == press_tick:
				# jump_speed minus the one tick of gravity the launch tick applies.
				launched = bound[1].velocity.y > _cfg.jump_speed * 0.5
			await _physics_frame()

		assert_true(launched, "jump pressed on tick %d of the descent launches" % press_tick)
		player.queue_free()
		ramp.queue_free()
		await _settle()


func test_running_off_a_ledge_still_goes_airborne() -> void:
	# The step-down trace reaches sv_stepsize (0.45 m). A drop far deeper than that
	# is a real fall: the player must leave the ground and keep accelerating down.
	var ledge := _make_ledge(0.0)
	var player := _make_player(Vector3(0, 0.05, -4.0))
	await _settle()
	var bound := _bind(player)
	await _run_ticks(bound[0], bound[1])

	var went_airborne := false
	for i in 120:
		_sim.simulate_tick(bound[0], bound[1], _cmd(300 + i, true))
		if player.global_position.z > 0.5 and not bound[1].on_floor:
			went_airborne = true
		await _physics_frame()

	assert_true(went_airborne, "walking off the edge of a slab is still a fall")
	assert_lt(player.global_position.y, -2.0, "and the player keeps falling")
	player.queue_free()
	ledge.queue_free()
	await _settle()
