extends RefCounted
## Particles out under the sky drift in the wind: each system's gravity takes the push, by how
## exposed its emitter is. Only drawn, so it goes by this peer's own wind, gusts and all.
## Spark systems share a process material per effect, so they get shared copies of it at a few
## exposure LEVELS rather than one each.

## Particles are lighter than a wizard: the push on them, against WeatherSystem.wind_push's.
const WEIGHT := 2.0
const LEVELS := 4.0
## How often (s) the emitters' exposure and the gusts are looked at again.
const LOOK := 0.25

var _weather: WeatherSystem
var _systems := {}  # GPUParticles3D / CPUParticles3D -> its own gravity or process material
var _copies := {}  # [material, level] -> the material blown at that level
var _since := 0.0


func _init(weather: WeatherSystem) -> void:
	_weather = weather


func track(node: Node) -> void:
	if not (node is GPUParticles3D or node is CPUParticles3D) or _systems.has(node):
		return
	_systems[node] = null
	node.tree_exiting.connect(func() -> void: _forget(node), CONNECT_ONE_SHOT)
	# Once the effect has put it where it goes: a burst is over before the next look.
	_blow.call_deferred(node)


func step(delta: float) -> void:
	_since += delta
	if _since < LOOK:
		return
	_since = 0.0
	for material: ParticleProcessMaterial in _copies_bases():
		for level in range(1, int(LEVELS) + 1):
			var copy: ParticleProcessMaterial = _copies.get([material, level])
			if copy:
				copy.gravity = material.gravity + _push(level / LEVELS)
	for node: Node3D in _systems.keys():
		_blow(node)


func _copies_bases() -> Array:
	var bases := {}
	for key: Array in _copies:
		bases[key[0]] = true
	return bases.keys()


## The push on a particle at `open` exposure (m/s²).
func _push(open: float) -> Vector3:
	var w := _weather.wind_now
	var k := float(ServerVars.get_value("wind_push", 1.0)) * WEIGHT * open
	return w * (w.length() * WeatherSystem.WIND_PUSH * maxf(k, 0.0))


func _blow(node: Node3D) -> void:
	if not is_instance_valid(node) or not node.is_inside_tree() or not _systems.has(node):
		return
	var at := node.global_position
	var open := 0.0
	if not SpatialQuery.is_point_in_water(node, at):
		open = _weather.wind_exposure(at, _weather.wind_now)
	var level := roundf(open * LEVELS)
	if node is CPUParticles3D:
		if _systems[node] == null:
			_systems[node] = node.gravity
		node.gravity = (_systems[node] as Vector3) + _push(level / LEVELS)
		return
	var base: ParticleProcessMaterial = _systems[node]
	if base == null:
		base = node.process_material as ParticleProcessMaterial
		if base == null:
			_systems.erase(node)
			return
		_systems[node] = base
	node.process_material = base if level == 0.0 else _copy(base, int(level))


func _copy(base: ParticleProcessMaterial, level: int) -> ParticleProcessMaterial:
	var copy: ParticleProcessMaterial = _copies.get([base, level])
	if copy == null:
		copy = base.duplicate()
		copy.gravity = base.gravity + _push(level / LEVELS)
		_copies[[base, level]] = copy
	return copy


func _forget(node: Node) -> void:
	_systems.erase(node)
