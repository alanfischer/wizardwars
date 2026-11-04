class_name WeatherSystem
extends "res://addons/overcast/overcast_weather.gd"
## Overcast's rain and lightning, wired into the game: the map's own weather (PotatoC SetWeather)
## and the `rain` / `lightning` server vars drive it, the host times the strikes for every peer,
## and the flash lights the map through NightMode.

const TopDownFrame = preload("res://src/systems/top_down_frame.gd")
## How readily each WorldMaterials class pools; anything it leaves unclassified takes the default.
const PUDDLE_BY_CLASS := {"ground": 1.0, "mineral": 0.6, "wood": 0.0}
const PUDDLE_DEFAULT := 0.5

## The map, handed over before the system enters the tree. None on a test or tool that has no map.
var map_root: Node
## What the map asked for (PotatoC SetWeather). The `rain` server var overrides it while non-zero.
var _current_type: int = 0
var _current_intensity: int = 0


func _ready() -> void:
	rain_bus = SoundSystem.RAIN_BUS
	thunder_bus = SoundSystem.EFFECTS_BUS
	rain_filter = SoundSystem.rain_filter()
	listener_height = 1.5
	bolt_drawer = _draw_beam_bolt
	flash_changed.connect(func(k: float) -> void: NightMode.set_flash(FLASH * k))
	struck.connect(_on_struck)
	super._ready()
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
		# Brush entities spawned later (/spawn, a round reset's respawns) cover too, once their own
		# _ready has said whether they are solid.
		get_tree().node_added.connect(_on_node_added)
	_apply_rain()


## The map's rain floor (MapConverter, GoldSrcBSP.bake_rain_floor), so no drop is drawn under a
## roof. A map converted before it existed has none: it rains everywhere and nothing gets wet.
func _take_rain_floor(map_root: Node) -> void:
	var data: Dictionary = map_root.get_meta("rain_floor", {})
	if data.is_empty():
		return
	# The extension's floor runs from its max-X corner; Overcast's from its min-X one.
	var img: Image = (data["image"] as Image).duplicate()
	img.flip_x()
	var size: Vector2 = data["size"]
	var origin: Vector3 = data["origin"]
	rain_floor = OvercastRainFloor.create(img, Vector3(origin.x - size.x, origin.y, origin.z), size,
		float(data["top"]))
	add_wet_materials(map_root, func(mi: MeshInstance3D) -> float:
		# The loader names each world mesh after its texture.
		return PUDDLE_BY_CLASS.get(WorldMaterials.classify(String(mi.name)), PUDDLE_DEFAULT))
	_cover_movers(map_root)


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


## How hard it is raining, Overcast's way (0 dry, 1 a downpour): the `rain` server var while set,
## the map's own 1–9 otherwise.
func rain_amount() -> float:
	var forced := float(ServerVars.get_value("rain", 0.0))
	if forced > 0.0:
		return forced
	if _current_type != 1 or _current_intensity <= 0:
		return 0.0
	return maxf((_current_intensity - 1) / 8.0, 0.01)


func _apply_rain() -> void:
	rain = rain_amount()
	lightning = bool(ServerVars.get_value("lightning", true))


func _on_server_var_changed(key: String, _value: Variant) -> void:
	if key == "rain" or key == "lightning":
		_apply_rain()
	elif key == "time":
		_apply_night()


## The night darkens the rain and the haze the way it darkens the sky's light.
func _apply_night() -> void:
	sky_light = sky_light_now()


## Join snapshot. Default weather is "none", which every peer already starts at, so a dry map
## sends nothing. The `rain` override is a server var and reaches the client with the rest of them.
func send_state_to(peer_id: int) -> void:
	if _current_type != 0 or _current_intensity != 0:
		set_weather.rpc_id(peer_id, _current_type, _current_intensity)


## The night darkens the rain and the haze the way it darkens the sky's light (NightMode).
static func sky_light_now() -> Color:
	var n := NightMode.night_light()
	var g := NightMode.LIGHTMAP_GAMMA
	return Color(pow(n.x, g), pow(n.y, g), pow(n.z, g))


func _process(delta: float) -> void:
	# The host times the strikes so every peer sees the same one. A role that can change with a
	# connection, so asked each frame.
	times_strikes = not NetworkManager.is_online() or NetworkManager.is_host()
	# GoldSrc drew no rain with the view underwater (v_waterlevel 3); the sound carries on.
	underwater = listener != null and listener.has_method("head_underwater") and listener.head_underwater()
	super._process(delta)


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
