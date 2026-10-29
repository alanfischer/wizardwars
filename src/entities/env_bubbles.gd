class_name EnvBubbles
extends EntityBase
# env_bubbles — CBubbling: a brush volume that streams bubbles upward to mark churning
# water. The brush is invisible/non-solid; it exists only to bound the emitter.
# Drawn as translucent spheres, not sprites — the mod never shipped a bubble sprite.

const RISE_SPEED := 2.0  # m/s — GoldSrc bubbles drift up at roughly this rate


func _ready() -> void:
	super()
	visible = false
	_anim_body.collision_layer = 0
	_anim_body.collision_mask = 0
	if DisplayServer.get_name() == "headless":
		return  # purely cosmetic — skip on dedicated servers

	var aabb := _volume_aabb()
	if aabb.size == Vector3.ZERO:
		return

	var frequency := maxf(parse_float(ent, "frequency", 2.0), 0.1)
	var density := maxf(parse_float(ent, "density", 2.0), 0.1) * GameConsts.SCALE_FACTOR
	var life := aabb.size.y / RISE_SPEED  # bubble lives until it clears the volume

	var p := CPUParticles3D.new()
	p.name = "Bubbles"
	p.amount = maxi(int(ceilf(frequency * life)), 1)
	p.lifetime = life
	p.preprocess = life  # spawn already in steady state
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	p.emission_box_extents = Vector3(aabb.size.x, 0.0, aabb.size.z) * 0.5  # emit from the floor, not the middle
	p.position = aabb.get_center() - Vector3(0, aabb.size.y * 0.5, 0)
	p.direction = Vector3.UP
	p.spread = 5.0
	p.initial_velocity_min = RISE_SPEED * 0.8
	p.initial_velocity_max = RISE_SPEED * 1.2
	p.gravity = Vector3.ZERO
	p.scale_amount_min = density
	p.scale_amount_max = density * 1.5

	var mesh := SphereMesh.new()
	mesh.radius = 0.5
	mesh.height = 1.0
	mesh.radial_segments = 6
	mesh.rings = 3
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.8, 0.9, 1.0, 0.35)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.disable_receive_shadows = true
	mesh.material = mat
	p.mesh = mesh

	add_child(p)


## The brush's own extent; the mesh is invisible but still parented here.
func _volume_aabb() -> AABB:
	var aabb := AABB()
	var first := true
	for child in get_children():
		if child is MeshInstance3D:
			var child_aabb: AABB = (child as MeshInstance3D).get_aabb()
			if first:
				aabb = child_aabb
				first = false
			else:
				aabb = aabb.merge(child_aabb)
	return aabb
