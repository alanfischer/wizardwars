class_name CloneWeapon
extends Weapon

## Aeromancer 5th spell — deflects the caster ±45° and spawns a decoy drifting the mirror
## direction, so caster and clone diverge 90° from the original path. Requires grounded + MIN_SPEED.

const MIN_SPEED := 5.0      # 200 GS units * scale
const DEFLECT_DEG := 45.0
const COOLDOWN := 3.0
const MANA_COST := 15.0


func _init() -> void:
	cooldown = COOLDOWN
	mana_cost = MANA_COST
	weapon_name = "Clone"


func precache() -> void:
	AssetLoader.precache_model("models/player/wind.mdl")
	AssetLoader.precache_model("models/staves/wind.mdl")
	SoundSystem.precache("spells/updraft_cast.wav")


func play_attack_sound(attacker: Node3D) -> void:
	SoundSystem.spawn_on(attacker, "spells/updraft_cast.wav")


func can_fire(attacker: Node3D, _aim_dir: Vector3 = Vector3.ZERO) -> bool:
	if not NetworkManager.is_authoritative_fire(attacker):
		return true  # server is authoritative; client always sends the request
	var grounded = attacker.get("grounded")
	if grounded != null and not grounded:
		return false
	if attacker is CharacterBody3D:
		var vel: Vector3 = (attacker as CharacterBody3D).velocity
		if Vector2(vel.x, vel.z).length() < MIN_SPEED:
			return false
	return true


## primary: caster left, clone right. secondary: mirrored.
func fire(attacker: Node3D, _aim_from: Vector3 = Vector3.INF, _aim_dir: Vector3 = Vector3.ZERO, _charge_percent: float = 0.0, secondary: bool = false) -> bool:
	if attacker is CharacterBody3D:
		var body := attacker as CharacterBody3D
		var vel := body.velocity
		var flat_vel := Vector3(vel.x, 0.0, vel.z)
		var flat_speed := flat_vel.length()
		var original_dir := flat_vel.normalized()

		# positive rotation = left (CCW from above); secondary inverts it
		var deflect_sign := -1.0 if secondary else 1.0
		var deflect_rad := deg_to_rad(DEFLECT_DEG * deflect_sign)

		var player_dir := original_dir.rotated(Vector3.UP, deflect_rad)
		var clone_dir := original_dir.rotated(Vector3.UP, -deflect_rad)

		body.velocity = player_dir * flat_speed
		body.velocity.y = vel.y

		if NetworkManager.is_authoritative_fire(attacker):
			var wizard := Wizard.create(attacker.element)
			var staff_path := ""
			if attacker.weapons.size() > 0 and attacker.weapons[0] is Staff:
				staff_path = attacker.weapons[0].staff_model_path

			NetworkManager.spawn_dynamic_entity({
				"script_path": "res://src/effects/wizard_clone.gd",
				"position": attacker.global_position,
				"direction": clone_dir,
				"speed": flat_speed,
				"model_path": wizard.player_model_path,
				"staff_path": staff_path,
				"team": attacker.get("team"),
			})

	_fire_tail(attacker)
	return true
