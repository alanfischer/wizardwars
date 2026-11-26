extends RefCounted
## Particles drift in the air: each system's gravity takes the push of the air at its emitter
## (WeatherSystem.airflow), the wind and any tornado alike. Only drawn, so it goes by this peer's
## own wind, gusts and all.
## Spark systems share a process material per effect, so they get shared copies of it, one per
## push rounded to QUANTUM, rather than one each.

## Particles are lighter than a wizard: the push on them, against WeatherSystem.wind_push's.
const WEIGHT := 2.0
## Pushes (m/s²) closer than this share a copy.
const QUANTUM := 0.25
## How often (s) the emitters' air and the gusts are looked at again.
const LOOK := 0.25

var _weather: WeatherSystem
var _systems := {}  # GPUParticles3D / CPUParticles3D -> its own gravity or process material
var _copies := {}  # [material, Vector3i push in QUANTUM] -> the material blown that hard
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
	for node: Node3D in _systems.keys():
		_blow(node)
	_drop_unused_copies()


## The push on a particle in air moving at `air` (m/s²).
func _push(air: Vector3) -> Vector3:
	var k := float(ServerVars.get_value("wind_push", 1.0)) * WEIGHT
	return air * (air.length() * WeatherSystem.WIND_PUSH * maxf(k, 0.0))


func _blow(node: Node3D) -> void:
	if not is_instance_valid(node) or not node.is_inside_tree() or not _systems.has(node):
		return
	var at := node.global_position
	var push := Vector3.ZERO
	if not SpatialQuery.is_point_in_water(node, at):
		push = _push(_weather.airflow(at, _weather.wind_now))
	if node is CPUParticles3D:
		if _systems[node] == null:
			_systems[node] = node.gravity
		node.gravity = (_systems[node] as Vector3) + push
		return
	var base: ParticleProcessMaterial = _systems[node]
	if base == null:
		base = node.process_material as ParticleProcessMaterial
		if base == null:
			_systems.erase(node)
			return
		_systems[node] = base
	var notch := Vector3i((push / QUANTUM).round())
	node.process_material = base if notch == Vector3i.ZERO else _copy(base, notch)


func _copy(base: ParticleProcessMaterial, notch: Vector3i) -> ParticleProcessMaterial:
	var copy: ParticleProcessMaterial = _copies.get([base, notch])
	if copy == null:
		copy = base.duplicate()
		copy.gravity = base.gravity + Vector3(notch) * QUANTUM
		_copies[[base, notch]] = copy
	return copy


## Gusts and a passing tornado keep minting pushes; a copy no system wears any more goes.
func _drop_unused_copies() -> void:
	var worn := {}
	for node: Node in _systems:
		if node is GPUParticles3D and is_instance_valid(node):
			worn[node.process_material] = true
	for key: Array in _copies.keys():
		if not worn.has(_copies[key]):
			_copies.erase(key)


func _forget(node: Node) -> void:
	_systems.erase(node)
