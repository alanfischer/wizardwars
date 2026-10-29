extends "res://src/tests/test_base.gd"
## Combat.find_homing_target: who gets picked, and how many rays picking them costs.
##
## Every monster and homing projectile calls it on its own think clock, over the whole
## `damageable` group, with a visibility ray per candidate — so its cost scales with whatever
## is alive. Dummies sit on collision_layer 0 so they cannot occlude each other; occlusion is
## tested deliberately, with a blocker on MASK_WORLD.

const SEARCH := 60.0


## A box body at `at`. layer 0 is a damageable that blocks nothing; MASK_WORLD is scenery.
func _box(at: Vector3, size: Vector3, layer: int) -> StaticBody3D:
	var body := _keep(StaticBody3D.new()) as StaticBody3D
	body.collision_layer = layer
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	body.add_child(cs)
	_root().add_child(body)
	body.global_position = at
	return body


## A damageable with no team, which reads as an enemy to any team: teams_friendly(team, NONE) is
## false, so summon_spares does not spare it. Added in call order, so tree order is arrival order.
func _dummy(at: Vector3) -> StaticBody3D:
	var body := _box(at, Vector3(1, 2, 1), 0)
	body.add_to_group("damageable")
	return body


func _searcher() -> Node3D:
	var n := _keep(Node3D.new()) as Node3D
	_root().add_child(n)
	n.global_position = Vector3.ZERO
	return n


func _find(from: Node3D, radius := SEARCH, facing := Vector3.ZERO,
		spare := Callable()) -> Node3D:
	return Combat.find_homing_target(from, null, GameConsts.Team.RED, radius,
		RID(), Vector3.INF, facing, 0.0, spare)


func test_nearest_visible_candidate_wins() -> void:
	var me := _searcher()
	# Far ones first, so the answer cannot come from arrival order.
	_dummy(Vector3(30, 0, 0))
	_dummy(Vector3(0, 0, 20))
	var near := _dummy(Vector3(5, 0, 0))
	await _settle()
	assert_eq(_find(me), near, "the nearest of three clear candidates, not the first in tree order")


func test_an_occluded_candidate_is_passed_over() -> void:
	var me := _searcher()
	# Nearest, but walled off: the ray must stop on the wall and reject it.
	_dummy(Vector3(10, 0, 0))
	_box(Vector3(5, 0, 0), Vector3(6, 6, 0.5), GameConsts.MASK_WORLD)
	var clear := _dummy(Vector3(0, 0, 25))
	await _settle()
	assert_eq(_find(me), clear, "a walled-off nearer candidate loses to a clear farther one")


func test_the_search_radius_is_enforced() -> void:
	var me := _searcher()
	_dummy(Vector3(30, 0, 0))
	await _settle()
	assert_eq(_find(me, 10.0), null, "nothing inside a 10m radius")
	assert_ne(_find(me, 40.0), null, "but it is found at 40m")


func test_candidates_outside_the_facing_cone_are_ignored() -> void:
	var me := _searcher()
	var ahead := _dummy(Vector3(0, 0, -10))
	_dummy(Vector3(0, 0, 10))
	await _settle()
	# A 90-degrees-either-side cone pointed at -z: the one behind is out.
	assert_eq(_find(me, SEARCH, Vector3(0, 0, -1)), ahead, "the one in the cone, never the one behind")


## The "unhunted" group: in "damageable" so a blast still hurts it, never something a search
## picks. Its members are pinned where they live — test_sheep.gd, test_breakable_gibs.gd,
## test_bird_gib.gd — so this is the rule itself, and the ray it must not cost.
func test_an_unhunted_candidate_is_never_picked() -> void:
	var me := _searcher()
	var near := _dummy(Vector3(3, 0, 0))
	near.add_to_group("unhunted")
	var far := _dummy(Vector3(8, 0, 0))
	await _settle()

	Combat.homing_ray_count = 0
	assert_eq(_find(me), far, "the nearer unhunted body is passed over")
	assert_eq(Combat.homing_ray_count, 1,
		"and is dropped before the ray, not after it")


## The `spare` hook, which nothing else covers.
func test_a_spare_callable_vetoes_a_candidate() -> void:
	var me := _searcher()
	var near := _dummy(Vector3(3, 0, 0))
	var far := _dummy(Vector3(8, 0, 0))
	await _settle()
	assert_eq(_find(me), near, "nearest without a veto")
	assert_eq(_find(me, SEARCH, Vector3.ZERO, func(n): return n == near), far,
		"vetoing the nearest falls through to the next")


## The cost invariant. A candidate that is not nearer than the best in hand cannot win, so it must
## not be raycast — which is exactly what moving the distance test back below the ray would undo,
## with every case above still passing.
func test_rays_are_only_spent_on_improving_candidates() -> void:
	var me := _searcher()
	# Nearest first, then steadily farther: after the first, none is an improvement.
	_dummy(Vector3(2, 0, 0))
	_dummy(Vector3(12, 0, 0))
	_dummy(Vector3(22, 0, 0))
	_dummy(Vector3(32, 0, 0))
	await _settle()

	Combat.homing_ray_count = 0
	assert_ne(_find(me), null, "it still finds the near one")
	assert_eq(Combat.homing_ray_count, 1,
		"4 candidates, nearest first: only the one that can win is raycast")
