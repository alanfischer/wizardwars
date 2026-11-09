extends "res://src/tests/test_base.gd"
## `rain` takes values past 1, where it only draws more drops; `time` is hours round the clock.
## (Overcast tests the weather itself.)
##
## Scene-run only (needs the ServerVars autoload): res://src/tests/run_tests.tscn.

const Movement = preload("res://addons/pmove/movement.gd")


## A floor 4 m by 2 m from (-2, -1): the west half roofed at 3 m, the east half open to 0.
func _roofed_weather() -> WeatherSystem:
	var img := Image.create_empty(4, 2, false, Image.FORMAT_RF)
	for y in 2:
		for x in 4:
			img.set_pixel(x, y, Color(3.0 if x < 2 else 0.0, 0, 0))
	var weather := WeatherSystem.new()
	weather.rain_floor = OvercastRainFloor.create(img, Vector3(-2, 0, -1), Vector2(4, 2), 10.0)
	return weather


func test_the_rain_var_reaches_overcast_unchanged() -> void:
	var weather := WeatherSystem.new()
	for rain in ["0.3", "1", "6"]:
		ServerVars.set_from_string("rain", rain)
		assert_almost_eq(weather.rain_amount(), float(rain), 1e-6, "rain %s" % rain)
	ServerVars.set_from_string("rain", "0")
	assert_eq(weather.rain_amount(), 0.0, "dry with no var and no map weather")
	weather._current_type = 1
	weather._current_intensity = 9
	assert_almost_eq(weather.rain_amount(), 1.0, 1e-6, "the map's heaviest rain is a downpour")
	weather._current_intensity = 1
	assert_gt(weather.rain_amount(), 0.0, "and its lightest still rains")
	weather.free()


func test_drifts_lie_on_neither_the_maps_liquids_nor_its_sky() -> void:
	var weather := WeatherSystem.new()
	var floor_mesh := MeshInstance3D.new()
	var water := MeshInstance3D.new()
	water.set_meta("is_water_surface", true)
	var sky := MeshInstance3D.new()
	sky.set_meta("is_sky_surface", true)
	assert_true(weather._drifts_on(floor_mesh), "the world's own faces")
	assert_false(weather._drifts_on(water), "not a liquid's surface")
	assert_false(weather._drifts_on(sky), "nor the sky")
	for n: Node in [weather, floor_mesh, water, sky]:
		n.free()


func test_dynamic_weather_leaves_the_maps_weather_unused() -> void:
	var weather := WeatherSystem.new()
	weather._current_type = 1
	weather._current_intensity = 9
	ServerVars.set_from_string("dynamic_weather", "on")
	ServerVars.set_from_string("rain", "0")
	assert_eq(weather.rain_amount(), 0.0, "a dry spell is dry whatever the map asked for")
	ServerVars.set_from_string("rain", "0.2")
	assert_almost_eq(weather.rain_amount(), 0.2, 1e-6, "and a shower is the cycle's")
	ServerVars.set_from_string("dynamic_weather", "off")
	ServerVars.set_from_string("rain", "0")
	assert_almost_eq(weather.rain_amount(), 1.0, 1e-6, "off again, the map's weather is back")
	weather.free()


func test_the_wind_vars_blow_overcast_wind() -> void:
	var weather := WeatherSystem.new()
	ServerVars.set_from_string("wind", "4")
	ServerVars.set_from_string("wind_dir", "90")
	weather._apply_wind()
	assert_vec3_almost_eq(weather.wind, Vector3(4.0, 0.0, 0.0), 1e-5, "4 m/s toward +X")
	ServerVars.set_from_string("wind", "0")
	ServerVars.set_from_string("wind_dir", "0")
	weather._apply_wind()
	assert_eq(weather.wind, Vector3.ZERO, "calm")
	weather.free()


func test_every_hour_lights_the_rain_with_a_number() -> void:
	for t in ["0", "6", "12", "18", "18:30", "23.75"]:
		ServerVars.set_from_string("time", NightMode.parse(t))
		var n := NightMode.night_light()
		assert_true(n.x >= 0.0 and n.y >= 0.0 and n.z >= 0.0, "%s never goes below black" % t)
		var sky := WeatherSystem.sky_light_now()
		assert_false(is_nan(sky.r) or is_nan(sky.g) or is_nan(sky.b), "%s lights the rain with a number" % t)
	ServerVars.set_from_string("time", "12")


