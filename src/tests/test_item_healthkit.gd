extends "res://src/tests/test_base.gd"
## item_healthkit mirrors Half-Life's CHealthKit: TakeHealth returns 0 with no room to heal, so a
## full-health kit stays un-consumed; polling (not body_entered) is what makes that work, since a
## player who enters at full health and later gets hurt won't re-trigger a signal.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.


func _kit(keys := {}) -> ItemHealthkit:
	var k := ItemHealthkit.new()
	var e := {"classname": "item_healthkit", "angles": "0 0 0"}
	e.merge(keys, true)
	k.set_meta("entity", e)
	_root().add_child(k)
	_spawned.append(k)
	return k


## A stand-in for the player: _try_give only asks for heal/health/max_health/is_dead.
class _Patient:
	extends CharacterBody3D
	var health := 40.0
	var max_health := 100.0
	var is_dead := false
	var healed := 0.0

	func heal(amount: float, _healer: Node3D = null, _allow_overheal := false) -> void:
		healed += amount
		health = minf(health + amount, max_health)


func _patient(health := 40.0) -> _Patient:
	var p := _Patient.new()
	p.health = health
	# Player-sized capsule, so the area-overlap test has something to detect.
	var col := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.4
	capsule.height = 1.8
	col.shape = capsule
	col.position = Vector3(0, 0.9, 0)
	p.add_child(col)
	_root().add_child(p)
	_spawned.append(p)
	return p


func test_hurt_player_gets_healed_and_kit_disappears() -> void:
	var k := _kit()
	var p := _patient(40.0)
	assert_true(k._try_give(p), "a hurt player picks the kit up")
	assert_almost_eq(p.healed, ItemHealthkit.HEAL_AMOUNT, 0.001, "healed for the kit's value")
	assert_false(k._touch.available, "the kit is spent")
	assert_false(k._game_visible, "and hidden — clients are told through the synced flag")
	var state: Dictionary = k._get_sync_state()
	assert_eq(state.get("visible"), false, "sync state reports the pickup to clients")


func test_full_health_player_leaves_the_kit() -> void:
	var k := _kit()
	var p := _patient(100.0)
	assert_false(k._try_give(p), "no room to heal, so no pickup")
	assert_eq(p.healed, 0.0, "nothing healed")
	assert_true(k._touch.available, "the kit is still there for later")
	assert_true(k._game_visible, "and still visible")


func test_kit_is_not_over_healed_past_max() -> void:
	var k := _kit()
	var p := _patient(90.0)
	assert_true(k._try_give(p), "a player 10 short still picks it up")
	assert_almost_eq(p.health, 100.0, 0.001, "but caps at max_health, no overheal")


func test_dead_player_cannot_pick_up() -> void:
	var k := _kit()
	var p := _patient(0.0)
	p.is_dead = true
	assert_false(k._try_give(p), "a corpse walking over a kit takes nothing")
	assert_true(k._touch.available, "the kit survives")


func test_non_player_bodies_are_ignored() -> void:
	var k := _kit()
	var rock := CharacterBody3D.new()
	_root().add_child(rock)
	_spawned.append(rock)
	assert_false(k._try_give(rock), "something with no heal() is not a pickup candidate")


func test_kit_respawns_by_default() -> void:
	var k := _kit()
	assert_gt(k._touch.respawn_time, 0.0, "no spawnflags means it comes back — none of the 166 set any")
	k._try_give(_patient(40.0))
	k._touch._respawn()
	assert_true(k._touch.available, "rematerializing puts it back in play")
	assert_true(k._game_visible, "and visible again")


## The tests above call _try_give directly. This one goes through the real
## Area3D so the collision mask and the box size are covered too.
func test_player_standing_on_a_kit_is_detected_through_the_area() -> void:
	var k := _kit()
	k.global_position = Vector3(0, 0, 0)
	var p := _patient(40.0)
	p.collision_layer = GameConsts.MASK_PLAYER
	# Feet on the kit's origin, which is where GoldSrc's drop-to-floor leaves it.
	p.global_position = Vector3(0, 0.2, 0)
	var tree := Engine.get_main_loop() as SceneTree
	await tree.physics_frame  # let the area register the new body
	await tree.physics_frame
	k._touch.drops_to_floor = false  # no world geometry in the test scene to drop onto
	k._touch._poll_accum = TouchBehavior.POLL_INTERVAL  # force the poll this tick
	k._physics_process(0.0)
	assert_almost_eq(p.healed, ItemHealthkit.HEAL_AMOUNT, 0.001,
		"the touch area saw the player and gave the kit")
	assert_false(k._touch.available, "kit consumed")


func test_norespawn_flag_removes_it_for_good() -> void:
	var k := _kit({"spawnflags": str(ItemHealthkit.SF_NORESPAWN)})
	assert_eq(k._touch.respawn_time, 0.0, "SF_NORESPAWN is a one-time pickup")
	assert_true(k._try_give(_patient(40.0)), "still heals once")
	assert_false(k._touch.available, "then stays gone")
