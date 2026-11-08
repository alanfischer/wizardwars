class_name WeatherCycle
extends Node
## Weather that comes and goes on its own (OvercastCycle), on the authority, carried to every client
## and to anyone joining through the vars it writes:
## - `dynamic_wind` (on by default): a wind that rises, falls and turns, a breeze at most.
## - `dynamic_weather`: showers of a few minutes that swell, wander and die away, written to `rain`,
##   with the wind blowing harder in them.
## Rain or wind set some other way (/rain, /wind, the slider) takes that part over and turns its var
## off.

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
var _since_wind := SEND_INTERVAL
var _wind_sent := NAN  # the wind and its direction as last written here
var _dir_sent := NAN


func _init(rng_seed: int = 0) -> void:
	_cycle = OvercastCycle.new(rng_seed)


func _ready() -> void:
	ServerVars.value_changed.connect(_on_server_var_changed)
	_update_processing()


func _showers() -> bool:
	return bool(ServerVars.get_value("dynamic_weather", false))


func _winds() -> bool:
	return bool(ServerVars.get_value("dynamic_wind", true))


func _update_processing() -> void:
	set_process(_showers() or _winds())


func _process(delta: float) -> void:
	if not NetworkManager.is_authority():
		return
	_t += delta
	_since_send += delta
	if _winds():
		_send_wind(delta)
	if not _showers():
		return
	var rain := _cycle.rain_at(_t)
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
	var w := _cycle.wind_at(_t) if _showers() else _cycle.breeze_at(_t)
	var speed := snappedf(Vector2(w.x, w.z).length(), WIND_STEP)
	var dir := snappedf(fposmod(rad_to_deg(atan2(w.x, w.z)), 360.0), DIR_STEP)
	if speed != float(ServerVars.get_value("wind")):
		_wind_sent = speed
		ServerVars.set_from_string("wind", str(speed))
	if dir != float(ServerVars.get_value("wind_dir")):
		_dir_sent = dir
		ServerVars.set_from_string("wind_dir", str(dir))


func _on_server_var_changed(key: String, value: Variant) -> void:
	if not NetworkManager.is_authority():
		return
	match key:
		"rain":
			# Rain it did not write (/rain, the slider) is someone taking the weather over by hand.
			if is_processing() and _showers() and absf(float(value) - _sent) > 0.001:
				_sent = -1.0  # theirs now, so turning off leaves it be
				ServerVars.set_from_string("dynamic_weather", "off")
		"wind", "wind_dir":
			var sent := _wind_sent if key == "wind" else _dir_sent
			if _winds() and not is_equal_approx(float(value), sent):
				ServerVars.set_from_string("dynamic_wind", "off")
		"dynamic_wind":
			_update_processing()
			if bool(value):
				_since_wind = SEND_INTERVAL
		"dynamic_weather":
			_update_processing()
			var was_raining := _sent > 0.0
			_sent = -1.0
			if bool(value):
				_t = 0.0
				_since_wind = SEND_INTERVAL
				_cycle.restart()
			elif was_raining:
				ServerVars.set_from_string("rain", "0")
