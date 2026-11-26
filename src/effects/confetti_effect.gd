class_name ConfettiEffect
extends MultiMeshInstance3D
## A burst of paper confetti that tumbles and flutters down, comes to rest on the floor under the
## burst, and shrinks away. Drawn on each peer from HolidayGroup's pop; nothing about it is
## networked. Its own small simulation, not CPUParticles3D: that has no floor to land on, and its
## damping is a fixed braking rather than drag, which leaves paper either hanging or plummeting.

const LIFE := 6.0
const SHRINK := 1.0  # the last second of LIFE
const GRAVITY := 9.8
const DRAG := 6.0  # per second, so paper falls at about GRAVITY / DRAG
const FLUTTER := 0.9  # m/s of side-to-side sway while it falls
const PIECE := Vector2(0.035, 0.022)

static var _quad: QuadMesh

var _floor := 0.0
var _age := 0.0
var _pos := PackedVector3Array()
var _vel := PackedVector3Array()
var _axis := PackedVector3Array()
var _spin := PackedFloat32Array()
var _phase := PackedFloat32Array()
var _landed := PackedByteArray()
var _rest: Array[Basis] = []


## `pieces` bits of paper bursting up from `at`, out of something about `size` (metres) across.
static func spawn(parent: Node, at: Vector3, colors: Array[Color], size: float, pieces := 90) -> ConfettiEffect:
	var c := ConfettiEffect.new()
	c.position = at
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = _shared_quad()
	mm.instance_count = pieces
	c.multimesh = mm
	c.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(c)
	var ground := SpatialQuery.ground_y_below(c, at)
	c._floor = -4.0 if ground == INF else ground - 0.046 - at.y  # the helper stands 5 cm off the floor
	# Lit by the map where it bursts, carried in each piece's colour so every burst shares one material.
	var light := AssetLoader.light_grid.sample(at) if AssetLoader.light_grid else Color(0.6, 0.6, 0.6)
	var tint := Color(minf(light.r * 1.6, 1.0), minf(light.g * 1.6, 1.0), minf(light.b * 1.6, 1.0))
	for i in pieces:
		var up := Vector3(randf_range(-1, 1), 0, randf_range(-1, 1)) * randf_range(0.2, 1.1) + Vector3.UP
		c._pos.append(Vector3(randf_range(-1, 1), randf_range(-0.5, 0.5), randf_range(-1, 1)) * size * 0.3)
		c._vel.append(up.normalized() * randf_range(4.0, 7.0 + size * 4.0))
		c._axis.append(Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)).normalized())
		c._spin.append(randf_range(6.0, 14.0))
		c._phase.append(randf() * TAU)
		c._landed.append(0)
		c._rest.append(Basis(Vector3.UP, randf() * TAU) * Basis(Vector3.RIGHT, -PI * 0.5))
		mm.set_instance_color(i, colors[randi() % colors.size()] * tint)
	c._step(0.0)
	return c


static func _shared_quad() -> QuadMesh:
	if _quad == null:
		_quad = QuadMesh.new()
		_quad.size = PIECE
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.vertex_color_use_as_albedo = true
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		_quad.material = mat
	return _quad


func _process(delta: float) -> void:
	_age += delta
	if _age >= LIFE:
		queue_free()
		return
	_step(delta)


func _step(delta: float) -> void:
	var scale_now := clampf((LIFE - _age) / SHRINK, 0.0, 1.0)
	var shrinking := scale_now < 1.0
	for i in _pos.size():
		var turn: Basis
		if _landed[i]:
			if not shrinking:
				continue  # lying still since it landed
			turn = _rest[i]
		else:
			var v := _vel[i]
			v.y -= GRAVITY * delta
			v -= v * minf(DRAG * delta, 1.0)
			var phase := _phase[i] + _age * 3.0
			var sway := Vector3(cos(phase), 0, sin(phase * 1.3)) * FLUTTER
			var p := _pos[i] + (v + sway) * delta
			_pos[i] = p
			_vel[i] = v
			turn = Basis(_axis[i], _phase[i] + _age * _spin[i])
			if p.y <= _floor and v.y < 0.0:
				_pos[i].y = _floor
				_landed[i] = 1
				turn = _rest[i]
		multimesh.set_instance_transform(i, Transform3D(turn.scaled(Vector3.ONE * scale_now), _pos[i]))
