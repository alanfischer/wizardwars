extends Node3D
func _ready() -> void:
	var cam := Camera3D.new()
	cam.position = Vector3(0, 0, 6)
	add_child(cam)
	cam.current = true
	RenderingServer.set_default_clear_color(Color(0.05, 0.05, 0.1))
	# a straight beam, a noisy one, and a colour-ramped one
	BeamSystem.create_tracked(self, Vector3(-4, 2, 0), Vector3(4, 2, 0),
		{"color": Color(0.3, 0.8, 1.0, 1.0), "width": 0.25, "segments": 8})
	BeamSystem.create_tracked(self, Vector3(-4, 0, 0), Vector3(4, 0, 0),
		{"color": Color(1.0, 0.5, 0.1, 1.0), "width": 0.18, "segments": 16,
		 "noise_fn": func(t): return Vector3(0, sin(t * 22.0) * 0.45, 0)})
	BeamSystem.create_tracked(self, Vector3(-4, -2, 0), Vector3(4, -2, 0),
		{"width": 0.3, "segments": 12, "uv_tiles": 4.0,
		 "color_fn": func(t): return Color(1.0 - t, t, 0.4, 1.0)})
	var trail := TrailFader.new()
	trail.width = 0.5
	trail.max_life = 99.0
	add_child(trail)
	for i in 20:
		trail.add_point(Vector3(-4.0 + i * 0.42, -3.4 + sin(i * 0.6) * 0.6, 0))
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(OS.get_environment("WW_SHOT"))
	get_tree().quit()
