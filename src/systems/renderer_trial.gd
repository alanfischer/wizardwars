extends Node
## Honouring the lobby's renderer choice, which can only be done by starting over.
##
## The rendering method is fixed when the engine starts, so a setting the player changed in the
## lobby cannot apply to the running process — the only honest way to honour it is to relaunch with
## the flag. That makes this a startup concern with a failure mode of its own: a renderer the
## machine cannot run does not reliably fall back, so the attempt has to be recorded BEFORE it is
## made and retired only once the lobby has actually come up on it.
##
## Parented to main.gd, which owns the lobby wiring and the --renderer-applied flag; everything
## about trying a renderer and writing the verdict down lives here.

## The one settings file, declared by RenderQuality — the renderer choice is stored beside the
## picture-quality level it belongs with.
const _SETTINGS_PATH := RenderQuality.SETTINGS_PATH
## Written before relaunching onto a chosen renderer and cleared once the lobby has actually come
## up on it. A renderer the machine cannot run does not reliably fall back — on the older Macs that
## forced the mobile default to be reverted, requesting a RenderingDevice renderer takes the process
## down with it — and the choice is stored, so without this the next launch reads the same setting,
## relaunches into the same crash, and the game can never be started again. Finding this key still
## set at startup means the last attempt never reached the lobby, so the renderer is treated as
## fatal on this machine and the preference goes back to the project default.
const _RENDERER_TRIAL_KEY := "renderer_trial"

## Set when a trial was abandoned; main shows it once the lobby exists.
var reset_note := ""


## An RD renderer that fails to start silently falls back to gl_compatibility, so a report of
## "it looks different / it is slow" is unreadable without knowing which renderer actually initialised.
func log_active_renderer() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var method: String = RenderingServer.get_current_rendering_method()
	# _with_override, or this reads the base setting ("mobile" for Android/Quest) and reports every
	# desktop launch as a fallback off the rendering_method.pc value.
	var wanted: String = str(ProjectSettings.get_setting_with_override(
			&"rendering/renderer/rendering_method"))
	# Godot strips recognised engine args from get_cmdline_args(), so a manual --rendering-method is
	# indistinguishable from a fallback here — report both and let the reader judge.
	var note := "" if method == wanted else "  [project default: %s]" % wanted
	Log.info("Renderer: %s (%s)%s" % [method, RenderingServer.get_video_adapter_name(), note])
	# Boot-time logging is stdout-only — the log FILE is opened later, when a join or /perf happens —
	# so a report sent in from another machine arrives with no idea what hardware produced it. Repeat
	# the identity into the file whenever one is opened.
	# The viewport's own rect is the authority on how many pixels are actually shaded — screen scale
	# alone does not say whether the window is HiDPI-backed.
	var vp := get_viewport()
	Log.info("Machine: %s %s | %s | %d cores | window %s @ %.1fx | viewport %s" % [
		OS.get_name(), OS.get_version(), OS.get_processor_name(), OS.get_processor_count(),
		DisplayServer.window_get_size(), DisplayServer.screen_get_scale(),
		vp.get_visible_rect().size if vp else Vector2.ZERO])


## Start the stored renderer preference, relaunching if the running process is not already on it.
## Returns true if a relaunch was started, in which case the caller should stop setting itself up.
##
## Worth the trouble because the gap between renderers on a given GPU is not small: the same scene
## measured 62.9ms under gl_compatibility and ~2ms under both RenderingDevice renderers on one Mac,
## while a different Mac could not run them at all. Only the machine can settle it.
func apply_preference(renderer_applied: bool, is_dedicated_server: bool) -> bool:
	if renderer_applied or is_dedicated_server or DisplayServer.get_name() == "headless":
		return false
	var cfg := ConfigFile.new()
	if cfg.load(_SETTINGS_PATH) != OK:
		return false
	var trial := str(cfg.get_value("graphics", _RENDERER_TRIAL_KEY, ""))
	if not trial.is_empty():
		cfg.set_value("graphics", _RENDERER_TRIAL_KEY, "")
		cfg.set_value("graphics", "renderer", "")
		cfg.save(_SETTINGS_PATH)
		reset_note = "Renderer '%s' could not start on this machine — back to the default." % trial
		Log.info("Renderer '%s' never reached the lobby last launch; preference reset to the project default." % trial)
		return false
	var want := str(cfg.get_value("graphics", "renderer", ""))
	if want.is_empty() or want == RenderingServer.get_current_rendering_method():
		return false
	return relaunch_for(want)


## Reaching the lobby is the definition of "this renderer works well enough to change it again",
## so that is where the trial marker is retired.
func clear_trial() -> void:
	_set_trial("")


## Record that `want` is being tried, so a launch that dies before the lobby can be recognised as
## fatal next time. Written before the child starts, because a crashing child never gets to write
## anything itself; "" clears it.
func _set_trial(want: String) -> void:
	var cfg := ConfigFile.new()
	cfg.load(_SETTINGS_PATH)  # load existing; OK if missing
	cfg.set_value("graphics", _RENDERER_TRIAL_KEY, want)
	cfg.save(_SETTINGS_PATH)


## Start this executable again on `want` ("" means the project default) and quit. Returns false if
## the new process could not be started, in which case this one carries on untouched.
func relaunch_for(want: String) -> bool:
	var exe := OS.get_executable_path()
	if exe.is_empty():
		return false
	var args := PackedStringArray()
	if not want.is_empty():
		args.append("--rendering-method")
		args.append(want)
	args.append("--")
	# Only user args survive: Godot strips the engine args it recognised from get_cmdline_args(),
	# so a --resolution or a manual --rendering-method cannot be reconstructed here. That is why
	# --renderer-applied exists as an opt-out for scripts that pick a renderer on purpose.
	for arg in OS.get_cmdline_user_args():
		if arg != "--renderer-applied":
			args.append(arg)
	# The child is marked even when it is going back to the project default: a renderer that fails
	# to start falls back to gl_compatibility without changing the setting, so an unmarked child
	# would read the same preference, disagree with what came up, and relaunch forever.
	args.append("--renderer-applied")
	Log.info("Relaunching on renderer '%s' (currently %s)" % [
			want if not want.is_empty() else "project default",
			RenderingServer.get_current_rendering_method()])
	_set_trial(want if not want.is_empty() else "default")
	if OS.create_process(exe, args) <= 0:
		_set_trial("")  # nothing was tried, so nothing should be blamed next launch
		push_warning("Could not relaunch for renderer '%s' — staying on %s" % [
				want, RenderingServer.get_current_rendering_method()])
		return false
	get_tree().quit()
	return true
