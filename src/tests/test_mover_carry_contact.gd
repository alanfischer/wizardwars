extends "res://src/tests/test_base.gd"
## The ride's CONTACT test — which mover is underfoot — must not miss a tick while a deck
## bobs. A player standing on a deck that drops faster than gravity is briefly airborne by
## more than the hull's safe_margin, so any probe that only sees resting contact reads "no
## mover" and drops that tick's horizontal carry entirely. There is nothing to give it back
## (the velocity path's correction is bounded per tick and measures from a baseline that
## refreshes with or without contact), so every missed tick is permanent slip — the golem
## failure mode where riders walk out from under themselves.
##
## Guards _compute_mover_carry against being fed contact from a source that only reports
## resting contact.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.

const Movement = preload("res://addons/pmove/movement.gd")
const MovementConfig = preload("res://addons/pmove/movement_config.gd")
const GodotBodyC = preload("res://addons/pmove/godot_body.gd")
const InputCommand = preload("res://addons/pmove/input_command.gd")

const TICK := 1.0 / 60.0
const SETTLE_TICKS := 12
const RIDE_TICKS := 120
const DRIFT_SPEED := 2.0   # m/s sideways — a golem's stride, not a slow lift
const BOB_AMPLITUDE := 0.1 # m
const BOB_HZ := 2.5        # a peak drop of ~26mm/tick, well past the 10mm safe_margin
const MAX_SLIP := 0.1      # m — a single lost tick of carry is 33mm, so this catches ~3

## A mover that publishes the replicated velocity fields the carry prefers (mover_net_vel),
## like every brush entity that actually moves in game. The carry reads them off the MoverNet
## child, so the stub carries one too (added in _make_deck).
class Deck extends AnimatableBody3D:
	var net: MoverNetPublisher = null

var _cfg: MovementConfig
var _seq := 0


func _setup_test(_test_name: String) -> void:
	_cfg = MovementConfig.new()
	_seq = 0


func _teardown_test() -> void:
	_despawn_all()


func _make_deck(pos: Vector3) -> Deck:
	var body := Deck.new()
	body.sync_to_physics = false  # it would swallow the direct global_position writes below
	body.collision_layer = GameConsts.MASK_ENTITY
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(8, 0.2, 8)
	cs.shape = box
	body.add_child(cs)
	body.net = MoverNetPublisher.new()
	body.net.name = MoverNetPublisher.NODE_NAME
	body.add_child(body.net)
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


## Move the deck to `pos` and publish the velocity it just travelled at, the way a
## replicated mover does.
func _drive(deck: Deck, pos: Vector3) -> void:
	deck.net.mover_net_vel = (pos - deck.global_position) / TICK
	deck.global_position = pos


func test_a_rider_on_a_bobbing_deck_keeps_every_tick_of_carry() -> void:
	var sim := Movement.Simulation.new(_cfg)
	var deck := _make_deck(Vector3.ZERO)
	var rider := _make_rider(Vector3(0, 0.2, 0))
	var ctx := PlayerMovementContext.new(rider, null, null)
	var bound := _bind(rider)
	for _i in SETTLE_TICKS:
		await _sim_tick(sim, ctx, bound)

	var settled_offset: float = rider.global_position.x - deck.global_position.x
	var worst_slip := 0.0
	var airborne_ticks := 0
	for i in RIDE_TICKS:
		var t: float = (i + 1) * TICK
		var next := Vector3(DRIFT_SPEED * t, BOB_AMPLITUDE * sin(TAU * BOB_HZ * t), 0.0)
		# How far the deck's top drops below the rider's feet this tick: past safe_margin
		# is a tick a resting-contact probe cannot see.
		if deck.global_position.y - next.y > rider.safe_margin:
			airborne_ticks += 1
		_drive(deck, next)
		await _sim_tick(sim, ctx, bound)
		var slip: float = absf((rider.global_position.x - deck.global_position.x) - settled_offset)
		worst_slip = maxf(worst_slip, slip)

	assert_gt(airborne_ticks, 20,
		"the bob must actually break resting contact, or this proves nothing (got %d/%d ticks)"
			% [airborne_ticks, RIDE_TICKS])
	assert_lt(worst_slip, MAX_SLIP,
		"a rider holds their place on the deck through the bob (drifted %.3f m; one lost tick is %.3f m)"
			% [worst_slip, DRIFT_SPEED * TICK])
	assert_true(bound[1].on_floor, "and is still standing on it at the end of the ride")
