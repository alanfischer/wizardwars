extends "res://src/tests/test_base.gd"
## PlayerMovementContext.mover_obstruction — the number a brush mover reads to decide it is
## Blocked (FuncDoorBase._physics_process). Resting on a mover must stay inside safe_margin;
## being crushed by one must GROW, via the support contact the pusher filters out; and
## "never touched" (0.0) must stay distinguishable from "no measurement" (-1.0).
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.

const Movement = preload("res://addons/pmove/movement.gd")
const MovementConfig = preload("res://addons/pmove/movement_config.gd")
const GodotBodyC = preload("res://addons/pmove/godot_body.gd")
const InputCommand = preload("res://addons/pmove/input_command.gd")

const TICK := 1.0 / 60.0
const SETTLE_TICKS := 12
const RISE_SPEED := 3.0  # m/s — a stock plat, fast enough that a pinch deepens visibly

var _cfg: MovementConfig
var _seq := 0


func _setup_test(_test_name: String) -> void:
	_cfg = MovementConfig.new()
	_seq = 0


func _teardown_test() -> void:
	_despawn_all()


func _make_deck(pos: Vector3) -> AnimatableBody3D:
	var body := AnimatableBody3D.new()
	body.sync_to_physics = false  # it would swallow the direct global_position writes below
	body.collision_layer = GameConsts.MASK_ENTITY
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4, 0.2, 4)
	cs.shape = box
	body.add_child(cs)
	_root().add_child(body)
	_spawned.append(body)
	body.global_position = pos
	return body


func _make_ceiling(pos: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = GameConsts.MASK_ENTITY  # the rider's only mask, below
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4, 0.4, 4)
	cs.shape = box
	body.add_child(cs)
	_root().add_child(body)
	_spawned.append(body)
	body.global_position = pos
	return body


func _make_rider(pos: Vector3) -> CharacterBody3D:
	var p := _pmove_body(_cfg.stand_height)
	p.collision_mask = GameConsts.MASK_ENTITY
	_root().add_child(p)
	_spawned.append(p)
	p.global_position = pos
	return p


func _bind(player: CharacterBody3D) -> Array:
	var state := Movement.MovementState.new()
	var body = GodotBodyC.new(player)
	state.bind_body(body)
	state.on_floor = true
	return [body, state]


## One netmove tick, then a physics frame. Distinct from the base _tick, which only waits:
## this one drives the simulation.
func _sim_tick(sim: Movement.Simulation, ctx: PlayerMovementContext, bound: Array) -> void:
	_seq += 1
	var cmd := InputCommand.new()
	cmd.seq = _seq
	cmd.delta = TICK
	cmd.move_input = Vector2.ZERO
	var mods := ctx.get_modifiers(_cfg, bound[1], [], 1.0, cmd)
	mods.apply_to(bound[1])
	sim.simulate_tick(bound[0], bound[1], cmd)
	await (Engine.get_main_loop() as SceneTree).physics_frame


func test_a_rider_at_rest_reports_depth_inside_its_own_margin() -> void:
	var sim := Movement.Simulation.new(_cfg)
	var deck := _make_deck(Vector3.ZERO)
	var rider := _make_rider(Vector3(0, 0.2, 0))
	var ctx := PlayerMovementContext.new(rider, null, null)
	var bound := _bind(rider)
	for _i in SETTLE_TICKS:
		await _sim_tick(sim, ctx, bound)

	var depth := ctx.mover_obstruction(deck)
	assert_gt(depth, -0.0001, "a mover the hull touches reports a real depth, never -1.0")
	assert_lt(depth, rider.safe_margin * 2.0,
		"standing on a still deck is resting contact — below the slop a mover treats as free (got %.4f m)" % depth)


func test_a_rider_crushed_into_a_ceiling_reports_growing_depth() -> void:
	var sim := Movement.Simulation.new(_cfg)
	var deck := _make_deck(Vector3.ZERO)
	# Head height plus a little: a few free ticks of ride before the pinch.
	_make_ceiling(Vector3(0, _cfg.stand_height + 0.5, 0))
	var rider := _make_rider(Vector3(0, 0.2, 0))
	var ctx := PlayerMovementContext.new(rider, null, null)
	var bound := _bind(rider)
	for _i in SETTLE_TICKS:
		await _sim_tick(sim, ctx, bound)

	var settled := ctx.mover_obstruction(deck)
	var depths: Array[float] = []
	for _i in 40:
		deck.global_position.y += RISE_SPEED * TICK
		await _sim_tick(sim, ctx, bound)
		depths.append(ctx.mover_obstruction(deck))

	var deepest: float = depths.max()
	assert_gt(deepest, rider.safe_margin * 2.0,
		"a rider with nowhere left to go gets deeper into the deck every tick (settled %.4f m, deepest %.4f m)"
			% [settled, deepest])
	# That depth rides a support normal, the one the pusher filters out: move recording back
	# behind that filter and this drops to 0.
	var growing := 0
	for i in range(1, depths.size()):
		if depths[i] > depths[i - 1] + 0.002:
			growing += 1
	assert_gt(growing, 3,
		"and does so on consecutive ticks, which is the signal a mover reads as Blocked (got %d ticks)" % growing)


func test_an_untouched_mover_reads_zero_and_a_stale_sample_reads_unknown() -> void:
	var sim := Movement.Simulation.new(_cfg)
	var deck := _make_deck(Vector3.ZERO)
	var elsewhere := _make_deck(Vector3(500, 0, 0))
	var rider := _make_rider(Vector3(0, 0.2, 0))
	var ctx := PlayerMovementContext.new(rider, null, null)
	var bound := _bind(rider)
	for _i in SETTLE_TICKS:
		await _sim_tick(sim, ctx, bound)

	assert_eq(ctx.mover_obstruction(elsewhere), 0.0,
		"a mover the hull never touched is free, not unmeasured")
	assert_eq(ctx.mover_obstruction(null), -1.0, "and nothing at all is unmeasured")
	assert_gt(ctx.mover_obstruction(deck), -0.0001, "the deck underfoot still measures")

	# Two physics frames with no movement tick: the sample is now too old to compare against.
	await (Engine.get_main_loop() as SceneTree).physics_frame
	await (Engine.get_main_loop() as SceneTree).physics_frame
	assert_eq(ctx.mover_obstruction(deck), -1.0,
		"a player that ran no tick reports unknown, so a mover holds its decision instead of resuming")
