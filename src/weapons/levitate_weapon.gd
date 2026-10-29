class_name LevitateWeapon
extends Weapon

## Levitate — hold attack to float with reduced gravity and air steering; release to drop.

const GRAVITY_SCALE := 0.1
const LIFT_IMPULSE := 5.0  # initial upward push, applied via cmd.custom_flags

const MANA_COST := 5.0
const MANA_DRAIN := 2.0

var _levitating := false
var _levitate_just_started := false


func contribute_input_flags(cmd) -> void:
	if _levitating:
		cmd.custom_flags |= GameConsts.CMF_LEVITATING
		if _levitate_just_started:
			cmd.custom_flags |= GameConsts.CMF_LEVITATE_START
			_levitate_just_started = false


func contribute_modifiers(mods: Movement.MovementModifiers, cmd, _state: Movement.MovementState) -> void:
	if cmd.custom_flags & GameConsts.CMF_LEVITATING:
		mods.gravity_scale = GRAVITY_SCALE
		if cmd.custom_flags & GameConsts.CMF_LEVITATE_START:
			mods.velocity_impulse.y = LIFT_IMPULSE
	else:
		mods.gravity_scale = 1.0


func _init() -> void:
	auto_repeat = true
	# level-triggered via PLAYER_FLAG_FIRING (RemotePlayer._reconcile_firing), not the unreliable
	# sync_stop_attack event — so losing that event or leaving PVS mid-float can't strand LevitateLoop
	sustained = true
	cooldown = 0.1  # fast repeat so fire() runs frequently while held
	mana_cost = MANA_COST
	mana_drain = MANA_DRAIN


func precache() -> void:
	SoundSystem.precache("spells/levitate.wav")


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
	if not _levitating:
		_start_levitate(attacker)
	_fire_tail(attacker)
	return true


func stop_firing(attacker: Node3D, _secondary: bool = false) -> void:
	_auto_anim_held = false
	_stop_levitate(attacker)


func cleanup(attacker: Node3D) -> void:
	_stop_levitate(attacker)


func _start_levitate(attacker: Node3D) -> void:
	_levitating = true
	_levitate_just_started = true
	SoundSystem.spawn_on(attacker, "spells/levitate.wav", true, 20.0, "LevitateLoop")


func _stop_levitate(attacker: Node3D) -> void:
	if not _levitating:
		return
	_levitating = false
	var snd := attacker.get_node_or_null("LevitateLoop")
	if snd:
		snd.queue_free()
	var anim_player: AnimationPlayer = attacker.get("_hand_anim_player")
	if anim_player and anim_player.has_animation(hand_idle_anim):
		anim_player.play(hand_idle_anim)