func test_time_reads_as_hours_names_and_clock_times() -> void:
	assert_eq(NightMode.parse("18:30"), "18.5", "h:mm")
	assert_eq(NightMode.parse("dusk"), "18.0", "a name")
	assert_eq(NightMode.parse("6"), "6.0", "plain hours")
	assert_eq(NightMode.parse("25"), "", "past the clock")
	assert_eq(NightMode.parse("12:75"), "", "not a minute")
	assert_eq(NightMode.format(18.5), "18:30", "and back")
	ServerVars.set_from_string("time", "12")
	assert_eq(NightMode.night_light(), Vector3.ONE, "noon is the map as lit")
	ServerVars.set_from_string("time", "0")
	assert_almost_eq(NightMode.amount(), 1.0, 1e-6, "midnight is full night")
	ServerVars.set_from_string("time", "12")


## The extension bakes its rain floor from the max-X corner and Overcast reads from the min-X one:
## the conversion must land every column where the extension put it.
func test_the_maps_rain_floor_lands_where_the_extension_baked_it() -> void:
	var img := Image.create_empty(5, 3, false, Image.FORMAT_RF)
	for y in 3:
		for x in 5:
			img.set_pixel(x, y, Color(x * 10 + y, 0, 0))
	var origin := Vector3(4.0, 0.0, -1.0)
	var size := Vector2(5.0, 3.0)
	var map_root := Node3D.new()
	map_root.set_meta("rain_floor", {"image": img, "origin": origin, "size": size, "top": 9.0})
	var under := Image.create_empty(5, 3, false, Image.FORMAT_RGF)
	for y in 3:
		for x in 5:
			under.set_pixel(x, y, Color(x * 10 + y - 1, x * 10 + y - 3, 0))
	map_root.get_meta("rain_floor")["under"] = under
	var weather := WeatherSystem.new()
	weather._take_rain_floor(map_root)
	for q in [Vector3(3.5, 0, -0.5), Vector3(-0.5, 0, 1.5), Vector3(1.2, 0, 0.7)]:
		# goldsrc-godot's own lookup (rain_floor.gdshaderinc before Overcast).
		var u: float = (origin.x - q.x) / size.x
		var v: float = (q.z - origin.z) / size.y
		var want := img.get_pixel(int(u * 5), int(v * 3)).r
		assert_eq(weather.floor_at(q), want, "column at %s" % q)
		# The air under cover is flipped with it: Overcast reads it by the same column.
		var f: OvercastRainFloor = weather.rain_floor
		var cell := Vector2i(int((q.x - f.origin.x) / f.size.x * 5), int((q.z - f.origin.z) / f.size.y * 3))
		assert_eq(f.under.get_pixel(cell.x, cell.y).r, want - 1.0, "air under the column at %s" % q)
	weather.free()
	map_root.free()


## Rain wets the map only where it has a rain floor, and each surface pools as its texture would.
func test_the_maps_surfaces_pool_by_their_material() -> void:
	var wet := Shader.new()
	wet.code = 'shader_type spatial;\n#include "res://addons/overcast/shaders/wet.gdshaderinc"\nvoid fragment() {}'
	var map_root := Node3D.new()
	var mats := {}
	for tex in ["out_wd", "grass1"]:
		var mi := MeshInstance3D.new()
		mi.name = tex
		mi.mesh = BoxMesh.new()
		var mat := ShaderMaterial.new()
		mat.shader = wet
		mi.mesh.surface_set_material(0, mat)
		map_root.add_child(mi)
		mats[tex] = mat
	var weather := WeatherSystem.new()
	weather.wet_ground = false
	weather._take_rain_floor(map_root)
	assert_false(weather.wet_ground, "a map with no rain floor stays dry")
	var img := Image.create_empty(2, 2, false, Image.FORMAT_RF)
	map_root.set_meta("rain_floor", {"image": img, "origin": Vector3(2, 0, 0), "size": Vector2(2, 2), "top": 9.0})
	weather._take_rain_floor(map_root)
	assert_true(weather.wet_ground, "one with a floor gets wet")
	assert_eq(mats["out_wd"].get_shader_parameter("puddle_scale"), 0.0, "wood drains")
	assert_eq(mats["grass1"].get_shader_parameter("puddle_scale"),
		WeatherSystem.PUDDLE_BY_CLASS.get(WorldMaterials.classify("grass1"), WeatherSystem.PUDDLE_DEFAULT),
		"and the rest pool as their class does")
	weather.free()
	map_root.free()


func test_the_server_sends_the_grounds_wetness_in_steps() -> void:
	var weather := _roofed_weather()
	weather.ground.wetness = 0.51
	weather.ground.ice = 0.26
	weather._share_ground()
	assert_eq(weather._ground_sent, Vector3(0.5, 0.25, 0.0), "to the nearest step")
	assert_eq(weather.footing(Vector3(1, 0, 0)).x, 0.5, "out in the rain the ground is that wet")
	assert_eq(weather.footing(Vector3(-1, 0, 0)), Vector2.ZERO, "under the roof it is dry")
	weather.free()


