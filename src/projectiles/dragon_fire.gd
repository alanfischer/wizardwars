class_name DragonFire
extends Projectile

const DRAGONFIRE_DAMAGE := 10.0
const DRAGONFIRE_RADIUS := 4.5
const DRAGONFIRE_SPEED := 30.0
const DRAGONFIRE_LIFETIME := 1.0

var _exploded := false


func setup(data: Dictionary, is_host := true) -> void:
	speed = DRAGONFIRE_SPEED
	lifetime = DRAGONFIRE_LIFETIME
	super(data, is_host)


func _ready() -> void:
	_scene_root = get_tree().current_scene
	_create_light(Color(1.0, 0.45, 0.1), 2.5, 4.0)
	_create_trail([Color(1.0, 0.6, 0.0), Color(0.8, 0.2, 0.0), Color(0.3, 0.1, 0.0)], 0.08, 0.2)

	if _is_host:
		_register_entity({
			"script_path": "res://src/projectiles/dragon_fire.gd",
			"position": position,
			"direction": direction,
		})


func _on_expired() -> void:
	_explode()


func _on_world_hit(_result: Dictionary) -> void:
	_explode()


func _on_actor_hit(_victim) -> void:
	_explode()


func _exit_tree() -> void:
	if not _exploded:
		_spawn_explosion(global_position)
	_stop_trail()


func _explode() -> void:
	var explode_pos := global_position
	_spawn_explosion(explode_pos)
	Combat.apply_aoe_damage(
		get_world_3d().direct_space_state,
		explode_pos, DRAGONFIRE_DAMAGE, DRAGONFIRE_RADIUS, {},
		GameConsts.DamageType.FIRE, owner_node
	)
	_die()


func _spawn_explosion(pos: Vector3) -> void:
	if _exploded:
		return
	_exploded = true
	if not is_instance_valid(_scene_root):
		return
	ExplosionEffect.spawn(_scene_root, pos)
