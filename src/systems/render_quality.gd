class_name RenderQuality
extends Object
## Picture-quality presets, chosen in the lobby and stored beside the renderer choice.
##
## Unlike the rendering method — which is fixed when the engine starts and costs a relaunch to
## change (see LobbyUI._show_renderer_restart_popup) — everything here is a live property on the
## viewport, so a new choice takes effect on the next frame. Every level works on all three
## rendering methods; gl_compatibility resolves MSAA the same way the RD renderers do.

const SETTINGS_PATH := "user://settings.cfg"  # shared with LobbyUI and RendererTrial
const DEFAULT_LEVEL := "medium"

## setting value -> [label, msaa, glow, surface detail, procedural sky]. Ordered cheapest first;
## the lobby lists them in this order. 2x is the default because multisampling is resolved in
## tile memory on the mobile GPUs (Quest) and is close to free on any desktop part, while BSP
## maps are nothing but hard geometric edges. Glow, surface detail and the sky are the entries
## that change how the game LOOKS rather than how cleanly it draws, so all three stay off until
## asked for. Detail costs a second draw of the world besides (see WorldMaterials), and the sky
## is the priciest of them on these maps: sky is over half the world surface area on the median
## WW map, so it is a per-pixel shader running across a lot of the frame.
const LEVELS := {
	"low": ["Low — no antialiasing", Viewport.MSAA_DISABLED, false, false, false, false],
	"medium": ["Medium — 2x antialiasing", Viewport.MSAA_2X, false, false, false, false],
	"high": ["High — 4x antialiasing, glow, surface detail, sky, water", Viewport.MSAA_4X,
		true, true, true, true],
}

## Nothing in the scene renders above 1.0: the world shader clamps albedo x lightmap to it
## (goldsrc_bsp.cpp) and gl_compatibility draws into an LDR buffer either way, so a threshold AT
## 1.0 — Godot's default — would find nothing to bloom. Just under it catches what is meant to
## read as bright: spell sprites, projectile flashes, light fixtures. Additive rather than the
## default soft-light because a fireball should add light to the room, not tint it.
const GLOW_HDR_THRESHOLD := 0.9
const GLOW_INTENSITY := 0.45


static var _logged_level := ""  # so re-applying the same level on every map load stays quiet


## The stored choice, or the default when nothing is stored and when a settings file names a
## level this build no longer has.
static func load_level() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return DEFAULT_LEVEL
	var level := str(cfg.get_value("graphics", "quality", DEFAULT_LEVEL))
	return level if LEVELS.has(level) else DEFAULT_LEVEL


## Whether this level draws the world's detail pass. Read by main.gd rather than applied here:
## it needs the loaded map, which is not this class's business.
static func detail_enabled(level := "") -> bool:
	var preset: Array = LEVELS.get(level if level else load_level(), LEVELS[DEFAULT_LEVEL])
	return preset[3]


## Whether this level gives liquid its depth-driven half: absorption, shoreline foam and wave
## shading. Read by main.gd and handed to WaterSurfaces, which owns the liquid materials —
## same division of labour as detail_enabled above. Rides the quality level rather than the
## renderer because the depth texture it needs works on both (see WaterSurfaces).
static func water_depth_enabled(level := "") -> bool:
	var preset: Array = LEVELS.get(level if level else load_level(), LEVELS[DEFAULT_LEVEL])
	return preset[5]


## Whether this level draws the procedural sky in place of the map's shipped cubemap. Read by
## Skybox, which owns the sky material — same division of labour as detail_enabled above.
static func sky_enhanced(level := "") -> bool:
	var preset: Array = LEVELS.get(level if level else load_level(), LEVELS[DEFAULT_LEVEL])
	return preset[4]


static func save_level(level: String) -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)  # load existing; OK if missing
	cfg.set_value("graphics", "quality", level)
	cfg.save(SETTINGS_PATH)


## Push `level` onto `viewport`, and onto `env` when the caller has one — the gameplay Environment
## is built per map by Skybox.setup, so it arrives later than the viewport and is replaced on every
## map change. Safe to call on a headless server, and with a null env.
static func apply(level: String, viewport: Viewport, env: Environment = null) -> void:
	if not viewport or DisplayServer.get_name() == "headless":
		return
	var preset: Array = LEVELS.get(level, LEVELS[DEFAULT_LEVEL])
	viewport.msaa_3d = preset[1]
	if env:
		env.glow_enabled = preset[2]
		env.glow_hdr_threshold = GLOW_HDR_THRESHOLD
		env.glow_intensity = GLOW_INTENSITY
		env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
	# Logged for the same reason the rendering method is: a report of "it looks different / it is
	# slow" is unreadable without knowing what the machine was actually drawing at. Only on a
	# change, or every map load would repeat it.
	if level != _logged_level:
		_logged_level = level
		Log.info("Render quality: %s (msaa_3d=%d, glow=%s)" % [level, viewport.msaa_3d, preset[2]])
