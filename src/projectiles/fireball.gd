class_name Fireball
extends Projectile

const FIREBALL_DAMAGE := 40.0
const FIREBALL_RADIUS := 4.0    # 128 * 0.025 scale
const FIREBALL_KNOCKBACK := 12.0  # 480 GS u/s at the blast centre — enough to rocket jump
const FIREBALL_SPEED := 18.00
const FIREBALL_LIFETIME := 5.0

var _ambience: AudioStreamPlayer3D
var _exploded := false


func setup(data: Dictionary, is_host := true) -> void:
	speed = FIREBALL_SPEED
	lifetime = FIREBALL_LIFETIME
	super(data, is_host)


func _ready() -> void:
	_scene_root = get_tree().current_scene

	_create_sprite("sprites/animglow01.spr")

	_create_light(Color(1.0, 0.59, 0.2), 2.0, 3.2)

	_create_trail()

	_ambience = _create_ambient_sound("spells/fireball_ambience.wav", 15.0)

	# replication handled by the dynamic-entity spawner; destroy is a plain queue_free (entity_id stays -1)


func _on_expired() -> void:
	_explode()


func _on_world_hit(result: Dictionary) -> void:
	_explode()
	var collider = result.collider
	if collider is StaticBody3D:
		if Game.decal_system:
			var decal_name := "{scorch%d" % (randi() % 3 + 1)
			Game.decal_system.place_rpc.rpc(decal_name, result.position, result.normal, 0.25, collider.get_path())


func _on_actor_hit(_victim) -> void:
	_explode()


func _exit_tree() -> void:
	# safety net for external frees (destroy_all_dynamic_entities, map change); _exploded guards against double-fire
	if not _exploded:
		_spawn_explosion(global_position)
	_stop_trail()


func _explode() -> void:
	var explode_pos := global_position

	_spawn_explosion(explode_pos)

	var space := get_world_3d().direct_space_state
	Combat.apply_aoe_damage(
		space,
		explode_pos, FIREBALL_DAMAGE, FIREBALL_RADIUS, {},
		GameConsts.DamageType.FIRE, owner_node
	)
	# The caster is pushed too, so a fireball at your own feet launches you.
	Combat.apply_aoe_knockback(space, explode_pos, FIREBALL_KNOCKBACK, FIREBALL_RADIUS, owner_node)

	_die()


func _spawn_explosion(pos: Vector3) -> void:
	if _exploded:
		return
	_exploded = true
	if not is_instance_valid(_scene_root):
		return
	ExplosionEffect.spawn(_scene_root, pos)
