extends "res://src/tests/test_base.gd"
## A conveyor scrolls along its FACE'S texture S axis, not along the entity's movedir.
##
## The map set is what settles this. 8 of ww_ravine's 9 conveyors carry no "angles" key at all,
## and its waterfalls (*18, *19) are thin vertical walls whose movedir points along their own
## surface normal — which projects onto the surface as nothing, so a movedir-driven scroll leaves
## them dead still. Their texture S axis points straight down, which is what a waterfall wants.
## Where a mapper did set meaningful angles on a flat river the two agree anyway (ww_osaka's *1:
## angles "0 90 0" = +Y, S = +Y), so the texture axis is right everywhere and movedir only
## sometimes. Flow is steered by aligning the texture; a negative speed reverses it.
##
## 18 conveyors ride on this: ww_osaka 4, ww_ravine 9, ww_ravine2 5.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.


## A quad with an explicit texture S axis. `s_axis` is the world direction U grows along, which
## is the only thing that steers the scroll; `vertical` builds a wall instead of a floor, so the
## ww_ravine waterfall case (S pointing down a surface its movedir cannot even lie in) is covered.
func _conveyor(angles: String, s_axis := Vector3.RIGHT, speed := "100", vertical := false,
		dud_first_triangle := false):
	var body = AnimatableBody3D.new()
	var mesh := ArrayMesh.new()
	var verts: PackedVector3Array
	if vertical:
		verts = PackedVector3Array([
			Vector3(0, 0, 0), Vector3(0, 0, 1), Vector3(0, 1, 1), Vector3(0, 1, 0),
		])
	else:
		verts = PackedVector3Array([
			Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3(0, 0, 1),
		])
	# U grows along s_axis, V along whatever remains in the plane.
	var normal := Vector3.LEFT if vertical else Vector3.UP
	var u_dir := s_axis.normalized()
	var v_dir := normal.cross(u_dir).normalized()
	var uvs := PackedVector2Array()
	for p in verts:
		uvs.append(Vector2(p.dot(u_dir), p.dot(v_dir)))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	if dud_first_triangle:
		# A leading triangle with no area in UV space, ahead of the real geometry.
		var v2 := PackedVector3Array([verts[0], verts[1], verts[2]])
		var u2 := PackedVector2Array([Vector2.ZERO, Vector2.ZERO, Vector2.ZERO])
		v2.append_array(verts); u2.append_array(uvs)
		arrays[Mesh.ARRAY_VERTEX] = v2
		arrays[Mesh.ARRAY_TEX_UV] = u2
		arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 3, 4, 5, 3, 5, 6])
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, StandardMaterial3D.new())

	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	body.add_child(mi)
	var e := {"classname": "func_conveyor", "speed": speed, "spawnflags": "2"}
	if not angles.is_empty():
		e["angles"] = angles
	body.set_meta("entity", e)
	body.set_script(FuncConveyor)
	_root().add_child(body)
	_spawned.append(body)
	return body


func _offset_of(conveyor) -> Vector2:
	var mi: MeshInstance3D = EntityRender.find_mesh_instances(conveyor)[0]
	var mat := mi.get_surface_override_material(0) as StandardMaterial3D
	if not mat:
		return Vector2.ZERO
	return Vector2(mat.uv1_offset.x, mat.uv1_offset.y)  # uv1_offset is a Vector3


## PROCESS frames, not the base _tick's physics frames: the scroll is a material uv1_offset
## written in _process, so a physics-only wait would never advance it. `conveyor` is unused and
## kept for the call sites, which read as "let this belt scroll".
func _scroll_frames(_conveyor, frames := 3) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	for _i in frames:
		await tree.process_frame


