class_name WeatherCycle
extends Node
## The `dynamic_weather` server var: showers come and go on their own (OvercastCycle), each a few
## minutes of rain that swells, wanders and dies away, in a wind that rises, falls and turns. Runs
## on the authority and only writes the `rain`, `wind` and `wind_dir` vars, which carry it to every
## client and to anyone joining mid-shower.

## Rain and wind (m/s, degrees) written to the vars in these steps, and no more often than this:
## each write is a reliable message to every client.
const STEP := 0.02
const WIND_STEP := 0.1
const DIR_STEP := 1.0
const SEND_INTERVAL := 0.5

var _cycle: OvercastCycle
var _t := 0.0
var _sent := -1.0
var _since_send := 0.0
var _since_wind := 0.0


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
	_send_wind(delta)
	var q := 0.0 if rain <= 0.0 else maxf(snappedf(rain, STEP), 0.01)
	if q == _sent or (_since_send < SEND_INTERVAL and q > 0.0 and _sent > 0.0):
		return
	_sent = q
	_since_send = 0.0
	ServerVars.set_from_string("rain", str(q))


func _send_wind(delta: float) -> void:
	_since_wind += delta
	if _since_wind < SEND_INTERVAL:
		return
	_since_wind = 0.0
	var w := _cycle.wind_at(_t)
	var speed := snappedf(Vector2(w.x, w.z).length(), WIND_STEP)
	var dir := snappedf(fposmod(rad_to_deg(atan2(w.x, w.z)), 360.0), DIR_STEP)
	if speed != float(ServerVars.get_value("wind")):
		ServerVars.set_from_string("wind", str(speed))
	if dir != float(ServerVars.get_value("wind_dir")):
		ServerVars.set_from_string("wind_dir", str(dir))


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
		_since_wind = SEND_INTERVAL
		_cycle.restart()
		return
	if was_raining:
		ServerVars.set_from_string("rain", "0")
	ServerVars.set_from_string("wind", "0")
