extends Node
## Film the LIVE game from above: a second camera on the real scene, captured to frames.
##
## This is not a replay of logged positions — it shares the running World3D, so whatever is on
## screen is in the shot: spells, projectiles, monsters, gibs, doors, the lot. That is the whole
## reason it exists; a CSV replay can only ever draw what somebody remembered to record.
##
##   /topview [seconds]      ... play ...      /stoptopview
##   tools/match_gif.py --frames <dir> --out /tmp/match.mp4
##
## Needs a real renderer, so it runs in a client or listen host, never --headless.
##
## Cost: a second view of the whole map is a second full draw. Two things keep it affordable —
## the viewport only renders on the frames actually captured (UPDATE_ONCE, not ALWAYS), and
## frames are JPEG rather than PNG, which is roughly 10x faster to encode at this size.

const TopDownFrame = preload("res://src/systems/top_down_frame.gd")

const FPS := 12.0            # captures a second
const PIXELS := 1200         # square; the whole map is framed, so this is the detail budget.
## At 900 a player was ~6px across and hard to pick out; markers from /record can be overlaid
## on top of these frames (tools/match_gif.py --frames DIR --csv CSV), which is the readable combo.
const JPEG_QUALITY := 0.82
const ENCODE_QUEUE := 4      # JPEG encodes allowed in flight before we wait for the oldest

var _sub: SubViewport = null
var _cam: Camera3D = null
var _t := 0.0
var _elapsed := 0.0
var _limit := 0.0
var _n := 0
var _busy := false
## Every frame's real elapsed time. Frames do NOT come out at exactly FPS — a capture awaits
## frame_post_draw, and the clock kept running while it did — so 300s produced 3467 frames, an
## 11.56fps average against an assumed 12. The compositor indexing by frame number then drifted
## about 11 seconds ahead of the picture by the end of a five-minute match. Writing the true
## timestamps means the overlay is matched to when the frame was actually taken.
var _times: FileAccess = null
var _encodes: Array[int] = []   # JPEG encodes running on worker threads (see _capture)
var dir := ""


func start(map_name: String, seconds: float, cut_override := INF) -> String:
	stop()
	var main := get_tree().current_scene
	if main == null:
		return ""
	var raw := TopDownFrame.world_aabb(main)
	if raw.size == Vector3.ZERO:
		return ""
	var f := TopDownFrame.frame(raw, cut_override)

	var stamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	dir = "user://replays/%s-%s-top" % [map_name, stamp]
	DirAccess.make_dir_recursive_absolute(dir)

	_sub = SubViewport.new()
	_sub.size = Vector2i(PIXELS, PIXELS)
	_sub.own_world_3d = false          # SHARE the live world — this is the point
	_sub.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_sub)
	_cam = TopDownFrame.make_camera(f)
	_sub.add_child(_cam)

	var meta := TopDownFrame.meta(map_name, PIXELS, f)
	meta["fps"] = FPS
	FileAccess.open(dir + "/meta.json", FileAccess.WRITE).store_string(JSON.stringify(meta, "  "))
	_times = FileAccess.open(dir + "/times.csv", FileAccess.WRITE)
	_times.store_line("frame,t")
	_n = 0
	_t = 0.0
	_elapsed = 0.0
	_limit = seconds
	set_process(true)
	return dir


func stop() -> void:
	set_process(false)
	for t in _encodes:
		WorkerThreadPool.wait_for_task_completion(t)
	_encodes.clear()
	if _times != null:
		_times.close()
		_times = null
	if _sub != null and is_instance_valid(_sub):
		_sub.queue_free()
	_sub = null
	_cam = null


func is_recording() -> bool:
	return _sub != null


func frames() -> int:
	return _n


func _process(delta: float) -> void:
	if _sub == null:
		return
	# Keep the clock running through a capture. Returning early here is what made the real frame
	# rate drift below FPS and desynced the overlay.
	_elapsed += delta
	if _busy:
		return
	if _limit > 0.0 and _elapsed >= _limit:
		stop()
		return
	_t += delta
	if _t < 1.0 / FPS:
		return
	_t -= 1.0 / FPS
	_capture()


func _capture() -> void:
	_busy = true
	# Draw this frame only. Leaving the viewport on UPDATE_ALWAYS would double the renderer's
	# work for every frame of the match, not just the twelve a second that get kept.
	var stamp := _elapsed
	_sub.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	var img := _sub.get_texture().get_image()
	# The GPU readback has to happen here, but the JPEG encode does not: 1.4 megapixels through
	# libjpeg is 5-15ms, twelve times a second, on the thread also simulating the match. Once
	# get_image() has returned, the Image is an ordinary Resource a worker can have.
	var out := "%s/f%05d.jpg" % [dir, _n]
	while _encodes.size() >= ENCODE_QUEUE:
		WorkerThreadPool.wait_for_task_completion(_encodes.pop_front())
	_encodes.append(WorkerThreadPool.add_task(func() -> void: img.save_jpg(out, JPEG_QUALITY)))
	if _times != null:
		_times.store_line("%d,%.3f" % [_n, stamp])
	_n += 1
	_busy = false

