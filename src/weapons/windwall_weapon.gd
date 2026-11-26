class_name WindwallWeapon
extends Weapon

## Windwall — held, it blows a cone of wind out of the caster's hands (WindWall) that shoves
## enemies and their spells away and spares the caster's side.
##
## Like the other combo spells the book is the cost, not mana: it holds BLOWING seconds of wind,
## spent while the trigger is held, and once they run out the spell leaves the loadout.

const BLOWING := 8.0
const COOLDOWN := 0.1

var _wall: WindWall
var _left_ms := roundi(BLOWING * 1000.0)


func _init() -> void:
	auto_repeat = true
	sustained = true
	cooldown = COOLDOWN


func precache() -> void:
	SoundSystem.precache(WindWall.SOUND)


func can_fire(_attacker: Node3D, _aim_dir: Vector3 = Vector3.ZERO) -> bool:
	return _left_ms > 0


## Each repeat of the held trigger keeps the wind up and spends a repeat's worth of the book. An
## observer gets one call for the whole hold.
func fire(attacker: Node3D, _aim_from: Vector3 = Vector3.INF, _aim_dir: Vector3 = Vector3.ZERO, _charge_percent: float = 0.0, secondary: bool = false) -> bool:
	if secondary or _left_ms <= 0:
		return false
	var authoritative := NetworkManager.is_authoritative_fire(attacker)
	if not (is_instance_valid(_wall) and _wall.is_blowing()):
		var blows := authoritative or not NetworkManager.is_authority()
		var drawn := _fire_cosmetics(attacker)
		if blows or drawn:
			_wall = WindWall.new(attacker, blows, drawn)
			attacker.add_child(_wall)
		_fire_tail(attacker)
	_left_ms -= roundi(cooldown * 1000.0)
	if _left_ms <= 0:
		_end(attacker)
		if authoritative and attacker.has_method("revoke_weapon"):
			attacker.call_deferred(&"revoke_weapon", SpawnRegistry.name_for(get_script()))
	return true


func stop_firing(attacker: Node3D, secondary: bool = false) -> void:
	super(attacker, secondary)
	_end(attacker)


func cleanup(attacker: Node3D) -> void:
	_end(attacker)


func _end(_attacker: Node3D) -> void:
	if is_instance_valid(_wall):
		_wall.stop()
	_wall = null
