@tool
class_name WeatherSystem
extends "res://addons/overcast/overcast_weather.gd"
## Overcast's rain, snow and lightning, wired into the game: the map's own weather (PotatoC
## SetWeather) and the `rain` / `snow` / `lightning` server vars drive it, the host times the strikes for every peer,
## and the flash lights the map through NightMode.

const TopDownFrame = preload("res://src/systems/top_down_frame.gd")
const WindParticles = preload("res://src/systems/wind_particles.gd")
## How readily each WorldMaterials class pools; anything it leaves unclassified takes the default.
const PUDDLE_BY_CLASS := {"ground": 1.0, "mineral": 0.6, "wood": 0.0}
const PUDDLE_DEFAULT := 0.5
## The deepest a drift starts against a wall: about a wizard's waist, where Overcast's own would
## bury one to the chest.
const DRIFT_DEEPEST := 1.0
## Steps the server sends the ground's wetness, ice and snow cover in.
const WET_STEPS := 32.0
## The air's push, m/s² per (m/s)² of it: 0.75 in a 5 m/s breeze, 6.75 in a 15 m/s gale.
const WIND_PUSH := 0.03
## A wall's lee reaches LEE times its height above a body downwind; looked for upwind every
## LEE_STEP metres, LEE_SAMPLES times.
const LEE := 3.0
const LEE_STEP := 0.5
const LEE_SAMPLES := 12
## A rain floor cell stands at the highest of its corners, so a point on the ground can sit a little
## under its own cell; a roof stands well above.
const ROOF_REACH := 0.5
## Below this speed (m/s) a rigid body is at rest and the wind leaves it be; how often (s) a carried
## body's exposure is looked at again.
const CARRY_RESTING := 0.5
const CARRY_LOOK := 0.25
## Nodes that move the air themselves (a tornado, a windwall), each with
## `airflow(p: Vector3, who: Node) -> Vector3`, the air's velocity it adds at `p` (m/s), zero beyond
## its reach. `who` is what is being blown, or null for anything; a source may spare it. See airflow.
const WIND_SOURCES := &"wind_source"
## How fast (m/s) air that lifts harder than gravity takes a walker off the ground: see blow_walker.
const LIFTOFF := 1.0

## The map, handed over before the system enters the tree. None on a test or tool that has no map.
var map_root: Node
## What the map asked for (PotatoC SetWeather). The `rain` server var overrides it while non-zero,
## and dynamic weather throughout.
var _current_type: int = 0
var _current_intensity: int = 0
## Rigid bodies the wind carries -> (exposure, msec it is good until).
var _carried := {}
var _sources: Array[Node] = []
var _sources_frame := -1
## Drifts the particles in the wind; none on a peer that draws nothing.
var _particles: WindParticles
var _ground_sent := Vector3(-1, -1, -1)  # the ground's wetness, ice and snow cover, in WET_STEPS, as last sent to the clients


func _ready() -> void:
	rain_bus = SoundSystem.RAIN_BUS
	thunder_bus = SoundSystem.EFFECTS_BUS
	rain_filter = SoundSystem.rain_filter()
	listener_height = 1.5
	bolt_drawer = _draw_beam_bolt
	light_from_sky = false  # NightMode's light, which knows the map's lightmaps
	wet_ground = false  # until the map turns out to have a rain floor
	ground.soaks = not NetworkManager.is_online() or NetworkManager.is_host()  # a client draws its server's
	drift_deepest = DRIFT_DEEPEST
	snow_drifts = false  # off until they look right; the even layer still lies
	flash_changed.connect(func(light: Color) -> void: NightMode.set_flash(Vector3(light.r, light.g, light.b)))
	struck.connect(_on_struck)
	super._ready()
	_light_drifts()
	ServerVars.value_changed.connect(_on_server_var_changed)
	# In game Skybox hands over each map's sky once it is built (Skybox._setup_for_map); a tool may
	# have built its sky first.
	if is_instance_valid(Game.skybox):
		sky = Game.skybox.overcast
	_apply_night()
	if map_root:
		var box := TopDownFrame.world_aabb(map_root)
		if box.size != Vector3.ZERO:
			area = box
		_take_rain_floor(map_root)
		_keep_snow_off_liquids(map_root)
		drift_ground = map_root.get_node_or_null("worldspawn")
		# Brush entities spawned later (/spawn, a round reset's respawns) cover too, once their own
		# _ready has said whether they are solid.
		get_tree().node_added.connect(_on_node_added)
	_apply_rain()
	_apply_wind()
	if not Engine.is_editor_hint():
		if presenting:
			_particles = WindParticles.new(self)
		for kind in ["RigidBody3D", "PhysicalBone3D", "GPUParticles3D", "CPUParticles3D"]:
			for node in get_tree().root.find_children("*", kind, true, false):
				_track_blown(node)
		get_tree().node_added.connect(_track_blown)