## Holding it between sends is Overcast's `soaks` (tested there); WW turns it off on a client.
func test_a_client_draws_and_goes_by_the_servers_wetness() -> void:
	var weather := _roofed_weather()
	weather.ground.wetness = 0.2
	weather.set_ground(0.5, 0.25, 0.0)
	assert_eq(weather.ground.wetness, 0.5, "it draws the server's ground")
	assert_eq(weather.ground.ice, 0.25, "frozen as far")
	assert_eq(weather.footing(Vector3(1, 0, 0)).x, 0.5, "and its footing is the server's")
	weather.free()


func test_soaked_ground_is_slick_and_stacks_with_frost() -> void:
	var weather := _roofed_weather()
	weather.set_ground(1.0, 0.0, 0.0)
	var was: WeatherSystem = Game.weather_system
	Game.weather_system = weather
	var body := Node3D.new()
	var ctx := PlayerMovementContext.new(body, null, null)
	var state := Movement.MovementState.new()
	var slick := float(ServerVars.get_value("wet_friction", 1.0))
	assert_lt(slick, 1.0, "soaked ground is slicker than dry")
	assert_gt(slick, 0.5, "but only a little")
	state.position = Vector3(1, 0, 0)
	var mods := Movement.MovementModifiers.new()
	mods.friction_scale = 0.15
	ctx._slick_when_wet(mods, state)
	assert_almost_eq(mods.friction_scale, 0.15 * slick, 1e-6, "out in the rain, on top of frost")
	state.position = Vector3(-1, 0, 0)
	mods = Movement.MovementModifiers.new()
	ctx._slick_when_wet(mods, state)
	assert_eq(mods.friction_scale, 1.0, "under the roof the footing is dry")
	Game.weather_system = was
	body.free()
	weather.free()


func test_ice_spells_freeze_wet_ground_slick_and_fire_thaws_it() -> void:
	var weather := _roofed_weather()
	weather.set_ground(1.0, 0.0, 0.0)
	var was: WeatherSystem = Game.weather_system
	Game.weather_system = weather
	var body := Node3D.new()
	var ctx := PlayerMovementContext.new(body, null, null)
	var state := Movement.MovementState.new()
	state.position = Vector3(1.5, 0, 0.5)
	var wet := float(ServerVars.get_value("wet_friction", 1.0))
	var icy := float(ServerVars.get_value("ice_friction", 1.0))
	assert_lt(icy, wet, "ice is slicker than wet")
	WeatherSystem.heat_ground(state.position, IceShard.GROUND_FREEZE_RADIUS, -1.0)
	assert_eq(weather.footing(state.position).y, 1.0, "a shard freezes the wet ground over")
	var mods := Movement.MovementModifiers.new()
	ctx._slick_when_wet(mods, state)
	assert_almost_eq(mods.friction_scale, icy, 1e-6, "and it is ice to walk on")
	NetworkManager.test_authority = NetworkManager.TestAuthority.CLIENT
	WeatherSystem.heat_ground(state.position, 2.0)
	NetworkManager.test_authority = NetworkManager.TestAuthority.REAL
	assert_eq(weather.footing(state.position).y, 1.0, "a client's own blast leaves the server's ice be")
	WeatherSystem.heat_ground(state.position, 2.0)
	mods = Movement.MovementModifiers.new()
	ctx._slick_when_wet(mods, state)
	assert_almost_eq(mods.friction_scale, wet, 1e-6, "fire thaws it back to wet")
	weather.set_ground(0.0, 0.0, 0.0)
	WeatherSystem.heat_ground(state.position, IceShard.GROUND_FREEZE_RADIUS, -1.0)
	assert_eq(weather.footing(state.position), Vector2.ZERO, "dry ground has nothing to freeze")
	Game.weather_system = was
	body.free()
	weather.free()


func test_a_joining_client_takes_up_the_servers_ice() -> void:
	var server := _roofed_weather()
	server.ground.wetness = 1.0
	server.ground.heat(Vector3(1.5, 0, 0.5), 0.6, -1.0)
	var cells := server.ground.ice_cells()
	var client := _roofed_weather()
	client.set_ice(cells.size(), cells.compress(FileAccess.COMPRESSION_ZSTD))
	client.set_ground(1.0, 0.0, 0.0)
	assert_eq(client.footing(Vector3(1.5, 0, 0.5)).y, 1.0, "frozen where the server's is")
	assert_eq(client.footing(Vector3(0.5, 0, 0.5)).y, 0.0, "and not where it is not")
	server.free()
	client.free()


