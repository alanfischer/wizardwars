class_name WeatherCycle
extends Node
## The `dynamic_weather` server var: showers come and go on their own (OvercastCycle), each a few
## minutes of rain that swells, wanders and dies away. Runs on the authority and only writes the
## `rain` var, which carries it to every client and to anyone joining mid-shower.

## Rain written to the var in these steps, and no more often than this: each write is a reliable
## message to every client.
const STEP := 0.02
const SEND_INTERVAL := 0.5

var _cycle: OvercastCycle
var _t := 0.0
var _sent := -1.0
var _since_send := 0.0


func _init(rng_seed: int = 0) -> void:
	_cycle = OvercastCycle.new(rng_seed)


func _ready() -> void:
	ServerVars.value_changed.connect(_on_server_var_changed)
	set_process(bool(ServerVars.get_value("dynamic_weather", false)))


func _process(delta: float) -> void:
	if not NetworkManager.is_authority():
		return
	_t += delta
	_since_send += delta
	var rain := _cycle.rain_at(_t)
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
		_cycle.restart()
	elif was_raining:
		ServerVars.set_from_string("rain", "0")
