class_name BearBiteWeapon
extends Weapon

var melee_damage := 150.0
var melee_range := 48.0 * GameConsts.SCALE_FACTOR  # 1.2 m

const HIT_SOUNDS := [
	"spells/bearbite_hitbod1.wav",
	"spells/bearbite_hitbod2.wav",
	"spells/bearbite_hitbod3.wav",
]
const WALL_SOUND := "spells/bearbite_hitwall.wav"
const MISS_SOUND := "spells/bearbite_miss.wav"


func _init() -> void:
	element = GameConsts.Element.EARTH
	hand_model_path = "models/hands/bear.mdl"
	hand_idle_anim = "biteidle"
	hand_attack_anims.assign(["biteattack"])
	hand_hit_anims.assign(["biteattack"])
	player_attack_prefix = "bearbite"
	cooldown = 1.0


func fire(attacker: Node3D, aim_from: Vector3 = Vector3.INF, aim_dir: Vector3 = Vector3.ZERO, _charge: float = 0.0, secondary: bool = false) -> bool:
	if secondary:
		return false
	var anim_player: AnimationPlayer = attacker.get("_hand_anim_player")
	var aim := Combat.get_aim(attacker, aim_from, aim_dir)

	var ray := Combat.raycast_world(
		attacker, aim.from, aim.aim_dir, melee_range, attacker.get_rid(), GameConsts.MASK_MELEE)
	var hit = not ray.result.is_empty()
	var hit_body =  hit and ray.result.collider is StaticBody3D

	if hit and NetworkManager.is_authoritative_fire(attacker):
		Combat.damage_chain(ray.result.collider, melee_damage, GameConsts.DamageType.PHYSICAL, attacker)

	if hit and not hit_body:
		SoundSystem.spawn_on(attacker, HIT_SOUNDS[randi() % HIT_SOUNDS.size()])
	elif hit_body:
		SoundSystem.spawn_on(attacker, WALL_SOUND)
	else:
		SoundSystem.spawn_on(attacker, MISS_SOUND)

	if anim_player and anim_player.has_animation("biteattack"):
		var anim_res := anim_player.get_animation("biteattack")
		anim_res.loop_mode = Animation.LOOP_NONE
		anim_player.stop()
		anim_player.play("biteattack")
	return true


func precache() -> void:
	for s in HIT_SOUNDS + [WALL_SOUND, MISS_SOUND]:
		SoundSystem.precache(s)
	AssetLoader.precache_model(hand_model_path)
