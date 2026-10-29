extends "res://src/tests/test_base.gd"
## HomingBehavior is the shared search-and-chase core the skull and bird fly on: turn rate is
## capped, a lock is kept until the target dies, and searching is throttled to think_interval.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.

const ProjectileScript = preload("res://src/projectiles/projectile.gd")

const HOST_POS := Vector3(0.0, 80.0, 0.0)  # clear of map geometry, so LOS rays hit nothing


## Minimal damageable stand-in: what find_homing_target scans the "damageable" group for.
class DummyTarget extends CharacterBody3D:
	var is_dead := false
	var team := 99  # teams_friendly(1, 99) is false — a valid enemy


func _host() -> Projectile:
	var p: Projectile = ProjectileScript.new()
	p.name = "HomingHost"
	_root().add_child(p)
	p.global_position = HOST_POS
	_spawned.append(p)
	return p


## Offset from HOST_POS, because every case here is about where the missile turns relative to
## the wizard that fired it.
func _target_at(offset: Vector3) -> DummyTarget:
	return _damageable_at(DummyTarget, HOST_POS + offset, 0.5) as DummyTarget


## A behavior wired to a host, with an acquire counter for the tests to read.
class Acquires extends RefCounted:
	var count := 0
	func on_acquire() -> void:
		count += 1


func _homing(host: Projectile, turn_speed := 90.0, think := 0.1) -> Array:
	var acq := Acquires.new()
	var h := HomingBehavior.new()
	h.initialize(host, 1, acq.on_acquire)
	h.search_radius = 20.0
	h.turn_speed = turn_speed
	h.think_interval = think
	return [h, acq]


func test_acquires_an_enemy_in_range_and_reports_the_lock() -> void:
	var host := _host()
	var enemy := _target_at(Vector3(0, 0, -5))
	var pair := _homing(host)
	var h: HomingBehavior = pair[0]
	var acq: Acquires = pair[1]

	assert_eq(h.target, null, "starts unlocked")
	h.steer(Vector3.FORWARD, 0.2)  # delta > think_interval: searches on the first tick
	assert_eq(h.target, enemy, "locks the enemy in range")
	assert_eq(acq.count, 1, "and reports the lock exactly once")


func test_a_fresh_lock_does_not_steer_on_the_tick_it_acquires() -> void:
	# The pre-extraction code searched in an `elif`, so acquiring and steering never
	# happened on the same tick. Projectiles fly straight through the acquiring frame.
	var host := _host()
	_target_at(Vector3(5, 0, 0))
	var h: HomingBehavior = _homing(host)[0]

	var dir := h.steer(Vector3.FORWARD, 0.2)
	assert_vec3_almost_eq(dir, Vector3.FORWARD, 0.0001, "direction is untouched while acquiring")
	assert_ne(h.target, null, "even though the lock landed")


func test_turn_rate_is_capped_by_turn_speed() -> void:
	# Target at 90° to the right; one 0.1 s tick at 90 deg/s may turn at most 9°.
	var host := _host()
	_target_at(Vector3(5, 0, 0))
	var h: HomingBehavior = _homing(host, 90.0)[0]
	h.steer(Vector3.FORWARD, 0.2)  # acquire

	var dir := h.steer(Vector3.FORWARD, 0.1)
	var turned := rad_to_deg(Vector3.FORWARD.angle_to(dir))
	assert_almost_eq(turned, 9.0, 0.01, "turns exactly its 9° budget, not straight at the target")
	assert_almost_eq(dir.length(), 1.0, 0.0001, "and stays normalized")


func test_a_faster_turn_speed_closes_the_angle_faster() -> void:
	var host_slow := _host()
	_target_at(Vector3(5, 0, 0))
	var slow: HomingBehavior = _homing(host_slow, 90.0)[0]
	var fast: HomingBehavior = _homing(host_slow, 360.0)[0]
	slow.steer(Vector3.FORWARD, 0.2)
	fast.steer(Vector3.FORWARD, 0.2)

	var slow_dir := slow.steer(Vector3.FORWARD, 0.1)
	var fast_dir := fast.steer(Vector3.FORWARD, 0.1)
	assert_gt(Vector3.FORWARD.angle_to(fast_dir), Vector3.FORWARD.angle_to(slow_dir),
		"the skull's 360 deg/s out-turns the bird's 150")


