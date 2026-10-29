extends Node3D
## Throwaway: loads a map, points a camera at a goldsrc position, saves a PNG.

func _ready() -> void:
	var map = load("res://maps/%s.bsp" % OS.get_environment("MAP")).instantiate()
	EntityRender.apply_color_space(map)
	add_child(map)
	var cam := Camera3D.new()
	cam.fov = 75.0
	cam.far = 4000.0
	add_child(cam)
	var target := _gs(OS.get_environment("TARGET"))
	var eye := _gs(OS.get_environment("EYE"))
	cam.global_position = eye
	cam.look_at(target, Vector3.UP)
	cam.current = true
	var l := DirectionalLight3D.new()
	l.rotation_degrees = Vector3(-50, -30, 0)
	l.light_energy = 0.6
	add_child(l)
	for i in 20:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(OS.get_environment("SHOT"))
	print("eye=", eye, " target=", target)
	get_tree().quit()

func _gs(s: String) -> Vector3:
	var p := s.split(" ")
	var g := Vector3(float(p[0]), float(p[1]), float(p[2]))
	return Vector3(-g.x, g.z, g.y) * GameConsts.SCALE_FACTOR
