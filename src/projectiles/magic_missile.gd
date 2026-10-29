class_name MagicMissile
extends Projectile

## Magic missile — straight-line flight, direct hit damage (no splash). Shared by both
## the single and double missile weapons.
##
## A missile carries whatever damage type the weapon that fired it hands over, and wears its
## colour. Most classes hand over nothing and get the plain white-blue bolt; the necromancer's is
## a poison missile, green all the way through, which is also what lets him re-element his own
## skull with it (see Skull.take_damage).

const MISSILE_SPEED := 50.0    # 2000 GS * 0.025
const MISSILE_DAMAGE := 15.0
const MISSILE_LIFETIME := 5.0
const PLAIN_COLOR := Color(0.7, 0.8, 1.0)

## Rides the spawn data, so both peers build the same coloured missile and it never has to be
## replicated again — unlike a skull's, a missile's type is fixed the moment it is cast.
var damage_type := GameConsts.DamageType.PHYSICAL


func setup(data: Dictionary, is_host := true) -> void:
	speed = MISSILE_SPEED
	lifetime = MISSILE_LIFETIME
	contact_radius = 0.5
	damage_type = data.get("damage_type", GameConsts.DamageType.PHYSICAL)
	super(data, is_host)


func _ready() -> void:
	_scene_root = get_tree().current_scene

	_orient_to_direction()

	var color: Color = GameConsts.DAMAGE_TYPE_COLORS.get(damage_type, PLAIN_COLOR)

	var sprite := _create_sprite("sprites/flare6.spr")
	if sprite and sprite.material_override is BaseMaterial3D:
		(sprite.material_override as BaseMaterial3D).albedo_color = color

	_create_light(color)

	# Head stays white — a missile reads as a bright bolt however it is dressed — and the tail is
	# the damage type, which for the plain one is the light blue it always was.
	_create_trail([
		Color(1.0, 1.0, 1.0, 1.0),
		Color(color.r, color.g, color.b, 0.9),
		Color(color.r * 0.6, color.g * 0.6, color.b * 0.6, 0.5),
		Color(color.r * 0.3, color.g * 0.3, color.b * 0.3, 0.0),
	], 0.08, 0.25)

	if _is_host:
		_register_entity({
			"script_path": "res://src/projectiles/magic_missile.gd",
			"position": position,
			"direction": direction,
			"speed": speed,
			"lifetime": lifetime,
			"damage_type": damage_type,
		})


func _on_world_hit(result: Dictionary) -> void:
	_hit_target(result.collider)


func _on_actor_hit(victim) -> void:
	_hit_target(victim)


func _hit_target(collider) -> void:
	Combat.damage_chain(collider, MISSILE_DAMAGE, damage_type, owner_node)

	SoundSystem.play_3d("weapons/xbow_hitbod1.wav", global_position)

	_die()
