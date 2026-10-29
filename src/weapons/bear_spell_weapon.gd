class_name BearSpellWeapon
extends Weapon

func _init() -> void:
	element = GameConsts.Element.EARTH
	# hand_model_path/hand_idle_anim/mana_cost set by the caller (differ by wizard vs bear form)
	cooldown = 0.5


func fire(attacker: Node3D, _aim_from: Vector3 = Vector3.INF, _aim_dir: Vector3 = Vector3.ZERO, _charge: float = 0.0, secondary: bool = false) -> bool:
	if secondary:
		return false
	if attacker.has_method("toggle_bear_form"):
		attacker.toggle_bear_form()
		return true
	if attacker.has_method("client_bear_morph"):
		attacker.client_bear_morph()
	return true


func precache() -> void:
	SoundSystem.precache("spells/bearmorph.wav")
	AssetLoader.precache_model("models/hands/bear.mdl")
	AssetLoader.precache_model("models/player/bear.mdl")
	# not in the standard wizard loadout, so precache it explicitly
	BearBiteWeapon.new().precache()
