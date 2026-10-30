class_name MindMissile
extends Projectile

## Mind missile — what Ice and Wind cast instead of the magic missile. Slower and dearer for
## twice the damage, and it does two things the plain missile doesn't: it rocks the view of
## whoever it hits, and it presses whatever it lands on, so those two classes work a button or
## a door from across a room (proj_mindmissle, projectiles.cpp).

const MISSILE_SPEED := 40.0     # 1200 GS, against the magic missile's 1500
const MISSILE_DAMAGE := 30.0
const MISSILE_LIFETIME := 5.0
const PUNCH_ROLL := 20.0        # degrees either way, as GoldSrc's own RANDOM_FLOAT(-20,20)
const SPRITE := "sprites/xspark1.spr"
const HIT_SOUND := "weapons/xbow_hitbod1.wav"


func setup(data: Dictionary, is_host := true) -> void:
	speed = MISSILE_SPEED
	lifetime = MISSILE_LIFETIME
	contact_radius = 0.5
	super(data, is_host)


func _ready() -> void:
	_scene_root = get_tree().current_scene

	_orient_to_direction()

	_create_sprite(SPRITE)

	_create_light(Color(0.8, 0.5, 1.0))

	_create_trail([
		Color(1.0, 1.0, 1.0, 1.0),   # head: white
		Color(0.8, 0.5, 1.0, 0.9),   # violet
		Color(0.5, 0.2, 0.8, 0.5),
		Color(0.2, 0.0, 0.4, 0.0),   # dark violet, faded
	], 0.08, 0.25)


func _on_world_hit(result: Dictionary) -> void:
	_hit_target(result.collider)


func _on_actor_hit(victim) -> void:
	_hit_target(victim)


func _hit_target(collider) -> void:
	var target := Combat.damage_chain(collider, MISSILE_DAMAGE, GameConsts.DamageType.PHYSICAL,
		owner_node, global_position)
	# The original punches whatever it touches; sparing allies keeps it from being a
	# way to rock a teammate's aim in a game that has no friendly fire to answer with.
	if target != null and not Teams.nodes_friendly(owner_node, target):
		NetworkManager.send_view_punch(target, randf_range(-PUNCH_ROLL, PUNCH_ROLL))

	_press(collider)

	SoundSystem.play_3d(HIT_SOUND, global_position)

	_die()


## The reach the spell is really for: the missile works whatever it hit as if its caster had
## walked up and pressed it. Same walk up the parents as a player's own +use, so a shape child
## or a plain wall in front of a button is climbed past rather than stopped on.
func _press(collider: Node) -> void:
	var node: Node = collider
	while node:
		if GoldSrcEntity.is_player_usable(node) and node.has_method("trigger"):
			node.trigger(owner_node, TriggerSystem.Type.TOGGLE)
			return
		node = node.get_parent()
