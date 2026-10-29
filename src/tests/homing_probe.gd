extends Node
## What does Combat.find_homing_target cost, and how much of it is waste?
##
##   godot --headless --path . res://src/tests/homing_probe.tscn
##
## test_homing_target pins the invariant — a candidate that cannot win is never raycast — but it
## cannot show the magnitude, or that the magnitude depends on the order candidates arrive in.
## That order is scene-tree order, so all three are reported: best, realistic, worst.
##
## Dummies sit on collision_layer 0 so they cannot occlude each other, which isolates the
## distance-ordering waste from how often a ray happens to be blocked.
##
## Measured 2026-10-05, paired, median of 3 runs each, before and after moving the distance and
## cone tests ahead of the ray and the vetoes, and sharing one query object across the sweep
## (400 calls per row, rays per call / ms per 1000 calls):
##
##   dummies  order           before             after
##   8        nearest-first   8.0 /  17.17       1.0 /   5.89
##   8        shuffled        8.0 /  17.23       3.0 /   8.22
##   8        nearest-last    8.0 /  17.44       8.0 /  13.93
##   24       nearest-first  24.0 /  50.55       1.0 /  13.69
##   24       shuffled       24.0 /  51.16       1.0 /  13.91
##   24       nearest-last   24.0 /  52.39      24.0 /  45.40
##   64       nearest-first  64.0 / 136.65       1.0 /  34.70
##   64       shuffled       64.0 / 134.51       6.0 /  40.17
##   64       nearest-last   64.0 / 139.16      64.0 / 113.03
##
## So 3.3x on the realistic case at n=64, with 10.7x fewer rays. Ray counts are exact and
## identical across runs; timings held within 3%. The worst case saves no ray at all and still
## gains 19%, which is the allocations and the vetoes no longer running on out-of-range
## candidates.

const CALLS := 400
const COUNTS := [8, 24, 64]
const SPREAD := 40.0
const SEARCH := 60.0


func _ready() -> void:
	await get_tree().physics_frame
	print("\n=== find_homing_target: %d calls per row ===" % CALLS)
	print("%-8s %-14s %10s %12s %11s" % ["dummies", "order", "rays", "rays/call", "ms/1k calls"])
	for n in COUNTS:
		for order in ["nearest-first", "shuffled", "nearest-last"]:
			await _run_case(n, order)
	print("")
	get_tree().quit(0)


func _dummy(at: Vector3) -> Node3D:
	var body := StaticBody3D.new()
	body.collision_layer = 0      # never occludes; see the header
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1, 2, 1)
	cs.shape = box
	body.add_child(cs)
	body.add_to_group("damageable")
	add_child(body)
	body.global_position = at
	return body


## Radii in the requested arrival order. Seeded, so before/after sees the same field.
func _radii(count: int, order: String) -> Array:
	var r: Array = []
	for i in count:
		r.append(SPREAD * (float(i + 1) / float(count)) + 2.0)
	if order == "nearest-last":
		r.reverse()
	elif order == "shuffled":
		seed(12345)
		r.shuffle()
	return r


func _run_case(count: int, order: String) -> void:
	var searcher := Node3D.new()
	add_child(searcher)
	searcher.global_position = Vector3.ZERO

	var radii := _radii(count, order)
	var dummies: Array[Node3D] = []
	for i in count:
		var ang := TAU * float(i) * 0.61803      # golden-angle spread, so none coincide
		dummies.append(_dummy(Vector3(cos(ang) * radii[i], 0.0, sin(ang) * radii[i])))

	# Shapes have to reach the physics server before the rays mean anything.
	await get_tree().physics_frame
	await get_tree().physics_frame

	Combat.homing_ray_count = 0
	var t0 := Time.get_ticks_usec()
	for _c in CALLS:
		Combat.find_homing_target(searcher, null, GameConsts.Team.RED, SEARCH)
	var usec := Time.get_ticks_usec() - t0
	var rays := Combat.homing_ray_count

	# us/call and ms/1000 calls are the same number.
	print("%-8d %-14s %10d %12.1f %11.2f" % [
		count, order, rays, float(rays) / CALLS, float(usec) / CALLS])

	for d in dummies:
		d.free()
	searcher.free()
