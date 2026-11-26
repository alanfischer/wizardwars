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


func test_a_sky_lid_is_no_cover() -> void:
	var weather := WeatherSystem.new()
	weather.rain_floor = OvercastRainFloor.create(Image.create_empty(2, 2, false, Image.FORMAT_RF),
		Vector3(-1, 0, -1), Vector2(2, 2), 10.0)
	var bodies: Array[AnimatableBody3D] = []
	for layer in [1, GameConsts.MASK_WORLD_SKY, 0]:
		var body := AnimatableBody3D.new()
		body.collision_layer = layer
		var mesh := MeshInstance3D.new()
		mesh.mesh = BoxMesh.new()
		body.add_child(mesh)
		weather.add_child(body)
		weather._cover_if_solid(body)
		bodies.append(body)
	assert_true(weather.has_cover(bodies[0]), "a solid brush keeps the rain off")
	assert_false(weather.has_cover(bodies[1]), "an all-sky brush ({blue lid) does not")
	assert_false(weather.has_cover(bodies[2]), "nor does one that is not solid")
	weather.free()


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
	var full := NightMode.night_light()
	assert_eq(NightMode.parse_moon("new"), "0.0", "a moon by name")
	assert_eq(NightMode.parse_moon("0.3"), "0.3", "or by phase")
	assert_eq(NightMode.parse_moon("2"), "", "but not past its month")
	ServerVars.set_from_string("moon", "0")
	assert_lt(NightMode.night_light().x, full.x, "a new moon leaves midnight darker")
	assert_gt(NightMode.night_light().x, 0.0, "though never black")
	ServerVars.set_from_string("moon", "0.5")
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
	assert_almost_eq(mods.accel_scale, icy, 1e-6, "which takes the grip twice over, as frost does")
	NetworkManager.test_authority = NetworkManager.TestAuthority.CLIENT
	WeatherSystem.heat_ground(state.position, 2.0)
	NetworkManager.test_authority = NetworkManager.TestAuthority.REAL
	assert_eq(weather.footing(state.position).y, 1.0, "a client's own blast leaves the server's ice be")
	WeatherSystem.heat_ground(state.position, 2.0)
	mods = Movement.MovementModifiers.new()
	ctx._slick_when_wet(mods, state)
	assert_almost_eq(mods.friction_scale, wet, 1e-6, "fire thaws it back to wet")
	assert_eq(mods.accel_scale, 1.0, "and wet alone only the once")
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
	vec3 lit = goldsrc_lightmap(vec3(0.5), vec2(1.0, 0.5), world_pos);
	vec3 albedo = vec3(0.5);
	goldsrc_surface(lit, albedo, vec3(1.0), 1.0, world_pos, vec3(0.0, 1.0, 0.0), NORMAL, VIEW);
	ALBEDO = albedo + lit;
}
void light() {
	goldsrc_light(DIFFUSE_LIGHT, LIGHT, LIGHT_COLOR, ATTENUATION, LIGHT_IS_DIRECTIONAL, NORMAL, ALBEDO,
		vec3(1.0), vec3(0.5), world_pos, 2.0);
}
"""
	var declared := {}
	for u in shader.get_shader_uniform_list():
		declared[u["name"]] = true
	assert_true(declared.has("puddle_scale"), "the hook wets the ground")
	assert_true(declared.has("snow_scale"), "and lays snow on it")
	assert_true(declared.has("sun_unbaked"), "and can hand the sun to a real-time light")


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


## A 20 m strip from x = 0, open ground at 0 but for a wall 2 m high over x 10..11; wind toward +X.
func _walled_weather() -> WeatherSystem:
	var img := Image.create_empty(20, 1, false, Image.FORMAT_RF)
	img.set_pixel(10, 0, Color(2.0, 0, 0))
	var weather := WeatherSystem.new()
	weather.rain_floor = OvercastRainFloor.create(img, Vector3(0, 0, -0.5), Vector2(20, 1), 10.0)
	weather.wind = Vector3(10, 0, 0)
	return weather


func test_the_wind_reaches_the_open_but_not_under_a_roof_or_in_a_lee() -> void:
	var weather := _walled_weather()
	assert_eq(weather.wind_exposure(Vector3(19, 1, 0)), 1.0, "well downwind of the wall, in the open")
	assert_eq(weather.wind_exposure(Vector3(8, 1, 0)), 1.0, "upwind of it too")
	assert_almost_eq(weather.wind_exposure(Vector3(12.5, 1, 0)), 2.0 / 3.0, 1e-6,
		"2 m behind a wall standing 1 m above, its lee is a third of the way to open")
	assert_lt(weather.wind_exposure(Vector3(11.5, 0.2, 0)), 0.2, "right behind it, low down: hardly any")
	assert_eq(weather.wind_exposure(Vector3(12.5, 3, 0)), 1.0, "above the wall's top: all of it")
	assert_eq(weather.wind_exposure(Vector3(19, -0.2, 0)), 1.0, "a spark on the ground just under its own cell is out in it")
	weather.free()
	weather = _roofed_weather()
	weather.wind = Vector3(10, 0, 0)
	assert_eq(weather.wind_exposure(Vector3(-1, 1, 0)), 0.0, "under the roof")
	weather.free()
	weather = WeatherSystem.new()
	weather.wind = Vector3(10, 0, 0)
	assert_eq(weather.wind_exposure(Vector3(0, 1, 0)), 0.0, "no rain floor, no telling the sky: none")
	weather.free()


func test_the_wind_pushes_by_its_square_up_to_its_own_speed() -> void:
	var weather := _walled_weather()
	var at := Vector3(19, 1, 0)
	var gale := weather.wind_push(at, Vector3.ZERO)
	assert_vec3_almost_eq(gale, Vector3(WeatherSystem.WIND_PUSH * 100.0, 0, 0), 1e-5, "downwind")
	weather.wind = Vector3(5, 0, 0)
	assert_almost_eq(weather.wind_push(at, Vector3.ZERO).x, gale.x / 4.0, 1e-5, "half the wind, a quarter the push")
	assert_eq(weather.wind_push(at, Vector3(5, 0, 0)), Vector3.ZERO, "moving with it as fast as it blows")
	assert_gt(weather.wind_push(at, Vector3(0, 0, 8)).x, 0.0, "across it, carried along")
	assert_eq(weather.wind_push(at, Vector3.ZERO, 0.0), Vector3.ZERO, "a weightless push is none")
	ServerVars.set_from_string("wind_push", "0")
	assert_eq(weather.wind_push(at, Vector3.ZERO), Vector3.ZERO, "wind_push 0 turns it off")
	ServerVars.set_from_string("wind_push", "1")
	weather.wind = Vector3.ZERO
	assert_eq(weather.wind_push(at, Vector3.ZERO), Vector3.ZERO, "calm")
	weather.free()


func test_the_wind_carries_a_player_in_the_air_and_a_projectile() -> void:
	var weather := _walled_weather()
	var was: WeatherSystem = Game.weather_system
	Game.weather_system = weather
	var body := Node3D.new()
	var ctx := PlayerMovementContext.new(body, null, null)
	var cfg := preload("res://addons/pmove/movement_config.gd").new()
	var cmd := preload("res://addons/pmove/input_command.gd").new()
	cmd.delta = 0.1
	var state := Movement.MovementState.new()
	state.position = Vector3(19, 0.5, 0)
	var mods := Movement.MovementModifiers.new()
	ctx._blown(mods, cfg, state, cmd)
	assert_gt(mods.velocity_add.x, 0.0, "in the air in the open, blown downwind")
	state.on_floor = true
	mods = Movement.MovementModifiers.new()
	ctx._blown(mods, cfg, state, cmd)
	assert_gt(mods.velocity_add.x, 0.0, "on the ground too: friction is what holds you there")
	state.on_floor = false
	mods = Movement.MovementModifiers.new()
	mods.velocity_override_active = true
	ctx._blown(mods, cfg, state, cmd)
	assert_eq(mods.velocity_add, Vector3.ZERO, "on a ladder or swimming, not")
	var shot := Projectile.new()
	shot.set_physics_process(false)
	shot.set_process(false)
	_root().add_child(shot)
	shot.global_position = Vector3(19, 1, 0)
	shot.direction = Vector3(0, 0, 1)
	shot.speed = 20.0
	shot._blow(0.1)
	assert_gt(shot.direction.x, 0.0, "a shot across the wind bends downwind")
	assert_almost_eq(shot.direction.length(), 1.0, 1e-5, "and still flies one way")
	Game.weather_system = was
	shot.free()
	body.free()
	weather.free()



func test_the_wind_carries_every_moving_rigid_body() -> void:
	var weather := _walled_weather()
	var body := RigidBody3D.new()
	body.gravity_scale = 0.0
	_root().add_child(body)
	body.global_position = Vector3(19, 1, 0)
	weather._track_blown(body)
	var bone := PhysicalBone3D.new()
	weather._track_blown(bone)
	assert_true(weather._carried.has(bone), "a ragdoll's bones are carried too")
	weather._carried.erase(bone)
	bone.free()
	var rid := body.get_rid()
	PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3(0, 0, 12))
	weather._carry(0.1)
	var v: Vector3 = PhysicsServer3D.body_get_state(rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY)
	assert_almost_eq(v.x, WeatherSystem.WIND_PUSH * 100.0 * 0.1, 1e-4, "thrown across the wind, it drifts downwind")
	PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3(0.1, 0, 0))
	weather._carry(0.1)
	v = PhysicsServer3D.body_get_state(rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY)
	assert_eq(v, Vector3(0.1, 0, 0), "at rest it is left be, to sleep")
	body.freeze = true
	PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3(0, 0, 12))
	weather._carry(0.1)
	v = PhysicsServer3D.body_get_state(rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY)
	assert_eq(v.x, 0.0, "a frozen one is not this peer's to move")
	body.queue_free()
	await body.tree_exited
	assert_false(weather._carried.has(body), "gone from the tree, forgotten")
	weather.free()


## A stand-in tornado: a still column of air rising at `up` m/s within a metre of `at`.
class Updraft extends Node3D:
	var up := 30.0

	func airflow(p: Vector3, _who: Node = null) -> Vector3:
		var off := p - global_position
		off.y = 0.0
		return Vector3(0, up, 0) if off.length() < 1.0 else Vector3.ZERO


func _updraft_at(at: Vector3) -> Updraft:
	var source := Updraft.new()
	source.add_to_group(WeatherSystem.WIND_SOURCES)
	_root().add_child(source)
	source.global_position = at
	_keep(source)
	await _physics_frame()  # the sources are looked up once a physics frame
	return source


func test_a_wind_source_adds_its_own_air_under_any_roof() -> void:
	var weather := _roofed_weather()
	weather.wind = Vector3(10, 0, 0)
	await _updraft_at(Vector3(-1, 0, 0))
	assert_eq(weather.airflow(Vector3(-1, 1, 0)), Vector3(0, 30, 0), "under the roof, the source's air and none of the wind's")
	assert_eq(weather.airflow(Vector3(-4, 1, 0)), Vector3.ZERO, "out of its reach, still air")
	var push := weather.wind_push(Vector3(-1, 1, 0), Vector3.ZERO)
	assert_almost_eq(push.y, WeatherSystem.WIND_PUSH * 900.0, 1e-4, "pushing by the same rule as the wind")
	assert_eq(weather.wind_push(Vector3(-1, 1, 0), Vector3(0, 30, 0)), Vector3.ZERO, "and only up to its own speed")
	weather.free()
	weather = _walled_weather()
	assert_eq(weather.airflow(Vector3(19, 1, 0)), Vector3(10, 0, 0), "out in the open with no source near: just the wind")
	weather.free()


func test_air_that_lifts_harder_than_gravity_takes_you_off_your_feet() -> void:
	var weather := WeatherSystem.new()
	var source := await _updraft_at(Vector3(320, 0, 0))
	var at := Vector3(320, 1, 0)
	var change := weather.blow_walker(at, Vector3.ZERO, true, 20.0, 1.0 / 60.0)
	assert_almost_eq(change.y, WeatherSystem.LIFTOFF + 20.0 / 60.0, 1e-5, "standing, lifted off at LIFTOFF past this tick's gravity")
	change = weather.blow_walker(at, Vector3.ZERO, false, 20.0, 1.0 / 60.0)
	assert_almost_eq(change.y, WeatherSystem.WIND_PUSH * 900.0 / 60.0, 1e-5, "in the air, just carried")
	source.up = 20.0  # 12 m/s² of lift against 20 of gravity
	change = weather.blow_walker(at, Vector3.ZERO, true, 20.0, 1.0 / 60.0)
	assert_lt(change.y, 1.0, "a lift weaker than gravity leaves you standing")
	weather.free()


func test_a_wind_source_picks_up_a_body_at_rest() -> void:
	var weather := WeatherSystem.new()
	await _updraft_at(Vector3(300, 0, 0))
	var body := RigidBody3D.new()
	body.gravity_scale = 0.0
	_root().add_child(body)
	_keep(body)
	body.global_position = Vector3(300, 1, 0)
	weather._track_blown(body)
	var rid := body.get_rid()
	PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_SLEEPING, true)
	weather._carry(0.1)
	var v: Vector3 = PhysicsServer3D.body_get_state(rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY)
	assert_gt(v.y, 1.0, "asleep where the wind would leave it, the source lifts it")
	assert_false(PhysicsServer3D.body_get_state(rid, PhysicsServer3D.BODY_STATE_SLEEPING), "and wakes it")
	weather.free()


func test_a_monster_is_blown_like_a_player() -> void:
	var weather := _walled_weather()
	var was: WeatherSystem = Game.weather_system
	Game.weather_system = weather
	var host := CharacterBody3D.new()
	_root().add_child(host)
	_keep(host)
	host.global_position = Vector3(19, 1, 0)
	var walker := MonsterBody.new()
	walker.setup(host, 4.0, 1.8)
	walker.state.on_floor = false
	walker._blown(0.1)
	assert_gt(walker.state.velocity.x, 0.0, "carried downwind")
	walker.state.velocity = Vector3.ZERO
	walker.in_water = true
	walker._blown(0.1)
	assert_eq(walker.state.velocity, Vector3.ZERO, "but not while it swims")
	Game.weather_system = was
	weather.free()


func test_particles_near_a_wind_source_take_its_air() -> void:
	var weather := WeatherSystem.new()
	await _updraft_at(Vector3(310, 0, 0))
	var particles := preload("res://src/systems/wind_particles.gd").new(weather)
	var cpu := CPUParticles3D.new()
	cpu.gravity = Vector3(0, -2, 0)
	_root().add_child(cpu)
	_keep(cpu)
	cpu.global_position = Vector3(310, 1, 0)
	particles.track(cpu)
	particles._blow(cpu)
	assert_gt(cpu.gravity.y, 0.0, "sparks in an updraft go up")
	weather.free()


func test_particles_out_in_the_wind_drift_with_it() -> void:
	var weather := _walled_weather()
	weather._wind_now = Vector3(10, 0, 0)
	var particles := preload("res://src/systems/wind_particles.gd").new(weather)
	var cpu := CPUParticles3D.new()
	cpu.gravity = Vector3(0, -2, 0)
	_root().add_child(cpu)
	cpu.global_position = Vector3(19, 1, 0)
	particles.track(cpu)
	particles._blow(cpu)
	assert_gt(cpu.gravity.x, 0.0, "out in the open, drifting downwind")
	assert_eq(cpu.gravity.y, -2.0, "and falling as it did")
	var shared := ParticleProcessMaterial.new()
	shared.gravity = Vector3(0, -6, 0)
	var sparks: Array[GPUParticles3D] = []
	for at in [Vector3(19, 1, 0), Vector3(18, 1, 0), Vector3(10.5, 1, 0)]:
		var gpu := GPUParticles3D.new()
		gpu.process_material = shared
		_root().add_child(gpu)
		gpu.global_position = at
		particles.track(gpu)
		particles._blow(gpu)
		sparks.append(gpu)
	assert_eq(shared.gravity, Vector3(0, -6, 0), "the shared material is left as it was")
	assert_gt((sparks[0].process_material as ParticleProcessMaterial).gravity.x, 0.0, "sparks in the open drift")
	assert_eq(sparks[0].process_material, sparks[1].process_material, "and share one blown copy")
	assert_eq(sparks[2].process_material, shared, "sparks on the wall's top, under the floor, keep the shared one")
	weather._wind_now = Vector3.ZERO
	particles._blow(cpu)
	assert_eq(cpu.gravity, Vector3(0, -2, 0), "calm again, back to its own")
	cpu.free()
	for gpu in sparks:
		gpu.free()
	weather.free()
