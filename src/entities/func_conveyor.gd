class_name FuncConveyor
extends EntityBase
# func_conveyor — visual-only conveyor belt that scrolls texture UVs.
# C++ confirms no player push — purely cosmetic.

const SF_NOT_SOLID := 2

## Sign of the UV step. uv1_offset is ADDED before sampling, so stepping it along +U makes the
## pattern appear to travel toward -U. Negate, and the surface flows along its texture's S axis
## — which on ww_ravine's waterfalls is straight down, the one direction that needs no argument.
const SCROLL_SIGN := -1.0
## Triangles to try before giving up on a surface. Every brush in the map set answers on its
## first or second; the cap is only there so a pathological mesh cannot walk itself.
const MAX_RATE_PROBES := 32

var _speed: float
var _mesh_instances: Array[MeshInstance3D] = []
## Per (mesh, surface): UV travelled per world unit along the texture's S axis, so `speed` (world
## units/second) becomes a UV rate. Measured off the surface, since texture scale varies per face.
var _uv_rate: Array[float] = []


func _ready() -> void:
	super()
	# CFuncConveyor::Spawn: `if (pev->speed == 0) pev->speed = 100`. A DECLARED zero means the
	# default too, not a stopped belt — ww_ravine's *5, *6, *11 and *12 all say speed 0 and are
	# meant to flow. parse_float's default only covers an absent key.
	var raw_speed := parse_float(ent, "speed", 100.0)
	if is_zero_approx(raw_speed):
		raw_speed = 100.0
	_speed = raw_speed * GameConsts.SCALE_FACTOR
	var spawnflags := parse_spawnflags(ent)

	if spawnflags & SF_NOT_SOLID:
		_anim_body.collision_layer = 0
		_anim_body.collision_mask = 0

	EntityRender.apply_render_properties(self, ent)

	# Duplicate materials (per-entity UV offset) and convert lightmapped ShaderMaterials
	# to StandardMaterial3D, which is what supports the UV scroll below.
	_mesh_instances = EntityRender.find_mesh_instances(self)
	for mesh_inst in _mesh_instances:
		for surf_idx in mesh_inst.mesh.get_surface_count():
			var mat: Material = mesh_inst.get_active_material(surf_idx)
			if mat is StandardMaterial3D:
				mesh_inst.set_surface_override_material(surf_idx, mat.duplicate())
			elif mat is ShaderMaterial:
				mesh_inst.set_surface_override_material(surf_idx, EntityRender.convert_shader_to_standard(mat))
			_uv_rate.append(_measure_uv_rate(mesh_inst.mesh, surf_idx))


## UV travelled per world unit along the texture's S axis (its U direction).
##
## A conveyor scrolls along the FACE'S OWN texture axis, not along the entity's movedir. The map
## set settles it: 8 of ww_ravine's 9 conveyors carry no "angles" key at all, and its waterfalls
## (*18, *19 — thin vertical walls) have movedirs pointing along their own surface normal, which
## projects onto the surface as nothing. Their texture S axis, meanwhile, points straight down.
## Where a mapper did set meaningful angles on a flat river the two agree anyway — ww_osaka's *1
## is angles "0 90 0" (+Y) with S = +Y — so the texture axis is right in every case and movedir
## only in some. Mappers steer the flow by aligning the texture and reverse it with a negative
## speed, which is why the sign of `speed` is carried through untouched.
##
## Both mappings are linear across a triangle, so one triangle settles the scale: solve for the
## world vector that spans one UV unit along U, and its length is the world distance per UV unit.
func _measure_uv_rate(mesh: Mesh, surf_idx: int) -> float:
	var arrays := mesh.surface_get_arrays(surf_idx)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	if verts.size() < 3 or uvs.size() != verts.size():
		return 0.0
	# Ask the triangles in turn rather than trusting the first. A brush's faces are merged into
	# ONE surface per texture, so a single degenerate triangle at the head of it used to zero the
	# scroll for the whole model: that is exactly what stopped ww_ravine's *12, one of the four
	# pools on its lowest level, while its three mirror-image siblings flowed.
	# Both counts are whole triangles, so the division is exact; the floor only guards a
	# malformed surface.
	@warning_ignore("integer_division")
	var tri_count := (idx.size() / 3) if idx.size() >= 3 else (verts.size() / 3)
	for tri in mini(tri_count, MAX_RATE_PROBES):
		var i0 := idx[tri * 3] if idx.size() >= 3 else tri * 3
		var i1 := idx[tri * 3 + 1] if idx.size() >= 3 else tri * 3 + 1
		var i2 := idx[tri * 3 + 2] if idx.size() >= 3 else tri * 3 + 2

		var e1 := verts[i1] - verts[i0]
		var e2 := verts[i2] - verts[i0]
		var d1 := uvs[i1] - uvs[i0]
		var d2 := uvs[i2] - uvs[i0]

		# Solve a*d1 + b*d2 = (1, 0) for the edge-basis weights that span one UV unit along U.
		var det := d1.x * d2.y - d1.y * d2.x
		if absf(det) < 1e-12:
			continue  # degenerate UVs on this triangle; another will do
		var world_per_uv := (e1 * (d2.y / det) + e2 * (-d1.y / det)).length()
		if world_per_uv > 1e-9:
			return 1.0 / world_per_uv
	return 0.0


func _process(delta: float) -> void:
	var travelled := _speed * delta * SCROLL_SIGN
	var i := 0
	for mesh_inst in _mesh_instances:
		for surf_idx in mesh_inst.mesh.get_surface_count():
			var mat := mesh_inst.get_surface_override_material(surf_idx) as StandardMaterial3D
			if mat and i < _uv_rate.size():
				mat.uv1_offset.x += travelled * _uv_rate[i]
			i += 1
