class_name ThrowingBone
extends Projectile

## What a raised skeleton throws — proj_throwingbone from the WW 1.2 source. Fast, flat and
## cheap: 45 m/s, no gravity, gone on any contact at all.

const SCALE := GameConsts.SCALE_FACTOR
const BONE_SPEED := 1800.0 * SCALE      # THROWINGBONE_VELOCITY — 45 m/s
## THROWINGBONE_DAMAGE was 40, thrown out of HL schedules. This one throws on a clean clock at
## anything it can see, so 40 was a fireball a second from something that never misses.
const DAMAGE := 20.0
## The original had none — it dies on its first touch, and at this speed it always finds one.
## This is a backstop at three times the width of the biggest map.
const BONE_LIFETIME := 3.0
const SPIN := -400.0 * SCALE * 10.0     # pev->avelocity.x, as radians of tumble per second
const MODEL := "models/bone.mdl"
const HIT_SOUND := "weapons/xbow_hitbod1.wav"

var _model: Node3D
var _spent := false


func setup(data: Dictionary, is_host := true) -> void:
	speed = BONE_SPEED
	lifetime = BONE_LIFETIME
	super(data, is_host)


func _ready() -> void:
	_scene_root = get_tree().current_scene
	_model = AssetLoader.load_model(MODEL)
	if _model:
		_model.scale = Vector3(0.5, 0.5, 0.5)
		add_child(_model)
	_orient_to_direction()


## No trail — the bone tumbles instead, the whole way, as the original spun it.
func _update_visuals(delta: float) -> void:
	if is_instance_valid(_model):
		_model.rotate_x(SPIN * delta)


func _on_world_hit(result: Dictionary) -> void:
	_strike(result.collider)


func _on_actor_hit(victim) -> void:
	_strike(victim)


## Anything it touches ends it, whether there was something there to hurt or not.
func _strike(struck: Object) -> void:
	if _spent:
		return
	_spent = true
	if Combat.damage_chain(struck, DAMAGE, GameConsts.DamageType.PHYSICAL, owner_node) != null:
		SoundSystem.play_3d(HIT_SOUND, global_position)
	_die()
