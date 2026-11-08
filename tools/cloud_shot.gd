extends Node3D
## Renders the procedural sky's clouds from a map's spawn. OUT=dir, MAPS=a,b, STORM=0, VOL=1 for
## the volumetric (High quality) clouds, RAIN=0.8 for rain, SNOW=1 for it to fall as snow, WIND=8 for a wind
## to drift it (m/s, toward WIND_DIR degrees), MELT=1 to
## melt holes in it every 6 m, as fireballs would. PERF=1 instead prints the GPU frame time looking up, with
## the volumetric clouds off and on.

func _ready() -> void:
	ServerVars.set_from_string("dynamic_weather", "1")
	var out := OS.get_environment("OUT")
	var storm := float(OS.get_environment("STORM")) if OS.get_environment("STORM") != "" else 0.0
	for map_name in OS.get_environment("MAPS").split(","):
		# The converted scene the game plays, which carries the sun-share bake cloud shadows need.
		var scn := "user://resources/maps/%s.scn" % map_name
		var map: Node3D = load(scn if ResourceLoader.exists(scn) else "res://maps/%s.bsp" % map_name).instantiate()
		EntityRender.apply_color_space(map)
		add_child(map)
		AssetLoader.light_grid = LightGrid.from_meta(map)  # as main loads it, for what it lights
		var sky := Skybox.new()
		add_child(sky)
		Game.skybox = sky
		OvercastClouds.set_volumetric(OS.get_environment("VOL") == "1")
		var ws := map.get_node_or_null("worldspawn")
		var sky_name: String = ws.get_meta("entity").get("skyname", "") if ws else ""
		sky.setup(sky_name, map, _find(map, "light_environment"))
		if sky.overcast:
			sky.overcast.storm = storm
		if OS.get_environment("TIME") != "":
			ServerVars.set_from_string("time", OS.get_environment("TIME"))
		NightMode.apply(map)
		var weather: WeatherSystem = null
		if OS.get_environment("RAIN") != "":
			ServerVars.set_from_string("rain", OS.get_environment("RAIN"))
			if OS.get_environment("SNOW") != "":
				ServerVars.set_from_string("snow", OS.get_environment("SNOW"))
			if OS.get_environment("WIND") != "":
				ServerVars.set_from_string("wind", OS.get_environment("WIND"))
				ServerVars.set_from_string("wind_dir", OS.get_environment("WIND_DIR") if OS.get_environment("WIND_DIR") != "" else "0")
			weather = WeatherSystem.new()
			weather.map_root = map
			add_child(weather)
			Game.weather_system = weather
			weather.settle()
			weather.bake_drifts()
		var spawn := {}
		for cls in ["info_player_deathmatch", "info_player_start", "info_player_teamspawn"]:
			spawn = _find(map, cls)
			if not spawn.is_empty():
				break
		var cam := Camera3D.new()
		cam.fov = 80.0
		cam.far = 4000.0
		add_child(cam)
		cam.global_position = _gs(spawn.get("origin", "0 0 0")) + Vector3(0, 1.0, 0)
		cam.current = true
		var sun: Vector3 = sky._params.get("sun_dir", Vector3.UP)
		var sun_yaw := rad_to_deg(atan2(-sun.x, -sun.z))
		if weather and OS.get_environment("MELT") == "1" and weather.rain_floor:
			# A hole every 6 m over the whole rain floor, wherever the views end up looking.
			var f := weather.rain_floor
			var dims := f.image.get_size()
			var cell := f.size / Vector2(dims)
			for j in range(0, dims.y, ceili(6.0 / cell.y)):
				for i in range(0, dims.x, ceili(6.0 / cell.x)):
					weather.melt(Vector3(f.origin.x + (i + 0.5) * cell.x, f.image.get_pixel(i, j).r,
						f.origin.z + (j + 0.5) * cell.y), 1.5)
		if OS.get_environment("PERF") == "1":
			cam.rotation_degrees = Vector3(50.0, sun_yaw + 180.0, 0)
			DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
			Engine.max_fps = 0
			for vol in [false, true, false, true]:
				OvercastClouds.set_volumetric(vol)
				for i in 60:
					await get_tree().process_frame
				var t0 := Time.get_ticks_usec()
				for i in 300:
					await get_tree().process_frame
				var ms := (Time.get_ticks_usec() - t0) / 300.0 / 1000.0
				print("PERF %s %v %s %.2f ms/frame" % [map_name, DisplayServer.window_get_size(), "volumetric" if vol else "flat", ms])
			get_tree().quit()
			return
		var views := [[sun_yaw + 180.0, 20.0, "away"], [sun_yaw, 15.0, "sun"],
			[sun_yaw + 90.0, 55.0, "up"], [sun_yaw + 90.0, 8.0, "horizon"],
			[sun_yaw + 180.0, -30.0, "ground"]]
		for v in views:
			cam.rotation_degrees = Vector3(v[1], v[0], 0)
			for i in 6:
				await get_tree().process_frame
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png("%s/%s_%s.png" % [out, map_name, v[2]])
		map.queue_free()
		sky.queue_free()
		if weather:
			weather.queue_free()
		cam.queue_free()
		await get_tree().process_frame
	get_tree().quit()

func _find(root: Node, cls: String) -> Dictionary:
	for c in root.get_children():
		if c.has_meta("entity") and c.get_meta("entity").get("classname", "") == cls:
			return c.get_meta("entity")
	return {}

func _gs(s: String) -> Vector3:
	var p := s.split(" ")
	var g := Vector3(float(p[0]), float(p[1]), float(p[2]))
	return Vector3(-g.x, g.z, g.y) * GameConsts.SCALE_FACTOR
