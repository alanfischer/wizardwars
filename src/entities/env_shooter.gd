class_name EnvShooter
extends EntityBase
# env_shooter — CEnvShooter: spits `m_iGibs` sprites along its angles when
# triggered, one every `delay` seconds. ww_shrinkspell's four rune fountains
# (rt1..rt4) are the only ones in the map set; each is fired by a shootable
# func_button, so this is live feedback for hitting the rune.
#
# CGibShooter's model keys are honoured (shootmodel, scale, m_flGibLife,
# m_flVelocity, m_flVariance, rendermode/rendercolor). shootsounds is not:
# the impact-sound sets it indexes aren't bundled.

const SF_REPEATABLE := 1
const GOLDSRC_GRAVITY := 800.0
const SUBSTITUTE_SPRITES := {
	# shrinkspell asks for glow02.spr, which the mod never shipped. Same family,
	# and the entity tints it via rendercolor anyway.
	"sprites/glow02.spr": "sprites/glow01.spr",
}

var _gibs := 1
var _delay := 0.0
var _repeatable := false
var _fired := false
var _particles: CPUParticles3D


func _ready() -> void:
	super()
	_gibs = maxi(parse_int(ent, "m_iGibs", 1), 1)
	_delay = maxf(parse_float(ent, "delay", 0.0), 0.0)
	_repeatable = bool(parse_spawnflags(ent) & SF_REPEATABLE)

	if DisplayServer.get_name() == "headless":
		return  # only the visuals are skipped on a dedicated server

	var sprite_path: String = ent.get("shootmodel", "")
	sprite_path = SUBSTITUTE_SPRITES.get(sprite_path, sprite_path)
	var tex := AssetLoader.load_sprite_first_frame(sprite_path)
	if not tex:
		push_warning("env_shooter: failed to load %s" % sprite_path)
		return

	_particles = _build_particles(tex)
	add_child(_particles)


func _build_particles(tex: Texture2D) -> CPUParticles3D:
	var life := maxf(parse_float(ent, "m_flGibLife", 4.0), 0.05)
	var speed := parse_float(ent, "m_flVelocity", 0.0) * GameConsts.SCALE_FACTOR
	var gib_scale := parse_float(ent, "scale", 1.0)
	var rc := parse_color(ent.get("rendercolor", "0 0 0"))
	var renderamt := parse_int(ent, "renderamt", 255)

	var p := CPUParticles3D.new()
	p.name = "Shooter"
	p.emitting = false
	p.one_shot = true
	p.explosiveness = 1.0  # the whole burst leaves at once
	p.amount = 1  # one gib per restart(); the delay between them is the point
	p.lifetime = life
	p.direction = _shoot_direction()
	p.spread = parse_float(ent, "m_flVariance", 0.0)
	p.initial_velocity_min = speed
	p.initial_velocity_max = speed
	p.gravity = Vector3(0, -GOLDSRC_GRAVITY * GameConsts.SCALE_FACTOR, 0)

	var mesh := QuadMesh.new()
	mesh.size = Vector2(tex.get_width(), tex.get_height()) * GameConsts.SCALE_FACTOR * gib_scale
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if parse_int(ent, "rendermode", 0) == 5:
		AssetLoader.set_additive_blend(mat)
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = tex
	mat.disable_receive_shadows = true
	mesh.material = mat
	p.mesh = mesh

	# Engine-literal: an all-zero rendercolor is unset, and the sprite draws white.
	var tint := Color.WHITE if (rc.r == 0.0 and rc.g == 0.0 and rc.b == 0.0) else rc
	p.color = Color(tint.r, tint.g, tint.b, renderamt / 255.0)
	return p


## GoldSrc view-angle convention: pitch -90 = straight up (every shipped
## shooter uses it). Forward = (cos p·cos y, cos p·sin y, -sin p) → Godot.
## Read raw, not via parse_angles — that builds a node rotation, not a heading.
func _shoot_direction() -> Vector3:
	var parts := str(ent.get("angles", "0 0 0")).split(" ")
	var pitch := deg_to_rad(float(parts[0])) if parts.size() > 0 else 0.0
	var yaw := deg_to_rad(float(parts[1])) if parts.size() > 1 else 0.0
	var g := Vector3(cos(pitch) * cos(yaw), cos(pitch) * sin(yaw), -sin(pitch))
	return Vector3(-g.x, g.z, g.y)


func trigger(_activator: Node, _type: TriggerSystem.Type) -> void:
	if _particles == null:
		return
	if _fired and not _repeatable:
		return
	_fired = true
	_shoot_burst()


func _shoot_burst() -> void:
	for i in _gibs:
		if not is_instance_valid(_particles):
			return
		_particles.restart()
		if i < _gibs - 1 and _delay > 0.0:
			await get_tree().create_timer(_delay).timeout
