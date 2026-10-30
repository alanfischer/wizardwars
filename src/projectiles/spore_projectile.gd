class_name SporeProjectile
extends Projectile

## Poison spore projectile fired by thornplant turret (level 2+).
## Straight-line flight, proximity hit.

var damage := 12.0


func setup(data: Dictionary, is_host := true) -> void:
	speed = 20.0
	contact_radius = 0.5
	super(data, is_host)
	damage = data.get("damage", 12.0)


func _ready() -> void:
	_scene_root = get_tree().current_scene

	_orient_to_direction()

	var model := AssetLoader.load_model("models/npc/spore.mdl")
	if model:
		model.rotation.y = PI
		AssetLoader.apply_additive_overrides(model)
		add_child(model)

	_create_light(Color(0.2, 0.8, 0.1), 1.5, 2.0)

	_create_trail([
		Color(0.4, 1.0, 0.2, 1.0),   # head: bright green
		Color(0.2, 0.8, 0.1, 0.8),   # medium green
		Color(0.1, 0.6, 0.05, 0.4),  # dark green
		Color(0.05, 0.4, 0.0, 0.0),  # faded
	], 0.06, 0.2)

	if _is_host:
		_register_entity({
			"script_path": "res://src/projectiles/spore_projectile.gd",
			"position": position,
			"direction": direction,
			"speed": speed,
			"lifetime": lifetime,
		})


func _on_world_hit(result: Dictionary) -> void:
	_hit_target(result.collider)


func _on_actor_hit(victim) -> void:
	_hit_target(victim)


func _hit_target(collider) -> void:
	# DamageType.DEATH triggers poison via StatusSystem.on_damage_dealt
	Combat.damage_chain(collider, damage, GameConsts.DamageType.DEATH, owner_node, global_position)

	SoundSystem.play_3d("monster/thornplant/sporehit.wav", global_position)
	_die()