func test_steering_converges_on_the_target() -> void:
	var host := _host()
	_target_at(Vector3(5, 0, 0))
	var h: HomingBehavior = _homing(host, 90.0)[0]
	h.steer(Vector3.FORWARD, 0.2)

	var dir := Vector3.FORWARD
	var to_target := Vector3.RIGHT
	var prev := dir.angle_to(to_target)
	for i in 20:
		dir = h.steer(dir, 0.1)
		var angle := dir.angle_to(to_target)
		assert_lt(angle, prev + 0.0001, "tick %d closes the angle" % i)
		prev = angle
	assert_lt(prev, 0.0001, "and ends up pointing at the target")


func test_an_exactly_aligned_target_snaps_instead_of_dividing_by_zero() -> void:
	var host := _host()
	_target_at(Vector3(0, 0, -5))
	var h: HomingBehavior = _homing(host)[0]
	h.steer(Vector3.FORWARD, 0.2)

	var dir := h.steer(Vector3.FORWARD, 0.1)
	assert_vec3_almost_eq(dir, Vector3.FORWARD, 0.0001,
		"already-on-target is the max_turn/angle divide-by-zero case; it takes the snap branch")


func test_the_lock_is_kept_while_the_target_lives() -> void:
	# No mid-flight target switching: a closer enemy appearing later must not steal the lock.
	var host := _host()
	var first := _target_at(Vector3(0, 0, -10))
	var pair := _homing(host)
	var h: HomingBehavior = pair[0]
	var acq: Acquires = pair[1]
	h.steer(Vector3.FORWARD, 0.2)
	assert_eq(h.target, first, "locked the only enemy")

	_target_at(Vector3(0, 0, -2))  # much closer
	for i in 10:
		h.steer(Vector3.FORWARD, 0.2)
	assert_eq(h.target, first, "keeps chasing the original despite a nearer enemy")
	assert_eq(acq.count, 1, "and never re-reports a lock it already had")


func test_a_dead_target_releases_the_lock_and_a_new_one_is_found() -> void:
	var host := _host()
	var first := _target_at(Vector3(0, 0, -4))
	var second := _target_at(Vector3(9, 0, 0))
	var pair := _homing(host)
	var h: HomingBehavior = pair[0]
	var acq: Acquires = pair[1]
	h.steer(Vector3.FORWARD, 0.2)
	assert_eq(h.target, first, "locked the nearer enemy first")

	first.is_dead = true
	h.steer(Vector3.FORWARD, 0.2)
	assert_eq(h.target, second, "drops the dead one and re-acquires")
	assert_eq(acq.count, 2, "the second lock is reported too — projectiles re-extend their life")


func test_a_freed_target_releases_the_lock_without_crashing() -> void:
	var host := _host()
	var first := _target_at(Vector3(0, 0, -10))
	var h: HomingBehavior = _homing(host)[0]
	h.steer(Vector3.FORWARD, 0.2)
	assert_eq(h.target, first, "locked")

	_spawned.erase(first)
	first.free()
	var dir := h.steer(Vector3.FORWARD, 0.2)
	assert_eq(h.target, null, "a freed target clears the lock instead of dangling")
	assert_vec3_almost_eq(dir, Vector3.FORWARD, 0.0001, "and flies straight with nothing to chase")


func test_searching_is_throttled_to_think_interval() -> void:
	# Searching is a group walk plus an LOS ray per candidate — it must not run every tick.
	var host := _host()
	var h: HomingBehavior = _homing(host, 90.0, 0.5)[0]
	h.steer(Vector3.FORWARD, 0.1)  # first tick: timer 0.0 -> searches, finds nothing, arms 0.5

	var enemy := _target_at(Vector3(0, 0, -5))
	h.steer(Vector3.FORWARD, 0.1)
	assert_eq(h.target, null, "the enemy that appeared mid-interval is not seen yet")
	h.steer(Vector3.FORWARD, 0.4)  # 0.5 s since the interval was armed: think tick due
	assert_eq(h.target, enemy, "and is picked up on the next think tick")


func test_a_friendly_is_never_acquired() -> void:
	var host := _host()
	var friend := _target_at(Vector3(0, 0, -5))
	friend.team = 1  # same team as the behavior
	var h: HomingBehavior = _homing(host)[0]

	for i in 5:
		h.steer(Vector3.FORWARD, 0.2)
	assert_eq(h.target, null, "homing never locks onto its own team")


func test_a_target_beyond_search_radius_is_ignored() -> void:
	var host := _host()
	_target_at(Vector3(0, 0, -50))  # search_radius is 20
	var h: HomingBehavior = _homing(host)[0]

	h.steer(Vector3.FORWARD, 0.2)
	assert_eq(h.target, null, "out of range stays out of range")