func test_a_joining_client_takes_up_the_servers_snow() -> void:
	var server := _roofed_weather()
	server.rain = 1.0
	server.temperature = -5.0
	server.settle()
	var at := Vector3(1.5, 0, 0.5)
	assert_true(server.ground.heat(at, 0.6), "the server melts its own snow")
	var ground := server._shared_ground()
	assert_eq(ground.z, 1.0, "and sends how far it has snowed over")
	var cells := server.ground.snow_cells()
	var client := _roofed_weather()
	client.set_ground(ground.x, ground.y, ground.z)
	client.set_snow(cells.size(), cells.compress(FileAccess.COMPRESSION_ZSTD))
	assert_eq(client.ground.snow_cover, 1.0, "the client draws the server's cover")
	assert_eq(client.ground.snow_depth_at(at), 0.0, "bare where the server's is")
	assert_almost_eq(client.ground.snow_depth_at(Vector3(0.5, 0, 0.5)), WeatherSystem.DRIFT_LAYER, 1e-3,
		"and snowed over where it is not")
	server.free()
	client.free()


func test_the_temperature_var_turns_the_fall_to_snow() -> void:
	var weather := WeatherSystem.new()
	ServerVars.set_from_string("rain", "0.6")
	ServerVars.set_from_string("temperature", "-5")
	weather._apply_rain()
	assert_almost_eq(weather.rain, 0.6, 1e-6, "how much falls is still the rain var")
	assert_almost_eq(weather.snowfall, 0.6, 1e-6, "and below freezing all of it is snow")
	assert_eq(weather.rainfall, 0.0, "none of it rain")
	ServerVars.set_from_string("temperature", "10")
	weather._apply_rain()
	assert_eq(weather.snowfall, 0.0, "warm, it is rain again")
	ServerVars.set_from_string("rain", "0")
	weather.free()


## The commands reply to their sender, which asks the peer who it is: offline here, as a lone host.
func _offline_host() -> MultiplayerPeer:
	var was := CommandSystem.multiplayer.multiplayer_peer
	CommandSystem.multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	return was


func test_temperature_sets_the_var_and_refuses_what_is_not_a_number() -> void:
	var was := _offline_host()
	var me: int = CommandSystem.multiplayer.get_unique_id()
	CommandSystem._cmd_temperature(me, "-3.5")
	assert_eq(float(ServerVars.get_value("temperature")), -3.5, "set")
	CommandSystem._cmd_temperature(me, "cold")
	assert_eq(float(ServerVars.get_value("temperature")), -3.5, "a word is refused")
	ServerVars.set_from_string("temperature", "10")
	CommandSystem.multiplayer.multiplayer_peer = was