## The map's rain floor (MapConverter, GoldSrcBSP.bake_surface_below_sky), so no drop is drawn under a
## roof. A map converted before it existed has none: it rains everywhere and nothing gets wet.
func _take_rain_floor(root: Node) -> void:
	var data: Dictionary = root.get_meta("rain_floor", {})
	if data.is_empty():
		return
	# The extension's floor runs from its max-X corner; Overcast's from its min-X one.
	var img: Image = (data["image"] as Image).duplicate()
	img.flip_x()
	# The air under cover, which wind blows rain in through; a map converted before it had none.
	var air: Image = null
	if data.has("under"):
		air = (data["under"] as Image).duplicate()
		air.flip_x()
	var size: Vector2 = data["size"]
	var origin: Vector3 = data["origin"]
	rain_floor = OvercastRainFloor.create(img, Vector3(origin.x - size.x, origin.y, origin.z), size,
		float(data["top"]), air)
	# Without a floor rain would wet the map indoors too.
	wet_ground = true
	_set_puddle_scales(root)
	_cover_movers(root)


## Drifts lit as the models are, by the light grid, to meet the lightmapped snow beside them.
func _light_drifts() -> void:
	if drift_material == null:
		return  # drawing nothing
	drift_material.shader = preload("res://shaders/snow_drift.gdshader")
	drift_material.set_shader_parameter("linear_output", EntityRender.renderer_is_linear())
	if AssetLoader.light_grid:
		AssetLoader.light_grid.bind(drift_material)


## Drifts lie on the world's own faces, not its liquids' surfaces or its sky.
func _drifts_on(mesh: MeshInstance3D) -> bool:
	return not mesh.has_meta("is_water_surface") and not mesh.has_meta("is_sky_surface")


## No snow on a liquid's bed, which is all the rain floor sees under it: each liquid volume's
## convex pieces, world water and func_water (slime, lava) alike.
func _keep_snow_off_liquids(root: Node) -> void:
	for liquid: Area3D in root.find_children("*", "Area3D", true, false):
		if not liquid.is_inside_tree() or not _is_liquid(liquid):
			continue
		for piece: CollisionShape3D in liquid.find_children("*", "CollisionShape3D", false, false):
			var convex := piece.shape as ConvexPolygonShape3D
			if convex == null or convex.points.is_empty():
				continue
			var box := AABB(convex.points[0], Vector3.ZERO)
			for p in convex.points:
				box = box.expand(p)
			ground.add_snowless(piece.global_transform * box)


## A liquid volume: on MASK_WATER, or a func_water's Volume before FuncWater has put it there.
static func _is_liquid(volume: Area3D) -> bool:
	if volume.collision_layer & GameConsts.MASK_WATER:
		return true
	var owner_node := volume.get_parent()
	return volume.name == &"Volume" and owner_node and owner_node.has_meta("entity") \
		and owner_node.get_meta("entity").get("classname", "") == "func_water"


var _pools_by_shader := {}  # Shader -> whether it takes puddle_scale


## How readily each world surface pools, by its texture's WorldMaterials class. The loader names
## each world mesh after its texture.
func _set_puddle_scales(root: Node) -> void:
	for mi: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
		if mi.mesh == null:
			continue
		var pools: float = PUDDLE_BY_CLASS.get(WorldMaterials.classify(String(mi.name)), PUDDLE_DEFAULT)
		for i in mi.mesh.get_surface_count():
			var mat := mi.get_surface_override_material(i) as ShaderMaterial
			if mat == null:
				mat = mi.mesh.surface_get_material(i) as ShaderMaterial
			if mat and _pools(mat.shader):
				mat.set_shader_parameter("puddle_scale", pools)


func _pools(shader: Shader) -> bool:
	if shader == null:
		return false
	if not _pools_by_shader.has(shader):
		_pools_by_shader[shader] = shader.get_shader_uniform_list().any(
			func(u: Dictionary) -> bool: return u["name"] == "puddle_scale")
	return _pools_by_shader[shader]


## The bake leaves out brush entities (doors, plats and trains move; breakables break), so each
## solid one is a cover that keeps the rain off whatever of the map is under it, wherever it has
## got to. A func_illusionary is not solid, and rain falls through it as it did in GoldSrc, which
## traced for solid. Nor is a brush the importer put on the sky layer alone: all sky and {blue
## faces, the invisible lid that boxes a map like ww_ravine in, which rain falls through like the sky.
func _cover_movers(node: Node) -> void:
	for child in node.get_children():
		if child is AnimatableBody3D:
			_cover_if_solid(child)
		else:
			_cover_movers(child)


