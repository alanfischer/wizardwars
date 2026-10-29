extends "res://src/tests/test_base.gd"
## SpatialQuery.nodes_near / nodes_near_segment stand in for a walk of a whole group, so the only
## property that matters is that they never hide a member the walk would have found. Everything
## here is a superset check against that walk; a tight result is an optimisation, not a contract.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.

## Tight enough that the mid radii routinely have something to find — a scatter the size of a
## map makes every query empty and the superset check vacuous.
const AREA := 10.0
const RADII := [0.6, 0.8, 1.25, 2.5, 3.2, 10.0]


func _body_at(pos: Vector3, group := &"damageable") -> CharacterBody3D:
	var b := CharacterBody3D.new()
	var col := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.3
	cap.height = 1.8
	col.shape = cap
	b.add_child(col)
	b.add_to_group(group)
	_root().add_child(b)
	b.global_position = pos
	_keep(b)
	return b


func _rand_vec(rng: RandomNumberGenerator, span: float) -> Vector3:
	return Vector3(rng.randf_range(-span, span), rng.randf_range(-span, span),
			rng.randf_range(-span, span))


## Lifted clear of the scratch bodies every other suite leaves near the origin, so a query here
## sees only what the test put here.
const AWAY := Vector3(0.0, 60.0, 0.0)
## nodes_near walks the group instead of indexing it whenever there are fewer members than cells
## to probe, so a test of the INDEX has to hold enough of them. These sit far from AWAY: they
## push the count past the bound and the index has to prune them all away again.
const FILLER := 16


func _fill_far() -> void:
	for i in FILLER:
		_body_at(AWAY + Vector3(40.0 + float(i) * 10.0, 0.0, 0.0))


## Keys this frame's buckets, which is what the staleness tests then go behind the back of.
func _prime(pos: Vector3) -> void:
	SpatialQuery.nodes_near(&"damageable", pos, 1.0)


func _walk(group: StringName, from: Vector3, to: Vector3, radius: float) -> Array:
	var out: Array = []
	for node in _tree().get_nodes_in_group(group):
		var c: Vector3 = SpatialQuery.collision_center(node)
		if GeomUtil.dist_to_segment(c, from, to) <= radius:
			out.append(node)
	return out


## Returns how many members the walk found, so a test can show it was not asserting over air.
func _assert_superset(walk: Array, got: Array, context: String) -> int:
	for node in walk:
		assert_true(got.has(node), "%s: %s within reach but not offered" % [context, node])
	return walk.size()


## Random points, random segments, random radii, against the walk each one replaces. The sphere
## and the segment form are swept together because nodes_near is nodes_near_segment with the
## segment collapsed, and a seed that catches one should catch the other.
func test_offers_everything_the_walk_would_find() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in 40:
		_body_at(_rand_vec(rng, AREA))
	await _tree().physics_frame

	var found := 0
	for t in 60:
		var radius: float = RADII[rng.randi() % RADII.size()]
		var from := _rand_vec(rng, AREA)
		var to := from + _rand_vec(rng, 3.0)
		found += _assert_superset(_walk(&"damageable", from, from, radius),
				SpatialQuery.nodes_near(&"damageable", from, radius), "sphere r=%s" % radius)
		found += _assert_superset(_walk(&"damageable", from, to, radius),
				SpatialQuery.nodes_near_segment(&"damageable", from, to, radius),
				"segment r=%s" % radius)
	assert_gt(found, 100, "members the walk found across the sweep")


## The guard on every test below it: at the group size they build, a 1 m query must actually
## take the indexed path. Nothing else here can tell the difference — every result is a superset
## either way — so if a constant ever drifts far enough to put these back on the walk, this is
## the assertion that says so instead of four tests quietly passing over nothing.
func test_this_suite_exercises_the_index_and_not_the_fallback() -> void:
	_fill_far()
	_body_at(AWAY)
	await _tree().physics_frame
	SpatialQuery._prox_stamp.clear()
	SpatialQuery.nodes_near(&"damageable", AWAY, 1.0)
	assert_true(SpatialQuery._prox_stamp.has(&"damageable"), "the query keyed buckets")


## The buckets are keyed once per physics frame, so a member that moves after the keying has to
## still be offered — that is what _PROX_SLACK buys, and this is the case it was bought for: at
## keying time the body is outside the 1 m the query asks for, and a walk would not have
## returned it; a tick of travel later it is on top of the query point. Nothing promises a
## member that moved FURTHER than the pad in one tick, which is why this moves 1.8 m and not 10.
func test_a_member_that_moved_since_the_keying_is_still_offered() -> void:
	_fill_far()
	var body := _body_at(AWAY + Vector3(0.0, 0.0, 1.8))
	await _tree().physics_frame
	_prime(AWAY)  # keys the buckets with the body out of reach
	body.global_position = AWAY
	assert_true(SpatialQuery.nodes_near(&"damageable", AWAY, 1.0).has(body),
			"a body that closed the distance within the frame")


## A member that joined after the keying is offered too — the member count is half the stamp.
func test_a_member_that_joined_since_the_keying_is_offered() -> void:
	_fill_far()
	await _tree().physics_frame
	_prime(AWAY)
	var late := _body_at(AWAY)
	assert_true(SpatialQuery.nodes_near(&"damageable", AWAY, 1.0).has(late), "a late joiner")


## A freed member never reaches a caller, however stale the bucket holding it.
func test_a_freed_member_is_not_offered() -> void:
	_fill_far()
	var keep := _body_at(AWAY)
	var doomed := _body_at(AWAY + Vector3(0.2, 0.0, 0.0))
	await _tree().physics_frame
	_prime(AWAY)
	_spawned.erase(doomed)
	doomed.free()
	var got := SpatialQuery.nodes_near(&"damageable", AWAY, 1.0)
	assert_true(got.has(keep), "the live body")
	assert_eq(got.size(), 1, "only the live body")


## A reach wide enough to cost more in cells than the group costs in members hands back the
## group itself — the whole-map radii must not pay for a grid they would walk anyway.
func test_a_whole_map_reach_falls_back_to_the_group() -> void:
	for i in 4:
		_body_at(Vector3(i * 2.0, 60.0, 0.0))
	await _tree().physics_frame
	var got := SpatialQuery.nodes_near(&"damageable", Vector3(0.0, 60.0, 0.0), GameConsts.WORLD_BOUND)
	assert_eq(got.size(), _tree().get_node_count_in_group(&"damageable"), "the whole group")


## Groups are indexed apart: a crowded "damageable" must not leak into a "pushable" query.
func test_groups_are_indexed_separately() -> void:
	_fill_far()
	_body_at(AWAY)
	var shoved := _body_at(AWAY + Vector3(0.3, 0.0, 0.0), &"pushable")
	for i in FILLER:
		_body_at(AWAY + Vector3(0.0, 0.0, 40.0 + float(i) * 10.0), &"pushable")
	await _tree().physics_frame
	var got := SpatialQuery.nodes_near(&"pushable", AWAY, 1.0)
	assert_eq(got.size(), 1, "only the pushable")
	assert_true(got.has(shoved), "the pushable")


func test_an_empty_group_offers_nothing() -> void:
	assert_true(SpatialQuery.nodes_near(&"no_such_group", Vector3.ZERO, 5.0).is_empty(),
			"a group nothing is in")