## The map's world shaders take Overcast's wet ground and lying snow through the hook.
func test_the_world_hook_compiles_with_wet_ground_and_snow() -> void:
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
#define GOLDSRC_HOOK_WORLD
#include "res://shaders/goldsrc_hook.gdshaderinc"
varying vec3 world_pos;
void vertex() { world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
void fragment() {
	vec3 lit = goldsrc_lightmap(vec3(0.5), 1.0, world_pos);
	vec3 albedo = vec3(0.5);
	goldsrc_surface(lit, albedo, vec3(1.0), 1.0, world_pos, vec3(0.0, 1.0, 0.0), NORMAL, VIEW);
	ALBEDO = albedo + lit;
}
"""
	var declared := {}
	for u in shader.get_shader_uniform_list():
		declared[u["name"]] = true
	assert_true(declared.has("puddle_scale"), "the hook wets the ground")
	assert_true(declared.has("snow_scale"), "and lays snow on it")


func test_fire_melts_the_lying_snow_where_it_lands() -> void:
	var img := Image.create_empty(10, 6, false, Image.FORMAT_RF)
	var weather := WeatherSystem.new()
	weather.rain_floor = OvercastRainFloor.create(img, Vector3.ZERO, Vector2(10, 6), 10.0)
	weather.rain = 1.0
	weather.temperature = -5.0
	weather.settle()
	var was: WeatherSystem = Game.weather_system
	Game.weather_system = weather
	var at := Vector3(5.5, 0.0, 3.5)
	assert_almost_eq(weather.ground.snow_depth_at(at), WeatherSystem.DRIFT_LAYER, 1e-4, "snowed over")
	NetworkManager.test_authority = NetworkManager.TestAuthority.CLIENT
	WeatherSystem.heat_ground(at, 2.0)
	NetworkManager.test_authority = NetworkManager.TestAuthority.REAL
	assert_almost_eq(weather.ground.snow_depth_at(at), WeatherSystem.DRIFT_LAYER, 1e-4, "a client's own blast leaves the server's snow be")
	WeatherSystem.heat_ground(at, 2.0)
	assert_eq(weather.ground.snow_depth_at(at), 0.0, "bare where the server's fire landed, drawn or not")
	assert_almost_eq(weather.ground.snow_depth_at(Vector3(9.5, 0.0, 3.5)), WeatherSystem.DRIFT_LAYER, 1e-4,
		"and snowed over past its reach")
	Game.weather_system = was
	weather.free()


func test_wind_set_by_hand_and_handed_back() -> void:
	var was := _offline_host()
	var me: int = CommandSystem.multiplayer.get_unique_id()
	CommandSystem._cmd_wind(me, "8 450")
	assert_eq(float(ServerVars.get_value("wind")), 8.0, "8 m/s")
	assert_eq(float(ServerVars.get_value("wind_dir")), 90.0, "toward +X, however many times round")
	assert_false(bool(ServerVars.get_value("dynamic_wind")), "set by hand, it no longer varies")
	CommandSystem._cmd_wind(me, "-1")
	assert_eq(float(ServerVars.get_value("wind")), 8.0, "a wind below calm is refused")
	CommandSystem._cmd_wind(me, "auto")
	assert_true(bool(ServerVars.get_value("dynamic_wind")), "auto hands it back")
	ServerVars.set_from_string("wind", "0")
	ServerVars.set_from_string("wind_dir", "0")
	CommandSystem.multiplayer.multiplayer_peer = was


## Drifts are lit as the models are: their shader takes the light grid's uniforms.
func test_drifts_take_the_light_grid() -> void:
	var shader: Shader = load("res://shaders/snow_drift.gdshader")
	var names := {}
	for u in shader.get_shader_uniform_list():
		names[u["name"]] = true
	for n in ["acube_pos_y", "acube_sun", "grid_origin", "sky_light", "linear_output"]:
		assert_true(names.has(n), "it compiles, and takes %s" % n)
	var model: Shader = load("res://shaders/mdl_ambient_cube.gdshader")
	assert_false(model.get_shader_uniform_list().is_empty(), "and the models still compile around the same light")


## A liquid's bed, which is all the rain floor sees under it, keeps no snow: world water on its
## layer, and a func_water before FuncWater has put its Volume there.
func test_liquids_keep_the_snow_off_their_beds() -> void:
	var map := Node3D.new()
	_root().add_child(map)
	var pool := Area3D.new()
	pool.collision_layer = GameConsts.MASK_WATER
	map.add_child(pool)
	var shape := CollisionShape3D.new()
	var convex := ConvexPolygonShape3D.new()
	convex.points = PackedVector3Array([Vector3(1, -1, 1), Vector3(3, -1, 1), Vector3(3, 0, 5), Vector3(1, 0, 5)])
	shape.shape = convex
	pool.add_child(shape)
	var water := Node3D.new()
	water.set_meta("entity", {"classname": "func_water"})
	map.add_child(water)
	var volume := Area3D.new()
	volume.name = "Volume"
	water.add_child(volume)
	var shape2 := CollisionShape3D.new()
	var convex2 := ConvexPolygonShape3D.new()
	convex2.points = PackedVector3Array([Vector3(6, -1, 1), Vector3(8, -1, 1), Vector3(8, 0, 5), Vector3(6, 0, 5)])
	shape2.shape = convex2
	volume.add_child(shape2)
	var img := Image.create_empty(10, 6, false, Image.FORMAT_RF)
	img.fill_rect(Rect2i(1, 1, 2, 4), Color(-1.0, 0, 0))
	img.fill_rect(Rect2i(6, 1, 2, 4), Color(-1.0, 0, 0))
	var weather := WeatherSystem.new()
	weather.presenting = true
	weather.rain_floor = OvercastRainFloor.create(img, Vector3.ZERO, Vector2(10, 6), 10.0)
	weather._keep_snow_off_liquids(map)
	weather.rain = 1.0
	weather.temperature = -5.0
	weather.settle()
	assert_eq(weather.ground.snow_depth_at(Vector3(2.5, -1, 3.5)), 0.0, "none on the pool's bed")
	assert_eq(weather.ground.snow_depth_at(Vector3(7.5, -1, 3.5)), 0.0, "nor the func_water's")
	assert_gt(weather.ground.snow_depth_at(Vector3(4.5, 0, 3.5)), 0.0, "the ground between keeps its snow")
	weather.free()
	map.queue_free()