func _on_node_added(node: Node) -> void:
	if node is AnimatableBody3D and is_instance_valid(map_root) and map_root.is_ancestor_of(node):
		_cover_if_solid.call_deferred(node)


func _cover_if_solid(body: AnimatableBody3D) -> void:
	if is_instance_valid(body) and body.collision_layer & ~GameConsts.MASK_WORLD_SKY != 0 \
			and not has_cover(body):
		add_cover(body)


## The node this follows. The map-load path builds the system before the local player exists, and
## a dedicated server never gets one.
func attach_player(player: Node3D) -> void:
	listener = player


## Server-authoritative (a PotatoC entity drives it): applies locally and then re-sends itself to
## the clients, which take the same path with is_host() false and so do not re-broadcast.
@rpc("authority", "call_remote", "reliable")
func set_weather(type: int, intensity: int) -> void:
	Log.debug("  WeatherSystem -> set_weather(type=%d, intensity=%d)" % [type, intensity])
	_current_type = type
	_current_intensity = intensity
	if NetworkManager.is_online() and NetworkManager.is_host():
		set_weather.rpc(type, intensity)
	_apply_rain()


## How hard it is raining, Overcast's way (0 dry, 1 a downpour): the `rain` server var while set
## or under dynamic weather, the map's own 1–9 otherwise.
func rain_amount() -> float:
	var forced := float(ServerVars.get_value("rain", 0.0))
	if forced > 0.0 or bool(ServerVars.get_value("dynamic_weather", false)):
		return forced
	if _current_type != 1 or _current_intensity <= 0:
		return 0.0
	return maxf((_current_intensity - 1) / 8.0, 0.01)


func _apply_rain() -> void:
	rain = rain_amount()
	temperature = float(ServerVars.get_value("temperature", 10.0))
	lightning = bool(ServerVars.get_value("lightning", true))


func _apply_wind() -> void:
	var dir := deg_to_rad(float(ServerVars.get_value("wind_dir", 0.0)))
	wind = Vector3(sin(dir), 0.0, cos(dir)) * float(ServerVars.get_value("wind", 0.0))


func _on_server_var_changed(key: String, _value: Variant) -> void:
	if key in ["rain", "temperature", "lightning", "dynamic_weather"]:
		_apply_rain()
	elif key == "wind" or key == "wind_dir":
		_apply_wind()
	elif key in NightMode.VARS:
		_apply_night()


## The night darkens the rain and the haze the way it darkens the sky's light.
func _apply_night() -> void:
	sky_light = sky_light_now()


## Join snapshot. Default weather is "none", which every peer already starts at, so a dry map
## sends no weather. The `rain` override is a server var and reaches the client with the rest of
## them. The ground always goes: a client may have soaked its own before it knew it was one, and
## what heat and melts left is only the server's to say.
func send_state_to(peer_id: int) -> void:
	if _current_type != 0 or _current_intensity != 0:
		set_weather.rpc_id(peer_id, _current_type, _current_intensity)
	var shared := _shared_ground()
	set_ground.rpc_id(peer_id, shared.x, shared.y, shared.z)
	var cells := ground.ice_cells()
	if cells.size() > 0:
		set_ice.rpc_id(peer_id, cells.size(), cells.compress(FileAccess.COMPRESSION_ZSTD))
	cells = ground.snow_cells()
	if cells.size() > 0:
		set_snow.rpc_id(peer_id, cells.size(), cells.compress(FileAccess.COMPRESSION_ZSTD))


## The server's ground, which a client draws and goes by: it soaks, freezes and snows over none of
## its own (`ground.soaks`).
@rpc("authority", "call_remote", "reliable")
func set_ground(w: float, frozen: float, snow: float) -> void:
	ground.wetness = w
	ground.ice = frozen
	ground.snow_cover = snow


@rpc("authority", "call_remote", "reliable")
func set_ice(size: int, packed: PackedByteArray) -> void:
	ground.set_ice_cells(packed.decompress(size, FileAccess.COMPRESSION_ZSTD))


@rpc("authority", "call_remote", "reliable")
func set_snow(size: int, packed: PackedByteArray) -> void:
	ground.set_snow_cells(packed.decompress(size, FileAccess.COMPRESSION_ZSTD))


