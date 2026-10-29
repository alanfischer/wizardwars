class_name InvisibilityWeapon
extends Weapon

## Invisibility — hold attack to fade invisible; speed affects visibility (still = fully
## invisible, full sprint = 50% visible). Releasing or running out of mana restores it.

const MANA_COST := 8.0
const MANA_DRAIN := 2.5

var _invisible := false


func _init() -> void:
	auto_repeat = true
	cooldown = 0.1
	mana_cost = MANA_COST
	mana_drain = MANA_DRAIN
	weapon_name = "Invisibility"


func precache() -> void:
	SoundSystem.precache("spells/icepoke.wav")


func play_attack_anim(anim_player: AnimationPlayer) -> void:
	if not anim_player:
		return
	var anim := hand_attack_anims[0] if hand_attack_anims.size() > 0 else ""
	if anim.is_empty() or not anim_player.has_animation(anim):
		return
	if anim_player.current_animation == anim:
		return  # already playing
	var anim_res := anim_player.get_animation(anim)
	anim_res.loop_mode = Animation.LOOP_LINEAR
	anim_player.play(anim)


func fire(attacker: Node3D, _aim_from: Vector3 = Vector3.INF, _aim_dir: Vector3 = Vector3.ZERO, _charge_percent: float = 0.0, secondary: bool = false) -> bool:
	if secondary:
		return false
	if not _invisible:
		_start_invisible(attacker)
	_fire_tail(attacker)
	return true


func stop_firing(attacker: Node3D, _secondary: bool = false) -> void:
	_auto_anim_held = false
	_stop_invisible(attacker)


func cleanup(attacker: Node3D) -> void:
	_stop_invisible(attacker)


func _start_invisible(attacker: Node3D) -> void:
	_invisible = true
	SoundSystem.spawn_on(attacker, "spells/icepoke.wav")
	if attacker.has_method("start_invisibility"):
		attacker.start_invisibility()


func _stop_invisible(attacker: Node3D) -> void:
	if not _invisible:
		return
	_invisible = false
	if attacker.has_method("stop_invisibility"):
		attacker.stop_invisibility()
	var anim_player: AnimationPlayer = attacker.get("_hand_anim_player")
	if anim_player and anim_player.has_animation(hand_idle_anim):
		anim_player.play(hand_idle_anim)
