extends "res://src/tests/test_base.gd"
## /interp_diag's accounting. The property that matters is that it measures the stream only while
## the stream is LIVE: a settled entity's newest sample ages forever, so counting those frames is
## what made every previous "the buffer is dry N% of the time" number meaningless.


func _diag_with(id: int) -> InterpDiag:
	var diag := InterpDiag.new()
	var node := Node3D.new()
	node.name = "Corpse"
	_root().add_child(node)
	# One advancing stamp, so the record exists and has an interval open.
	diag.note_frame(id, node, 1.000, 0.016, false, false)
	return diag


func _rec(diag: InterpDiag, id: int):
	return diag._records[id]


func test_frames_after_the_last_sample_are_not_counted() -> void:
	var diag := _diag_with(1)
	# The publisher went quiet (the entity came to rest). These frames must not be committed.
	for i in 100:
		diag.note_frame(1, _root().get_node(^"Corpse"), 1.000, 1.0 + i * 0.016, false, true)
	var rec = _rec(diag, 1)
	assert_eq(rec.frames, 0, "the resting tail is discarded, not averaged in")
	assert_eq(rec.hold_frames, 0, "a held frame after the stream stopped is not starvation")
	_root().get_node(^"Corpse").queue_free()


func test_frames_between_two_samples_are_counted() -> void:
	var diag := _diag_with(2)
	var node: Node3D = _root().get_node(^"Corpse")
	diag.note_frame(2, node, 1.000, 0.020, true, false)
	diag.note_frame(2, node, 1.000, 0.036, true, false)
	diag.note_frame(2, node, 1.033, 0.010, false, false)  # next sample lands: commits the interval
	var rec = _rec(diag, 2)
	assert_eq(rec.gaps, 1, "one advancing stamp closes one interval")
	assert_almost_eq(rec.gap_max_ms, 33.0, 0.01, "sample spacing is the stamp delta")
	assert_eq(rec.frames, 3, "every frame up to the new sample belongs to the interval")
	assert_eq(rec.extrap_frames, 2, "frames the buffer had to dead-reckon")
	assert_almost_eq(rec.age_max_ms, 36.0, 0.01, "worst age reached inside the interval")
	node.queue_free()


func test_an_unclamped_extrapolation_is_flagged() -> void:
	var diag := _diag_with(3)
	var node: Node3D = _root().get_node(^"Corpse")
	var anchor := Vector3(0, 5, 0)
	var guess := Vector3(0, 3, 0)
	diag.note_extrap(3, anchor, guess, guess, false)  # no collision shape resolved
	diag.note_frame(3, node, 1.033, 0.010, false, false)
	var rec = _rec(diag, 3)
	assert_true(rec.no_shape, "an entity with no shape extrapolates through the floor unopposed")
	assert_almost_eq(rec.extrap_max_m, 2.0, 0.001, "how far the guess ran from the last real sample")
	assert_true(rec.line().contains("NO COLLISION SHAPE"), "the report calls it out")
	node.queue_free()


func test_an_unclamped_frame_in_the_resting_tail_is_not_reported() -> void:
	# The tail extrapolates too (zero velocity, zero motion), and the clamp early-outs there without
	# resolving a shape. Letting that reach the report marked every settled corpse "NO COLLISION
	# SHAPE" — a finding that was purely an artifact of measuring the tail.
	var diag := _diag_with(6)
	diag.note_extrap(6, Vector3(0, 5, 0), Vector3(0, 5, 0), Vector3(0, 5, 0), false)
	var rec = _rec(diag, 6)
	assert_false(rec.no_shape, "nothing after the last advancing sample reaches the report")
	assert_false(rec.line().contains("NO COLLISION SHAPE"), "and the line stays clean")
	_root().get_node(^"Corpse").queue_free()


func test_a_clamped_extrapolation_records_the_cut() -> void:
	var diag := _diag_with(4)
	var node: Node3D = _root().get_node(^"Corpse")
	diag.note_extrap(4, Vector3(0, 5, 0), Vector3(0, 3, 0), Vector3(0, 4, 0), true)
	diag.note_frame(4, node, 1.033, 0.010, false, false)
	var rec = _rec(diag, 4)
	assert_eq(rec.clamp_cuts, 1, "the sweep stopped the guess short")
	assert_almost_eq(rec.clamp_cut_max_m, 1.0, 0.001, "how much of the guess the world took back")
	node.queue_free()


func test_finish_drops_the_record() -> void:
	var diag := _diag_with(5)
	diag.finish(5)
	assert_false(diag._records.has(5), "a despawned entity reports once and is forgotten")
	_root().get_node(^"Corpse").queue_free()
