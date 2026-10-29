extends "res://src/tests/test_base.gd"
## What the step path is allowed to climb.
##
## walk_move runs two paths and keeps the better: a plain move_and_slide, and a lift →
## slide → drop "step" that clears a stair the slide path is stopped by. The step is only
## taken if the drop lands on something — and that test used to accept any surface past
## normal.y 0.5, which is 60 degrees. move_and_slide's own floor limit is 45 (0.707), so
## between the two a player could be STEPPED onto a slope they could not stand on, one
## step per tick, climbing it in a series of hops while every other part of the movement
## code still called that surface a wall.
##
## ww_2fort's lifts are where it shows: each hangs on four rope brushes pitched at 59.3
## degrees (normal.y = 0.51), sitting exactly in the gap. Walking onto the platform, the
## player climbed the ropes instead of crossing the deck, and the lift — reading the
## growing penetration of a rider it could not lift clear — reversed halfway up.
##
## COVERAGE, measured by putting the 0.5 back: climbs_nothing_it_cannot_stand_on fails
## with the player 3.3 m up the ramp. The walkable case is the control, and it is the
## reason the fix is a threshold rather than a ban on stepping onto slopes at all.

const Movement = preload("res://addons/pmove/movement.gd")
const InputCommand = preload("res://addons/pmove/input_command.gd")
const MovementConfig = preload("res://addons/pmove/movement_config.gd")

const TICKS := 90
const ROPE_NORMAL_Y := 0.51   # ww_2fort's lift ropes
const RAMP_NORMAL_Y := 0.80   # a plain walkable ramp, ~37 degrees


## Flat ground out to +/-10 m, with a slab pitched so its top face normal is `normal_y`
## and its surface passes through the origin, rising toward +x.
func _world(normal_y: float) -> void:
	var ground := StaticBody3D.new()
	var gs := CollisionShape3D.new()
	var gbox := BoxShape3D.new()
	gbox.size = Vector3(20, 1, 20)
	gs.shape = gbox
	gs.position = Vector3(0, -0.5, 0)
	ground.add_child(gs)
	_root().add_child(ground)
	_spawned.append(ground)

	var t := acos(normal_y)
	var ramp := StaticBody3D.new()
	var rs := CollisionShape3D.new()
	var rbox := BoxShape3D.new()
	rbox.size = Vector3(8, 1, 8)
	rs.shape = rbox
	ramp.add_child(rs)
	ramp.rotation = Vector3(0, 0, t)     # +Y face normal becomes (-sin t, cos t, 0)
	ramp.position = Vector3(-sin(t), cos(t), 0) * -0.5
	_root().add_child(ramp)
	_spawned.append(ramp)


## Walks a player-shaped CharacterBody3D at the slope for TICKS ticks; returns the HIGHEST it got.
## Not its final height: the ramp is only about four metres of run and the player covers twelve in
## TICKS, so it crests the slope, runs off the far end and is standing back on the flat ground by
## the last tick. Sampling the end reads ~0 for a ramp the player climbed perfectly well.
func _walk_into_it() -> float:
	var player := CharacterBody3D.new()
	player.safe_margin = 0.01
	player.floor_block_on_wall = false
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.8
	cs.shape = cap
	cs.position = Vector3(0, 0.9, 0)
	player.add_child(cs)
	_root().add_child(player)
	_spawned.append(player)
	player.global_position = Vector3(-3.0, 0.02, 0)

	var tree := Engine.get_main_loop() as SceneTree
	await tree.physics_frame

	var sim := Movement.Simulation.new(MovementConfig.new())
	var body := GodotBody.new(player)
	var state := Movement.MovementState.new()
	state.bind_body(body)
	state.on_floor = true
	var peak := -INF
	for i in TICKS:
		var cmd := InputCommand.new()
		cmd.seq = i
		cmd.delta = 1.0 / 60.0
		cmd.move_input = Vector2(0, 1)
		cmd.yaw = PI * 0.5           # forward is +x, into the slope
		sim.simulate_tick(body, state, cmd)
		await tree.physics_frame
		peak = maxf(peak, player.global_position.y)
	return peak


func _cleanup() -> void:
	for n in _spawned:
		if is_instance_valid(n):
			n.free()
	_spawned.clear()


func test_climbs_nothing_it_cannot_stand_on() -> void:
	_world(ROPE_NORMAL_Y)
	var y: float = await _walk_into_it()
	# Walking into a steep face rides up a little (~0.4 m at the high-water mark) and slides back,
	# which is the slide path doing its job. A climb is metres, not half a hull.
	assert_lt(y, 0.5, "a %.1f deg slope is not stairs — the player must not be stepped up it"
		% rad_to_deg(acos(ROPE_NORMAL_Y)))
	_cleanup()


func test_still_walks_up_a_walkable_ramp() -> void:
	_world(RAMP_NORMAL_Y)
	var y: float = await _walk_into_it()
	assert_gt(y, 1.0, "a %.1f deg ramp is walkable and the player should be well up it"
		% rad_to_deg(acos(RAMP_NORMAL_Y)))
	_cleanup()
