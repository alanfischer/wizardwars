extends Node
## What a player's FPS actually is, measured and shown.
##
## ServerPerf (in main.gd) measures the simulation tick; this measures the RENDERED frame. The two
## are kept apart because a listen host runs both in one process and their budgets fail
## independently — a 2ms tick can still sit behind a 20ms frame.
##
## Reached two ways: --perf-log <sec> on the command line, and /perf in chat. The command exists
## because a player on a machine we cannot get a shell on has no way to pass a flag, but they can
## always open chat. Both go through set_reporting(), so a flagged run and a typed one report the
## same way.
##
## Parented to main.gd as "ClientPerf" and kept across map changes, overlay and all: a measurement
## that lost its numbers every map load would not be one.

## --perf-log <sec> / /perf <sec>: 0 = off.
var _log_interval := 0.0
var _log_timer := 0.0
## --perf-quit <sec>: quit this long after the map is live; 0 = never.
var _quit_after := 0.0
var _quit_timer := 0.0
var _frame_usec: PackedInt32Array = PackedInt32Array()  # per-frame wall times since last report
var _last_frame_usec := 0
var _proc_sec := 0.0             # worst TIME_PROCESS seen this window
var _phys_sec := 0.0             # worst TIME_PHYSICS_PROCESS seen this window
var _inventoried := false        # the scene inventory is logged once, at the first report
var _overlay: CanvasLayer
var _overlay_label: Label

## main.gd, only as the root to walk for the scene inventory.
var _main: Node3D
## src/systems/renderer_trial.gd — which renderer came up belongs in the perf log.
var _renderer_trial: Node


func bind(main: Node3D, renderer_trial: Node) -> void:
	_main = main
	_renderer_trial = renderer_trial


func _ready() -> void:
	ClientCommandSystem.register("perf", _cmd_perf, "/perf [seconds | 0]",
			"Frame-cost overlay + [ClientPerf] log lines. No argument toggles it.")


## /perf [seconds | 0] — the console route to the frame profiler. No argument toggles it at 1s.
func _cmd_perf(args: String) -> void:
	var arg := args.strip_edges()
	if arg.is_empty():
		set_reporting(0.0 if _log_interval > 0.0 else 1.0)
	elif arg.is_valid_float():
		set_reporting(maxf(0.0, float(arg)))
	else:
		ClientCommandSystem.reply_err("Usage: /perf [seconds | 0]")
		return
	if _log_interval > 0.0:
		# A listen host opens no log file — only the dedicated-server and join paths do — so a
		# player hosting their own game would get an overlay and nothing to send anywhere.
		if not Log.is_file_logging():
			Log.enable_file_logging("perf.log")
		_renderer_trial.log_active_renderer()
		ClientCommandSystem.reply_ok("Perf overlay on, reporting every %ss." % _log_interval)
		ClientCommandSystem.reply_ok("Writing to %s" % Log.get_file_path())
		if not Game.game_active:
			ClientCommandSystem.reply_ok("Waiting for a map — nothing is sampled in the menu.")
	else:
		ClientCommandSystem.reply_ok("Perf overlay off. Log kept at %s" % Log.get_file_path())


func set_reporting(interval: float) -> void:
	_log_interval = interval
	# A stale window would report the gap since the last sample as one enormous frame.
	_frame_usec.clear()
	_last_frame_usec = 0
	_log_timer = 0.0
	_proc_sec = 0.0
	_phys_sec = 0.0
	if interval <= 0.0:
		if _overlay:
			_overlay.visible = false
		return
	if not is_instance_valid(_overlay):
		_build_overlay()
	_overlay.visible = true
	_overlay_label.text = "waiting for a frame..."


func set_quit_after(seconds: float) -> void:
	_quit_after = seconds


## Child of this node rather than the HUD: the HUD is torn down and rebuilt across map changes, and
## an overlay that vanished mid-measurement would be worse than none.
func _build_overlay() -> void:
	_overlay = CanvasLayer.new()
	_overlay.name = "PerfOverlay"
	_overlay.layer = 128
	add_child(_overlay)
	var panel := PanelContainer.new()
	panel.position = Vector2(8, 8)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.0, 0.0, 0.0, 0.55)
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 4
	style.content_margin_bottom = 4
	panel.add_theme_stylebox_override("panel", style)
	_overlay.add_child(panel)
	_overlay_label = Label.new()
	_overlay_label.add_theme_font_size_override("font_size", 13)
	_overlay_label.add_theme_color_override("font_color", Color(0.7, 1.0, 0.7))
	_overlay_label.add_theme_constant_override("outline_size", 3)
	_overlay_label.add_theme_color_override("font_outline_color", Color.BLACK)
	panel.add_child(_overlay_label)


func _process(delta: float) -> void:
	# Only once the map is live: load frames are a multi-hundred-ms stall that would own every
	# "worst frame" number for the rest of the run.
	if _log_interval > 0.0 and Game.game_active:
		_sample_frame(delta)


func _physics_process(delta: float) -> void:
	if not Game.game_active:
		return
	if _log_interval > 0.0:
		_phys_sec = maxf(_phys_sec, Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS))
	if _quit_after > 0.0:
		_quit_timer += delta
		if _quit_timer >= _quit_after:
			Log.info("[ClientPerf] --perf-quit reached %.0fs, exiting" % _quit_after)
			get_tree().quit()


