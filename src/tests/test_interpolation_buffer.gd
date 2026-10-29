extends "res://src/tests/test_base.gd"
## InterpolationBuffer.sample() "holding" contract: once a stream runs dry past the extrapolation
## window, sample() must flag a pure static hold so the caller stops re-asserting the frozen
## transform — otherwise interp_entities() clobbers a reliable teleport (ww_2fort flag return).


func _make_buf() -> InterpolationBuffer:
	var buf := InterpolationBuffer.new()
	buf.extrap_max = 0.25
	return buf


func test_empty_buffer_invalid_not_holding() -> void:
	var buf := _make_buf()
	var s := buf.sample(1.0)
	assert_false(s.valid, "no snapshot yet")
	assert_false(s.holding, "invalid samples are never a hold")


func test_interpolating_is_writable() -> void:
	var buf := _make_buf()
	buf.push(1.0, Vector3.ZERO, Vector3.ZERO)
	buf.push(2.0, Vector3(10, 0, 0), Vector3.ZERO)
	var s := buf.sample(1.5)  # between the two snapshots
	assert_true(s.valid)
	assert_false(s.holding, "actively interpolating → caller should write")
	assert_vec3_almost_eq(s.position, Vector3(5, 0, 0), 0.01, "midpoint lerp")


func test_within_extrap_window_still_writable() -> void:
	var buf := _make_buf()
	buf.push(1.0, Vector3.ZERO, Vector3.ZERO, Vector3(10, 0, 0))  # velocity 10 u/s
	buf.push(2.0, Vector3(10, 0, 0), Vector3.ZERO, Vector3(10, 0, 0))
	# 0.1s past the last snapshot, inside the 0.25s extrap window → extrapolating, writable.
	var s := buf.sample(2.1)
	assert_true(s.valid)
	assert_false(s.holding, "extrapolating within window is live motion")
	assert_vec3_almost_eq(s.position, Vector3(11, 0, 0), 0.01, "extrapolated by vel*0.1")


func test_angular_extrapolation_within_window() -> void:
	var buf := _make_buf()
	# 2 rad/s spin about Y, zero linear velocity.
	buf.push(1.0, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3(0, 2, 0))
	buf.push(2.0, Vector3.ZERO, Vector3(0, 2, 0), Vector3.ZERO, Vector3(0, 2, 0))
	# 0.1s past the last snapshot, inside the 0.25s extrap window → rotation extrapolated by angvel*0.1.
	var s := buf.sample(2.1)
	assert_true(s.valid)
	assert_false(s.holding, "extrapolating within window is live motion")
	assert_vec3_almost_eq(s.rotation, Vector3(0, 2.2, 0), 0.01, "rotation extrapolated by angvel*0.1")


func test_dry_past_window_holds() -> void:
	var buf := _make_buf()
	buf.push(1.0, Vector3.ZERO, Vector3.ZERO)
	buf.push(2.0, Vector3(10, 0, 0), Vector3.ZERO)
	# 0.5s past the last snapshot, beyond the 0.25s window → static hold.
	var s := buf.sample(2.5)
	assert_true(s.valid, "still reports a position for anything that does read it")
	assert_true(s.holding, "dry past extrap window → caller must stop clobbering the transform")


func test_fresh_snapshot_resumes_writes() -> void:
	var buf := _make_buf()
	buf.push(1.0, Vector3.ZERO, Vector3.ZERO)
	buf.push(2.0, Vector3(10, 0, 0), Vector3.ZERO)
	assert_true(buf.sample(2.5).holding, "went dry")
	# A teleport-sized jump clears history and appends; a following snapshot brackets render_time.
	buf.push(3.0, Vector3(500, 0, 0), Vector3.ZERO)  # > teleport_dist → history cleared
	buf.push(3.1, Vector3(500, 1, 0), Vector3.ZERO)
	var s := buf.sample(3.05)
	assert_true(s.valid)
	assert_false(s.holding, "fresh snapshots → interp takes back over")


## The extrapolated/anchor pair is what lets NetworkManager._clamp_extrapolation sweep the entity's
## collision volume from the last real sample to the guess — this class can't do that itself (it has
## no world), so it has to say when the position is a guess and where the guess started.
func test_interpolating_is_not_flagged_extrapolated() -> void:
	var buf := _make_buf()
	buf.push(1.0, Vector3.ZERO, Vector3.ZERO)
	buf.push(2.0, Vector3(10, 0, 0), Vector3.ZERO)
	var s := buf.sample(1.5)
	assert_false(s.extrapolated, "bracketed by two real snapshots → not a guess")
	assert_vec3_almost_eq(s.anchor, Vector3.ZERO, 0.01, "anchor is the snapshot being lerped from")


func test_extrapolated_reports_guess_and_anchor() -> void:
	var buf := _make_buf()
	buf.push(1.0, Vector3.ZERO, Vector3.ZERO, Vector3(10, 0, 0))
	buf.push(2.0, Vector3(10, 0, 0), Vector3.ZERO, Vector3(10, 0, 0))
	var s := buf.sample(2.1)  # 0.1s past the last snapshot, inside the window
	assert_true(s.extrapolated, "dead-reckoned past the last snapshot → a guess")
	assert_vec3_almost_eq(s.anchor, Vector3(10, 0, 0), 0.01, "anchor is the last REAL sample")
	assert_vec3_almost_eq(s.position, Vector3(11, 0, 0), 0.01, "guess is anchor + vel*0.1")


func test_single_snapshot_is_not_a_guess() -> void:
	var buf := _make_buf()
	buf.push(1.0, Vector3(3, 4, 5), Vector3.ZERO, Vector3(10, 0, 0))
	var s := buf.sample(2.0)
	assert_false(s.extrapolated, "one snapshot is held, never dead-reckoned")
	assert_vec3_almost_eq(s.anchor, Vector3(3, 4, 5), 0.01)
