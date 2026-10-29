extends "res://src/tests/test_base.gd"
## ViewDiag's arithmetic on synthetic camera paths: steady motion is quiet, a jump is a pop and is
## blamed on a correction only right after one, a frozen frame is a stall only if its tick moved,
## and arrival spacing is summarized from the gaps.

const DT := 1.0 / 144.0


func _walk(diag: ViewDiag, from: Vector3, vel: Vector3, frames: int) -> Vector3:
	var p := from
	for i in frames:
		p += vel * DT
		diag.note_frame(DT, p, vel.length() * DT * 2.4)
	return p


func _field(line: String, key: String) -> float:
	return float(line.split(key + "=")[1].split(" ")[0])


func test_steady_motion_is_quiet() -> void:
	var diag := ViewDiag.new()
	_walk(diag, Vector3.ZERO, Vector3(5, 0, 0), 100)
	var line := diag.report()
	assert_eq(_field(line, "pops"), 0.0, "constant velocity has no pops")
	assert_true(_field(line, "accel_rms") < 0.01, "and no acceleration")


func test_a_jump_is_a_pop_blamed_on_a_correction_only_right_after_one() -> void:
	var diag := ViewDiag.new()
	var p := _walk(diag, Vector3.ZERO, Vector3(5, 0, 0), 20)
	diag.note_frame(DT, p + Vector3(0.1, 0, 0), 0.08)  # 10 cm out of nowhere
	p = _walk(diag, p + Vector3(0.1, 0, 0), Vector3(5, 0, 0), 20)
	var line := diag.report()
	assert_true(_field(line, "pops") >= 1.0, "a 10 cm jump pops")
	assert_eq(_field(line, "corr_pops"), 0.0, "with no correction near it, it isn't the netcode's")

	var blamed := ViewDiag.new()
	p = _walk(blamed, Vector3.ZERO, Vector3(5, 0, 0), 20)
	blamed.note_reconcile(3, true, 0.1)
	blamed.note_frame(DT, p + Vector3(0.1, 0, 0), 0.08)
	assert_true(_field(blamed.report(), "corr_pops") >= 1.0, "right after a correction, it is")


func test_a_frozen_frame_is_a_stall_only_if_its_tick_moved() -> void:
	var diag := ViewDiag.new()
	var p := _walk(diag, Vector3.ZERO, Vector3(5, 0, 0), 10)
	diag.note_frame(DT, p, 0.0)   # pressed into a wall: the tick didn't move either
	assert_eq(_field(diag.report(), "stalls"), 0.0, "not a stall")
	diag.note_frame(DT, p, 0.08)  # the tick moved 8 cm but the frame didn't
	assert_eq(_field(diag.report(), "stalls"), 1.0, "a stall")


func test_reconciles_and_corrections_are_summed() -> void:
	var diag := ViewDiag.new()
	diag.note_reconcile(2, false, 0.0)
	diag.note_reconcile(4, true, 0.05)
	diag.note_reconcile(3, true, 0.2)
	var line := diag.report()
	assert_eq(_field(line, "reconciles"), 3.0)
	assert_eq(_field(line, "replay_avg"), 3.0)
	assert_eq(_field(line, "replay_max"), 4.0)
	assert_eq(_field(line, "corrections"), 2.0)
	assert_eq(_field(line, "corr_max"), 0.2)


func test_arrival_spacing() -> void:
	var diag := ViewDiag.new()
	var t := 1_000_000
	for gap_ms in [0, 16, 17, 16, 17, 50, 16, 2000, 17]:  # 2000: a respawn, not the stream
		t += gap_ms * 1000
		diag.note_state(t)
	var line := diag.report()
	assert_eq(_field(line, "states"), 7.0, "the respawn gap is left out")
	assert_eq(_field(line, "gap_max"), 50.0)
	assert_eq(_field(line, "long"), 1.0, "one gap ran past 1.5x the median")
