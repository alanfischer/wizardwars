extends Node
## Render one frame of a map's water to a PNG, so water can be judged by looking at it.
##
## Every visual change to the liquid so far was made blind and tuned by argument: the waves were
## set to 8cm because GoldSrc's were gentle, the crest shading to 15% because that seemed tasteful,
## and absorption was declared working on the strength of a log line. The result was invisible, and
## then briefly white. This is the missing feedback loop.
##
## Must run WINDOWED — the headless renderer draws nothing, so the capture would be blank.
##
##   godot --path . tools/shot_water.tscn -- --map ww_2fort --water on --out /tmp/on.png
##
## Args: --map <name>  --water on|off  --out <path>  [--eye x,y,z] [--look x,y,z] [--sky on|off]
##       [--sprite x,y,z]  drop a fireball's sprite there, to see whether liquid occludes it
##       [--orbit N]      shoot N frames instead of one, panning the eye around --look, and
##                        write them as <out>_00.png.. — a still frame cannot show popping, and
##                        popping is what water's sorting bugs look like from inside the game.
##       [--layers on]    count the liquid layers surviving the depth test instead of shading
##                        them; see the flag's own note below.
##       [--hide <meta>]  hide every mesh carrying that metadata flag — is_water_surface for
##                        "what is behind the water", is_sky_surface for "is that the sky".
##       [--bias f]       rewrite the depth twin's 1.002 depth push; see the flag's own note
##       [--arc D]        how many degrees the orbit sweeps (default 60)
##       [--outward on]   orbit facing AWAY from the centre, which is what walking a shoreline
##                        looking at the water actually is
##       [--pvs off]      do not register worldspawn groups for PVS culling — the control for
##                        "is PVS taking away water the frame should have had?"
##       [--walk a:b]     slide the eye from a to b over --orbit frames, keeping the look
##                        direction, the way a player walks an edge. PVS re-culls per leaf
##                        crossed, so this is the mode that shows a group blinking out.
##
## PVS is LIVE here, exactly as main.gd sets it up. Without it the capture shows geometry the
## game would have culled, which is how a whole class of liquid artefact stays invisible to
## this tool: the depth prepass only stamps liquid that is drawn.

const DEFAULT_MAP := "ww_2fort"
## Over ww_2fort's moat (*229, GoldSrc centre 32,0,-218, surface at z -116), in Godot units.
## GoldSrc (x, y, z) maps to Godot (-x, z, y) * SCALE_FACTOR.
const DEFAULT_EYE := Vector3(-0.8, 0.6, 7.0)
const DEFAULT_LOOK := Vector3(-0.8, -2.9, 0.0)
const WARMUP_FRAMES := 30  # shaders compile on first draw; a cold capture is a black frame
const ORBIT_ARC := PI / 3.0  # how far --orbit swings the eye, centred on the given one


