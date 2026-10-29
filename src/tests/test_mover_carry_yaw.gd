extends "res://src/tests/test_base.gd"
## The yaw a rider's VIEW rides must come from the mover's measured rotation, never from the
## angular rate it publishes.
##
## mover_net_angvel is measured on the wall clock (MoverNetPublisher.publish divides a
## Time.get_ticks_msec difference) and spent on the simulation clock (angvel * delta), so any
## frame whose real length misses the nominal tick scales the ride. The linear carry survives
## that because it is corrected toward the measured delta every tick; the view ride has no such
## correction, so its error is a heading random walk a rider can never shed — and a rider whose
## heading has drifted off the golem walks diagonally into the cockpit wall and slides along it
## until they reach the rear shaft and leave. Measured on ww_golem (tools/probe_golem_real.gd,
## TURN=1 FOLLOW=1): the published rate over-rode the ride by 19%, and the rider left at tick 96
## against 278 on the measured pair.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.

const Movement = preload("res://addons/pmove/movement.gd")
const MovementConfig = preload("res://addons/pmove/movement_config.gd")
const GodotBodyC = preload("res://addons/pmove/godot_body.gd")
const InputCommand = preload("res://addons/pmove/input_command.gd")

const TICK := 1.0 / 60.0
const SETTLE_TICKS := 12
const RIDE_TICKS := 60
const SPIN_STEP := deg_to_rad(0.5)  # 30 deg/s, a touch above the golem's own 20
const RIDER_OFFSET := 2.0           # m off the axis, so the rider's own point really moves
const TOLERANCE := deg_to_rad(0.01)

## A turntable that publishes a transform the way every brush entity in game does.
class Turntable extends AnimatableBody3D:
	var net: MoverNetPublisher = null

var _cfg: MovementConfig
var _seq := 0


func _setup_test(_test_name: String) -> void:
	_cfg = MovementConfig.new()
	_seq = 0


func _teardown_test() -> void:
	_despawn_all()


func _make_turntable() -> Turntable:
	var body := Turntable.new()
	body.sync_to_physics = false  # it would swallow the direct rotation writes below
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
	body.global_position = Vector3.ZERO
	return body


func _make_rider() -> CharacterBody3D:
	var p := _pmove_body(_cfg.stand_height)
	p.collision_mask = GameConsts.MASK_ENTITY
	_root().add_child(p)
	_spawned.append(p)
	p.global_position = Vector3(RIDER_OFFSET, 0.2, 0.0)
	return p


func _bind(player: CharacterBody3D) -> Array:
	var state := Movement.MovementState.new()
	var body = GodotBodyC.new(player)
	state.bind_body(body)
	state.on_floor = true
	return [body, state]


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


## Spin the turntable one step and publish `rate_scale` times the rate it really turned at —
## 1.0 is a frame that took exactly its nominal length, anything else is the clock mismatch.
func _spin(deck: Turntable, rate_scale: float) -> void:
	deck.rotation.y += SPIN_STEP
	deck.net.mover_net_angvel = Vector3(0.0, SPIN_STEP / TICK * rate_scale, 0.0)
	deck.force_update_transform()


## Settle the rider onto the deck, then ride `RIDE_TICKS` of spin and report the total yaw the
## carry offered against the total the deck turned through.
func _ride(rate_scale: float) -> Array:
	var sim := Movement.Simulation.new(_cfg)
	var deck := _make_turntable()
	var rider := _make_rider()
	var ctx := PlayerMovementContext.new(rider, null, null)
	var bound := _bind(rider)
	for _i in SETTLE_TICKS:
		await _sim_tick(sim, ctx, bound)
	var rode := 0.0
	var turned := 0.0
	for _i in RIDE_TICKS:
		var before: float = deck.rotation.y
		_spin(deck, rate_scale)
		await _sim_tick(sim, ctx, bound)
		turned += wrapf(deck.rotation.y - before, -PI, PI)
		rode += ctx.get_carry_yaw_delta()
	return [rode, turned]


func test_the_ride_is_the_measured_rotation_not_the_published_rate() -> void:
	# A rate 50% too fast, which is what a frame half again longer than the tick publishes.
	var r := await _ride(1.5)
	assert_almost_eq(r[0], r[1], TOLERANCE,
		"rode %.3f deg over %d ticks, deck turned %.3f" % [
			rad_to_deg(r[0]), RIDE_TICKS, rad_to_deg(r[1])])


func test_a_mover_that_publishes_no_rate_still_turns_its_rider() -> void:
	# A golem part: its publisher is suppressed (a parent contraption drives it), so every
	# rate it holds stays zero while it really rotates.
	var r := await _ride(0.0)
	assert_almost_eq(r[0], r[1], TOLERANCE,
		"rode %.3f deg over %d ticks, deck turned %.3f" % [
			rad_to_deg(r[0]), RIDE_TICKS, rad_to_deg(r[1])])
