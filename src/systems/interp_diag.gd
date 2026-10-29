class_name InterpDiag
extends RefCounted

## Client-side instrumentation for the dynamic-entity interpolation stream (/interp_diag).
##
## The question it exists to answer: does an entity's snapshot buffer actually starve WHILE THE
## ENTITY IS MOVING? Averaging over a window can't answer that — a settled corpse's newest sample
## ages forever (the publisher goes quiet on purpose, see NetInterpBridge._publish), so any
## whole-window ratio is dominated by the resting tail and reads ~100% dry no matter what happened
## during the fall.
##
## So nothing is counted until the stream proves it is still live: frames accumulate in a pending
## bucket, and the bucket is only committed when the newest sample stamp actually ADVANCES. Frames
## after the last advance are discarded, which is exactly the resting tail.

## One entity's accounting. Committed totals only ever cover frames between two advancing stamps.
class Record:
	var label := ""
	var gaps := 0  # committed intervals — i.e. samples that advanced the stamp
	var gap_sum_ms := 0.0
	var gap_max_ms := 0.0
	var frames := 0
	var extrap_frames := 0
	var hold_frames := 0
	var age_max_ms := 0.0
	var extrap_max_m := 0.0
	var clamp_cuts := 0
	var clamp_cut_max_m := 0.0
	var no_shape := false

	var prev_stamp := -INF
	var p_frames := 0
	var p_extrap := 0
	var p_hold := 0
	var p_age_max := 0.0
	var p_extrap_max := 0.0
	var p_cuts := 0
	var p_cut_max := 0.0
	var p_no_shape := false

	func commit(gap_ms: float) -> void:
		gaps += 1
		gap_sum_ms += gap_ms
		gap_max_ms = maxf(gap_max_ms, gap_ms)
		frames += p_frames
		extrap_frames += p_extrap
		hold_frames += p_hold
		age_max_ms = maxf(age_max_ms, p_age_max)
		extrap_max_m = maxf(extrap_max_m, p_extrap_max)
		clamp_cuts += p_cuts
		clamp_cut_max_m = maxf(clamp_cut_max_m, p_cut_max)
		no_shape = no_shape or p_no_shape
		p_no_shape = false
		p_frames = 0
		p_extrap = 0
		p_hold = 0
		p_age_max = 0.0
		p_extrap_max = 0.0
		p_cuts = 0
		p_cut_max = 0.0

	func line() -> String:
		if gaps == 0:
			return "%s: no live stream observed" % label
		return ("%s: %d samples, spacing avg %.1f max %.1f ms | %d live frames, %.0f%% extrapolated,"
			+ " %.0f%% held | worst sample age %.0f ms | extrap max %.2f m, clamped %d (max cut %.2f m)%s") % [
			label, gaps, gap_sum_ms / gaps, gap_max_ms, frames,
			100.0 * extrap_frames / maxi(frames, 1), 100.0 * hold_frames / maxi(frames, 1),
			age_max_ms, extrap_max_m, clamp_cuts, clamp_cut_max_m,
			" | NO COLLISION SHAPE (extrapolation unclamped)" if no_shape else ""]


var _records: Dictionary = {}  # entity id -> Record


func _label(id: int, node: Node) -> String:
	var cls: String = node.get_script().get_global_name() if node.get_script() else node.get_class()
	return "%s#%d" % [cls, id]


## Per rendered frame, per entity, from interp_entities. `newest` is the buffer's newest sample time.
func note_frame(id: int, node: Node, newest: float, age: float, extrapolated: bool, holding: bool) -> void:
	var rec: Record = _records.get(id)
	if rec == null:
		rec = Record.new()
		rec.label = _label(id, node)
		_records[id] = rec
	if newest > rec.prev_stamp:
		if rec.prev_stamp > -INF:
			# First real interval: say so, because what a client actually holds is half the question —
			# a corpse it never receives can't be the one seen falling. Entities that never stream
			# (a map light, a corpse held out of PVS) stay silent here and show up in /interp_diag dump.
			if rec.gaps == 0:
				Log.info("[InterpDiag] tracking " + rec.label)
			rec.commit((newest - rec.prev_stamp) * 1000.0)
		rec.prev_stamp = newest
	rec.p_frames += 1
	rec.p_age_max = maxf(rec.p_age_max, age * 1000.0)
	if extrapolated:
		rec.p_extrap += 1
	if holding:
		rec.p_hold += 1


## From interp_entities, right after _clamp_extrapolation swept an extrapolated frame. Only called
## when the guess actually travelled: the clamp early-outs on zero motion without ever resolving the
## entity's shape, and reading its cache then reports every settled entity as shapeless.
func note_extrap(id: int, anchor: Vector3, guess: Vector3, clamped: Vector3, has_shape: bool) -> void:
	var rec: Record = _records.get(id)
	if rec == null:
		return
	rec.p_no_shape = rec.p_no_shape or not has_shape
	rec.p_extrap_max = maxf(rec.p_extrap_max, anchor.distance_to(guess))
	var cut := guess.distance_to(clamped)
	if cut > 0.001:
		rec.p_cuts += 1
		rec.p_cut_max = maxf(rec.p_cut_max, cut)


## The entity is gone (corpse expired, projectile despawned) — report what its stream looked like.
func finish(id: int) -> void:
	var rec: Record = _records.get(id)
	if rec == null:
		return
	_records.erase(id)
	if rec.gaps > 0:
		Log.info("[InterpDiag] " + rec.line())


## Everything still alive, for /interp_diag on demand.
func dump_live() -> Array[String]:
	var out: Array[String] = []
	for id in _records:
		out.append((_records[id] as Record).line())
	return out
