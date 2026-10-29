extends "res://src/tests/test_base.gd"
## Regression guard for _compute_mover_carry's FALLBACK path: movers with no MoverNetPublisher
## (no replicated mover_net_vel/angvel) carry by diffing two position samples, which mismatches client-predicted vs
## server carry every tick a mover is moving, since the client's local copy trails ~INTERP_DELAY
## behind the server's. Reproduced without a live client/server pair: two riders on identical
## elevators far enough apart their carry probes can't cross-detect, one seeing the live
## trajectory and the other seeing it delayed by DELAY_TICKS like an interpolated replica.

const Movement = preload("res://addons/pmove/movement.gd")
const MovementConfig = preload("res://addons/pmove/movement_config.gd")
const GodotBodyC = preload("res://addons/pmove/godot_body.gd")
const InputCommand = preload("res://addons/pmove/input_command.gd")

const TICK := 1.0 / 60.0
const DELAY_TICKS := 4       # ~66ms — a modest INTERP_DELAY; real jitter often runs higher
const RISE_TICKS := 60       # elevator rises for 1s
const RISE_SPEED := 2.0      # m/s
const SETTLE_TICKS := 12     # pre-rise ticks to let both riders settle onto their deck
const DRAIN_TICKS := 40      # post-stop ticks — comfortably more than DELAY_TICKS

var _cfg: MovementConfig


func _setup_test(_test_name: String) -> void:
	_cfg = MovementConfig.new()


func _make_elevator(x_offset: float) -> AnimatableBody3D:
	var body := AnimatableBody3D.new()
	# Movers must not sync_to_physics — direct global_position writes are how every mover in
	# this codebase (doors, plats, the golem body) drives its collision authoritatively.
	body.sync_to_physics = false
	body.collision_layer = GameConsts.MASK_ENTITY
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4, 0.2, 4)
	cs.shape = box
	body.add_child(cs)
	_root().add_child(body)
	body.global_position = Vector3(x_offset, 0.0, 0.0)
	return body


func _make_rider(pos: Vector3) -> CharacterBody3D:
	var p := _pmove_body(_cfg.stand_height)
	# Real players collide with MASK_ENTITY (see RemotePlayer.setup_server_movement); the
	# CharacterBody3D default (layer 1 only) would let the rider fall straight through an
	# elevator on MASK_ENTITY even though the separate carry-probe sphere query still saw it.
	p.collision_mask = GameConsts.MASK_ENTITY
	_root().add_child(p)
	p.global_position = pos
	return p


func _bind(player: CharacterBody3D) -> Array:
	var state := Movement.MovementState.new()
	var body = GodotBodyC.new(player)
	state.bind_body(body)
	state.on_floor = true
	return [body, state]


func _idle_cmd(seq: int) -> InputCommand:
	var c := InputCommand.new()
	c.seq = seq
	c.delta = TICK
	c.move_input = Vector2.ZERO
	return c


func _step(sim: Movement.Simulation, ctx: PlayerMovementContext, bound: Array, cmd: InputCommand) -> void:
	var mods := ctx.get_modifiers(_cfg, bound[1], [], 1.0, cmd)
	mods.apply_to(bound[1])
	sim.simulate_tick(bound[0], bound[1], cmd)


func test_carry_prediction_diverges_from_server_while_mover_moves() -> void:
	var sim := Movement.Simulation.new(_cfg)

	# "Server": true elevator + rider, always reading the elevator's live position.
	var server_elevator := _make_elevator(0.0)
	var server_rider := _make_rider(Vector3(0, 0.1, 0))
	var server_ctx := PlayerMovementContext.new(server_rider, null, null)
	var server_bound := _bind(server_rider)

	# "Client": identical elevator + rider, but this elevator's LOCAL copy shows the
	# trajectory DELAY_TICKS late, like a network-interpolated replica.
	var client_elevator := _make_elevator(1000.0)
	var client_rider := _make_rider(Vector3(1000, 0.1, 0))
	var client_ctx := PlayerMovementContext.new(client_rider, null, null)
	var client_bound := _bind(client_rider)

	await _settle()

	var true_heights: Array[float] = []
	var seq := 0
	var moving_ticks := 0
	var diverged_ticks := 0
	var max_divergence := 0.0
	const DIVERGE_EPSILON := 0.005  # 5mm — below this counts as "in sync" for a tick

	# Let both riders settle onto their (stationary) deck before the ride starts.
	for i in SETTLE_TICKS:
		seq += 1
		true_heights.append(0.0)
		server_elevator.global_position.y = 0.0
		client_elevator.global_position.y = 0.0
		_step(sim, server_ctx, server_bound, _idle_cmd(seq))
		_step(sim, client_ctx, client_bound, _idle_cmd(seq))
		await _physics_frame()

	for i in RISE_TICKS:
		seq += 1
		var true_y: float = RISE_SPEED * TICK * (i + 1)
		true_heights.append(true_y)
		server_elevator.global_position.y = true_y
		client_elevator.global_position.y = true_heights[true_heights.size() - 1 - DELAY_TICKS] \
			if true_heights.size() - 1 - DELAY_TICKS >= 0 else 0.0
		_step(sim, server_ctx, server_bound, _idle_cmd(seq))
		_step(sim, client_ctx, client_bound, _idle_cmd(seq))
		await _physics_frame()

		moving_ticks += 1
		var divergence := absf(server_rider.global_position.y - client_rider.global_position.y)
		max_divergence = maxf(max_divergence, divergence)
		if divergence > DIVERGE_EPSILON:
			diverged_ticks += 1

	assert_gt(max_divergence, 0.03,
		"client-side carry prediction should measurably diverge from the server's while the elevator climbs (got max %.4f m)" % max_divergence)
	assert_gt(diverged_ticks, int(moving_ticks * 0.8),
		"the mismatch should show up on most ticks of the climb, not just at start/stop (got %d/%d ticks > %.0fmm)"
			% [diverged_ticks, moving_ticks, DIVERGE_EPSILON * 1000.0])

	# Hold the elevator still and let the client's delayed feed drain: it should self-heal
	# once motion stops (the mismatch above is a lag, not a lost distance).
	var held_y: float = true_heights[true_heights.size() - 1]
	for i in DRAIN_TICKS:
		seq += 1
		true_heights.append(held_y)
		server_elevator.global_position.y = held_y
		client_elevator.global_position.y = true_heights[true_heights.size() - 1 - DELAY_TICKS]
		_step(sim, server_ctx, server_bound, _idle_cmd(seq))
		_step(sim, client_ctx, client_bound, _idle_cmd(seq))
		await _physics_frame()

	var final_divergence := absf(server_rider.global_position.y - client_rider.global_position.y)
	assert_lt(final_divergence, DIVERGE_EPSILON,
		"once the elevator has been stopped longer than the delay, prediction should re-converge (got %.4f m)" % final_divergence)

	server_elevator.queue_free()
	server_rider.queue_free()
	client_elevator.queue_free()
	client_rider.queue_free()
