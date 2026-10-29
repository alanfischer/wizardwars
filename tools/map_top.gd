extends Node3D
## Render a map from straight above, orthographically, as the backdrop for a match replay.
##
##   MAP=ww_ravine SHOT=/tmp/ww_ravine.png godot --path . res://tools/map_top.tscn
##
## NOT --headless: that installs the dummy rasterizer and the viewport has no pixels in it. This
## is a one-off per map, so a window appearing for a few seconds is the right trade.
##
## Alongside the PNG it writes <SHOT>.json with the world->pixel transform, so the compositor can
## place a bot at a world position without knowing anything about the camera. An orthographic
## camera makes that mapping a plain linear one, which is the whole reason for using it.

const TopDownFrame = preload("res://src/systems/top_down_frame.gd")

const PIXELS_PER_M := 6.0 # resolution of the backdrop


func _ready() -> void:
	var name_ := OS.get_environment("MAP")
	var out := OS.get_environment("SHOT")
	if name_.is_empty() or out.is_empty():
		push_error("[MapTop] set MAP and SHOT")
		get_tree().quit(1)
		return
	var map: Node3D = load("res://maps/%s.bsp" % name_).instantiate()
	EntityRender.apply_color_space(map)
	add_child(map)
	for _i in 10:
		await get_tree().process_frame

	var raw := TopDownFrame.world_aabb(map)
	if raw.size == Vector3.ZERO:
		push_error("[MapTop] %s has no geometry" % name_)
		get_tree().quit(1)
		return
	# CUT overrides the roof guess on the maps it gets wrong.
	var cut_override := float(OS.get_environment("CUT")) \
			if not OS.get_environment("CUT").is_empty() else INF
	var f := TopDownFrame.frame(raw, cut_override)
	var span: float = f["span"]
	var px := int(clampi(int(span * PIXELS_PER_M), 256, 2048))
	# A SubViewport, not the window's own: setting size on the root viewport does not take, so
	# the first render came out at the window's 1280x720 and every world->pixel mapping derived
	# from it was wrong. An explicit square target is the only way to know what a pixel means.
	var sub := SubViewport.new()
	sub.size = Vector2i(px, px)
	sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	sub.own_world_3d = false
	add_child(sub)

	var cam := TopDownFrame.make_camera(f)
	sub.add_child(cam)
	cam.current = true

	# Albedo only. A lit render of a map from above is mostly black — the interiors have no sky
	# light reaching them — and for a tactical backdrop the texture IS the information.
	sub.debug_draw = Viewport.DEBUG_DRAW_UNSHADED

	for _i in 30:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := sub.get_texture().get_image()
	img.save_png(out)

	var meta := TopDownFrame.meta(name_, px, f)
	FileAccess.open(out + ".json", FileAccess.WRITE).store_string(JSON.stringify(meta, "  "))
	print("[MapTop] %s -> %s (%dpx, %.1fm across)" % [name_, out, px, span])
	get_tree().quit()

