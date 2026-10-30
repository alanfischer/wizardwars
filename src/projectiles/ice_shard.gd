class_name IceShard
extends Projectile

## Ice shard — straight-line flight, direct hit damage (no splash). ICE damage
## auto-applies frost via StatusSystem.

var damage := 10.0

var _model: Node3D


func setup(data: Dictionary, is_host := true) -> void:
	speed = 25.0
	contact_radius = 0.5
	super(data, is_host)
	damage = data.get("damage", damage)


func _ready() -> void:
	_scene_root = get_tree().current_scene

	_orient_to_direction()

	_model = AssetLoader.load_model("models/iceshard.mdl")
	if _model:
		add_child(_model)

	_create_light(Color(0.0, 0.59, 1.0), 1.5, 2.0)

	_create_trail([
		Color(0.9, 0.95, 1.0, 1.0),   # white head
		Color(0.4, 0.7, 1.0, 1.0),    # light blue
		Color(0.2, 0.4, 0.9, 0.8),    # medium blue
		Color(0.1, 0.2, 0.6, 0.0),    # dark blue, faded
	])

	if _is_host:
		_register_entity({
			"script_path": "res://src/projectiles/ice_shard.gd",
			"position": position,
			"direction": direction,
			"speed": speed,
			"lifetime": lifetime,
		})


func _on_expired() -> void:
	_hit()


func _on_world_hit(result: Dictionary) -> void:
	Combat.damage_chain(result.collider, damage, GameConsts.DamageType.ICE, owner_node,
		global_position)
	_hit()


func _on_actor_hit(victim) -> void:
	victim.take_damage(damage, GameConsts.DamageType.ICE, owner_node)
	_hit()


## _fly_step has already put us at the impact point, so the shatter goes where we are.
func _hit() -> void:
	_spawn_hit_effect(global_position)
	_die()


func _spawn_hit_effect(pos: Vector3) -> void:
	if not is_instance_valid(_scene_root):
		return
	var effect := IceShardHitEffect.spawn(_scene_root, pos)
	if _is_host:
		NetworkManager.register_effect(effect, "res://src/effects/ice_shard_hit_effect.gd")