## Fire melts the snow and thaws the ice where it lands (`amount` > 0), cold freezes what is wet
## there. Played on, so the server heats and sends the heats that changed any.
static func heat_ground(at: Vector3, radius: float, amount := 1.0) -> void:
	var weather := Game.weather_system
	if weather == null or not NetworkManager.is_authority():
		return
	if weather.ground.heat(at, radius, amount) and NetworkManager.is_online():
		weather.take_heat.rpc(at, radius, amount)


@rpc("authority", "call_remote", "reliable")
func take_heat(at: Vector3, radius: float, amount: float) -> void:
	ground.heat(at, radius, amount)


## The ground at `feet` for footing, alike on every peer: how wet and how icy, in the steps the
## server sends them in. Dry ground is sure footing whatever ice it holds, so it reads as none.
func footing(feet: Vector3) -> Vector2:
	var wet := snappedf(ground.wetness_at(feet), 1.0 / WET_STEPS)
	if wet <= 0.0:
		return Vector2.ZERO
	return Vector2(wet, snappedf(ground.ice_at(feet), 1.0 / WET_STEPS))


## The push of the air at `p` on a body there moving at `velocity` (m/s²), alike on every peer:
## it goes by the steady `wind` the server sets, never this peer's own gusts. `weight` scales it
## per body; `who` is the body, for a source that spares some.
func wind_push(p: Vector3, velocity: Vector3, weight := 1.0, who: Node = null) -> Vector3:
	return push_through(airflow(p, Vector3.INF, who), velocity, weight)


## What the air does to a walker (a player, a monster) this tick: its change of velocity over
## `delta`. Standing, the ground eats a steady lift (GoldSrc keeps you on it), so air that lifts
## harder than `gravity` takes you off your feet at LIFTOFF instead, and carries you from there.
func blow_walker(p: Vector3, velocity: Vector3, on_floor: bool, gravity: float, delta: float,
		who: Node = null) -> Vector3:
	var push := wind_push(p, velocity, 1.0, who)
	var change := push * delta
	if on_floor and push.y > gravity:
		change.y = maxf(change.y, LIFTOFF - velocity.y + gravity * delta)
	return change


## The air moving at `p` (m/s): the wind, as far as `p` is open to it, and every WIND_SOURCES
## node's own. `blowing` is the wind, the steady one unless said; `who` is what it blows on.
func airflow(p: Vector3, blowing := Vector3.INF, who: Node = null) -> Vector3:
	if blowing == Vector3.INF:
		blowing = wind
	var air := local_airflow(p, who)
	if blowing != Vector3.ZERO:
		air += blowing * wind_exposure(p, blowing)
	return air


## Just the WIND_SOURCES' air at `p`, no sky needed: a tornado blows under a roof too.
func local_airflow(p: Vector3, who: Node = null) -> Vector3:
	var air := Vector3.ZERO
	for source in _wind_sources():
		if is_instance_valid(source):
			air += source.airflow(p, who)
	return air


## What air moving at `air` does to a body moving at `velocity`: drag grows with the square of the
## air's speed, so a breeze barely moves anyone and a gale or a tornado throws them, and it pushes
## only until the body moves along with the air as fast as the air does.
func push_through(air: Vector3, velocity: Vector3, weight := 1.0) -> Vector3:
	var speed := air.length()
	if speed <= 0.0 or weight <= 0.0:
		return Vector3.ZERO
	var dir := air / speed
	if velocity.dot(dir) >= speed:
		return Vector3.ZERO
	var k := float(ServerVars.get_value("wind_push", 1.0)) * weight
	if k <= 0.0:
		return Vector3.ZERO
	return dir * (WIND_PUSH * speed * speed * k)


func _wind_sources() -> Array[Node]:
	var frame := Engine.get_physics_frames()
	if frame != _sources_frame:
		_sources_frame = frame
		_sources = (Engine.get_main_loop() as SceneTree).get_nodes_in_group(WIND_SOURCES)
	return _sources


## How open `p` is to the wind, 0 sheltered to 1 out in it: nothing under a roof (where the rain
## floor stands ROOF_REACH above it), and in a wall's lee for LEE times as far downwind as the wall stands
## above it, opening up across that. A map with no rain floor has no sky to tell by: sheltered.
## `blowing` is the wind to be sheltered from, the steady one unless said.
func wind_exposure(p: Vector3, blowing := Vector3.INF) -> float:
	if blowing == Vector3.INF:
		blowing = wind
	if rain_floor == null or blowing == Vector3.ZERO:
		return 0.0
	var own := floor_at(p)
	if own > p.y + ROOF_REACH:
		return 0.0
	var base := maxf(p.y, own)
	var upwind := -blowing.normalized()
	var open := 1.0
	for i in range(1, LEE_SAMPLES + 1):
		var d := i * LEE_STEP
		var rise := floor_at(p + upwind * d) - base
		if rise > 0.0:
			open = minf(open, d / (LEE * rise))
	return clampf(open, 0.0, 1.0)


