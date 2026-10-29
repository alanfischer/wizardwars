extends "res://src/tests/test_base.gd"
## Projectile._trace_step is the swept-move core all seven flying projectiles share
## (fireball, magic missile, ice shard, spore, dragon fire, skull, bird). It sweeps one
## tick of motion against world geometry, reports the hit, and leaves the segment
## travelled in _step_from/_step_to for the caller's proximity check and final move.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.

const ProjectileScript = preload("res://src/projectiles/projectile.gd")

const ORIGIN := Vector3(0.0, 90.0, 0.0)  # clear of map geometry


func _projectile(dir: Vector3, speed: float) -> Projectile:
	var p: Projectile = ProjectileScript.new()
	p.name = "TraceProbe"
	_root().add_child(p)
	p.global_position = ORIGIN
	p.direction = dir.normalized()
	p.speed = speed
	_spawned.append(p)
	return p


func _wall(pos: Vector3) -> StaticBody3D:
	var wall := StaticBody3D.new()
	wall.collision_layer = GameConsts.MASK_WORLD
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4, 4, 0.5)
	cs.shape = box
	wall.add_child(cs)
	_root().add_child(wall)
	wall.global_position = pos
	_spawned.append(wall)
	return wall


func test_a_clear_path_reports_no_hit_and_spans_one_tick_of_motion() -> void:
	var p := _projectile(Vector3.FORWARD, 10.0)
	await _settle()

	var hit := p._trace_step(0.1)
	assert_true(hit.is_empty(), "nothing in the way")
	assert_vec3_almost_eq(p._step_from, ORIGIN, 0.0001, "the segment starts where the projectile is")
	assert_vec3_almost_eq(p._step_to, ORIGIN + Vector3(0, 0, -1.0), 0.0001,
		"and ends one tick of travel further on (10 m/s over 0.1 s)")


func test_the_trace_does_not_move_the_projectile_itself() -> void:
	# Callers finish the move with `global_position = _step_to` — but only after their
	# own hit checks have had a chance to redirect it.
	var p := _projectile(Vector3.FORWARD, 10.0)
	await _settle()

	p._trace_step(0.1)
	assert_vec3_almost_eq(p.global_position, ORIGIN, 0.0001, "still at the start of the tick")


func test_a_wall_in_the_path_is_reported_with_its_impact_point() -> void:
	var p := _projectile(Vector3.FORWARD, 10.0)
	_wall(ORIGIN + Vector3(0, 0, -0.5))
	await _settle()

	var hit := p._trace_step(0.1)
	assert_false(hit.is_empty(), "the wall is struck")
	var impact: Vector3 = hit.position
	assert_lt(impact.distance_to(ORIGIN), 1.0, "impact lands between the start and the far end")
	assert_gt(impact.z, p._step_to.z, "and short of where an unobstructed tick would have ended")


func test_a_wall_beyond_this_tick_is_not_struck_yet() -> void:
	var p := _projectile(Vector3.FORWARD, 10.0)
	_wall(ORIGIN + Vector3(0, 0, -5.0))  # 5 m out, tick covers 1 m
	await _settle()

	assert_true(p._trace_step(0.1).is_empty(), "out of reach this tick")


func test_exclude_rid_keeps_a_projectile_from_striking_its_own_shooter() -> void:
	var p := _projectile(Vector3.FORWARD, 10.0)
	var shooter := _wall(ORIGIN + Vector3(0, 0, -0.5))
	await _settle()

	assert_false(p._trace_step(0.1).is_empty(), "struck while unexcluded")
	p.exclude_rid = shooter.get_rid()
	assert_true(p._trace_step(0.1).is_empty(), "excluded body is passed straight through")


func test_a_stationary_projectile_traces_a_degenerate_segment() -> void:
	var p := _projectile(Vector3.FORWARD, 0.0)
	await _settle()

	assert_true(p._trace_step(0.1).is_empty(), "no motion, nothing to hit")
	assert_vec3_almost_eq(p._step_to, p._step_from, 0.0001, "and the segment has no length")


func test_the_segment_follows_the_projectile_as_it_travels() -> void:
	# Homing projectiles rewrite `direction` every tick before tracing; each trace has to
	# start from where the projectile actually is now, not where it spawned.
	var p := _projectile(Vector3.FORWARD, 10.0)
	await _settle()

	p._trace_step(0.1)
	p.global_position = p._step_to
	p.direction = Vector3.RIGHT
	p._trace_step(0.1)

	assert_vec3_almost_eq(p._step_from, ORIGIN + Vector3(0, 0, -1.0), 0.0001,
		"second tick starts where the first one ended")
	assert_vec3_almost_eq(p._step_to, ORIGIN + Vector3(1.0, 0, -1.0), 0.0001,
		"and runs along the new direction")


