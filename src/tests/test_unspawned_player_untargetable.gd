extends "res://src/tests/test_base.gd"
## A peer's body puppet exists from the moment it connects — parked on a spawn point while
## the client is still downloading and loading the map. Until it actually spawns it is a
## placeholder, not a body: homing/AoE scans walk the "damageable" group, so a thornplant
## covering that spawn used to lock on and kill it, dragging the loading client through a
## death it couldn't present. main._on_peer_connected drops it from the group and turns its
## collider off; take_damage refuses anything outside the group, so a direct hit agrees
## with the scans.
##
## The gate is spawn state, never team: deathmatch players have no team and are ordinary
## targets (test_teamless_spawned_player_takes_damage).
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.

const PlayerScript = preload("res://src/player.gd")

const SCAN_POS := Vector3(0.0, 80.0, 0.0)  # clear of map geometry, so LOS rays hit nothing


## Mirrors main._on_peer_connected: a puppet spawned for a peer that hasn't entered the world.
func _make_unspawned_puppet() -> Node:
	var p: CharacterBody3D = PlayerScript.new()
	var col := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.5
	cap.height = 1.8
	col.shape = cap
	p.add_child(col)
	p.collision_layer = GameConsts.MASK_PLAYER
	_root().add_child(p)
	p.set_damageable(false)
	return p


func test_unspawned_puppet_takes_no_damage() -> void:
	var p := _make_unspawned_puppet()
	p.take_damage(500.0)
	assert_eq(p.health, 100.0, "a body that never spawned takes no damage")
	assert_false(p.is_dead, "…and so can't be killed while its client is still loading")
	p.free()


## The reported bug, at the scan Thornplant._scan_for_enemies runs.
func test_thornplant_scan_skips_the_unspawned_puppet() -> void:
	var plant := Node3D.new()
	_root().add_child(plant)
	plant.global_position = SCAN_POS
	var p := _make_unspawned_puppet()
	p.global_position = SCAN_POS + Vector3(3.0, 0.0, 0.0)

	var target := Combat.find_homing_target(plant, null, GameConsts.Team.BLUE, 12.8)
	assert_true(target == null, "a plant finds no target in a peer that hasn't spawned")
	p.free()
	plant.free()


## _enable_after_spawn is the one spawn transition (spawn_at / spawn_at_transform).
func test_spawning_makes_it_a_real_body() -> void:
	var p := _make_unspawned_puppet()
	p.team = GameConsts.Team.RED
	p._enable_after_spawn()
	assert_true(p.is_in_group("damageable"), "spawning makes it a target")
	p.take_damage(30.0)
	assert_eq(p.health, 70.0, "…and it takes damage normally")
	p.free()


## Deathmatch: no team, but spawned — an ordinary target. Team must never be the gate.
func test_teamless_spawned_player_takes_damage() -> void:
	var p := _make_unspawned_puppet()
	p._enable_after_spawn()
	assert_eq(p.team, GameConsts.Team.NONE, "no team assigned")
	assert_true(p.is_in_group("damageable"), "a teamless spawned player is still a target")
	p.take_damage(30.0)
	assert_eq(p.health, 70.0, "a teamless spawned player takes damage")
	p.free()
