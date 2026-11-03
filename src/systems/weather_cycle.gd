class_name WeatherCycle
extends Node
## The `dynamic_weather` server var: showers come and go on their own, each a few minutes of rain
## that swells, wanders and dies away. Runs on the authority and only writes the `rain` var, which
## carries it to every client and to anyone joining mid-shower.

## Dry spell between showers, and how long one lasts (s).
const DRY := Vector2(240.0, 600.0)
const SHOWER := Vector2(90.0, 240.0)
## Peak rain a shower can reach, weighted toward the light end: a downpour is the rare one.
const PEAK := Vector2(0.1, 1.0)
## Seconds a shower takes to build and to die away.
const RAMP := 30.0
## How far the rain wanders below its peak mid-shower.
const WANDER := 0.4
## Rain written to the var in these steps, and no more often than this: each write is a reliable
## message to every client.
const STEP := 0.02
const SEND_INTERVAL := 0.5

var _rng := RandomNumberGenerator.new()
var _noise := FastNoiseLite.new()
var _t := 0.0
var _start := 0.0
var _end := 0.0
var _peak := 0.0
var _sent := -1.0
var _since_send := 0.0


func _init(rng_seed: int = 0) -> void:
	if rng_seed != 0:
		_rng.seed = rng_seed
	else:
		_rng.randomize()
	_noise.seed = _rng.randi()
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.frequency = 1.0 / 40.0
	_plan(0.0)


func _ready() -> void:
	ServerVars.value_changed.connect(_on_server_var_changed)
	set_process(bool(ServerVars.get_value("dynamic_weather", false)))


## The next shower, after a dry spell from `after`. The first comes sooner, so turning it on shows.
func _plan(after: float) -> void:
	var dry := _rng.randf_range(DRY.x, DRY.y) * (0.25 if after == 0.0 else 1.0)
	_start = after + dry
	_end = _start + _rng.randf_range(SHOWER.x, SHOWER.y)
	_peak = lerpf(PEAK.x, PEAK.y, pow(_rng.randf(), 2.0))


## Rain at `t` seconds into the cycle: 0 between showers. Times must not go backwards.
func rain_at(t: float) -> float:
	if t >= _end:
		_plan(_end)
	if t <= _start:
		return 0.0
	var envelope := smoothstep(0.0, RAMP, t - _start) * smoothstep(0.0, RAMP, _end - t)
	var wander := 1.0 - WANDER * (0.5 + 0.5 * _noise.get_noise_1d(t))
	return maxf(_peak * envelope * wander, 0.01)


func _process(delta: float) -> void:
	if not NetworkManager.is_authority():
		return
	_t += delta
	_since_send += delta
	var rain := rain_at(_t)
	var q := 0.0 if rain <= 0.0 else maxf(snappedf(rain, STEP), 0.01)
	if q == _sent or (_since_send < SEND_INTERVAL and q > 0.0 and _sent > 0.0):
		return
	_sent = q
	_since_send = 0.0
	ServerVars.set_from_string("rain", str(q))


func _on_server_var_changed(key: String, value: Variant) -> void:
	if not NetworkManager.is_authority():
		return
	if key == "rain":
		# Rain it did not write (/rain, the slider) is someone taking the weather over by hand.
		if is_processing() and absf(float(value) - _sent) > 0.001:
			_sent = -1.0  # theirs now, so turning off leaves it be
			ServerVars.set_from_string("dynamic_weather", "off")
		return
	if key != "dynamic_weather":
		return
	set_process(bool(value))
	var was_raining := _sent > 0.0
	_sent = -1.0
	if bool(value):
		_t = 0.0
		_plan(0.0)
	elif was_raining:
		ServerVars.set_from_string("rain", "0")
