class_name Comet
extends Projectile

## Homing comet — spawns above the target and dives down tracking it, exploding on
## proximity with AoE damage. Based on CComet from the original combo spell system.

const EXPLODE_DISTANCE := 1.25  # 50 GS units * 0.025
const TRAIL_WIDTH := 0.3
const LIFETIME := 8.0  # safety timeout
const SKY_OFFSET := 25.6  # 1024 GS units * 0.025
const SPEED := 16.0       # sv_maxspeed * 2.0 * 0.025
const DAMAGE := 200.0
const RADIUS := 5.0

# host-only registry of comets already homing a target (by instance id), so overlapping
# spawn guards don't double-comet the same intruder
static var _incoming: Dictionary = {}


## True if a live comet is already homing on `target` — spawners use this to avoid stacking.
static func has_incoming(target: Node) -> bool:
	if target == null:
		return false
	var c: Variant = _incoming.get(target.get_instance_id())
	return c != null and is_instance_valid(c)


## Spawns via the replicating projectile system (a bare add_child would be host-only).
## `p_owner` is excluded from the blast; pass null for spawn guards that must hit the intruder.
static func spawn(target: Node3D, p_owner: Node3D = null, p_exclude_rid := RID()) -> Comet:
	var target_pos := SpatialQuery.collision_center(target)
	var comet := NetworkManager.spawn_projectile("res://src/projectiles/comet.gd", {
		"position": target_pos + Vector3(0, SKY_OFFSET, 0),
		"target_pos": target_pos,
		"speed": SPEED,
		"damage": DAMAGE,
		"radius": RADIUS,
	}, p_owner, p_exclude_rid) as Comet
	if comet:
		comet.set_target(target)
	return comet


## _target_node is host-only and can't ride the spawn payload, so callers set it after
## _ready — hence the incoming-registry update lives here, not in _ready.
func set_target(node: Node3D) -> void:
	_target_node = node
	if _is_host and is_instance_valid(node):
		_incoming[node.get_instance_id()] = self

var damage := 200.0
var radius := 5.0
var _target_pos := Vector3.ZERO  # initial target pos (used by clients without node ref)
var _target_node: Node3D          # hard lock — tracked every frame until dead
var _exploded := false


func setup(data: Dictionary, is_host := true) -> void:
	speed = SPEED
	lifetime = LIFETIME
	super(data, is_host)
	_target_pos = data.get("target_pos", Vector3.ZERO)
	damage = data.get("damage", DAMAGE)
	radius = data.get("radius", RADIUS)


func _ready() -> void:
	_scene_root = get_tree().current_scene

	_create_sprite("sprites/animglow01.spr", 2.0)  # bigger than fireball

	_create_light(Color(1.0, 0.4, 0.1), 5.0, 6.0)

	_create_trail([
		Color(1.0, 0.8, 0.2, 1.0),   # head: bright yellow
		Color(1.0, 0.3, 0.0, 1.0),   # mid: orange-red
		Color(0.8, 0.1, 0.0, 0.8),   # mid-tail: deep red
		Color(0.3, 0.0, 0.0, 0.0),   # tail: dark, faded
	], TRAIL_WIDTH, 0.5)

	_create_ambient_sound("spells/combos/comet_hit.wav", 30.0)


func _host_physics(delta: float) -> void:
	_age += delta
	if _age >= LIFETIME:
		_explode()
		return

	if is_instance_valid(_target_node) and _target_node.is_inside_tree():
		if _target_node.get("is_dead"):
			_explode()  # explode at last known position
			return
		_target_pos = SpatialQuery.collision_center(_target_node)

	var to_target := _target_pos - global_position
	var dist := to_target.length()

	if dist < EXPLODE_DISTANCE:
		_explode()
		return

	var dir := to_target.normalized()
	var step := dir * speed * delta
	# check the whole path, not only the locked target
	var victim := _player_contact(global_position, global_position + step)
	if victim != null:
		global_position = SpatialQuery.collision_center(victim)
		_explode()
		return
	global_position += step


func _explode() -> void:
	if _exploded:
		return
	_exploded = true

	if is_instance_valid(_scene_root):
		CometExplosionEffect.spawn(_scene_root, global_position)

	if _is_host:
		Combat.apply_aoe_damage(
			get_world_3d().direct_space_state,
			global_position, damage, radius, {},
			GameConsts.DamageType.FIRE, owner_node, owner_node, true
		)

	_die()


func _exit_tree() -> void:
	if is_instance_valid(_target_node):
		var key := _target_node.get_instance_id()
		if _incoming.get(key) == self:
			_incoming.erase(key)
	if not _exploded and is_instance_valid(_scene_root):
		CometExplosionEffect.spawn(_scene_root, global_position)
	_stop_trail()