## Minimal damageable stand-in, the shape _player_contact scans the group for.
class DummyTarget extends CharacterBody3D:
	var is_dead := false
	var team := 0


func _target_at(pos: Vector3, team := 0) -> DummyTarget:
	var t := _damageable_at(DummyTarget, pos, 0.5) as DummyTarget
	t.team = team
	return t


func test_a_body_partway_along_the_tick_is_caught() -> void:
	# The point this whole unification turns on: the five projectiles that used to test a
	# single position would sail past anything they merely passed THROUGH within a tick.
	var p := _projectile(Vector3.FORWARD, 100.0)  # 10 m in one 0.1 s tick
	var midway := _target_at(ORIGIN + Vector3(0, 0, -5.0))
	await _settle()

	p._trace_step(0.1)
	assert_eq(p._player_contact(p._step_from, p._step_to), midway,
		"caught halfway along the segment, not just at either end")
	assert_gt(p._step_from.distance_to(ORIGIN + Vector3(0, 0, -5.0)), 1.0,
		"and it was far too distant for a point check at the tick's start")


func test_the_owner_is_never_its_own_victim() -> void:
	var p := _projectile(Vector3.FORWARD, 10.0)
	var shooter := _target_at(ORIGIN + Vector3(0, 0, -0.5))
	p.owner_node = shooter
	await _settle()

	p._trace_step(0.1)
	assert_eq(p._player_contact(p._step_from, p._step_to), null, "the owner is skipped")


func test_exclude_node_is_skipped_too() -> void:
	# A thornplant's spores must not detonate on the thornplant that fired them.
	var p := _projectile(Vector3.FORWARD, 10.0)
	var parent := _target_at(ORIGIN + Vector3(0, 0, -0.5))
	p.exclude_node = parent
	await _settle()

	p._trace_step(0.1)
	assert_eq(p._player_contact(p._step_from, p._step_to), null, "the excluded node is skipped")


func test_a_dead_body_is_not_a_contact() -> void:
	var p := _projectile(Vector3.FORWARD, 10.0)
	var corpse := _target_at(ORIGIN + Vector3(0, 0, -0.5))
	corpse.is_dead = true
	await _settle()

	p._trace_step(0.1)
	assert_eq(p._player_contact(p._step_from, p._step_to), null,
		"a dead body doesn't soak a projectile meant for someone behind it")


func test_a_teammate_stops_the_projectile() -> void:
	# Deliberate: contact ignores team. Friendly fire is rejected by the target
	# (player.take_damage / dragon.take_damage), so a teammate's body still blocks.
	var p := _projectile(Vector3.FORWARD, 10.0)
	p.team = GameConsts.Team.BLUE
	var ally := _target_at(ORIGIN + Vector3(0, 0, -0.5), GameConsts.Team.BLUE)
	await _settle()

	p._trace_step(0.1)
	assert_eq(p._player_contact(p._step_from, p._step_to), ally,
		"an ally in the way is still a contact")


func test_radius_bounds_the_contact() -> void:
	var p := _projectile(Vector3.FORWARD, 10.0)
	_target_at(ORIGIN + Vector3(2.0, 0, -0.5))  # well off to the side of the path
	await _settle()

	p._trace_step(0.1)
	assert_eq(p._player_contact(p._step_from, p._step_to, 0.5), null, "outside the narrow radius")
	assert_ne(p._player_contact(p._step_from, p._step_to, 3.0), null, "inside a generous one")


func test_a_damageable_projectile_is_not_its_own_contact() -> void:
	# Skull and bird carry HealthBehavior so they can be shot down, which puts them in the
	# very group _player_contact scans. Without a self-check they detonate on tick one,
	# at the caster's feet. Regression: this was masked by a team filter until contact
	# stopped looking at teams.
	# Aimed UP: a shape-less projectile's collision_center is its position + PLAYER_CENTER
	# (0.9 up), so travelling upward walks the segment straight into its own centre.
	var p := _projectile(Vector3.UP, 10.0)
	p.add_to_group("damageable")
	await _settle()

	p._trace_step(0.1)
	assert_eq(p._player_contact(p._step_from, p._step_to, 0.8), null,
		"a projectile never contacts itself, whatever direction it flies")


func test_a_damageable_projectile_still_contacts_others() -> void:
	var p := _projectile(Vector3.FORWARD, 10.0)
	p.add_to_group("damageable")
	var enemy := _target_at(ORIGIN + Vector3(0, 0, -0.5))
	await _settle()

	p._trace_step(0.1)
	assert_eq(p._player_contact(p._step_from, p._step_to, 0.8), enemy,
		"self-exclusion doesn't blind it to everyone else")
