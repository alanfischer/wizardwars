extends "res://src/tests/test_base.gd"
## Tests for the bot's projectile lead: BotBrain._track_target (measuring a target's motion) and
## _lead_point (solving where to aim so the shot meets it). Pure arithmetic on the brain, so it
## runs against a stub body rather than a live match.

const BotBrain = preload("res://src/bot/bot_brain.gd")

## What _lead_point needs of a bot: a position, and a get_server_movement() for the eye height.
## Null movement is the same answer a bot gives before its first tick — EYE_HEIGHT.
class StubBody extends CharacterBody3D:
	func get_server_movement():
		return null


var _brain: BotBrain
var _body: StubBody


func _fresh(vel := Vector3.ZERO, frac := 1.0) -> void:
	_brain = BotBrain.new()
	_body = StubBody.new()
	_root().add_child(_keep(_body))
	_body.global_position = Vector3.ZERO
	_brain._bot = _body
	_brain._lead_vel = vel
	_brain._lead_frac = frac


func test_hitscan_is_not_led() -> void:
	_fresh(Vector3(8.0, 0.0, 0.0))
	var tgt := Vector3(20.0, 0.0, 0.0)
	assert_vec3_almost_eq(_brain._lead_point(tgt, 0.0), tgt, 0.001,
			"a weapon with no flight speed must aim straight at the target")


func test_still_target_is_not_led() -> void:
	_fresh(Vector3.ZERO)
	var tgt := Vector3(0.0, 0.0, -20.0)
	assert_vec3_almost_eq(_brain._lead_point(tgt, 50.0), tgt, 0.001,
			"a target that isn't moving must not be led")


## The invariant that matters: the shot and the target reach the aim point at the same moment.
func test_lead_solves_the_intercept() -> void:
	var vel := Vector3(8.0, 0.0, 0.0)   # strafing across at sv_maxspeed
	var speed := 50.0                    # MagicMissile.MISSILE_SPEED
	_fresh(vel)
	var tgt := Vector3(0.0, 0.0, -20.0)
	var lead: Vector3 = _brain._lead_point(tgt, speed)
	var flight: float = _brain._eye().distance_to(lead) / speed
	assert_vec3_almost_eq(lead, tgt + vel * flight, 0.02,
			"aim point is not where the target will be when the shot arrives")
	assert_gt(lead.x, tgt.x, "lead must be on the side the target is moving toward")


func test_lead_frac_scales_it() -> void:
	var vel := Vector3(8.0, 0.0, 0.0)
	var tgt := Vector3(0.0, 0.0, -20.0)
	_fresh(vel, 1.0)
	var full: float = _brain._lead_point(tgt, 50.0).x - tgt.x
	_fresh(vel, 0.5)
	var half: float = _brain._lead_point(tgt, 50.0).x - tgt.x
	assert_gt(full, 0.1, "a crack shot leads a strafing target")
	assert_almost_eq(half / full, 0.5, 0.06, "half the skill should lead about half as far")
	_fresh(vel, 0.0)
	assert_vec3_almost_eq(_brain._lead_point(tgt, 50.0), tgt, 0.001,
			"no lead fraction must aim exactly where the target is")


func test_flight_time_is_capped() -> void:
	var vel := Vector3(8.0, 0.0, 0.0)
	_fresh(vel)
	# 200m away at 5 m/s is 40s of flight; uncapped that is 320m of lead, off the map.
	var lead: Vector3 = _brain._lead_point(Vector3(0.0, 0.0, -200.0), 5.0)
	assert_lt(lead.x, vel.x * BotBrain.LEAD_MAX_T + 0.001,
			"flight time past LEAD_MAX_T must not be led on")


func test_tracking_eases_toward_real_velocity() -> void:
	_fresh()
	var target := StubBody.new()
	_root().add_child(_keep(target))
	var delta := 1.0 / 60.0
	var vel := Vector3(6.0, 0.0, 0.0)
	target.global_position = Vector3.ZERO
	_brain._track_target(target, delta)
	assert_eq(_brain._lead_vel, Vector3.ZERO, "a first sighting has no measured velocity yet")
	for _i in 120:   # two seconds of steady strafing
		target.global_position += vel * delta
		_brain._track_target(target, delta)
	assert_vec3_almost_eq(_brain._lead_vel, vel, 0.05,
			"measured velocity did not converge on the target's real motion")
	# A new target starts from scratch rather than inheriting the last one's velocity.
	var other := StubBody.new()
	_root().add_child(_keep(other))
	_brain._track_target(other, delta)
	assert_eq(_brain._lead_vel, Vector3.ZERO, "velocity carried over to a different target")
	_brain._track_target(null, delta)
	assert_eq(_brain._lead_tgt, null, "losing the target must clear the tracking")


func test_teleport_is_not_motion() -> void:
	_fresh()
	var target := StubBody.new()
	_root().add_child(_keep(target))
	var delta := 1.0 / 60.0
	target.global_position = Vector3.ZERO
	_brain._track_target(target, delta)
	for _i in 60:
		target.global_position += Vector3(6.0, 0.0, 0.0) * delta
		_brain._track_target(target, delta)
	assert_gt(_brain._lead_vel.length(), 1.0, "should be tracking real motion by now")
	target.global_position += Vector3(0.0, 0.0, -60.0)   # respawn across the map in one tick
	_brain._track_target(target, delta)
	assert_eq(_brain._lead_vel, Vector3.ZERO, "a teleport must not be read as velocity")
