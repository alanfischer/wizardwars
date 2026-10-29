class_name FireControl
extends RefCounted

## The trigger, stepped once per input command. The server fires off it as it plays a player's
## commands, and the shooter's own view steps the same commands to predict those shots' sound and
## hand animation. Cooldowns count the commands' msec, as GoldSrc's m_flNextPrimaryAttack did, so
## both ends fire on the same command however the packets carrying them were spaced.
##
## step() decides; the shooter (LocalPlayer, RemotePlayer) acts:
##   shoot(cmd, secondary, charge_percent) -> Shot   one shot of the current weapon, for cmd
##   begin_charge() -> bool                     start charging; false = refused
##   release_charge() -> float                  the charge to fire with; < 0 = none in progress
##   stop_fire()                                a repeating weapon's hold ended

const InputCommand = preload("res://addons/pmove/input_command.gd")

const ATTACK := 1
const ATTACK2 := 2
## The command carries a hand's aim (VR hand tracking) rather than aiming along its view.
const HAND_AIM := 4

enum Shot {
	FIRED,
	REFUSED,  ## nothing happened
	DENIED,   ## short of mana: a repeating hold ends until a fresh press
	WARNED,   ## a warning press (confirm-before-destroy): the next press goes straight through
}

## The trigger's command-stream fields, coded after pmove's. shot_ms and the aim change every
## command while firing; buttons and weapon only on a press or a switch.
const FIELDS := {
	"shot_ms": {"type": TYPE_INT},
	"aim_yaw": {"type": TYPE_INT},
	"aim_pitch": {"type": TYPE_INT},
	"aim_x": {"type": TYPE_FLOAT},
	"aim_y": {"type": TYPE_FLOAT},
	"aim_z": {"type": TYPE_FLOAT},
	"buttons": {"type": TYPE_INT},
	"weapon": {"type": TYPE_INT},
}



## What one command asks of the trigger. Rides the command as its "fire" meta.
class TriggerInput:
	var buttons := 0
	## The slot switched to on this command (GoldSrc's usercmd weaponselect); -1 = none.
	var weapon_select := -1
	## The shooter's render time in the server clock (NetworkManager.shot_time_ms), for lag
	## compensation. Sent only while a button is down or just came up; 0 = none.
	var shot_ms := 0
	## With HAND_AIM: where the hand aims from and along.
	var aim_from := Vector3.INF
	var aim_dir := Vector3.ZERO


static var _no_input := TriggerInput.new()  # what a command without one reads as; never written

var buttons := 0  ## the last command's
var cooldown_ms := 0
var auto_firing := false
var charging := false
## The server makes a secondary wait out the cooldown as well, so a client can't spam a secondary
## with authoritative effects (clone). The shooter's view doesn't: a zoom toggle mid-cooldown works.
var secondary_waits := false


func step(cmd, shooter, weapon: Weapon) -> void:
	var held := input_of(cmd).buttons & (ATTACK | ATTACK2)
	var pressed := held & ~buttons
	var released := buttons & ~held
	buttons = held
	cooldown_ms = maxi(cooldown_ms - msec_of(cmd), 0)
	if weapon == null:
		return
	if pressed & ATTACK:
		if weapon.supports_charging:
			charging = cooldown_ms == 0 and shooter.begin_charge()
		else:
			auto_firing = weapon.auto_repeat
			_shoot(cmd, shooter, weapon, false, 0.0)
	elif held & ATTACK and auto_firing:
		_shoot(cmd, shooter, weapon, false, 0.0)
	elif released & ATTACK:
		if auto_firing:
			end_hold(shooter)
		elif charging:
			charging = false
			var charge_percent: float = shooter.release_charge()
			if charge_percent >= 0.0:
				_shoot(cmd, shooter, weapon, false, charge_percent, true)
	if pressed & ATTACK2:
		_shoot(cmd, shooter, weapon, true, 0.0)


## Ends what the trigger was doing. A button still down has to come up and go down again.
func reset() -> void:
	cooldown_ms = 0
	auto_firing = false
	charging = false


