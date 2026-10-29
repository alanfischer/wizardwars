class_name ViewDiag
extends RefCounted

## Client-side instrumentation for the player's own view (--view-diag): how smoothly the camera the
## player actually sees moves, and the prediction traffic behind it. Prints one line every
## REPORT_MS, so builds and network conditions can be compared run against run.
##
## Per rendered frame, from the camera position:
##   accel  the change in the camera's velocity over the frame. Steady running and turning stay
##          low; a correction the camera smoothing failed to hide is a spike.
##   pop    a frame whose accel is over POP_ACCEL. corr_pops are the ones within CORR_FRAMES of a
##          correction — the netcode's share; the rest are gameplay (steps, walls, jumps).
##   stall  a frame the camera didn't move although the physics tick it is drawn from did: the
##          interpolation froze. (Not "the player is moving": pressing into a wall keeps velocity
##          up while the body stays put, and that's no stall.)
## Per reconcile: how many unacked inputs it replays, and any correction's size.
## Per arriving own state: the spacing between arrivals, and how many gaps ran long.
##
## Frames are timed with the engine's own frame delta, the same clock the camera's physics
## interpolation runs on, so frame-timing noise doesn't read as motion.

const REPORT_MS := 5000
const POP_ACCEL := 60.0       ## m/s²
const CORR_FRAMES := 4
const STALL_MOVE := 0.0001    ## m: moved less than this in a frame = didn't move
const STALL_TICK := 0.002     ## m: ...while the tick it interpolates moved at least this far
const GAP_LIMIT_MS := 1000.0  ## longer gaps are deaths and respawns, not the stream
const LONG_GAP := 1.5         ## a gap over this many times the window's median ran long

var _next_report_ms := 0

var _has_prev := false
var _prev_pos := Vector3.ZERO
var _has_vel := false
var _prev_vel := Vector3.ZERO
var _last_state_us := 0

var _frames := 0
var _time := 0.0
var _accel_sq := 0.0
var _accel_max := 0.0
var _pops := 0
var _corr_pops := 0
var _since_corr := 1 << 30
var _stalls := 0
var _reconciles := 0
var _replay_sum := 0
var _replay_max := 0
var _corrections := 0
var _corr_sum := 0.0
var _corr_max := 0.0
var _gaps: Array[float] = []
var _uplink_sum := 0.0
var _uplink_n := 0
var _cmdrate := 0.0
var _arriving := 0
var _downlink_sum := 0.0
var _downlink_n := 0
var _rate := 0


## Spawn, teleport or death: the next frame starts a new path rather than jumping from the old one.
func reset_motion() -> void:
	_has_prev = false
	_has_vel = false


## tick_move: how far the camera moves across the physics tick this frame interpolates.
func note_frame(delta: float, pos: Vector3, tick_move: float) -> void:
	if _has_prev and delta > 0.0:
		var moved := pos - _prev_pos
		var vel := moved / delta
		if _has_vel:
			var accel := (vel - _prev_vel).length() / delta
			_accel_sq += accel * accel
			_accel_max = maxf(_accel_max, accel)
			if accel > POP_ACCEL:
				_pops += 1
				if _since_corr <= CORR_FRAMES:
					_corr_pops += 1
		if moved.length() < STALL_MOVE and tick_move >= STALL_TICK:
			_stalls += 1
		_prev_vel = vel
		_has_vel = true
		_frames += 1
		_time += delta
		_since_corr += 1
	_prev_pos = pos
	_has_prev = true
	_maybe_report()


func note_reconcile(unacked: int, corrected: bool, dist: float) -> void:
	_reconciles += 1
	_replay_sum += unacked
	_replay_max = maxi(_replay_max, unacked)
	if corrected:
		_since_corr = 0
		_corrections += 1
		_corr_sum += dist
		_corr_max = maxf(_corr_max, dist)


func note_state(now_us: int) -> void:
	if _last_state_us > 0:
		var gap := (now_us - _last_state_us) / 1000.0
		if gap < GAP_LIMIT_MS:
			_gaps.append(gap)
	_last_state_us = now_us


## The server's measure of our uplink queueing and of our packets arriving, and the input packet
## rate in force (0 = per tick).
func note_uplink(lag_ms: int, arriving: int, cmdrate: float) -> void:
	_uplink_sum += lag_ms
	_uplink_n += 1
	_arriving = arriving
	_cmdrate = cmdrate


## Our downlink's queueing, and the rate in force (0 = no limit).
func note_downlink(lag_ms: int, rate: int) -> void:
	_downlink_sum += lag_ms
	_downlink_n += 1
	_rate = rate


func _maybe_report() -> void:
	var now := Time.get_ticks_msec()
	if _next_report_ms == 0:
		_next_report_ms = now + REPORT_MS
		return
	if now < _next_report_ms:
		return
	_next_report_ms = now + REPORT_MS
	Log.info(report())
	_frames = 0
	_time = 0.0
	_accel_sq = 0.0
	_accel_max = 0.0
	_pops = 0
	_corr_pops = 0
	_stalls = 0
	_reconciles = 0
	_replay_sum = 0
	_replay_max = 0
	_corrections = 0
	_corr_sum = 0.0
	_corr_max = 0.0
	_gaps.clear()
	_uplink_sum = 0.0
	_uplink_n = 0
	_downlink_sum = 0.0
	_downlink_n = 0


func report() -> String:
	var gaps := _gaps.duplicate()
	gaps.sort()
	var n := gaps.size()
	var mean := 0.0
	for g in gaps:
		mean += g
	mean = mean / n if n > 0 else 0.0
	var sd := 0.0
	for g in gaps:
		sd += (g - mean) * (g - mean)
	sd = sqrt(sd / n) if n > 0 else 0.0
	var median: float = gaps[int(n * 0.5)] if n > 0 else 0.0
	var p95: float = gaps[mini(n - 1, int(n * 0.95))] if n > 0 else 0.0
	var long := 0
	for g in gaps:
		if g > median * LONG_GAP:
			long += 1
	return ("[ViewDiag] frames=%d fps=%.0f accel_rms=%.1f accel_max=%.0f pops=%d corr_pops=%d stalls=%d"
		+ " | reconciles=%d replay_avg=%.2f replay_max=%d corrections=%d corr_avg=%.3f corr_max=%.3f"
		+ " | states=%d gap_mean=%.1f gap_sd=%.1f gap_p95=%.1f gap_max=%.1f long=%d"
		+ " | uplink_lag=%.0f arriving=%d cmdrate=%.0f | downlink_lag=%.0f rate=%d") % [
		_frames, _frames / _time if _time > 0.0 else 0.0,
		sqrt(_accel_sq / _frames) if _frames > 0 else 0.0, _accel_max, _pops, _corr_pops, _stalls,
		_reconciles, float(_replay_sum) / maxi(_reconciles, 1), _replay_max,
		_corrections, _corr_sum / maxi(_corrections, 1), _corr_max,
		n, mean, sd, p95, gaps[n - 1] if n > 0 else 0.0, long,
		_uplink_sum / maxi(_uplink_n, 1), _arriving, _cmdrate, _downlink_sum / maxi(_downlink_n, 1), _rate]