## Mean FPS hides the stutter players actually notice, so the report leads with the 1% low (mean of
## the worst 1% of frames) and the single worst frame. peak proc is the engine's TIME_PROCESS,
## covering the whole idle step (every _process callback AND the renderer's draw submission), so it
## does not by itself say a cost was script-side — per-subsystem timers are the only way to settle that.
func _sample_frame(delta: float) -> void:
	var now := Time.get_ticks_usec()
	if _last_frame_usec > 0:
		_frame_usec.append(now - _last_frame_usec)
	_last_frame_usec = now
	# TIME_PROCESS is the worst step of the last second, not the last frame's — take the max over
	# the window rather than a mean, which would average a peak against itself.
	_proc_sec = maxf(_proc_sec, Performance.get_monitor(Performance.TIME_PROCESS))
	_log_timer += delta
	if _log_timer < _log_interval or _frame_usec.size() < 2:
		return
	var frames := _frame_usec.duplicate()
	frames.sort()
	var n := frames.size()
	var total := 0
	for f in frames:
		total += f
	var mean_ms := total / float(n) / 1000.0
	# 1% low: mean of the slowest 1% of frames (at least one), reported as the FPS that implies.
	@warning_ignore("integer_division")
	var low_n := maxi(1, n / 100)
	var low_total := 0
	for i in low_n:
		low_total += frames[n - 1 - i]
	var low_ms := low_total / float(low_n) / 1000.0
	# Both are peaks, not means — that's the number that explains a stutter; a mean would hide it.
	var proc_ms := _proc_sec * 1000.0
	var phys_ms := _phys_sec * 1000.0
	var worst_ms := frames[n - 1] / 1000.0
	var draws := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
	var objs := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME)
	@warning_ignore("integer_division")
	var prims_k := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME) / 1000
	var nodes := Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	var mem_mb := Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0
	var vram_mb := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED) / 1048576.0
	Log.info("[ClientPerf] fps=%.0f (%.2fms) 1%%low=%.0f (%.2fms) worst=%.2fms | peak proc=%.2fms phys=%.2fms | draws=%d objs=%d prims=%dk | nodes=%d mem=%.0fMB vram=%.0fMB" % [
		1000.0 / maxf(mean_ms, 0.001), mean_ms,
		1000.0 / maxf(low_ms, 0.001), low_ms,
		worst_ms,
		proc_ms, phys_ms,
		draws, objs, prims_k,
		nodes, mem_mb, vram_mb])
	if _overlay_label:
		# The renderer line leads: which renderer actually initialised is the first thing worth
		# knowing on an unfamiliar machine, and get_current_rendering_method() reports what came up,
		# not what was asked for.
		_overlay_label.text = "\n".join([
			"%s  %s" % [RenderingServer.get_current_rendering_method(), RenderingServer.get_video_adapter_name()],
			"fps %.0f (%.2fms)   1%% low %.0f (%.2fms)" % [
				1000.0 / maxf(mean_ms, 0.001), mean_ms, 1000.0 / maxf(low_ms, 0.001), low_ms],
			"worst %.2fms   proc %.2fms   phys %.2fms" % [worst_ms, proc_ms, phys_ms],
			"draws %d   objs %d   prims %dk" % [draws, objs, prims_k],
			"nodes %d   mem %.0fMB   vram %.0fMB" % [nodes, mem_mb, vram_mb]])
	if not _inventoried:
		_inventoried = true
		_log_scene_inventory()
	_frame_usec.clear()
	_log_timer = 0.0
	_proc_sec = 0.0
	_phys_sec = 0.0


## One-shot companion to the ClientPerf report: what the scene is ASKING the renderer to draw. The
## report's draws/objs are per-frame results after culling; this is the ceiling they come from, so
## together they say whether a heavy frame is a culling problem or an authoring problem.
func _log_scene_inventory() -> void:
	var meshes := 0
	var surfaces := 0
	var tris := 0
	var materials := {}          # material RID -> surface count; distinct materials bound the batching
	var stack: Array[Node] = [get_tree().current_scene if get_tree().current_scene else _main]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for c in node.get_children():
			stack.push_back(c)
		var mi := node as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		meshes += 1
		for s in mi.mesh.get_surface_count():
			surfaces += 1
			var arrays: Array = mi.mesh.surface_get_arrays(s)
			var idx: Variant = arrays[Mesh.ARRAY_INDEX]
			if idx != null:
				tris += idx.size() / 3
			elif arrays[Mesh.ARRAY_VERTEX] != null:
				tris += arrays[Mesh.ARRAY_VERTEX].size() / 3  # non-indexed: 3 verts per triangle
			var mat := mi.get_active_material(s)
			if mat != null:
				materials[mat.get_rid()] = materials.get(mat.get_rid(), 0) + 1
	@warning_ignore("integer_division")
	Log.info("[ClientPerf] scene: %d MeshInstance3D, %d surfaces, %d distinct materials, %dk tris total (%.0f tris/surface)" % [
		meshes, surfaces, materials.size(), tris / 1000, tris / float(maxi(surfaces, 1))])
