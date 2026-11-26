class_name WindWall
extends Node3D

## Windwall — the air a held windwall spell blows out of the caster's hands: a cone down their aim
## that shoves enemies, their spells in flight, corpses and sparks away (WeatherSystem.airflow),
## and spares the caster and their allies. Dust rides it (OvercastDustCone).
##
## Not a networked entity. Like a ray's beam it hangs off the caster on every peer, posed by their
## aim there, from the weapon's fire() to its stop_firing(). Each peer has the air of one per
## caster: the server the authoritative one, a client every one it sees, so the wizard it predicts
## is blown as the server blows it.

const LENGTH := 9.0
const START := 0.6           # m ahead of the eye
const START_RADIUS := 0.75
const END_RADIUS := 4.0
const SPREAD := (END_RADIUS - START_RADIUS) / LENGTH
## The air's speed (m/s) at the mouth and at the end; it fades over the outer EDGE of the radius.
const AIR_NEAR := 40.0
const AIR_FAR := 20.0
const EDGE := 0.3
const DUST_MOTES := 1500
const SOUND := "spells/combos/tornado_spin.wav"
const SOUND_RANGE := 25.0

var caster: Node3D
var _blows := false
var _dust: OvercastDustCone
var _sound: AudioStreamPlayer3D
var _origin := Vector3.ZERO
var _axis := Vector3.FORWARD
var _front := 0.0
var _reach := LENGTH
var _stopped := false


## `blows`: this peer feels its air. `drawn`: this peer shows its dust and plays its sound.
func _init(who: Node3D, blows: bool, drawn: bool) -> void:
	caster = who
	_blows = blows
	name = "WindWall"
	top_level = true
	if drawn:
		_dust = OvercastDustCone.new()
		_dust.length = LENGTH
		_dust.start_radius = START_RADIUS
		_dust.end_radius = END_RADIUS
		_dust.speed = AIR_NEAR
		_dust.motes = DUST_MOTES
		_dust.blown_out.connect(queue_free)
		add_child(_dust)


func _ready() -> void:
	if _blows:
		add_to_group(WeatherSystem.WIND_SOURCES)
	_follow()
	if _dust:
		_dust.blowing = true
		_sound = SoundSystem.spawn_on(self, SOUND, true, SOUND_RANGE)
		if _sound:
			_sound.pitch_scale = 1.4
	elif not _blows:
		queue_free()


func is_blowing() -> bool:
	return not _stopped


## The hold ended: the air stops now, the dust runs off the end, then it is gone.
func stop() -> void:
	if _stopped:
		return
	_stopped = true
	remove_from_group(WeatherSystem.WIND_SOURCES)
	if _sound:
		_sound.queue_free()
		_sound = null
	if _dust and is_inside_tree():
		_dust.blowing = false
	else:
		queue_free()


func _physics_process(delta: float) -> void:
	if not is_instance_valid(caster) or not caster.is_inside_tree():
		stop()
		return
	if _stopped:
		return
	_follow()
	_front = minf(_front + AIR_NEAR * delta, LENGTH)
	var ray := Combat.raycast_world(caster, _origin, _axis, LENGTH, caster.get_rid(),
			GameConsts.MASK_WORLD | GameConsts.MASK_CLIP)
	_reach = LENGTH if ray.result.is_empty() else _origin.distance_to(ray.impact_pos)


func _process(_delta: float) -> void:
	if _dust == null or not is_instance_valid(caster):
		return
	_follow()
	_dust.reach = _reach
	if AssetLoader.light_grid:
		_dust.light = AssetLoader.light_grid.sample(_origin + _axis * (LENGTH * 0.3)).srgb_to_linear()


func _follow() -> void:
	if not is_instance_valid(caster) or not caster.is_inside_tree():
		return
	var aim := Combat.get_aim(caster)
	_axis = (aim.aim_dir as Vector3).normalized()
	_origin = (aim.from as Vector3) + _axis * START
	var up := Vector3.UP if absf(_axis.y) < 0.99 else Vector3.FORWARD
	global_transform = Transform3D(Basis.looking_at(_axis, up), _origin)


## The air it moves at `p` (m/s) on `who`: down the cone and spreading with it, strongest at the
## mouth and on its middle, none past what stands in its way. None on the caster or their allies.
func airflow(p: Vector3, who: Node = null) -> Vector3:
	if _stopped or not is_instance_valid(caster):
		return Vector3.ZERO
	if who != null and (who == caster or Teams.summon_spares(int(caster.get("team")), caster, who)):
		return Vector3.ZERO
	var rel := p - _origin
	var d := rel.dot(_axis)
	if d < 0.0 or d > minf(_front, _reach):
		return Vector3.ZERO
	var radial := rel - _axis * d
	var r := radial.length()
	var radius := START_RADIUS + SPREAD * d
	if r >= radius:
		return Vector3.ZERO
	var edge := smoothstep(0.0, EDGE, (radius - r) / radius)
	var end := clampf(minf(_front, _reach) - d, 0.0, 1.0)
	var speed := lerpf(AIR_NEAR, AIR_FAR, d / LENGTH) * edge * end
	return (_axis + radial * (SPREAD / radius)).normalized() * speed
