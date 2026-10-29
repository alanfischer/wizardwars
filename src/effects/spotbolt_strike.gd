class_name SpotBoltStrike
extends Node3D

## Lightning bolt strike effect — jagged beam from sky to impact point,
## spark particles, light flash, thunder sound. Auto-frees after 2 seconds.

const BEAM_HEIGHT := 50.0
const BEAM_SEGMENTS := 12
const BEAM_JITTER := 0.8  # horizontal offset per segment
const FADE_TIME := 0.5
const BEAM_WIDTH := 0.1

var _effect := EffectBehavior.new()
var _charge_percent := 1.0
var _beam_id := -1
var _noise_fn: Callable


## Summon a single lightning strike as a dynamic entity. Must go through BeamSystem
## (not new()+register_effect) since the beam is parented to the scene root.
static func summon(pos: Vector3, charge_percent: float) -> void:
	NetworkManager.spawn_dynamic_entity({
		"script_path": "res://src/effects/spotbolt_strike.gd",
		"position": pos,
		"charge_percent": charge_percent,
	})


func setup(data: Dictionary, _is_host: bool = false) -> void:
	position = data.get("position", Vector3.ZERO)
	_charge_percent = data.get("charge_percent", 1.0)
	_build()


func _build() -> void:
	_effect.initialize(self)
	_effect.lifetime = 2.0
	_noise_fn = _make_bolt_noise()
	_effect.add_sparks("spotbolt", 48, 0.8, 0.15)
	_effect.add_flash(Color(1.0, 0.95, 0.6), 4.0 + 4.0 * _charge_percent, 8.0, FADE_TIME)
	_effect.add_sound("ambience/thunder.wav", 40.0)


## Fixed per-segment horizontal jitter, sampled by BeamSystem along the bolt.
func _make_bolt_noise() -> Callable:
	var offsets: Array[Vector3] = []
	offsets.resize(BEAM_SEGMENTS + 1)
	offsets[0] = Vector3.ZERO
	offsets[BEAM_SEGMENTS] = Vector3.ZERO
	for i in range(1, BEAM_SEGMENTS):
		offsets[i] = Vector3(
			randf_range(-BEAM_JITTER, BEAM_JITTER),
			0,
			randf_range(-BEAM_JITTER, BEAM_JITTER))
	return func(t: float) -> Vector3:
		return offsets[clampi(int(t * BEAM_SEGMENTS), 0, BEAM_SEGMENTS)]


func _ready() -> void:
	# The beam needs tree access for global_position, so it can't be built in _build().
	var from := global_position
	var to := global_position + Vector3(0, BEAM_HEIGHT, 0)
	_beam_id = BeamSystem.create_oneshot(get_tree().current_scene, from, to, {
		"color": Color(1.0, 1.0, 0.4, 1.0),
		"width": BEAM_WIDTH,
		"segments": BEAM_SEGMENTS,
		"noise_fn": _noise_fn,
		"fade_time": FADE_TIME,
	})
	_effect.start()


func _exit_tree() -> void:
	# Spawner-managed: despawn + tree_exiting hooks handle cleanup; nothing to unregister.
	_effect.entity_id = -1
