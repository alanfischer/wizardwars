## Shared snapshot interpolation utilities for network sync.
## Usage: const SnapshotInterp = preload("res://src/systems/snapshot_interp.gd")
## Snapshot buffers are Arrays of Arrays: each entry starts with [time, ...data].
## The interpolation logic finds the two snapshots straddling the render time
## and returns an interpolation result.

## Find the interpolation bracket in buf for the given render_time.
## Returns { s0_idx: int, t: float }.
##   s0_idx == -1            → render_time is before all snapshots (use buf[0])
##   s0_idx == buf.size()-1  → buffer ran dry, extrapolate from last two
##   otherwise               → interpolate between buf[s0_idx] and buf[s0_idx+1]
static func find_bracket(buf: Array, render_time: float) -> Dictionary:
	if buf.size() <= 1:
		return { "s0_idx": -1, "t": 0.0 }

	var s0_idx := -1
	for i in range(buf.size() - 1, -1, -1):
		if buf[i][0] <= render_time:
			s0_idx = i
			break

	if s0_idx == -1:
		return { "s0_idx": -1, "t": 0.0 }

	if s0_idx >= buf.size() - 1:
		return { "s0_idx": s0_idx, "t": 0.0 }

	var dt: float = buf[s0_idx + 1][0] - buf[s0_idx][0]
	var t := 0.0
	if dt > 0.0:
		t = clampf((render_time - buf[s0_idx][0]) / dt, 0.0, 1.0)
	return { "s0_idx": s0_idx, "t": t }


## Interpolate position (Vector3) between two snapshots at the given field index.
static func lerp_vec3(s0: Array, s1: Array, t: float, field: int) -> Vector3:
	return (s0[field] as Vector3).lerp(s1[field] as Vector3, t)


## Interpolate a rotation angle between two snapshots at the given field index.
static func lerp_rot(s0: Array, s1: Array, t: float, field: int) -> float:
	return lerp_angle(s0[field] as float, s1[field] as float, t)


## Prune old snapshots before s0_idx (keep s0 as the oldest needed entry).
static func prune(buf: Array, s0_idx: int) -> void:
	if s0_idx > 0:
		var remaining := buf.size() - s0_idx
		for i in remaining:
			buf[i] = buf[i + s0_idx]
		buf.resize(remaining)
