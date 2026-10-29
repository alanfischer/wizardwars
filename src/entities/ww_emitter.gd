class_name WWEmitter
extends EntityBase
# ww_emitter — Wizard Wars' custom sprite-particle emitter (node flames on
# ww_leyline, drifting motes on ww_wolteg/ww_memnate, snowfall on ww_december).
# Always-on scenery: no map instance has a targetname, so there is no trigger
# handling. Approximated with CPUParticles3D; unsupported keys (wind_scale,
# *_decay curves beyond linear, priority, delay) are ignored.
#
# Keys: sprite (first frame = particle texture), mins/maxs (emission box in
# GoldSrc units around origin), count per think interval (s), life (s),
# speed (u/s along pitch/angle), spread (deg), gravity (fraction of the
# GoldSrc 800 u/s²), scale (+scale_decay), render_color "r g b a",
# render_mode (5 = additive), render_decay (alpha fades over life).

const GOLDSRC_GRAVITY := 800.0


func _ready() -> void:
	super()
	if DisplayServer.get_name() == "headless":
		return  # purely cosmetic — skip on dedicated servers

	var sprite_path: String = ent.get("sprite", "")
	var tex := AssetLoader.load_sprite_first_frame(sprite_path)
	if not tex:
		push_warning("ww_emitter: failed to load sprite %s" % sprite_path)
		return

	var count := maxi(parse_int(ent, "count", 1), 1)
	var think := maxf(parse_float(ent, "think", 0.1), 0.005)
	var life := maxf(parse_float(ent, "life", 1.0), 0.05)
	var speed := parse_float(ent, "speed", 0.0) * GameConsts.SCALE_FACTOR
	var spread := parse_float(ent, "spread", 0.0)
	var gravity := parse_float(ent, "gravity", 0.0)
	var sprite_scale := parse_float(ent, "scale", 1.0)
	var scale_decay := parse_float(ent, "scale_decay", 0.0)
	var render_decay := parse_float(ent, "render_decay", 0.0)
	var color := _parse_render_color(ent.get("render_color", "1 1 1 1"))
	var additive := parse_int(ent, "render_mode", 0) == 5

	# Emission box: parse_vector3 converts each corner to Godot axes (which
	# flips/swaps components), so re-sort into lo/hi before taking extents.
	var a := parse_vector3(ent.get("mins", "0 0 0"))
	var b := parse_vector3(ent.get("maxs", "0 0 0"))
	var lo := Vector3(minf(a.x, b.x), minf(a.y, b.y), minf(a.z, b.z))
	var hi := Vector3(maxf(a.x, b.x), maxf(a.y, b.y), maxf(a.z, b.z))

	var p := CPUParticles3D.new()
	p.name = "Emitter"
	p.amount = maxi(int(ceilf(float(count) / think * life)), 1)
	p.lifetime = life
	p.preprocess = life  # spawn already in steady state
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	p.emission_box_extents = (hi - lo) * 0.5
	p.position = (hi + lo) * 0.5
	p.direction = _emit_direction()
	p.spread = maxf(spread, 0.0)
	p.initial_velocity_min = speed
	p.initial_velocity_max = speed
	p.gravity = Vector3(0, -gravity * GOLDSRC_GRAVITY * GameConsts.SCALE_FACTOR, 0)
	p.particle_flag_align_y = false

	# Sprite quad sized by the env_sprite convention: pixels × SCALE_FACTOR × scale
	var mesh := QuadMesh.new()
	mesh.size = Vector2(tex.get_width(), tex.get_height()) * GameConsts.SCALE_FACTOR * sprite_scale
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if additive:
		AssetLoader.set_additive_blend(mat)
	else:
		mat.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = tex
	mat.disable_receive_shadows = true
	mesh.material = mat
	p.mesh = mesh

	p.color = color
	if render_decay > 0.0:
		var ramp := Gradient.new()
		ramp.set_color(0, Color(1, 1, 1, 1))
		ramp.set_color(1, Color(1, 1, 1, 0))
		p.color_ramp = ramp
	if scale_decay > 0.0:
		var curve := Curve.new()
		curve.add_point(Vector2(0.0, 1.0))
		curve.add_point(Vector2(1.0, 0.0))
		p.scale_amount_curve = curve

	add_child(p)


func _emit_direction() -> Vector3:
	# GoldSrc view-angle convention: pitch -90 = straight up (every shipped
	# emitter uses -90). Forward = (cos p·cos y, cos p·sin y, -sin p) → Godot.
	var pitch := deg_to_rad(parse_float(ent, "pitch", 0.0))
	var yaw := deg_to_rad(parse_float(ent, "angle", 0.0))
	var g := Vector3(cos(pitch) * cos(yaw), cos(pitch) * sin(yaw), -sin(pitch))
	return Vector3(-g.x, g.z, g.y)


static func _parse_render_color(s: String) -> Color:
	var parts := s.split_floats(" ", false)
	if parts.size() >= 3:
		return Color(parts[0], parts[1], parts[2], parts[3] if parts.size() >= 4 else 1.0)
	return Color.WHITE