func _ready() -> void:
	var args := _args()
	var map_name: String = args.get("map", DEFAULT_MAP)
	var water_on: bool = args.get("water", "on") == "on"
	var out_path: String = args.get("out", "user://water.png")

	var converter := MapConverter.new()
	add_child(converter)
	if not converter.convert(map_name):
		printerr("convert failed: %s" % map_name)
		get_tree().quit(1)
		return
	var scn := ResourceLoader.load("user://resources/maps/%s.scn" % map_name, "",
			ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	var map_root: Node3D = scn.instantiate()
	add_child(map_root)

	# The world shaders pick their colour space per load, exactly as main.gd does it.
	EntityRender.apply_color_space(map_root)

	# PVS, as main.gd's _register_worldspawn_pvs_groups sets it up. Worldspawn is culled a
	# spatial group at a time and only re-evaluated when the observer changes leaf, so a group
	# appears and disappears in steps as you walk — which is what this tool has to be able to
	# see. The liquid's depth prepass only stamps the liquid that is drawn, so a group carrying
	# a pool's surface going away leaves the faces below it with nothing to reject them.
	# --pvs off is the control: the same frame with nothing culled. Any water the PVS pass
	# removes that the control still draws is water the game is losing.
	VisibilitySystem.setup(map_root)
	var ws := map_root.get_node_or_null("worldspawn") as Node3D
	if ws and args.get("pvs", "on") == "on":
		for child in ws.get_children():
			if child is Node3D and child.has_meta("pvs_leaves"):
				VisibilitySystem.track_node_by_leaves(child.get_instance_id(), child as Node3D,
						child.get_meta("pvs_leaves") as PackedInt32Array)

	# Without this the map's sky brushes draw as flat grey, which reads in a capture as a
	# mysterious sheet across the scene.
	var sky := Skybox.new()
	add_child(sky)
	# skyname lives on the worldspawn NODE, not on the map root — read it anywhere else and it
	# comes back empty, Skybox.setup returns before it loads anything, and every capture is shot
	# under a black void that reads as "the water is a slab floating in nothing".
	var ws_node := map_root.get_node_or_null("worldspawn")
	var world_ent: Dictionary = ws_node.get_meta("entity", {}) if ws_node and ws_node.has_meta("entity") else {}
	sky.setup(str(world_ent.get("skyname", "")), map_root, _light_environment(map_root))
	# --quality low|medium|high applies a REAL preset — MSAA, glow, the world detail pass, the sky
	# and liquid's depth half together — the way main.gd does on load and on a lobby change. The
	# individual --sky/--water flags only ever moved two of those five, so a capture taken with
	# them was never any preset a player can actually select, and the three the tool was silently
	# leaving at project defaults included MSAA.
	var quality := str(args.get("quality", ""))
	if quality:
		if not RenderQuality.LEVELS.has(quality):
			printerr("no such quality level: %s" % quality)
			get_tree().quit(1)
			return
		RenderQuality.apply(quality, get_viewport(), sky.get_node_or_null("WorldEnvironment").environment
				if sky.get_node_or_null("WorldEnvironment") else null)
		WorldMaterials.apply(map_root, RenderQuality.detail_enabled(quality))
		sky.apply_enhanced(RenderQuality.sky_enhanced(quality))
		water_on = RenderQuality.water_depth_enabled(quality)
		print("quality %s: msaa_3d=%d detail=%s sky=%s water_depth=%s" % [quality,
				get_viewport().msaa_3d, RenderQuality.detail_enabled(quality),
				RenderQuality.sky_enhanced(quality), water_on])
	else:
		sky.apply_enhanced(args.get("sky", "on") == "on")
	# --skyprio <n> rewrites every sky surface's render_priority, override included. The sky and
	# the liquid depth twin both ship at -1, which is the same rung: whichever the renderer puts
	# first decides whether the twin's depth stamp rejects the sky behind the water.
	#
	# --stockprio <n> moves ONLY the material baked into the .scn, leaving the procedural
	# override alone. That is a stale extension binary in one flag: the C++ writes the stock
	# material's priority and GDScript writes the override's, so a lib built from older source
	# than the checkout leaves the two disagreeing — and since the override only exists on High,
	# the bug comes back at every level BELOW it. Which is a thing a fix can only be caught out
	# by if the tool can shoot a real preset.
	for key in ["skyprio", "stockprio"]:
		if not args.has(key):
			continue
		var prio := int(args[key])
		for mi in map_root.find_children("*", "MeshInstance3D", true, false):
			if not mi.has_meta("is_sky_surface"):
				continue
			if key == "skyprio":
				var om := (mi as MeshInstance3D).material_override as Material
				if om:
					om.render_priority = prio
			# get_active_material returns the override when there is one, so reach past it.
			var sm := (mi as MeshInstance3D).mesh.surface_get_material(0)
			if sm:
				sm.render_priority = prio
		print("%s = %d" % [key, prio])
		print("sky render_priority = %d" % prio)
	var touched := WaterSurfaces.apply(map_root, water_on)
	# --waves off zeroes the baked amplitude, which is the water as it stood before Phase 1 —
	# the control for "was this always like that on this renderer?"
	if args.has("alpha"):
		for mi in map_root.find_children("*", "MeshInstance3D", true, false):
			if not mi.has_meta("is_water_surface"):
				continue
			for i in mi.mesh.get_surface_count():
				var m := mi.mesh.surface_get_material(i) as ShaderMaterial
				if m:
					m.set_shader_parameter("water_alpha", float(args["alpha"]))
	# --twins off hides the liquid's depth prepass twins, leaving the colour pass alone. The
	# control for "is the twin stamping depth over something that had not drawn yet?" — anything
	# the twin rejects is missing from the scene the water then blends over.
	if args.get("twins", "on") == "off":
		var off := 0
		for mi in map_root.find_children("*_depth", "MeshInstance3D", true, false):
			mi.visible = false
			off += 1
		print("hid %d depth twins" % off)

	# --absorb <units> rewrites absorb_distance. Raising it is the control for "is this slab
	# saturated absorption?": a surface that opens back up when absorption is stretched was
	# reading its thickness as far bigger than the pool is.
	if args.has("absorb"):
		for mi in map_root.find_children("*", "MeshInstance3D", true, false):
			if not mi.has_meta("is_water_surface"):
				continue
			for i in mi.mesh.get_surface_count():
				var m := mi.mesh.surface_get_material(i) as ShaderMaterial
				if m:
					m.set_shader_parameter("absorb_distance", float(args["absorb"]))
	if args.has("boost"):
		for mi in map_root.find_children("*", "MeshInstance3D", true, false):
			if not mi.has_meta("is_water_surface"):
				continue
			for i in mi.mesh.get_surface_count():
				var m := mi.mesh.surface_get_material(i) as ShaderMaterial
				if m:
					m.set_shader_parameter("linear_alpha_boost", float(args["boost"]))
	# --hide <meta>[,<meta>..] hides every mesh carrying any of those metadata flags — the way to
	# ask "what is actually behind this water?" one layer at a time. ww_golem's moat looks like
	# it has a pale slab lying across it until you hide is_sky_surface and find the sky brush
	# behind. Peeling two layers at once is what it takes to name a third thing between them.
	#
	# is_water_surface takes the liquid's depth twin with it. The twin carries no metadata of its
	# own, and left behind it goes on stamping liquid depth over a surface that is no longer
	# drawn — which punches a black hole in whatever WAS behind the water, i.e. the exact thing
	# this flag exists to reveal. Hiding the moat at ww_golem's east edge that way invents a
	# black slab in front of the skybox and reads as a rendering bug.
	if args.has("hide"):
		var hidden := 0
		var metas := String(args["hide"]).split(",")
		var with_twin := metas.has("is_water_surface")
		for mi in map_root.find_children("*", "MeshInstance3D", true, false):
			var hide_this := with_twin and String(mi.name).ends_with("_depth")
			for meta in metas:
				if mi.has_meta(meta):
					hide_this = true
					break
			if hide_this:
				mi.visible = false
				hidden += 1
		print("hid %d meshes carrying %s" % [hidden, args["hide"]])

	# --ids on paints each liquid MESH a flat colour of its own and everything else black, so a
	# capture says which surface owns which pixel. Two pools shading differently is a question
	# about meshes, and answering it by hiding them one at a time is one run per mesh.
	if args.get("ids", "off") == "on":
		var black := StandardMaterial3D.new()
		black.albedo_color = Color.BLACK
		black.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		var idx := 0
		for mi in map_root.find_children("*", "MeshInstance3D", true, false):
			var mat := StandardMaterial3D.new()
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			if mi.has_meta("is_water_surface"):
				mat.albedo_color = Color.from_hsv(fmod(float(idx) * 0.37, 1.0), 0.9, 1.0)
				print("  id %s = %s" % [mat.albedo_color.to_html(false), mi.get_path()])
				idx += 1
			elif String(mi.name).ends_with("_depth"):
				continue  # the twin still gates who wins; leave it exactly as it draws
			else:
				mat.albedo_color = Color.BLACK
			mi.material_override = mat

	# --bias <f> rewrites the depth twin's shipped 1.002. The twin stamps 0.2% of the VIEW
	# DISTANCE beyond the surface so the prepass cannot reject the colour pass it gates — but
	# being proportional to distance, that band also spares any liquid face BEHIND the nearest
	# one that falls inside it. At 60 units out the band is 5 GoldSrc units deep. Walk, and the
	# band breathes: a moat floor or back wall slips in and out of it. Only ever a face behind
	# the surface, never the surface itself.
	if args.has("bias"):
		var rewritten := {}
		for mi in map_root.find_children("*_depth", "MeshInstance3D", true, false):
			var om := (mi as MeshInstance3D).material_override as ShaderMaterial
			if om == null or om.shader == null or rewritten.has(om.shader):
				continue
			rewritten[om.shader] = true
			om.shader.code = om.shader.code.replace("1.002", str(float(args["bias"])))

	# --layers on draws every liquid fragment additively instead of shading it, so a pixel's
	# brightness counts the liquid faces that survived the depth test there: red for faces at
	# the liquid's own surface level, green for the rest, one layer per 0.25. Exactly one is
	# what the depth prepass is for — two means the water is blending over itself, which no
	# amount of looking at the shaded picture will tell you apart from a shading bug.
	if args.get("layers", "off") == "on":
		var count_shader := Shader.new()
		count_shader.code = """
shader_type spatial;
render_mode unshaded, shadows_disabled, ambient_light_disabled, cull_disabled, depth_draw_never, blend_add;
uniform float surface_y;
varying vec3 wpos;
void vertex() { wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
void fragment() {
	float top = step(abs(wpos.y - surface_y), 0.05);
	ALBEDO = vec3(top * 0.25, (1.0 - top) * 0.25, 0.0);
	ALPHA = 1.0;
}
"""
		# Everything that is not liquid draws flat black, so what the additive pass adds to is
		# zero and the count is a count. It still writes depth, so the world occludes water the
		# way it does in the game.
		var black := StandardMaterial3D.new()
		black.albedo_color = Color.BLACK
		black.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		for mi in map_root.find_children("*", "MeshInstance3D", true, false):
			if not mi.has_meta("is_water_surface") and not String(mi.name).ends_with("_depth"):
				(mi as MeshInstance3D).material_override = black
		for mi in map_root.find_children("*", "MeshInstance3D", true, false):
			if not mi.has_meta("is_water_surface"):
				continue
			var cm := ShaderMaterial.new()
			cm.shader = count_shader
			# The top of the mesh, which is the water line for any surface that reaches it.
			cm.set_shader_parameter("surface_y",
					((mi as MeshInstance3D).global_transform * mi.get_aabb()).end.y)
			mi.material_override = cm

	if args.get("waves", "on") == "off":
		for mi in map_root.find_children("*", "MeshInstance3D", true, false):
			if not mi.has_meta("is_water_surface"):
				continue
			for i in mi.mesh.get_surface_count():
				var m := mi.mesh.surface_get_material(i) as ShaderMaterial
				if m:
					m.set_shader_parameter("wave_height", 0.0)
	print("water depth effects %s on %d surfaces" % ["ON" if water_on else "OFF", touched])

	# A spell sprite, built the way Fireball builds it, and sorted against the liquid the way
	# Projectile._process sorts it — so a capture shows the real thing, detection included.
	var effect_mats: Array = []
	var sprite_pos := Vector3.ZERO
	if args.has("sprite"):
		var sprite := AssetLoader.load_sprite_node("sprites/animglow01.spr")
		if sprite:
			sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			sprite.pixel_size = GameConsts.SCALE_FACTOR
			sprite.transparent = true
			var smat := AssetLoader.get_sprite_material_template().duplicate()
			if sprite.texture:
				smat.albedo_texture = sprite.texture
			sprite.material_override = smat
			add_child(sprite)
			sprite_pos = _vec(args["sprite"], Vector3.ZERO)
			sprite.global_position = sprite_pos
			effect_mats.append(smat)

	var cam := Camera3D.new()
	add_child(cam)
	cam.global_position = _vec(args.get("eye", ""), DEFAULT_EYE)
	cam.look_at(_vec(args.get("look", ""), DEFAULT_LOOK), Vector3.UP)
	cam.current = true

	if not effect_mats.is_empty():
		# The water volumes are Area3Ds out of the .scn, so they are not queryable until the
		# physics server has seen a frame of them.
		await get_tree().physics_frame
		var submerged := SpatialQuery.is_point_in_water(map_root, sprite_pos)
		AssetLoader.sort_for_liquid(effect_mats, submerged)
		print("sprite at %s is %s" % [sprite_pos, "SUBMERGED" if submerged else "in open air"])

	for _i in WARMUP_FRAMES:
		await RenderingServer.frame_post_draw

	var frames := int(args.get("orbit", "1"))
	if frames <= 1:
		var img := get_viewport().get_texture().get_image()
		var err := img.save_png(out_path)
		print("saved %s (%s) err=%d" % [out_path, img.get_size(), err])
		get_tree().quit(0)
		return

	# --walk slides the eye down a line keeping its heading; otherwise the eye swings around
	# the look point. Sorting artefacts live in the DIFFERENCE between neighbouring frames, so
	# the step wants to be small.
	var target := _vec(args.get("look", ""), DEFAULT_LOOK)
	var base := cam.global_position - target
	var heading := (target - cam.global_position).normalized()
	var walk_from := Vector3.ZERO
	var walk_to := Vector3.ZERO
	var walking := args.has("walk")
	if walking:
		var ends := String(args["walk"]).split(":")
		walk_from = _vec(ends[0], cam.global_position)
		walk_to = _vec(ends[1] if ends.size() > 1 else "", cam.global_position)
	var stem := out_path.get_basename()
	for i in frames:
		var t := float(i) / float(frames - 1)
		if walking:
			cam.global_position = walk_from.lerp(walk_to, t)
			cam.look_at(cam.global_position + heading, Vector3.UP)
		else:
			var arc: float = deg_to_rad(float(args.get("arc", str(rad_to_deg(ORBIT_ARC)))))
			var offset := base.rotated(Vector3.UP, (t - 0.5) * arc)
			cam.global_position = target + offset
			if args.get("outward", "off") == "on":
				cam.look_at(cam.global_position + Vector3(offset.x, -0.35 * offset.length(), offset.z), Vector3.UP)
			else:
				cam.look_at(target, Vector3.UP)
		# The PVS observer moves with the eye, and its cull runs on the physics frame.
		VisibilitySystem.set_local_position(cam.global_position)
		await get_tree().physics_frame
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var frame := get_viewport().get_texture().get_image()
		frame.save_png("%s_%02d.png" % [stem, i])
		print("  frame %02d at %s: liquid drawn %s" % [i, cam.global_position, _liquid_groups_visible(map_root)])
	print("saved %d frames to %s_NN.png" % [frames, stem])
	get_tree().quit(0)


func _args() -> Dictionary:
	var out := {}
	var argv := OS.get_cmdline_user_args()
	var i := 0
	while i < argv.size():
		# Both "--key value" and "--key=value": the second is the habitual form and silently
		# parsed as a key nobody reads, which is how three "different angles" were all shot
		# from the default camera.
		if argv[i].begins_with("--"):
			var body := argv[i].substr(2)
			var eq := body.find("=")
			if eq > 0:
				out[body.substr(0, eq)] = body.substr(eq + 1)
			elif i + 1 < argv.size():
				out[body] = argv[i + 1]
				i += 1
		i += 1
	return out


func _vec(text: String, fallback: Vector3) -> Vector3:
	var parts := text.split(",")
	if parts.size() != 3:
		return fallback
	return Vector3(float(parts[0]), float(parts[1]), float(parts[2]))


func _light_environment(map_root: Node) -> Dictionary:
	for child in map_root.get_children():
		if child.has_meta("entity") and child.get_meta("entity").get("classname", "") == "light_environment":
			return child.get_meta("entity")
	return {}


## Which of the map's liquid meshes PVS is letting through this frame, each with the height
## span of its faces. A liquid surface that stops being drawn stops stamping depth for
## everything behind it, so a group going away is the thing to watch for.
func _liquid_groups_visible(map_root: Node) -> PackedStringArray:
	var out: PackedStringArray = []
	for mi in map_root.find_children("*", "MeshInstance3D", true, false):
		if not mi.has_meta("is_water_surface") or not (mi as MeshInstance3D).is_visible_in_tree():
			continue
		var box: AABB = (mi as MeshInstance3D).global_transform * (mi as MeshInstance3D).get_aabb()
		out.append("%s[y %.1f..%.1f]" % [mi.get_parent().name, box.position.y, box.end.y])
	out.sort()
	return out