## Every rigid body this peer simulates (gibs, corpses and their bones, satchels, stones) is
## carried as the air at it says. One at rest is left be by the wind, so it can sleep, but not by a
## tornado: that picks it up. Its exposure is looked at again every CARRY_LOOK seconds, not each
## tick: a corpse is 21 bodies.
func _carry(delta: float) -> void:
	if _carried.is_empty() or (wind == Vector3.ZERO and _wind_sources().is_empty()):
		return
	var now := Time.get_ticks_msec()
	for body: PhysicsBody3D in _carried.keys():
		var rid := body.get_rid()
		var mode := PhysicsServer3D.body_get_mode(rid)
		if mode != PhysicsServer3D.BODY_MODE_RIGID and mode != PhysicsServer3D.BODY_MODE_RIGID_LINEAR:
			continue
		var air := local_airflow(body.global_position, body)
		var asleep: bool = PhysicsServer3D.body_get_state(rid, PhysicsServer3D.BODY_STATE_SLEEPING)
		var v: Vector3 = PhysicsServer3D.body_get_state(rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY)
		if air == Vector3.ZERO and (asleep or v.length_squared() < CARRY_RESTING * CARRY_RESTING):
			continue
		if wind != Vector3.ZERO:
			air += wind * _exposure_of(body, now)
		var push := push_through(air, v)
		if push == Vector3.ZERO:
			continue
		if asleep:
			PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_SLEEPING, false)
		PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, v + push * delta)


func _exposure_of(body: PhysicsBody3D, now: int) -> float:
	var seen: Vector2 = _carried[body]
	if now >= seen.y:
		seen = Vector2(wind_exposure(body.global_position), now + CARRY_LOOK * 1000.0)
		_carried[body] = seen
	return seen.x


func _track_blown(node: Node) -> void:
	if _particles:
		_particles.track(node)
	if node is RigidBody3D or node is PhysicalBone3D:
		_carried[node] = Vector2(0.0, 0.0)
		node.tree_exiting.connect(func() -> void: _carried.erase(node), CONNECT_ONE_SHOT)


func _physics_process(delta: float) -> void:
	if not Engine.is_editor_hint():
		_carry(delta)


## The ground's wetness, ice and snow cover, in the steps the server sends them in.
func _shared_ground() -> Vector3:
	return Vector3(ground.wetness, ground.ice, ground.snow_cover).snapped(Vector3.ONE / WET_STEPS)


func _share_ground() -> void:
	var shared := _shared_ground()
	if shared == _ground_sent:
		return
	_ground_sent = shared
	if NetworkManager.is_online():
		set_ground.rpc(shared.x, shared.y, shared.z)


## The night darkens the rain and the haze the way it darkens the sky's light (NightMode).
static func sky_light_now() -> Color:
	var n := NightMode.to_gamma(NightMode.night_light())
	return Color(n.x, n.y, n.z)


func _process(delta: float) -> void:
	# The host times the strikes so every peer sees the same one. A role that can change with a
	# connection, so asked each frame.
	var server := not NetworkManager.is_online() or NetworkManager.is_host()
	times_strikes = server
	ground.soaks = server
	# GoldSrc drew no rain with the view underwater (v_waterlevel 3); the sound carries on.
	underwater = listener != null and listener.has_method("head_underwater") and listener.head_underwater()
	super._process(delta)
	if server:
		_share_ground()
	if _particles:
		_particles.step(delta)


## The host's strikes reach every client, which draws the same one from the seed.
func _on_struck(strike_seed: int) -> void:
	if NetworkManager.is_online() and NetworkManager.is_host():
		strike.rpc(strike_seed)


@rpc("authority", "call_remote", "reliable")
func strike(strike_seed: int) -> void:
	super.strike(strike_seed)


func _draw_beam_bolt(points: PackedVector3Array, width: float, brightness: float, fade: float) -> void:
	var parent := get_tree().current_scene
	var from := points[0]
	var to := points[points.size() - 1]
	var last := points.size() - 1
	var noise := func(t: float) -> Vector3:
		var i := clampi(roundi(t * last), 0, last)
		return points[i] - from.lerp(to, float(i) / last)
	BeamSystem.create_oneshot(parent, from, to, {
		"color": Color(0.85, 0.9, 1.0, brightness),
		"width": width,
		"segments": last,
		"noise_fn": noise,
		"fade_time": fade,
	})
