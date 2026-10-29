class_name HomingBehavior
extends RefCounted

## Search-and-chase targeting for homing projectiles. Set the config fields after
## initialize(), then call steer() once per host physics frame before moving.
##
## Only re-acquires while unlocked — a live target is chased until it dies or leaves
## the tree, so nothing switches targets mid-flight.

## Current lock, null while hunting.
var target: Node3D = null
var team := 0
var search_radius := 12.5
var turn_speed := 360.0    # degrees per second
var think_interval := 0.1  # seconds between searches while unlocked

var _host: Projectile
var _on_acquire: Callable
var _think_timer := 0.0


## on_acquire fires when a search lands a new lock — projectiles use it to extend
## their lifetime, and each does that on its own terms.
func initialize(host: Projectile, p_team: int, on_acquire: Callable = Callable()) -> void:
	_host = host
	team = p_team
	_on_acquire = on_acquire


## Turns `dir` toward the locked target by at most turn_speed * delta, searching for a
## new one first if unlocked. Returns the steered direction, unchanged when there is
## nothing to chase. Host-only; call before applying this tick's movement.
func steer(dir: Vector3, delta: float) -> Vector3:
	_think_timer -= delta
	if target and not _target_alive():
		target = null
	if target == null:
		if _think_timer <= 0.0:
			_think_timer = think_interval
			_search()
		return dir  # a fresh lock steers from next tick, not this one
	var to_target := (SpatialQuery.collision_center(target) - _host.global_position).normalized()
	var angle := dir.angle_to(to_target)
	if angle <= 0.001:
		return to_target
	var max_turn := deg_to_rad(turn_speed) * delta
	return dir.slerp(to_target, clampf(max_turn / angle, 0.0, 1.0)).normalized()


func _target_alive() -> bool:
	return is_instance_valid(target) and target.is_inside_tree() and not target.get("is_dead")


func _search() -> void:
	# owner_node/exclude_rid are assigned by spawn_projectile AFTER setup(), so read them
	# live rather than snapshotting them at initialize() time.
	var best := Combat.find_homing_target(_host, _host.owner_node, team,
			search_radius, _host.exclude_rid)
	if best == null:
		return
	target = best
	if _on_acquire.is_valid():
		_on_acquire.call()
