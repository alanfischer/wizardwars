class_name Meteor
extends Projectile

## Meteor — one of the three the Wizard Wars combo spell "weapon_meteorspell" calls down. Each is
## locked to the wizard it was called on from the moment it is spawned, 51 m out, and there is no
## losing it: it noclips through the map the whole way in and steers every tenth of a second.
##
## What is fixed is the arrival, not the speed. All three are called on the same tick from the same
## distance out, so all three work to the same clock, and each trims its own speed to the gap it has
## left — run from one and it opens up, run into another and it holds back. The strike lands as one
## blow however the target moves.
##
## What it buys the victim is the couple of seconds it takes to cross that distance. A meteor is not
## something you dodge, it is something you see coming — three blue smoke trails converging on
## you from three directions, and somewhere to be that is not here.

const SCALE := GameConsts.SCALE_FACTOR
const SPEED := 8.0 * 2.5                # sv_maxspeed * METEOR_VELOCITY, doubled — 20 m/s
const DAMAGE := 600.0
const RADIUS := 200.0 * SCALE           # 5 m of blast
const EXPLODE_DISTANCE := 90.0 * SCALE  # 2.25 m — how close it needs to get
const SPAWN_DISTANCE := 2048.0 * SCALE  # 51.2 m out, so about two and a half seconds of warning
## The original had no lifetime: a meteor closes at 20 m/s and cannot be blocked, so it always
## arrives. This is a backstop at several times the trip, not a balance number.
const MAX_LIFETIME := 15.0
## Ceiling on the speed trim, so a target who is launched or teleported away bends the strike
## rather than letting one meteor snap across the map to keep the appointment.
const MAX_CATCHUP := 3.0
## The same glow the comet falls as — a burning point of light reads better for a rock coming
## out of the sky than any model would, and the two spells are the same family.
const SPRITE := "sprites/animglow01.spr"
const SHAKE_AMPLITUDE := 120.0          # GoldSrc units, as NetworkManager.send_screen_shake wants
const SHAKE_RADIUS := 1000.0 * SCALE    # 25 m
const SHAKE_DURATION := 2.0
## The original asked for 1000 shakes/sec, which in GoldSrc drives a sine sampled once a frame.
## Here the frequency is the number of tween steps, so 1000 would build a 2000-step tween per
## meteor — three of them per cast. 40 is as fast as the rattle can actually read.
const SHAKE_FREQUENCY := 40.0

var _target_pos := Vector3.ZERO  # last known, and what clients home nothing on — they just ride
var _target_node: Node3D         # hard lock, host-only: it never loses what it was called on
var _travel_time := 0.0          # the appointment, set from the trip it was given at spawn
var _lead := false               # only the first of a strike carries the deep boom
var _exploded := false


## The lock cannot ride the spawn payload (it is a node, not a value), so callers set it after.
func set_target(node: Node3D) -> void:
	_target_node = node


func setup(data: Dictionary, is_host := true) -> void:
	speed = SPEED
	lifetime = MAX_LIFETIME
	super(data, is_host)
	_target_pos = data.get("target_pos", Vector3.ZERO)
	_lead = data.get("lead", false)
	_travel_time = maxf(position.distance_to(_target_pos) - EXPLODE_DISTANCE, 0.0) / SPEED


func _ready() -> void:
	_scene_root = get_tree().current_scene

	var sprite := AssetLoader.load_sprite_node(SPRITE)
	if sprite:
		sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		sprite.pixel_size = GameConsts.SCALE_FACTOR * 2.5
		sprite.transparent = true
		var mat := AssetLoader.get_sprite_material_template().duplicate()
		if sprite.texture:
			mat.albedo_texture = sprite.texture
		sprite.material_override = mat
		add_child(sprite)

	_create_light(Color(0.5, 0.6, 1.0), 4.0, 7.0)

	# Blue, as the original's beam-follow trail was — the one thing that gives the strike away
	# while it is still a long way off.
	_create_trail([
		Color(0.85, 0.9, 1.0, 1.0),
		Color(0.4, 0.55, 1.0, 1.0),
		Color(0.15, 0.2, 0.7, 0.7),
		Color(0.05, 0.05, 0.3, 0.0),
	], 0.35, 0.6)


func _host_physics(delta: float) -> void:
	_age += delta
	if _age >= MAX_LIFETIME:
		_explode()
		return

	# A target that dies before the meteor lands takes the rest of the strike with it: the others
	# burst wherever they happen to be, which is usually still up in the air. The original did
	# the same, and it is why a called strike is worth calling on someone who cannot leave.
	if is_instance_valid(_target_node) and _target_node.is_inside_tree():
		if _target_node.get("is_dead"):
			_explode()
			return
		_target_pos = SpatialQuery.collision_center(_target_node)
	else:
		_explode()
		return

	var to_target := _target_pos - global_position
	if to_target.length_squared() > 0.0:
		direction = to_target.normalized()
	var gap := to_target.length() - EXPLODE_DISTANCE

	# Whatever speed keeps the appointment the rest of the strike is keeping. A meteor that has
	# been left behind (clamped, or its target launched) flies the remainder flat out instead of
	# bursting in mid-air — the deadline is what the three agree on, not a hard stop.
	var time_left := _travel_time - _age
	speed = clampf(gap / maxf(time_left, delta), 0.0, SPEED * MAX_CATCHUP)
	if time_left <= delta and gap <= speed * delta:
		global_position = _target_pos - direction * EXPLODE_DISTANCE
		_explode()
		return

	# Straight through everything in the way — the original was MOVETYPE_NOCLIP, which is the
	# only reason a meteor spawned 51 m out and often outside the map ever arrives at all.
	global_position += direction * speed * delta


func _explode() -> void:
	var pos := global_position
	_spawn_explosion(pos)

	Combat.apply_aoe_damage(
		get_world_3d().direct_space_state,
		pos, DAMAGE, RADIUS, {},
		GameConsts.DamageType.FIRE, owner_node
	)
	NetworkManager.send_screen_shake(pos, SHAKE_AMPLITUDE, SHAKE_RADIUS, SHAKE_DURATION, SHAKE_FREQUENCY)

	_die()


## Clients reach this through _exit_tree when the despawn arrives, which is why the blast needs
## no event of its own — the same arrangement the comet uses.
func _spawn_explosion(pos: Vector3) -> void:
	if _exploded:
		return
	_exploded = true
	if not is_instance_valid(_scene_root):
		return
	MeteorExplosionEffect.spawn(_scene_root, pos, _lead)


func _exit_tree() -> void:
	_spawn_explosion(global_position)
	_stop_trail()
