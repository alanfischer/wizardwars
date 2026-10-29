extends "res://src/tests/test_base.gd"
## A sustained beam must never resolve to the wizard casting it. The life ray heals with
## overheal allowed, so a self-hit quietly pushed the caster past max health while they were
## healing a teammate; the same guard keeps the freeze and death rays off their own caster.
## One player can own two bodies (LocalPlayer view + server puppet sharing a peer_id), so
## identity is by peer_id, not by node.

const PlayerScene = preload("res://src/player.tscn")

var _players: Array[Node] = []


func _run_tests() -> void:
	await super()
	for p in _players:
		p.free()
	_players.clear()


func _player(peer_id: int) -> Player:
	var p: Player = PlayerScene.instantiate()
	p.peer_id = peer_id
	_players.append(p)
	return p


func test_caster_body_is_not_a_target() -> void:
	var caster := _player(7)
	assert_eq(LifeRayWeapon.new()._resolve_ray_target(caster, caster), null,
		"a ray that lands on its own caster resolves to nothing")


func test_casters_other_body_is_not_a_target() -> void:
	var caster := _player(7)
	var view := _player(7)  # same player's other body (host view vs. server puppet)
	assert_eq(LifeRayWeapon.new()._resolve_ray_target(caster, view), null,
		"the caster's other body is still the caster")


func test_another_player_is_a_target() -> void:
	var caster := _player(7)
	var other := _player(8)
	assert_eq(LifeRayWeapon.new()._resolve_ray_target(caster, other), other,
		"a different player is a real target")


func test_hitbox_child_resolves_to_its_player() -> void:
	var caster := _player(7)
	var other := _player(8)
	var hitbox := Area3D.new()
	other.add_child(hitbox)
	assert_eq(LifeRayWeapon.new()._resolve_ray_target(caster, hitbox), other,
		"a per-bone hitbox resolves up to the player wearing it")


func test_world_geometry_is_not_a_target() -> void:
	var caster := _player(7)
	var wall := StaticBody3D.new()
	assert_eq(LifeRayWeapon.new()._resolve_ray_target(caster, wall), null,
		"world geometry takes no ray hit")
	wall.free()


func test_every_ray_shares_the_guard() -> void:
	var caster := _player(7)
	var view := _player(7)
	for w in [LifeRayWeapon.new(), FreezeRayWeapon.new(), DeathRayWeapon.new()]:
		assert_eq(w._resolve_ray_target(caster, view), null,
			"%s must not touch its caster" % w.get_script().resource_path.get_file())
