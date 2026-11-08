@tool
class_name WeatherSystem
extends "res://addons/overcast/overcast_weather.gd"
## Overcast's rain, snow and lightning, wired into the game: the map's own weather (PotatoC
## SetWeather) and the `rain` / `snow` / `lightning` server vars drive it, the host times the strikes for every peer,
## and the flash lights the map through NightMode.

const TopDownFrame = preload("res://src/systems/top_down_frame.gd")
## How readily each WorldMaterials class pools; anything it leaves unclassified takes the default.
const PUDDLE_BY_CLASS := {"ground": 1.0, "mineral": 0.6, "wood": 0.0}
const PUDDLE_DEFAULT := 0.5
## The deepest a drift starts against a wall: about a wizard's waist, where Overcast's own would
## bury one to the chest.
const DRIFT_DEEPEST := 1.0
## Steps the server sends the ground's wetness in.
const WET_STEPS := 32.0

## The map, handed over before the system enters the tree. None on a test or tool that has no map.
var map_root: Node
## What the map asked for (PotatoC SetWeather). The `rain` server var overrides it while non-zero,
## and dynamic weather throughout.
var _current_type: int = 0
var _current_intensity: int = 0
var _wet_sent := -1.0  # the ground's wetness, in WET_STEPS, as last sent to the clients


func _ready() -> void:
	rain_bus = SoundSystem.RAIN_BUS
	thunder_bus = SoundSystem.EFFECTS_BUS
	rain_filter = SoundSystem.rain_filter()
	listener_height = 1.5
	bolt_drawer = _draw_beam_bolt
	light_from_sky = false  # NightMode's light, which knows the map's lightmaps
	wet_ground = false  # until the map turns out to have a rain floor
	soaks = not NetworkManager.is_online() or NetworkManager.is_host()  # a client draws its server's
	drift_deepest = DRIFT_DEEPEST
	flash_changed.connect(func(k: float) -> void: NightMode.set_flash(FLASH * k))
	struck.connect(_on_struck)
	super._ready()
	_light_drifts()
	ServerVars.value_changed.connect(_on_server_var_changed)
	# main hands over each new sky as night rebuilds it (main._build_skybox); this is the one the
	# map started with, if it was built first.
	if is_instance_valid(Game.skybox):
		sky = Game.skybox.overcast
	_apply_night()
	if map_root:
		var box := TopDownFrame.world_aabb(map_root)
		if box.size != Vector3.ZERO:
			area = box
		_take_rain_floor(map_root)
		_keep_snow_off_liquids(map_root)
		# Brush entities spawned later (/spawn, a round reset's respawns) cover too, once their own
		# _ready has said whether they are solid.
		get_tree().node_added.connect(_on_node_added)
	_apply_rain()
	_apply_wind()


## The map's rain floor (MapConverter, GoldSrcBSP.bake_rain_floor), so no drop is drawn under a
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
			add_snowless(piece.global_transform * box)


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
## traced for solid.
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
	if is_instance_valid(body) and body.collision_layer != 0 and not has_cover(body):
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
	snow = float(ServerVars.get_value("snow", 0.0))
	lightning = bool(ServerVars.get_value("lightning", true))


func _apply_wind() -> void:
	var dir := deg_to_rad(float(ServerVars.get_value("wind_dir", 0.0)))
	wind = Vector3(sin(dir), 0.0, cos(dir)) * float(ServerVars.get_value("wind", 0.0))


func _on_server_var_changed(key: String, _value: Variant) -> void:
	if key in ["rain", "snow", "lightning", "dynamic_weather"]:
		_apply_rain()
	elif key == "wind" or key == "wind_dir":
		_apply_wind()
	elif key == "time":
		_apply_night()


## The night darkens the rain and the haze the way it darkens the sky's light.
func _apply_night() -> void:
	sky_light = sky_light_now()


## Join snapshot. Default weather is "none", which every peer already starts at, so a dry map
## sends no weather. The `rain` override is a server var and reaches the client with the rest of
## them. The ground's wetness always goes: a client may have soaked its own before it knew it was one.
func send_state_to(peer_id: int) -> void:
	if _current_type != 0 or _current_intensity != 0:
		set_weather.rpc_id(peer_id, _current_type, _current_intensity)
	set_ground_wetness.rpc_id(peer_id, _ground_wetness())


## The server's ground, which a client draws and goes by: it soaks none of its own (`soaks`).
@rpc("authority", "call_remote", "reliable")
func set_ground_wetness(w: float) -> void:
	wetness = w


## Melts the lying snow round where fire lands. Each peer melts its own from the blast it draws:
## the snow is only drawn, never played on.
static func melt_snow(at: Vector3, radius: float) -> void:
	if Game.weather_system:
		Game.weather_system.melt(at, radius)


## How wet the ground at `feet` is for slick footing, 0 to 1, alike on every peer: the wetness in
## the steps the server sends it in, which a client has already.
func wet_at(feet: Vector3) -> float:
	var w := _ground_wetness()
	return w if w > 0.0 and rains_on(feet) else 0.0


func _ground_wetness() -> float:
	return snappedf(wetness, 1.0 / WET_STEPS)


func _share_wetness() -> void:
	var w := _ground_wetness()
	if w == _wet_sent:
		return
	_wet_sent = w
	if NetworkManager.is_online():
		set_ground_wetness.rpc(w)


## The night darkens the rain and the haze the way it darkens the sky's light (NightMode).
static func sky_light_now() -> Color:
	var n := NightMode.night_light()
	var g := NightMode.LIGHTMAP_GAMMA
	return Color(pow(n.x, g), pow(n.y, g), pow(n.z, g))


func _process(delta: float) -> void:
	# The host times the strikes so every peer sees the same one. A role that can change with a
	# connection, so asked each frame.
	var server := not NetworkManager.is_online() or NetworkManager.is_host()
	times_strikes = server
	soaks = server
	# GoldSrc drew no rain with the view underwater (v_waterlevel 3); the sound carries on.
	underwater = listener != null and listener.has_method("head_underwater") and listener.head_underwater()
	super._process(delta)
	if server:
		_share_wetness()


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
