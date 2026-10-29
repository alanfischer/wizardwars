extends "res://src/tests/test_base.gd"
## A GoldSrc compiler emits a liquid surface twice, wound each way, so its own engine can show
## the surface from in the water and from out of it. Godot draws liquid cull_disabled, so both
## copies used to survive: the pool blended over itself, and the depth prepass had two faces at
## one depth to choose between, so which copy won flipped as the camera moved.
## goldsrc_bsp.cpp now drops the back half of each pair.
##
## The check is coverage, not face count: stand on a liquid face and only one liquid face on
## that plane may cover the spot.
##
## Only maps whose liquid the compiler doubled are pinned. A handful of maps (ww_leyline) also
## have two water brushes built touching, whose shared inside faces overlap on one plane; that
## is the mapper's geometry, not the compiler's copy, and the converter leaves it alone.
##
## Scene-run only (MapConverter needs the Log autoload): res://src/tests/run_tests.tscn.

## ww_golem's moat is worldspawn liquid, which every shipped map doubles. ww_2fort's is a
## func_water the compiler never doubled, and which must therefore come through untouched — the
## converter reads the geometry rather than trusting the brush's scope.
const DOUBLED := "ww_golem"
const SINGLE_SIDED := "ww_2fort"
## Probes per plane. A doubled surface is doubled everywhere, so a spread of samples finds it;
## testing every face against every other on the biggest plane costs seconds for no more answer.
const PROBES := 24


func test_golem_liquid_is_covered_once() -> void:
	_assert_covered_once(DOUBLED)


func test_2fort_liquid_is_still_covered_once() -> void:
	_assert_covered_once(SINGLE_SIDED)


func _assert_covered_once(map_name: String) -> void:
	var planes := _liquid_planes(map_name)
	assert_gt(planes.size(), 0, "%s has liquid to check" % map_name)
	var doubled := 0
	var probed := 0
	for key in planes:
		var faces: Array = planes[key]
		var step: int = maxi(1, faces.size() / PROBES)
		for i in range(0, faces.size(), step):
			probed += 1
			var covering := 0
			for other in faces:
				if _covers(other, faces[i].mid):
					covering += 1
			if covering > 1:
				doubled += 1
	assert_eq(doubled, 0, "%s: %d of %d probes stand on more than one liquid face of their plane"
			% [map_name, doubled, probed])


## The map's liquid triangles bucketed by plane, as {pts, mid, axis}. The bucket key folds
## ±normal together, so a face and its oppositely-wound twin land in the same bucket.
func _liquid_planes(map_name: String) -> Dictionary:
	var converter := MapConverter.new()
	_root().add_child(converter)
	_spawned.append(converter)
	assert_true(converter.convert(map_name), "%s converts" % map_name)
	var scn := ResourceLoader.load("user://resources/maps/%s.scn" % map_name, "",
			ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	var root: Node3D = scn.instantiate()
	_root().add_child(root)
	_spawned.append(root)
	var planes := {}
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		if not mi.has_meta("is_water_surface") or mi.mesh == null:
			continue
		var arrays: Array = mi.mesh.surface_get_arrays(0)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var xf: Transform3D = (mi as MeshInstance3D).global_transform
		for t in (idx.size() if idx.size() > 0 else verts.size()) / 3:
			var p: Array[Vector3] = []
			for k in 3:
				p.append(xf * (verts[idx[t * 3 + k]] if idx.size() > 0 else verts[t * 3 + k]))
			var cross := (p[1] - p[0]).cross(p[2] - p[0])
			if cross.length() < 0.0001:
				continue
			var n := cross.normalized()
			if n.x < 0.0 or (is_zero_approx(n.x) and (n.y < 0.0 or (is_zero_approx(n.y) and n.z < 0.0))):
				n = -n
			# Integers, so a -0.0 component cannot split one plane into two keys.
			var key := "%d,%d,%d,%d" % [roundi(n.x * 100.0), roundi(n.y * 100.0),
					roundi(n.z * 100.0), roundi(n.dot(p[0]) * 100.0)]
			if not planes.has(key):
				planes[key] = []
			var a := absf(n.x)
			var b := absf(n.y)
			var c := absf(n.z)
			planes[key].append({
				pts = p,
				mid = (p[0] + p[1] + p[2]) / 3.0,
				axis = 0 if a >= b and a >= c else (1 if b >= c else 2),  # the one to drop
			})
	return planes


## Is `q` inside the face, projected flat down the face's own dominant axis? Both are on one
## plane by construction, so dropping that axis is exact.
func _covers(face: Dictionary, q: Vector3) -> bool:
	var p: Array = face.pts
	var axis: int = face.axis
	var a := _flatten(p[0], axis)
	var b := _flatten(p[1], axis)
	var c := _flatten(p[2], axis)
	var t := _flatten(q, axis)
	var d1 := (t - a).cross(b - a)
	var d2 := (t - b).cross(c - b)
	var d3 := (t - c).cross(a - c)
	return (d1 >= 0.0 and d2 >= 0.0 and d3 >= 0.0) or (d1 <= 0.0 and d2 <= 0.0 and d3 <= 0.0)


func _flatten(v: Vector3, axis: int) -> Vector2:
	if axis == 0:
		return Vector2(v.y, v.z)
	return Vector2(v.x, v.z) if axis == 1 else Vector2(v.x, v.y)
