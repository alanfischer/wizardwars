extends Node3D
## Throwaway: renders the procedural sky's clouds from a map's spawn. OUT=dir, MAPS=a,b, STORM=0.

func _ready() -> void:
	ServerVars.set_from_string("dynamic_weather", "1")
	var out := OS.get_environment("OUT")
	var storm := float(OS.get_environment("STORM")) if OS.get_environment("STORM") != "" else 0.0
	for map_name in OS.get_environment("MAPS").split(","):
		var map: Node3D = load("res://maps/%s.bsp" % map_name).instantiate()
		EntityRender.apply_color_space(map)
		add_child(map)
		var sky := Skybox.new()
		add_child(sky)
		var ws := map.get_node_or_null("worldspawn")
		var sky_name: String = ws.get_meta("entity").get("skyname", "") if ws else ""
		sky.setup(sky_name, map, _find(map, "light_environment"))
		sky.set_storm(storm)
		var spawn := _find(map, "info_player_deathmatch")
		if spawn.is_empty():
			spawn = _find(map, "info_player_start")
		if spawn.is_empty():
			spawn = _find(map, "info_player_teamspawn")
		var cam := Camera3D.new()
		cam.fov = 80.0
		cam.far = 4000.0
		add_child(cam)
		cam.global_position = _gs(spawn.get("origin", "0 0 0")) + Vector3(0, 1.0, 0)
		cam.current = true
		var sun: Vector3 = sky._params.get("sun_dir", Vector3.UP)
		var sun_yaw := rad_to_deg(atan2(-sun.x, -sun.z))
		var views := [[sun_yaw + 180.0, 20.0, "away"], [sun_yaw, 15.0, "sun"],
			[sun_yaw + 90.0, 55.0, "up"], [sun_yaw + 90.0, 8.0, "horizon"]]
		for v in views:
			cam.rotation_degrees = Vector3(v[1], v[0], 0)
			for i in 6:
				await get_tree().process_frame
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png("%s/%s_%s.png" % [out, map_name, v[2]])
		map.queue_free()
		sky.queue_free()
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