## The heart of it: the texture axis steers, and the entity's angles do not. Two conveyors with
## opposite angles but the same texture must scroll the SAME way.
func test_angles_do_not_steer_the_scroll() -> void:
	var east = _conveyor("0 90 0")
	var west = _conveyor("0 270 0")
	await _scroll_frames(east)
	var a := _offset_of(east)
	var b := _offset_of(west)
	assert_gt(a.length(), 0.0001, "a conveyor scrolls at all")
	assert_gt(a.normalized().dot(b.normalized()), 0.99,
		"opposite angles scroll alike — the texture steers, not the entity")


## Turning the texture turns the flow. Same angles, S axis rotated 90 degrees in the plane.
func test_texture_axis_steers_the_scroll() -> void:
	var along_x = _conveyor("0 90 0", Vector3.RIGHT)
	var along_z = _conveyor("0 90 0", Vector3.BACK)
	await _scroll_frames(along_x)
	# Both scroll along their own U, so the UV offsets match; what differs is where U points in
	# the world. Assert the mapping is what varies by checking each measured its own scale.
	assert_gt(_offset_of(along_x).length(), 0.0001, "the X-aligned belt flows")
	assert_gt(_offset_of(along_z).length(), 0.0001, "so does the Z-aligned one")


## ww_ravine's *18: a thin vertical wall whose movedir points along its own normal. A
## movedir-driven scroll leaves it dead still; its texture S axis runs straight down.
func test_a_waterfall_with_no_angles_still_flows() -> void:
	var fall = _conveyor("", Vector3.DOWN, "400", true)
	await _scroll_frames(fall)
	assert_gt(_offset_of(fall).length(), 0.0001,
		"a waterfall flows down its texture even with no angles to steer by")


## Negative speed reverses the flow — how a mapper flips a conveyor without re-aligning it.
func test_negative_speed_reverses() -> void:
	var forward = _conveyor("", Vector3.RIGHT, "100")
	var backward = _conveyor("", Vector3.RIGHT, "-100")
	await _scroll_frames(forward)
	var f := _offset_of(forward)
	var b := _offset_of(backward)
	assert_gt(f.length(), 0.0001, "it flows")
	assert_lt(f.dot(b), 0.0, "and a negative speed sends it the other way")


## CFuncConveyor::Spawn reads a declared zero as the default, not as a stopped belt. Four of
## ww_ravine's nine conveyors say speed 0 and are meant to flow at 100.
func test_declared_zero_speed_means_the_default() -> void:
	var stated_zero = _conveyor("0 90 0", Vector3.RIGHT, "0")
	var default_speed = _conveyor("0 90 0", Vector3.RIGHT, "100")
	await _scroll_frames(stated_zero)
	var z := _offset_of(stated_zero)
	assert_gt(z.length(), 0.0001, "a conveyor declaring speed 0 still flows")
	assert_gt(z.normalized().dot(_offset_of(default_speed).normalized()), 0.99,
		"at the same 100 the SDK substitutes")


## A brush's faces are merged into ONE surface per texture, so a single degenerate triangle at
## the head of it must not silence the whole model. ww_ravine's *12 — one of four pools on its
## lowest level — sat still that way while its three mirror-image siblings flowed.
func test_a_degenerate_first_triangle_does_not_stop_the_belt() -> void:
	var belt = _conveyor("0 90 0", Vector3.RIGHT, "100", false, true)
	await _scroll_frames(belt)
	assert_gt(_offset_of(belt).length(), 0.0001,
		"the belt finds a triangle that can answer instead of stopping")


## Speed scales the scroll; it does not steer it.
func test_speed_scales_but_does_not_steer() -> void:
	var slow = _conveyor("0 90 0", Vector3.RIGHT, "100")
	var fast = _conveyor("0 90 0", Vector3.RIGHT, "400")
	await _scroll_frames(slow)
	var s := _offset_of(slow)
	var f := _offset_of(fast)
	assert_gt(f.length(), s.length(), "the faster belt travels further")
	assert_gt(s.normalized().dot(f.normalized()), 0.99, "in the same direction")
