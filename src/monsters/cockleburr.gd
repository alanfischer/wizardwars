class_name Cockleburr
extends RigidBody3D

## Nature satchel parasite — bounces then sits as a trap; attaches to an enemy that walks
## over it, slowing them and dealing DPS. 25 HP, 30s max lifetime.

const DPS := 2.0
const SLOW_MULTIPLIER := 0.5  # halve victim's speed (applied once, not stacked)
const MAX_HP := 25.0
const MAX_LIFETIME := 30.0
const TRAP_RADIUS := 0.8
const THINK_INTERVAL := 0.2

var owner_node: Node3D
var team := 0

var _summon := SummonBehavior.new()
var _scene_root: Node
var _age := 0.0
var _target: Node3D
var _attached := false
var _think_timer := 0.0
var _model: Node3D
var _attach_offset := Vector3.ZERO  # unique offset so burrs spread around victim
var _prev_target_pos := Vector3.ZERO


func setup(data: Dictionary, is_host := true) -> void:
	team = data.get("team", 0)
	_summon.setup(self, data, is_host, MAX_HP, _die)
	linear_velocity = Vector3(randf_range(-2, 2), 3.0, randf_range(-2, 2))
	add_to_group("projectile")


func _ready() -> void:
	_scene_root = get_tree().current_scene

	collision_layer = GameConsts.MASK_TRAP
	collision_mask = GameConsts.MASK_WORLD | GameConsts.MASK_ENTITY
	continuous_cd = true
	linear_damp = 2.0
	var physics_material = PhysicsMaterial.new()
	physics_material.bounce = 0.4
	physics_material_override = physics_material
	var col := CollisionShape3D.new()
	var sphere_shape := SphereShape3D.new()
	sphere_shape.radius = 0.15
	col.shape = sphere_shape
	add_child(col)

	_model = AssetLoader.load_model("models/npc/cocklebur.mdl")
	if _model:
		add_child(_model)

	# Creation + replication handled by the dynamic-entity MultiplayerSpawner (spawn_projectile).


func _physics_process(delta: float) -> void:
	if _summon.is_host:
		_host_physics(delta)


func _host_physics(delta: float) -> void:
	# It outlives its caster, so a freed owner must not reach target filtering or damage credit:
	# a freed object at a typed `attacker: Node3D` parameter drops the whole damage call.
	if not is_instance_valid(owner_node):
		owner_node = null
	_age += delta
	if _age >= MAX_LIFETIME:
		_die()
		return

	if _attached:
		_attached_tick(delta)
		return

	# only once settled
	if linear_velocity.length() < 0.5:
		_think_timer -= delta
		if _think_timer <= 0.0:
			_think_timer = THINK_INTERVAL
			_check_for_victim()


func _check_for_victim() -> void:
	for node in get_tree().get_nodes_in_group("damageable"):
		if node == owner_node or node is Cockleburr:
			continue
		if not node.is_inside_tree():
			continue
		# Same rule as Combat.find_homing_target — without it the burr trips on the nearest
		# window or sheep instead of waiting for someone it can actually slow down.
		if node.is_in_group("unhunted"):
			continue
		var node_team: int = node.team if "team" in node else 0
		if Teams.teams_friendly(team, node_team):
			continue
		if node.get("is_dead"):
			continue
		var dist := global_position.distance_to(node.global_position)
		if dist < TRAP_RADIUS:
			_attach_to(node)
			return


func _attach_to(victim: Node3D) -> void:
	_attached = true
	_target = victim
	_prev_target_pos = victim.global_position
	freeze = true
	var angle := randf() * TAU
	_attach_offset = Vector3(cos(angle) * 0.5, randf_range(0.6, 1.4), sin(angle) * 0.5)
	# refcounted via meta on the victim (not this instance) so multiple burrs stack/restore correctly
	if "speed_multiplier" in victim:
		var count: int = victim.get_meta("cockleburr_count", 0)
		if count == 0:
			victim.set_meta("cockleburr_saved_speed", victim.speed_multiplier)
			victim.speed_multiplier *= SLOW_MULTIPLIER
		victim.set_meta("cockleburr_count", count + 1)
	SoundSystem.play_3d("spells/satchels/cocklebur.wav", global_position)


func _detach() -> void:
	if _target and is_instance_valid(_target) and "speed_multiplier" in _target:
		var count: int = _target.get_meta("cockleburr_count", 0) - 1
		if count <= 0:
			if _target.has_meta("cockleburr_saved_speed"):
				_target.speed_multiplier = _target.get_meta("cockleburr_saved_speed")
				_target.remove_meta("cockleburr_saved_speed")
			_target.remove_meta("cockleburr_count")
		else:
			_target.set_meta("cockleburr_count", count)
	_target = null
	_attached = false


func _attached_tick(delta: float) -> void:
	if not _target or not is_instance_valid(_target) or not _target.is_inside_tree():
		_die()
		return
	if _target.get("is_dead"):
		_detach()
		_die()
		return
	global_position = _target.global_position + _attach_offset
	var moved := _target.global_position.distance_to(_prev_target_pos) > 0.01
	_prev_target_pos = _target.global_position
	if moved and _target.has_method("take_damage"):
		_target.take_damage(DPS * delta, GameConsts.DamageType.PHYSICAL, owner_node)


func take_damage(amount: float, _type: int = 0, attacker: Node3D = null) -> void:
	_summon.take_damage(amount, _type, attacker)


func _die() -> void:
	_detach()
	_summon.destroy()