## As reset(), for a shooter whose commands stop (death): a button down in the first command after
## counts as a fresh press, on both ends.
func clear() -> void:
	reset()
	buttons = 0


## A repeating weapon's hold ends: out of mana, a warning, or the button let go.
func end_hold(shooter) -> void:
	if auto_firing:
		auto_firing = false
		shooter.stop_fire()


## The weapon can't fire again for its cooldown (a shot, or a charge that backfired).
func start_cooldown(weapon: Weapon) -> void:
	cooldown_ms = roundi(weapon.cooldown * 1000.0)


func _shoot(cmd, shooter, weapon: Weapon, secondary: bool, charge_percent: float, released := false) -> void:
	if cooldown_ms > 0 and not released and (secondary_waits or not secondary):
		return
	shooter.shot_seq = cmd.seq
	var shot: int = shooter.shoot(cmd, secondary, charge_percent)
	shooter.shot_seq = 0
	match shot:
		Shot.FIRED:
			start_cooldown(weapon)
		Shot.DENIED:
			end_hold(shooter)
		Shot.WARNED:
			cooldown_ms = 0
			end_hold(shooter)


## The command's msec as the server plays it (ServerMovement clamps a long one).
static func msec_of(cmd) -> int:
	return mini(roundi(cmd.delta * 1000.0), roundi(ServerMovement.MAX_CMD_DELTA * 1000.0))


static func input_of(cmd) -> TriggerInput:
	return cmd.get_meta(&"fire", _no_input)


## The way a command looks: its yaw and pitch, as the shooter's eye camera points.
static func view_dir(cmd) -> Vector3:
	return _dir(cmd.pitch, cmd.yaw)


static func _dir(pitch: float, yaw: float) -> Vector3:
	return Basis.from_euler(Vector3(pitch, yaw, 0.0)) * Vector3.FORWARD


# --- Wire ---

## The command stream's field table: pmove's, then the trigger's.
static func command_field_table() -> Dictionary:
	return InputCommand.FIELDS.merged(FIELDS)


static func command_fields(cmd) -> Dictionary:
	var f: Dictionary = cmd.to_fields()
	var input := input_of(cmd)
	var aim := Vector3.ZERO
	var aim_yaw := 0
	var aim_pitch := 0
	if input.buttons & HAND_AIM:
		aim = input.aim_from
		var dir := input.aim_dir.normalized()
		aim_yaw = InputCommand._angle_to(atan2(-dir.x, -dir.z))
		aim_pitch = InputCommand._angle_to(asin(clampf(dir.y, -1.0, 1.0)))
	f["shot_ms"] = input.shot_ms
	f["aim_yaw"] = aim_yaw
	f["aim_pitch"] = aim_pitch
	f["aim_x"] = aim.x
	f["aim_y"] = aim.y
	f["aim_z"] = aim.z
	f["buttons"] = input.buttons
	f["weapon"] = input.weapon_select + 1
	return f


## A command rebuilt from command_fields(), its trigger input attached. Null if a field is missing.
static func command_from_fields(f: Dictionary) -> RefCounted:
	var cmd = InputCommand.from_fields(f)
	if cmd == null:
		return null
	for field: String in FIELDS:
		if not f.has(field):
			return null
	var input := TriggerInput.new()
	input.buttons = int(f["buttons"]) & (ATTACK | ATTACK2 | HAND_AIM)
	input.weapon_select = int(f["weapon"]) - 1
	input.shot_ms = int(f["shot_ms"])
	if input.buttons & HAND_AIM:
		input.aim_from = Vector3(float(f["aim_x"]), float(f["aim_y"]), float(f["aim_z"]))
		input.aim_dir = _dir(InputCommand._angle_from(clampi(int(f["aim_pitch"]), -32767, 32767)),
				InputCommand._angle_from(clampi(int(f["aim_yaw"]), -32767, 32767)))
		if not input.aim_from.is_finite():
			input.buttons &= ~HAND_AIM
	cmd.set_meta(&"fire", input)
	return cmd

