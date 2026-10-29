class_name ChargeBehavior
extends RefCounted

## Server-authoritative charge state for charging weapons (Spot Bolt). The server owns the
## timer, decides the overcharge backfire, and derives the fired strength from `time` — the
## client's local charge is purely predictive. Held by Player as `charge`.

## -1 means no charge is in progress.
var weapon_idx := -1
var time := 0.0

var _host: Node3D


func initialize(host: Node3D) -> void:
	_host = host


## Server: begin charging a charging weapon, on the command that pressed attack. Validates the slot
## and mana before arming the timer; false = refused.
func begin(idx: int) -> bool:
	if _host.is_dead or idx < 0 or idx >= _host.weapons.size():
		return false
	var charging_weapon: Weapon = _host.weapon_at(idx)
	if charging_weapon == null or not charging_weapon.supports_charging:
		return false
	if charging_weapon.mana_cost > 0.0 and _host.mana < charging_weapon.mana_cost:
		return false
	time = 0.0
	weapon_idx = idx
	return true


func clear() -> void:
	time = 0.0
	weapon_idx = -1


## Server: advance the charge timer and fire the overcharge backfire when it runs long.
## Cancels itself if the player dies or switches away from the charging weapon.
## Called per input command, with its msec (RemotePlayer.fire_frame).
func tick(delta: float) -> void:
	if weapon_idx == -1:
		return
	# Cancelled by death or a weapon switch (a release goes through FireControl instead).
	if _host.is_dead or weapon_idx != _host.current_weapon_idx:
		clear()
		return
	var charging_weapon: Weapon = _host.weapon_at(weapon_idx)
	if charging_weapon == null or not charging_weapon.supports_charging:
		clear()
		return
	# The clock always advances (charge_percent_at reads it); overcharge_time() == 0
	# just means this weapon never backfires.
	time += delta
	var overcharge := charging_weapon.overcharge_time()
	if overcharge > 0.0 and time >= overcharge:
		clear()
		_host.take_damage(charging_weapon.backfire_damage(),
			charging_weapon.backfire_damage_type(), _host)
