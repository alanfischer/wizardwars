class_name Staff
extends Weapon

@export var staff_model_path := ""
@export var melee_damage := 30.0
@export var melee_range := 64.0 * GameConsts.SCALE_FACTOR  # 1.6m — GoldSrc units * scale

const COMBO_HITS := 5  # clashes each partner must land before the spell drops
const CLASH_SOUNDS := ["spells/staff_combo1.wav", "spells/staff_combo2.wav"]


func precache() -> void:
	for s in ["spells/staff_hitbod1.wav", "spells/staff_hitbod2.wav",
			"spells/staff_hitbod3.wav", "spells/staff_miss1.wav"] + CLASH_SOUNDS:
		SoundSystem.precache(s)


func fire(attacker: Node3D, aim_from: Vector3 = Vector3.INF, aim_dir: Vector3 = Vector3.ZERO, _charge_percent: float = 0.0, _secondary: bool = false) -> bool:
	if _secondary:
		return false
	var anim_player: AnimationPlayer = attacker.get("_hand_anim_player")
	var aim := Combat.get_aim(attacker, aim_from, aim_dir)
	# all peers trace for hit anim; only authority deals damage
	var hit := false
	var ray := Combat.raycast_world(attacker, aim.from, aim.aim_dir, melee_range, attacker.get_rid(), GameConsts.MASK_MELEE)
	if not ray.result.is_empty():
		hit = true
		if NetworkManager.is_authoritative_fire(attacker):
			var target := Combat.find_damageable(ray.result.collider)
			if target != null and not _combo_swing(attacker, target):
				target.take_damage(melee_damage, GameConsts.DamageType.PHYSICAL, attacker)
	# authority-only decal to avoid each peer spawning its own copy
	if hit and not ray.result.is_empty() and NetworkManager.is_authoritative_fire(attacker):
		var collider = ray.result.collider
		if collider is StaticBody3D:
			if Game.decal_system:
				var decal_name := "{shot%d" % (randi() % 4 + 1)
				Game.decal_system.place_rpc.rpc(decal_name, ray.result.position, ray.result.normal, 1.0, collider.get_path())
	# Swing cosmetics are the LocalPlayer view's job (it traced its own hit); the host's own body
	# puppet fires the real swing but stays silent, or every hit is heard twice.
	if _fire_cosmetics(attacker):
		if hit:
			var hit_sounds := ["spells/staff_hitbod1.wav", "spells/staff_hitbod2.wav", "spells/staff_hitbod3.wav"]
			SoundSystem.spawn_on(attacker, hit_sounds[randi() % hit_sounds.size()])
		else:
			SoundSystem.spawn_on(attacker, "spells/staff_miss1.wav")
		if anim_player:
			var anim: String
			if hit and hand_hit_anims.size() > 0:
				anim = get_hand_hit_anim()
			else:
				anim = get_hand_attack_anim()
			if anim_player.has_animation(anim):
				var anim_res := anim_player.get_animation(anim)
				anim_res.loop_mode = Animation.LOOP_NONE
				anim_player.stop()
				anim_player.play(anim)
	return true


## Host only. Two allied wizards beating their staves together, the way the original mod did it:
## a clash costs the swing its damage, and once BOTH partners have landed more than COMBO_HITS
## the swinger takes the spell. They're then locked out for the rest of the life (-1) while the
## partner goes back to zero, free to earn one of their own with somebody else. Any staff hit
## that isn't a clash drops the charge. Returns true when the swing was spent on a clash.
func _combo_swing(attacker: Node3D, target: Node) -> bool:
	var a := attacker as Player
	if a == null:
		return false
	var key := _clash_recipe(a, target)
	if key.is_empty():
		if a.combo_hits >= 0:
			a.combo_hits = 0
		return false
	if not bool(ServerVars.get_value("allow_combos", true)):
		CommandSystem.notify_peer(a.peer_id, "Combo spells are off on this server.")
		return false
	var b := target as Player
	# Either of them already holding their prize ends it: the swing lands as an ordinary hit.
	if a.combo_hits < 0 or b.combo_hits < 0:
		return false
	# play_3d, not spawn_on: the clash is decided on the host alone, and a puppet the host has
	# hidden would swallow a sound parented to it.
	SoundSystem.play_3d(CLASH_SOUNDS[randi() % CLASH_SOUNDS.size()], a.global_position)
	a.combo_hits += 1
	if a.combo_hits > COMBO_HITS and b.combo_hits > COMBO_HITS:
		a.combo_hits = -1
		b.combo_hits = 0
		if a.grant_weapon(key):
			var w := SpawnRegistry.build_weapon(key, a.element)
			CommandSystem.notify_peer(a.peer_id,
				"Your staves spark: you have learned %s!" % (w.get_display_name() if w else key))
	return true


## The spell this swing works toward, or "" when it isn't a clash at all: the target has to be a
## living ally holding their own staff, and the two elements have to make something together.
func _clash_recipe(a: Player, target: Node) -> String:
	var b := target as Player
	if b == null or b.is_dead or Teams.is_same_player(a, b):
		return ""
	if a.team == GameConsts.Team.NONE or a.team != b.team:
		return ""
	if not (b.weapon_at(b.current_weapon_idx) is Staff):
		return ""
	return GameConsts.combo_for(a.element, b.element)
