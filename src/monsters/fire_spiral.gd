class_name FireSpiral
extends Node3D

## Fire satchel spiral — two arms of flame that smoothly spin outward from center,
## dealing damage to anything they touch.

const MAX_RADIUS := 5.0
const DURATION := 2.0
const TURNS := 2.0             # full rotations over the duration
const FLAME_INTERVAL := 0.05  # seconds between flame spawns per arm
const DAMAGE_INTERVAL := 0.1  # seconds between damage ticks per arm position
const DAMAGE := 12.0
const DAMAGE_RADIUS := 1.25    # AoE around each sampled arm point
const DAMAGE_TYPE := GameConsts.DamageType.FIRE

var owner_node: Node3D
var team := 0

var _entity := EntityBehavior.new()
var _scene_root: Node
var _age := 0.0
var _flame_timer := 0.0
var _damage_timer := 0.0
var _start_angle := 0.0
var _origin := Vector3.ZERO
var _head1: FireSpiralEffect
var _head2: FireSpiralEffect
var _dying := false


func setup(data: Dictionary, is_host := true) -> void:
	_origin = data.get("position", Vector3.ZERO)
	position = _origin
	team = data.get("team", 0)
	_start_angle = data.get("start_angle", randf() * TAU)
	_entity.initialize(self, is_host)


func _ready() -> void:
	_scene_root = get_tree().current_scene

	if _entity.is_host:
		pass  # replication handled by the dynamic-entity MultiplayerSpawner


func _physics_process(delta: float) -> void:
	# It outlives its caster, so a freed owner must not reach target filtering or damage credit:
	# a freed object at a typed `attacker: Node3D` parameter drops the whole damage call.
	if not is_instance_valid(owner_node):
		owner_node = null
	_age += delta
	if _age >= DURATION:
		_die()
		return

	var t := _age / DURATION  # 0→1
	var radius := t * MAX_RADIUS
	var angle := _start_angle + t * TURNS * TAU

	# Two arms, 180 degrees apart
	var arm1_pos := _origin + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
	var arm2_pos := _origin + Vector3(cos(angle + PI) * radius, 0.0, sin(angle + PI) * radius)

	if is_instance_valid(_scene_root):
		if not _head1:
			_head1 = FireSpiralEffect.spawn(_scene_root, arm1_pos, true)
			_head2 = FireSpiralEffect.spawn(_scene_root, arm2_pos, true)
		else:
			_head1.global_position = arm1_pos
			_head2.global_position = arm2_pos

	_flame_timer += delta
	if _flame_timer >= FLAME_INTERVAL:
		_flame_timer -= FLAME_INTERVAL
		if is_instance_valid(_scene_root):
			var online := NetworkManager.is_online()
			var f1 := FireSpiralEffect.spawn(_scene_root, arm1_pos)
			var f2 := FireSpiralEffect.spawn(_scene_root, arm2_pos)
			if online and _entity.is_host:
				NetworkManager.register_effect(f1, "res://src/effects/fire_spiral_effect.gd")
				NetworkManager.register_effect(f2, "res://src/effects/fire_spiral_effect.gd")

	if _entity.is_host:
		_damage_timer += delta
		if _damage_timer >= DAMAGE_INTERVAL:
			_damage_timer -= DAMAGE_INTERVAL
			_damage_arms(arm2_pos, arm1_pos)


## Both arms in one pass. They are 180 degrees apart about _origin, so tip to tip is a single
## capsule and one segment test covers the whole of it — this used to sample each arm every
## DAMAGE_RADIUS and run a sphere test per sample, which needed a dictionary to stop a victim
## near the middle being hit by several samples at once.
func _damage_arms(from: Vector3, to: Vector3) -> void:
	for node in SpatialQuery.nodes_near_segment(&"damageable", from, to, DAMAGE_RADIUS):
		var node_team: int = node.team if "team" in node else 0
		if node != owner_node and Teams.teams_friendly(team, node_team):
			continue
		if node.get("is_dead"):
			continue
		if GeomUtil.dist_to_segment(SpatialQuery.collision_center(node), from, to) > DAMAGE_RADIUS:
			continue
		if node.has_method("take_damage"):
			node.take_damage(DAMAGE, DAMAGE_TYPE, owner_node)


func _die() -> void:
	if _dying:
		return
	_dying = true
	_stop_heads()
	_entity.destroy()


func _exit_tree() -> void:
	_stop_heads()


func _stop_heads() -> void:
	if is_instance_valid(_head1):
		_head1.stop()
	if is_instance_valid(_head2):
		_head2.stop()
