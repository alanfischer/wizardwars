extends Node3D

const Movement = preload("res://addons/pmove/movement.gd")
const LocalPlayerScene = preload("res://src/local_player.tscn")
const RemotePlayerScene = preload("res://src/remote_player.tscn")
const BlenderMapConverterScript = preload("res://src/systems/blender_map_converter.gd")
const IntroGuide = preload("res://src/systems/intro_guide.gd")
const KeyBindings = preload("res://src/systems/key_bindings.gd")
const WaypointBake = preload("res://src/bot/waypoint_bake.gd")
const RendererTrialScript = preload("res://src/systems/renderer_trial.gd")
const EntityRegistry = preload("res://src/entities/entity_registry.gd")
const ClientSyncScript = preload("res://src/systems/client_sync.gd")
const ClientPerfScript = preload("res://src/systems/client_perf.gd")
const ClientJoinScript = preload("res://src/systems/client_join.gd")


## A dynamic entity's NetSync: SyncSpec derives the config and goldnet's quant/push metas from
## this table. Shadow props feed client-side interp only, so half-floats are free bandwidth (~5cm
## at the ~102m world bound); net_stamp is stamped the tick it's published, so time_delta keeps it
## ~1B. All five are written by NetInterpBridge._publish, which marks the entity dirty.
const DYN_ENTITY_SPEC := {
	"NetInterp:net_pos": {"quant": "vec3_half", "push": true},
	"NetInterp:net_rot": {"quant": "vec3_half", "push": true},
	"NetInterp:net_vel": {"quant": "vec3_half", "push": true},
	"NetInterp:net_angvel": {"quant": "vec3_half", "push": true},
	"NetInterp:net_stamp": {"quant": "time_delta", "push": true},
}

var lightstyle_image: Image    # 64×1 FORMAT_RF, shared with shader materials
var lightstyle_texture: ImageTexture  # shared across all BSP materials
# Stored on the Game autoload, not here: the rest of the game reads these, and main.tscn is not
# the current scene under the test runner. Kept as properties so main's own ~150 uses read as
# plain fields while there is still only one copy of each — see src/systems/game.gd.
var _local_player: LocalPlayer:
	get: return Game.local_player
	set(v): Game.local_player = v
var _decal_system: DecalSystem:
	get: return Game.decal_system
	set(v): Game.decal_system = v
var weather_system: WeatherSystem:
	get: return Game.weather_system
	set(v): Game.weather_system = v
var hud: HUD:
	get: return Game.hud
	set(v): Game.hud = v
var _game_active: bool:
	get: return Game.game_active
	set(v): Game.game_active = v
var _is_dedicated_server := false
var _is_listen_host := false  # --host: start a listen server from the CLI (skip lobby)
var _server_perf_timer := 0.0
var _server_physics_ticks := 0  # count ticks per second for FPS logging
# Wall-clock tick profiling (host only): _server_perf_timer counts fixed physics delta, which can
# never reveal a slow server; these measure real microseconds so an over-budget tick is visible.
var _server_wall_usec := 0            # wall-clock time since the last report
var _server_tick_usec := 0            # summed wall time of the host tick section
var _server_bot_usec := 0             # of which: BotSystem.tick()
var _server_move_usec := 0            # of which: _process_player_movements()
var _server_bcast_usec := 0           # of which: net broadcast (NET_TICKRATE only)
var _server_last_tick_end_usec := 0   # timestamp of previous tick end (for wall delta)
var _net_half_tick := false           # toggles per net tick: gates the 30Hz half of the broadcast
var _server_cal_usec := 0             # clock calibration: summed cost of a fixed loop (see _clock_calibration)
var _server_cal_samples := 0
var _server_process_frames := 0       # host main-loop (_process) iterations since last report —
									  # this is the real ENet poll / ping-turnaround rate


# --- Host body puppet ---
# The listen-server host's own player IS a RemotePlayer puppet — the same server-authoritative,
# damageable, collidable body every client gets, fed wire-serialized copies of the local
# InputCommands through the normal _process_player_movements loop. _local_player is only the
# predicted first-person view (collision layer 0, not damageable), reconciled against the puppet
# through the same _on_owner_state handler clients use.
var _host_puppet: RemotePlayer = null
# All player puppets are created through this MultiplayerSpawner, which gives them the
# replication-ID handshake their baked MultiplayerSynchronizer needs to pair.
var _player_spawner: MultiplayerSpawner = null
# Dynamic entities get their net-id from the reliable spawn packet (unlike static map entities,
# which use the path cache), so there's no create-before-sync race.
var _dyn_spawner: MultiplayerSpawner = null

var _lobby: CanvasLayer
var _team_select_ui: CanvasLayer
var _map_root: Node3D
var _map_converter: Node
var _resource_converter: Node
var _blender_map_converter: Node
var _light_grid: LightGrid
var _world_env: WorldEnvironment
var _skybox: Skybox
var _xr_rig: Node3D
var _xr_rig_camera: Camera3D
var _vr_lobby_panel: VRLobbyPanel
var _vr_hud_panel: VRHUDPanel
var _head_probe_shape := SphereShape3D.new()
var _sky_surfaces: Array[MeshInstance3D] = []
var _xr_right_controller: XRController3D
var _xr_left_controller: XRController3D
var _current_map_name: String:
	get: return Game.current_map_name
	set(v): Game.current_map_name = v
var _current_map_info := ""  # raw text of maps/<map>.txt for the MOTD panel
var _current_map_world := ""  # raw text of maps/<map>.ww (world-map briefing)
var _local_player_name := "Wizard"

# Client join state: must wait for BOTH map and resources before loading
var _local_map_ready := false
var _local_resources_ready := false
var _local_pending_map_name := ""



var _auto_connect_ip := ""  # --connect <ip>: auto-join server on startup
var _bsp_hulls_arg := ""  # --bsp-hulls <on|off>: start with BSP hull collision forced either way
var _auto_team := 0  # --team <1-4>: auto-join team on game start
var _auto_class := 0  # --class <name>: auto-pick class on game start
var _auto_name := ""  # --name <name>: set player name from command line
var _auto_bots := 0  # --bots <n>: dedicated server fills with this many AI bots on startup
## --timelimit/--scorelimit/--fraglimit <n>, applied to the matching server var in _ready. A
## dedicated server has no console, so the match limits have to be reachable as flags.
var _limit_args: Dictionary = {}  # server var name -> unparsed value
## Carried across a map change, since _unload_map wipes them: the bots that were in play (so a
## rotation doesn't empty a bot server). The local player's role is deliberately NOT carried — a
## new map puts everyone back in the team/class menu.
var _carry_bots: Array[Dictionary] = []
var _auto_walk := false  # --auto-walk: test hook — local player walks forward and turns
var _bake_waypoints := false  # --bake-waypoints: offline bot-nav graph generator (then quit)
var _auto_walk_turn := 0.35  # --auto-walk-turn <rad/s>: auto-walk turn rate
# --nudge-players <m>,<s>: test hook — every <s> seconds the server shifts each client's player <m>
# sideways, a misprediction of known size, to calibrate --view-diag's measures of what one costs.
var _nudge_dist := 0.0
var _nudge_interval_ms := 1000
var _nudge_next_ms := 0
var _auto_fire := false  # --auto-fire: test hook — local player attacks continuously
var _auto_fire_slot := 1  # --auto-fire-slot <idx>: which weapon slot auto-fire uses
var _admin_password := ""  # --admin-password / WW_ADMIN_PASSWORD: enables /auth
var _renderer_applied := false  # --renderer-applied: this process is already the relaunch
## Renderer preference, trial marker and the relaunch that applies them (src/systems/renderer_trial.gd).
var _renderer_trial: Node
## The server-told-us-something handlers (src/systems/client_sync.gd).
var _client_sync: Node
## Rendered-frame profiling: /perf, --perf-log, --perf-quit (src/systems/client_perf.gd).
var _client_perf: Node
## Team/class picking and the join watchdog (src/systems/client_join.gd).
var _client_join: Node
var _use_goldnet := true  # default transport: GoldNetMultiplayer (GoldSrc ack-delta). --stock opts out.
## Set when goldnet was wanted but the extension was not there — a broken install, not a choice.
## Joining on stock against a goldnet server draws the world and no entities at all, so we refuse.
var _goldnet_missing := false
var _sv_updaterate := 0.0  # --sv-updaterate <hz>: server broadcast rate; 0 = leave at the default


## Every command-line flag, as name -> handler. A handler taking no argument is a bare switch; one
## taking a String consumes the next token as its value, and the arity comes from the Callable
## itself, so each flag is declared in exactly one place.
##
## Declarative rather than an elif chain so the two ways of getting it wrong are reportable: a flag
## typed without its value, and a flag that is not a flag at all. The old chain silently no-opped
## both, and a dedicated server has no console to notice on — it would just come up misconfigured.
func _flag_handlers() -> Dictionary:
	return {
		"--server": func() -> void: _is_dedicated_server = true,
		# Listen server (local player + authority in one process), no lobby UI. Combine with
		# --map, --team/--class for auto-join — headless-testable.
		"--host": func() -> void: _is_listen_host = true,
		# Test hooks: the local player walks forward and slowly turns (exercising prediction with
		# no human at the controls), and/or attacks continuously.
		"--auto-walk": func() -> void: _auto_walk = true,
		"--auto-walk-turn": func(v: String) -> void: _auto_walk_turn = float(v),  # rad/s; 0 = straight line
		"--nudge-players": func(v: String) -> void:
			var parts := v.split(",")
			_nudge_dist = float(parts[0])
			if parts.size() > 1:
				_nudge_interval_ms = int(float(parts[1]) * 1000.0),
		"--auto-fire": func() -> void: _auto_fire = true,
		"--auto-fire-slot": func(v: String) -> void: _auto_fire_slot = int(v),
		# Every <sec>, log rendered-frame cost. Counterpart to [ServerPerf], which only sees the
		# simulation tick. It also pins the global RNG: with --auto-walk the random spawn decides
		# the entire route, and an unseeded run would measure a different tour each time, swamping
		# the effect being profiled.
		"--perf-log": func(v: String) -> void:
			_client_perf.set_reporting(maxf(0.0, float(v)))
			seed(1),
		"--perf-quit": func(v: String) -> void: _client_perf.set_quit_after(maxf(0.0, float(v))),
		# Sets the server var (a dedicated server has no console for /bsp_hulls), so it replicates
		# normally. On a client it only holds until the host's snapshot lands on join.
		"--bsp-hulls": func(v: String) -> void: _bsp_hulls_arg = v.strip_edges().to_lower(),
		# Turn on one of Log's off-by-default tags (e.g. "tfgoal" for scoring).
		# Repeatable. Log.enable_tag existed but nothing could reach it.
		"--log-tag": func(v: String) -> void: Log.enable_tag(v.strip_edges()),
		# Offline tool: load --map headless, sample a bot navigation graph from its collision
		# world, write maps/waypoints/<map>.gen_wpt, and quit. See src/bot/waypoint_bake.gd.
		"--bake-waypoints": func() -> void: _bake_waypoints = true,
		"--map": func(v: String) -> void: _current_map_name = v,
		"--connect": func(v: String) -> void: _auto_connect_ip = v,
		"--team": func(v: String) -> void: _auto_team = int(v),
		"--class": func(v: String) -> void: _auto_class = _parse_element_name(v),
		"--name": func(v: String) -> void: _auto_name = v,
		# Test hook: request a rate WITHOUT persisting it, unlike the interactive
		# NetworkManager.set_cl_updaterate path, which writes settings.cfg.
		"--cl-updaterate": func(v: String) -> void: NetworkManager.cl_updaterate = float(v),
		"--rate": func(v: String) -> void: NetworkManager.cl_rate = int(v),  # same, for rate
		"--cl-cmdrate": func(v: String) -> void: NetworkManager.cl_cmdrate = float(v),  # and cl_cmdrate
		"--net-profile": func(v: String) -> void: NetworkManager.net_profile = v.strip_edges(),  # and the netsim profile
		"--sv-updaterate": func(v: String) -> void: _sv_updaterate = float(v),  # applied in _ready
		# On from the first frame, unlike the /interp_diag chat command — the entity you want
		# measured is usually spawned and gone before you can type.
		"--interp-diag": func() -> void:
			NetworkManager.interp_diag = InterpDiag.new()
			Log.info("[InterpDiag] on"),
		# Own-view smoothness and reconcile stats every 5 s (see ViewDiag); for comparing builds.
		"--view-diag": func() -> void:
			NetworkManager.view_diag = ViewDiag.new()
			Log.info("[ViewDiag] on"),
		"--bots": func(v: String) -> void: _auto_bots = int(v),
		# Same reason the limits are flags: a dedicated server has no console to type /botskill
		# into, and the skill has to be set before --bots spawns anyone.
		"--botskill": func(v: String) -> void: _limit_args["bot_skill"] = v.strip_edges(),
		# A dedicated server has no console, so the rotation and its limits are flags here.
		"--mapcycle": func(v: String) -> void: MatchSystem.cycle_path = v,
		"--timelimit": func(v: String) -> void: _limit_args["timelimit"] = v.strip_edges(),
		"--scorelimit": func(v: String) -> void: _limit_args["scorelimit"] = v.strip_edges(),
		"--fraglimit": func(v: String) -> void: _limit_args["fraglimit"] = v.strip_edges(),
		"--http-downloads-dir": func(v: String) -> void: MapTransfer.http_downloads_dir = v,
		"--http-base-url": func(v: String) -> void:
			MapTransfer.http_base_url_override = v
			Log.info("HTTP base URL override: %s" % v),
		"--admin-password": func(v: String) -> void: _admin_password = v,
		# Set by our own relaunch. Its only job is to stop a second one: if the requested renderer
		# fails to initialise Godot silently falls back, the preference would never match what is
		# running, and we would relaunch forever.
		"--renderer-applied": func() -> void: _renderer_applied = true,
		"--goldnet": func() -> void: _use_goldnet = true,  # the default; kept for explicitness/scripts
		"--stock": func() -> void: _use_goldnet = false,  # stock SceneMultiplayer, if goldnet regresses
	}


## Walks `args` against a flag table, calling each handler as it is matched, and returns one
## message per malformed token — empty when the line was clean. Static and diagnostic-returning so
## the walk is testable without a Main in a tree and without writing to the error log.
##
## A flag's value is taken verbatim, including one that itself starts with "--": `--map --bots`
## names a map "--bots". Guessing otherwise would mean a value can never look like a flag, and
## --name and --admin-password can legitimately be anything.
static func apply_flags(args: PackedStringArray, handlers: Dictionary) -> PackedStringArray:
	var problems := PackedStringArray()
	var i := 0
	while i < args.size():
		var flag := args[i]
		i += 1
		if not handlers.has(flag):
			problems.append("Unknown command-line flag '%s' — ignored." % flag)
			continue
		var handler: Callable = handlers[flag]
		if handler.get_argument_count() == 0:
			handler.call()
		elif i >= args.size():
			problems.append("%s expects a value — ignored." % flag)
		else:
			handler.call(args[i])
			i += 1
	return problems


## Applies the flag table to OS.get_cmdline_user_args(). Malformed input is reported and skipped
## rather than fatal: these args reach us through launcher scripts and the renderer relaunch, so
## refusing to boot over one bad token would be worse than coming up.
func _parse_cmdline_args() -> void:
	for problem in apply_flags(OS.get_cmdline_user_args(), _flag_handlers()):
		push_error(problem)
	if _admin_password.is_empty():
		_admin_password = OS.get_environment("WW_ADMIN_PASSWORD")
	CommandSystem.set_admin_password(_admin_password)
	if not _admin_password.is_empty():
		Log.info("Admin password configured (chat /auth enabled)")


## Replaces the SceneTree's default MultiplayerAPI with GoldNetMultiplayer before any map loads.
## GoldNet delegates handshake/@rpc to an inner SceneMultiplayer and replaces only state replication
## with GoldSrc-style unreliable ack-delta snapshots. Falls back to stock if the extension is missing.
##
## GoldnetTransport.install below is unguarded: goldnet's GDScript-facing API is fixed, so
## class_exists is the whole compatibility question and per-method probing only ever simulated a
## graceful path that does not exist (a mixed session is unserviceable either way — see
## NetworkManager.announce_transport). It runs BEFORE set_multiplayer, so a binary too old to
## answer one of its calls errors out with the tree still on stock, which is a self-consistent
## session that announce_transport can then refuse. NetworkManager.transport is committed last,
## after the install succeeds, so a failure part-way can never leave the game claiming goldnet.
##
## Spawner capture is NOT armed here any more: goldnet arms it itself on its first poll and when a
## peer is set, and wraps on the spot anything that beats both. It used to need a call right here,
## in the right order, or the host body and bots spawned during _ready silently never replicated.
##
## Push-based change detection is not switched on here either: a sync's "gn_push" meta is itself the
## opt-in, so goldnet polls every slot nobody declared and reads the declared ones only when
## mark_dirty announces them. A slot nobody promised for cannot go stale, which is why it needs no
## global enable and no audit mode.
func _install_goldnet() -> void:
	if not ClassDB.class_exists(&"GoldNetMultiplayer"):
		_goldnet_missing = true
		push_error("goldnet: extension not loaded (GoldNetMultiplayer missing) — staying on stock SceneMultiplayer")
		Log.warn("goldnet: libgoldnet is missing from the game folder — this client cannot join")
		return
	var mp: MultiplayerAPI = ClassDB.instantiate(&"GoldNetMultiplayer")
	var transport := GoldnetTransport.install(mp)
	get_tree().set_multiplayer(mp)
	NetworkManager.transport = transport
	Log.info("goldnet: installed GoldNetMultiplayer (GoldSrc ack-delta transport)")


func _parse_element_name(element_name: String) -> int:
	var id := GameConsts.element_from_name(element_name)
	if id > 0:
		return id
	var num := int(element_name)  # also accept a numeric element id
	if num > 0:
		return num
	return GameConsts.Element.FIRE


## The gameplay Environment, or null before a map has built one.
func _current_environment() -> Environment:
	return _world_env.environment if _world_env else null


func _ready() -> void:
	KeyBindings.ensure_applied()
	RenderingServer.set_debug_generate_wireframes(true)
	_renderer_trial = RendererTrialScript.new()
	_renderer_trial.name = "RendererTrial"
	add_child(_renderer_trial)
	_client_sync = ClientSyncScript.new()
	_client_sync.name = "ClientSync"
	_client_sync.bind(self)
	add_child(_client_sync)
	NetworkManager.register_sync_handler(_client_sync)
	# Before _parse_cmdline_args: --perf-log and /perf are the same feature reached two ways, and
	# the flag goes through the same setter, so the node has to exist by the time flags are read.
	_client_perf = ClientPerfScript.new()
	_client_perf.name = "ClientPerf"
	_client_perf.bind(self, _renderer_trial)
	add_child(_client_perf)
	_client_join = ClientJoinScript.new()
	_client_join.name = "ClientJoin"
	add_child(_client_join)
	_renderer_trial.log_active_renderer()
	_parse_cmdline_args()
	ClientCommandSystem.register("scale", _cmd_scale, "/scale [0.25-1.0]",
			"Render 3D at a fraction of window resolution. The A/B for a fill-rate-bound machine.")
	ClientCommandSystem.register("fx", _cmd_fx, "/fx [0|1]",
			"Stop beam and trail geometry rebuilding each frame. The A/B for per-frame buffer churn.")
	if _renderer_trial.apply_preference(_renderer_applied, _is_dedicated_server):
		return  # relaunching; this process is on its way out
	ServerVars.value_changed.connect(_on_server_var_changed)
	if not _bsp_hulls_arg.is_empty():
		var r: Dictionary = ServerVars.set_from_string("bsp_hulls", _bsp_hulls_arg)
		if not r["ok"]:
			push_error("--bsp-hulls expects on|off, got '%s'" % _bsp_hulls_arg)
	for limit_key in _limit_args:
		var lr: Dictionary = ServerVars.set_from_string(limit_key, _limit_args[limit_key])
		if not lr["ok"]:
			push_error("--%s expects a number, got '%s'" % [limit_key, _limit_args[limit_key]])
	_apply_bsp_hulls()
	if _use_goldnet:
		_install_goldnet()
	# Must run after the transport installs (apply_sv_updaterate pushes into goldnet) but before
	# hosting, so the first synchronizer registers at the right rate. Always, so goldnet knows the
	# rate it grants clients under.
	NetworkManager.apply_sv_updaterate(_sv_updaterate if _sv_updaterate > 0.0 else NetworkManager.NET_TICKRATE)
	_map_converter = Node.new()
	_map_converter.set_script(MapConverter)
	_map_converter.name = "MapConverter"
	add_child(_map_converter)

	_resource_converter = Node.new()
	_resource_converter.set_script(ResourceConverter)
	_resource_converter.name = "ResourceConverter"
	add_child(_resource_converter)

	_blender_map_converter = Node.new()
	_blender_map_converter.set_script(BlenderMapConverterScript)
	_blender_map_converter.name = "BlenderMapConverter"
	add_child(_blender_map_converter)

	NetworkManager.disconnected.connect(_on_disconnected)
	NetworkManager.peer_connected.connect(_on_peer_connected)
	NetworkManager.peer_disconnected.connect(_on_peer_disconnected)

	_setup_player_spawner()

	if _bake_waypoints:
		var bake := WaypointBake.new()
		bake.name = "WaypointBake"
		add_child(bake)
		bake.run(self)
		return

	if _is_dedicated_server:
		_start_dedicated_server()
		return

	_xr_rig = get_node("XRRig")
	_xr_rig_camera = _xr_rig.get_node_or_null("XRCamera3D") as Camera3D
	_xr_right_controller = get_node_or_null("XRRig/RightController")
	_xr_left_controller = get_node_or_null("XRRig/LeftController")
	_head_probe_shape.radius = 0.12
	if XRManager.is_vr:
		_xr_rig.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF

	# The stored picture-quality level has to be in force before the lobby can offer to change it,
	# and before precache_resources warms shaders against the main viewport's framebuffer format.
	RenderQuality.apply(RenderQuality.load_level(), get_viewport())

	_lobby = LobbyUI.new()
	_lobby.name = "LobbyUI"

	Log.info("XRManager.is_vr = %s" % XRManager.is_vr)
	if XRManager.is_vr:
		_vr_lobby_panel = VRLobbyPanel.new()
		_vr_lobby_panel.name = "VRLobbyPanel"
		if _xr_rig_camera:
			_xr_rig_camera.add_child(_vr_lobby_panel)
			_vr_lobby_panel.position = Vector3(0.0, 0.0, -2.0)
		else:
			add_child(_vr_lobby_panel)
		_vr_lobby_panel.add_ui(_lobby)

		for ctrl in [_xr_right_controller, _xr_left_controller]:
			if ctrl == null:
				continue
			var laser := MeshInstance3D.new()
			laser.name = "LaserPointer"
			var laser_mesh := BoxMesh.new()
			laser_mesh.size = Vector3(0.003, 0.003, 4.0)
			laser.mesh = laser_mesh
			var laser_mat := StandardMaterial3D.new()
			laser_mat.albedo_color = Color(1.0, 0.2, 0.2, 0.6)
			laser_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			laser_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			laser.material_override = laser_mat
			laser.position = Vector3(0.0, 0.0, -2.0)
			ctrl.add_child(laser)
	else:
		add_child(_lobby)

	_lobby.host_pressed.connect(_on_lobby_host)
	_lobby.join_pressed.connect(_on_lobby_join)
	_lobby.renderer_restart_requested.connect(_on_lobby_renderer_restart)
	_lobby.quality_changed.connect(func(level: String) -> void:
		RenderQuality.apply(level, get_viewport(), _current_environment())
		WorldMaterials.apply(_map_root, RenderQuality.detail_enabled(level))
		WaterSurfaces.apply(_map_root, RenderQuality.water_depth_enabled(level))
		if _skybox:
			_skybox.apply_enhanced(RenderQuality.sky_enhanced(level)))
	MapTransfer.map_already_cached.connect(_on_map_ready)
	MapTransfer.map_transfer_complete.connect(_on_map_ready)
	MapTransfer.map_transfer_failed.connect(_on_map_transfer_failed)
	MapTransfer.resources_ready.connect(_on_resources_ready)
	MapTransfer.resources_transfer_progress.connect(_on_resources_transfer_progress)
	NetworkManager.map_change_requested.connect(_on_map_change_requested)
	_lobby.show_menu()
	_renderer_trial.clear_trial()
	if not _renderer_trial.reset_note.is_empty():
		_lobby.set_status(_renderer_trial.reset_note)
	if not _auto_connect_ip.is_empty():
		_on_lobby_join(_auto_connect_ip, "")
	elif _is_listen_host:
		if _current_map_name.is_empty():
			push_error("--host requires --map <name>")
		else:
			_on_lobby_host(_current_map_name)


func _on_server_var_changed(key: String, _value: Variant) -> void:
	if key == "bsp_hulls":
		_apply_bsp_hulls()


## Runs on host and client alike, because movement prediction has to run against the same geometry
## on both ends. Only hop can trace a BSP hull; under default Godot physics the flag is inert.
func _apply_bsp_hulls() -> void:
	var server: Object = Engine.get_singleton(&"PhysicsServer3D")
	if server == null or not server.has_method("set_bsp_hulls_enabled"):
		return
	server.call("set_bsp_hulls_enabled", bool(ServerVars.get_value("bsp_hulls", true)))


## The flag says what was asked for; this says what is in effect.
func bsp_hulls_active() -> bool:
	var server: Object = Engine.get_singleton(&"PhysicsServer3D")
	if server == null or not server.has_method("get_bsp_hulls_enabled"):
		return false
	return bool(server.call("get_bsp_hulls_enabled"))


func _start_dedicated_server() -> void:
	Log.enable_file_logging()
	Log.info("[Server] Starting dedicated server for map: %s" % _current_map_name)
	NetworkManager.map_change_server_request.connect(change_map)
	if not prepare_host_map(_current_map_name):
		push_error("[Server] Failed to prepare map: %s" % _current_map_name)
		get_tree().quit(1)
		return
	load_map_headless(_current_map_name)
	var err := NetworkManager.host()
	if err != OK:
		push_error("[Server] Failed to host: %s" % error_string(err))
		get_tree().quit(1)
		return
	# Prepare map metadata for transfer to clients.
	var map_hash: String = _map_converter.get_map_hash(_current_map_name)
	MapTransfer.set_host_map(_current_map_name, map_hash)
	MapTransfer.load_resource_manifest()
	ServerBrowser.start_beacon(_current_map_name, map_hash)
	_set_game_active(true)
	for _b in _auto_bots:
		BotSystem.add_bot()
	if _auto_bots > 0:
		Log.info("[Server] Spawned %d startup bot(s)" % _auto_bots)
	MatchSystem.begin_map(_current_map_name)
	Log.info("[Server] Dedicated server ready, waiting for clients...")


## Both BSP and Blender produce .scn output, but via different converters.
func _is_blender_map(map_name: String) -> bool:
	return FileAccess.file_exists(ProjectSettings.globalize_path("res://maps/%s.glb" % map_name))


## Ensures a usable .scn (+ .hash) exists at user://resources/maps/<name>. Returns false if there's
## no source to convert and no cached .scn either. Public because the offline bake drives map boot
## from outside (src/bot/waypoint_bake.gd).
func prepare_host_map(map_name: String) -> bool:
	# Each sub-converter self-gates on its plugin (MDL/SPR/WAD), so this is safe when only some
	# assets are available.
	_resource_converter.convert_all()

	if _is_blender_map(map_name):
		if _blender_map_converter.convert(map_name):
			return true
	elif ClassDB.class_exists(&"GoldSrcBSP"):
		if _map_converter.convert(map_name):
			return true

	# No usable source on this peer: fall back to any .scn already on disk, typically downloaded
	# from another host. This is how a client-joined peer gets to re-host the map later.
	var scn_path := "user://resources/maps/%s.scn" % map_name
	var hash_path := "user://resources/maps/%s.hash" % map_name
	return FileAccess.file_exists(scn_path) and FileAccess.file_exists(hash_path)


## Everything is .scn — Blender .glb is pre-converted on the host, so the runtime loader only ever
## deals with one format.
const _MAP_SEARCH_PATHS := [
	"user://resources/maps/%s.scn",  # converted on this peer OR downloaded from another
	"exported/%s.scn",               # legacy exported scene
]


func _load_map_root(map_name: String) -> Node3D:
	for tpl in _MAP_SEARCH_PATHS:
		var path: String = tpl % map_name
		var in_resources := path.begins_with("res://")
		var exists := ResourceLoader.exists(path) if in_resources else FileAccess.file_exists(path)
		if not exists:
			continue
		var root := _load_map_scene(path)
		if root != null:
			return root
	return null


## Shared post-load setup: entity spawning, sync body collection.
func _register_worldspawn_pvs_groups(map_root: Node3D) -> void:
	var ws := map_root.get_node_or_null("worldspawn") as Node3D
	if ws == null:
		return
	var count := 0
	for child in ws.get_children():
		if child is Node3D and child.has_meta("pvs_leaves"):
			VisibilitySystem.track_node_by_leaves(
				child.get_instance_id(), child as Node3D,
				child.get_meta("pvs_leaves") as PackedInt32Array)
			count += 1
	if count > 0:
		Log.info("[Visibility] Tracking %d worldspawn spatial groups for PVS culling" % count)


func _setup_map_common(map_root: Node3D) -> void:
	# Tell multi_manager about TFC entity keys so it doesn't treat them as targets
	MultiManager.extra_reserved_keys = PackedStringArray([
		"goal_no", "goal_group", "goal_state", "items_allowed",
		"maxammo_shells", "maxammo_nails", "maxammo_rockets", "maxammo_cells",
	])
	EntityRender.apply_color_space(map_root)
	EntityRegistry.apply_scripts(map_root)
	add_child(map_root)  # entity _ready runs here, info_wwdetect included
	if GoalSystem.is_combo_chaos():
		Log.info("Combo chaos ON: this map's weapon/ammo pickups are combo spellbooks")
	_map_root = map_root
	_init_spawn_groups()


## Server-side map load with no rendering or local player. Public for the same reason as
## prepare_host_map: the offline bake boots a map the same way a dedicated server does.
func load_map_headless(map_name: String) -> void:
	var map_root := _load_map_root(map_name)
	if map_root == null:
		push_error("[Server] Failed to load map: %s" % map_name)
		get_tree().quit(1)
		return

	VisibilitySystem.setup(map_root)
	_setup_map_common(map_root)

	# DecalSystem must exist on the server so Godot can route place_rpc to clients.
	# It won't render anything headless — place() exits early when textures fail to load.
	_decal_system = DecalSystem.new()
	_decal_system.name = "DecalSystem"
	_decal_system.setup()
	add_child(_decal_system)

	AssetLoader.precache_resources(self)

	weather_system = WeatherSystem.new()
	weather_system.name = "WeatherSystem"
	weather_system.setup()
	add_child(weather_system)

	Log.info("[Server] Map loaded: %d spawn points" % SpawnSystem.get_all_spawns().size())


## Baked into the loaded .scn's metadata by MapConverter (was maps/<map>.txt, read off disk).
## Bundled maps ship one; downloaded custom maps may not, so callers must tolerate "".
func _read_map_info() -> String:
	return _map_root.get_meta("map_description", "") if _map_root else ""


## Baked into the .scn's metadata (was maps/<map>.ww). Format: world name (names
## maps/worlds/<name>.tga), then the marker's X and Y in per-mille (0-1000) of the image.
func _read_map_world() -> String:
	return _map_root.get_meta("map_world_info", "") if _map_root else ""


## Returns {} if the text is malformed or the named world image isn't bundled.
static func _parse_map_world(text: String) -> Dictionary:
	var lines: Array[String] = []
	for line in text.split("\n"):
		var s: String = line.strip_edges()
		if not s.is_empty():
			lines.append(s)
	if lines.size() < 3 or not lines[1].is_valid_int() or not lines[2].is_valid_int():
		return {}
	var tex_path := "res://maps/worlds/%s.tga" % lines[0]
	if not ResourceLoader.exists(tex_path):
		return {}
	return {
		"texture": load(tex_path),
		"marker": Vector2(lines[1].to_int() / 1000.0, lines[2].to_int() / 1000.0),
	}


## Returns false when the map has neither sheet.
func _show_map_info_panel() -> bool:
	var world := _parse_map_world(_current_map_world)
	if _current_map_info.is_empty() and world.is_empty():
		return false
	hud.show_map_info(_current_map_name, _current_map_info,
		world.get("texture"), world.get("marker", Vector2(-1, -1)))
	return true


## /intro — re-read the controls card. Deliberately doesn't touch the "seen it" tick: asking
## for it is not the same as wanting it back at every map start.
func show_intro() -> void:
	if hud == null:
		return
	hud.show_intro(IntroGuide.body(XRManager.is_vr))


func show_motd() -> void:
	if hud == null:
		return
	if not _show_map_info_panel():
		hud.show_center_message("No description for %s" % _current_map_name)


func _load_map(map_name: String) -> void:
	var map_root := _load_map_root(map_name)
	if map_root == null:
		push_warning("Failed to load map: %s (no cache, export, or BSP plugin)" % map_name)
		return

	# Initialize light grid before spawning entities so item models get lit
	_light_grid = LightGrid.from_meta(map_root)
	if _light_grid.is_valid():
		Log.info("Light grid loaded from map metadata")
		AssetLoader.light_grid = _light_grid

	VisibilitySystem.setup(map_root)
	_setup_map_common(map_root)
	_register_worldspawn_pvs_groups(map_root)

	_decal_system = DecalSystem.new()
	_decal_system.name = "DecalSystem"
	_decal_system.setup()
	add_child(_decal_system)

	# Built here and not with the local player below for the same reason as DecalSystem: its
	# set_weather is an @rpc, so the node must exist at a matching path on every peer. The
	# follow target is attached once the player exists (and never, on a dedicated server).
	weather_system = WeatherSystem.new()
	weather_system.name = "WeatherSystem"
	weather_system.setup()
	add_child(weather_system)

	# Set up skybox from worldspawn skyname property
	var sky_name := ""
	var worldspawn := map_root.get_node_or_null("worldspawn")
	if worldspawn and worldspawn.has_meta("entity"):
		sky_name = worldspawn.get_meta("entity").get("skyname", "")
	_skybox = Skybox.new()
	_skybox.name = "Skybox"
	add_child(_skybox)
	# Read straight off the map rather than waiting for LightEnvironment._ready: entity _ready
	# order follows the BSP lump order, and the sky is built here, before any of them run.
	_skybox.setup(sky_name, map_root, _find_entity(map_root, "light_environment"))
	_world_env = _skybox.get_node_or_null("WorldEnvironment") as WorldEnvironment
	# Skybox builds a fresh Environment per map, so the quality level has to be stamped onto this
	# one — before precache_resources below reuses the resource to warm the model shaders.
	RenderQuality.apply(RenderQuality.load_level(), get_viewport(), _current_environment())
	# Detail needs the map itself, and the map's own sky/water surfaces are flagged by now.
	var detailed := WorldMaterials.apply(map_root, RenderQuality.detail_enabled())
	if detailed > 0:
		Log.info("Surface detail applied to %d world surfaces" % detailed)
	var watered := WaterSurfaces.apply(map_root, RenderQuality.water_depth_enabled())
	if watered > 0:
		Log.info("Water depth effects %s on %d liquid surfaces" % [
				"on" if RenderQuality.water_depth_enabled() else "off", watered])
	_sky_surfaces.clear()
	_collect_sky_surfaces(map_root)
	apply_vr_passthrough(XRManager.vr_passthrough)

	# Precache weapon models, sounds, sprites so first shot has no hitch
	AssetLoader.precache_resources(self)

	# Spawn player at first non-team spawn point (info_player_start)
	var all_spawns := SpawnSystem.get_all_spawns()
	Log.info("Spawn points found: %d" % all_spawns.size())
	if all_spawns.size() > 0:
		_local_player = LocalPlayerScene.instantiate()
		# ENet is brought up before the map loads, so get_unique_id() is the real id here
		# (offline it's 1). Consumers read peer_id directly, no fallback needed downstream.
		_local_player.peer_id = multiplayer.get_unique_id()
		var sp := all_spawns[0]
		for candidate in all_spawns:
			if candidate.team_no == 0:
				sp = candidate
				break
		_local_player.position = sp.get_spawn_position()
		_local_player.rotation.y = sp.rotation.y
		if XRManager.is_vr and _xr_rig:
			_local_player.xr_camera = _xr_rig_camera
			_local_player.xr_rig = _xr_rig
			_local_player.xr_left = _xr_left_controller
			_local_player.xr_right = _xr_right_controller
		add_child(_local_player)
		# Offline the LocalPlayer IS the server-side player, so register it for get_player()
		# lookups. Online the cache entry is the body puppet instead (_register_host_player after
		# _load_map), and is_online() correctly skips this.
		if not NetworkManager.is_online():
			NetworkManager.register_player(_local_player.peer_id, _local_player)
		_local_player.set_spectating(true)
		if XRManager.is_vr:
			_local_player.vr_menu_requested.connect(_on_vr_menu_requested)
		Log.info("Player spawned at: %s, yaw: %s" % [_local_player.position, _local_player.rotation.y])

		weather_system.attach_player(_local_player)

		hud = HUD.create()
		add_child(hud)
		_local_player._hud = hud
		hud.chat_submitted.connect(_local_player._on_chat_submitted)

		# Baked into the .scn's metadata, so this works the same whether the map was converted
		# locally or downloaded — no separate host->client transfer needed.
		_current_map_info = _read_map_info()
		_current_map_world = _read_map_world()
		# A player who has never been here gets the controls card first, with the map
		# description queued behind it. Showing it is what clears the tick, so it costs one
		# reading and then never appears again unless the lobby (or /intro) asks for it.
		if IntroGuide.should_show():
			IntroGuide.set_show(false)
			hud.show_intro(IntroGuide.body(XRManager.is_vr), _show_map_info_panel)
		else:
			_show_map_info_panel()
		if XRManager.is_vr and _xr_rig_camera:
			_vr_hud_panel = VRHUDPanel.new()
			_vr_hud_panel.name = "VRHUDPanel"
			_xr_rig_camera.add_child(_vr_hud_panel)
			_vr_hud_panel.position = Vector3(0.0, -0.1, -1.2)
			hud.move_to_vr_panel(_vr_hud_panel.viewport)

		_team_select_ui = CanvasLayer.new()
		_team_select_ui.set_script(TeamSelectUI)
		_team_select_ui.name = "TeamSelectUI"
		if XRManager.is_vr and _vr_lobby_panel:
			_vr_lobby_panel.add_ui(_team_select_ui)
		else:
			add_child(_team_select_ui)
		_client_join.bind_menu(_team_select_ui)



## The map .scn stays cached, so its meshes outlive the nodes that drew them, but a per-instance
## override material dies with its node — leaving RenderingServer reading a freed RID ("material is null").
func _release_override_materials(node: Node) -> void:
	if node is GeometryInstance3D:
		(node as GeometryInstance3D).material_override = null
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		for i in mi.get_surface_override_material_count():
			mi.set_surface_override_material(i, null)
	for child in node.get_children():
		_release_override_materials(child)


func _unload_map() -> void:
	if _local_player and _local_player.has_method("free_debug_render"):
		_local_player.free_debug_render()
	# Free explicitly — in VR it lives in the SubViewport, not as a direct child.
	if _team_select_ui:
		_team_select_ui.queue_free()
		_team_select_ui = null
	# Parented to the persistent XR rig camera, so the children loop below won't catch it — without
	# this, each map reload stacks another ghost HUD on the camera.
	if _vr_hud_panel:
		_vr_hud_panel.queue_free()
		_vr_hud_panel = null
	# Everything here is init-time infrastructure: built once and never recreated, so freeing it
	# leaves main.gd holding a freed instance for the rest of the session. The spawners dangle on
	# the next spawn(); ClientSync also drops its NetworkManager registration (tree_exiting),
	# killing sync dispatch for good. ClientPerf deliberately outlives a map change, overlay and all.
	var keep := [_lobby, _map_converter, _resource_converter, _blender_map_converter, _xr_rig,
			_player_spawner, _dyn_spawner, _client_sync, _renderer_trial, _client_perf,
			_client_join]
	for child in get_children():
		if child in keep:
			continue
		_release_override_materials(child)
		child.queue_free()
	_map_root = null
	Game.clear_world()
	_sky_surfaces.clear()
	_light_grid = null
	_world_env = null
	_skybox = null
	AssetLoader.light_grid = null
	LightGrid._all_acube_materials.clear()
	NetworkManager.clear_players()
	NetworkManager.reset_entities()
	VisibilitySystem.teardown()
	_local_map_ready = false
	_local_resources_ready = false
	_local_pending_map_name = ""
	_client_join.clear_watchdog()  # the new map re-asks from scratch; don't resend the old map's pick
	GoalSystem.reset()
	SpawnSystem.reset()
	TriggerSystem.reset()
	StatusSystem.reset()
	BotSystem.reset()
	SiegeSystem.reset()
	MonsterNav.reset()
	MatchSystem.reset()
	PotatoC.global_vars.clear()


## Listen server: bring up ENet + load the map in this same process, with full client setup. The
## host is peer 1 and also a player — no separate dedicated process, no loopback UDP round-trip for
## the host's own input. GoldSrc-style.
func _on_lobby_host(map_name: String) -> void:
	_current_map_name = map_name

	if not prepare_host_map(map_name):
		_set_status("Conversion failed!")
		_lobby._set_controls_disabled(false)
		return

	if _is_port_in_use(NetworkManager.PORT):  # orphan from a prior session
		Log.info("Port %d in use — killing old server" % NetworkManager.PORT)
		_set_status("Killing old server...")
		_kill_process_on_port(NetworkManager.PORT)
		await get_tree().create_timer(1.0).timeout

	if not _auto_name.is_empty():
		_local_player_name = _auto_name
	elif _lobby:
		_local_player_name = _lobby.get_player_name()

	_set_status("Starting host...")

	# Map-change requests now route to ourselves (we're the server).
	if not NetworkManager.map_change_server_request.is_connected(change_map):
		NetworkManager.map_change_server_request.connect(change_map)

	# Bring up ENet first so multiplayer.get_unique_id() returns the real host
	# id (1) before we register _local_player in the player cache.
	var err := NetworkManager.host()
	if err != OK:
		push_warning("Failed to host: %s" % error_string(err))
		_set_status("Failed to start host!")
		_lobby._set_controls_disabled(false)
		return

	# Load the map with full client setup (spawns _local_player, HUD, team-select UI).
	_load_map(map_name)

	var host_id := multiplayer.get_unique_id()
	if _local_player:
		_register_host_player()
	CommandSystem.grant_admin(host_id)  # listen-server host runs admin commands without /auth

	var map_hash: String = _map_converter.get_map_hash(map_name)
	MapTransfer.set_host_map(map_name, map_hash)
	MapTransfer.load_resource_manifest()
	ServerBrowser.start_beacon(map_name, map_hash)

	_set_game_active(true)
	MatchSystem.begin_map(map_name)
	Log.info("[ListenServer] Hosting %s as peer %d" % [map_name, host_id])


func _on_lobby_join(ip: String, _map_name: String) -> void:
	if not _auto_name.is_empty():
		_local_player_name = _auto_name
	elif _lobby:
		_local_player_name = _lobby.get_player_name()
	# Opened now, not after map+resources finish — that's too late if the join itself stalls.
	Log.enable_file_logging("client.log")
	_renderer_trial.log_active_renderer()
	if _goldnet_missing:
		# The connection itself would succeed — @rpc rides the inner SceneMultiplayer — and the
		# world would draw. Nothing else would: goldnet owns every spawn and synchronizer, so a
		# stock client is handed no entities at all. Say so here rather than in an empty map.
		if _lobby:
			# show_menu() resets the status label and re-enables the controls, so it goes first.
			_lobby.show_menu()
			_lobby.show_error_popup("Cannot Join",
					"This client is missing the goldnet network library, so it cannot receive "
					+ "players or objects from a server.\n\nRe-download the client — the game "
					+ "folder is incomplete.")
		_set_status("Client install incomplete\nRe-download the game")
		return
	if _lobby:
		_lobby._set_controls_disabled(true)  # the Join button path does this itself; --connect doesn't
	var err := NetworkManager.join(ip)  # map loads later, once map_info arrives from host
	if err == ERR_ALREADY_IN_USE:
		return  # already joining or joined: this second request is moot
	if err != OK:
		push_warning("Failed to join: %s" % error_string(err))
		if _lobby:
			_lobby.show_menu()
			_lobby._set_controls_disabled(false)
		_set_status("Connection failed\nCheck WiFi and try again")
		return
	_set_status("Connecting to %s..." % ip)


## /connect — leave whatever is running and join `ip`. Deliberately the lobby's own join path, so a
## server that refuses or never answers lands the player back in the menu with its error rather
## than in a dead map. Hosting is no special case: the listen server goes down and its players are
## dropped, same as closing the game on them.
## Deferred because _unload_map() frees the old map with queue_free — including the HUD whose chat
## line is still on the stack here. The frees are already queued, so the join runs behind them.
func connect_to_server(ip: String) -> void:
	if NetworkManager.is_online():
		NetworkManager.disconnect_from_game()
	call_deferred("_on_lobby_join", ip, "")


func _set_game_active(active: bool) -> void:
	_game_active = active
	if _is_dedicated_server:
		return  # headless: no client UI to update
	if active:
		if _lobby:
			_lobby.hide_menu()
		_set_status("")
		# The role to come back on: only --team/--class, which is a scripted launch that must not
		# stop at a menu. Everyone else picks again on every map, rotation included. Deferred — on
		# a listen host the map change registers the host puppet after this call, and the join
		# request needs that puppet.
		var join_team := _auto_team
		var join_class := _auto_class
		var joining: bool = join_team > 0 and _local_player and _local_player.spectating
		if joining:
			_client_join.call_deferred("select_team_class", join_team,
				join_class if join_class > 0 else GameConsts.Element.FIRE)
		if _auto_bots > 0 and NetworkManager.is_host():  # dedicated spawns its own in _start_dedicated_server
			for _b in _auto_bots:
				BotSystem.add_bot()
			_auto_bots = 0  # once per session, not per map change
		if not joining and _team_select_ui and _local_player and _local_player.spectating:
			_team_select_ui.show_ui()
		else:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		if _lobby:
			_lobby.show_menu()
		if _vr_lobby_panel and _xr_rig_camera and _vr_lobby_panel.get_parent() != _xr_rig_camera:
			_vr_lobby_panel.reparent(_xr_rig_camera, false)
			_vr_lobby_panel.position = Vector3(0.0, 0.0, -2.0)
			_vr_lobby_panel.rotation = Vector3.ZERO


## The server refused a team (full, no active spawn, class restricted).
func _on_reject_team_join(team: int, reason: String) -> void:
	_client_join.abandon("%s %s" % [GoalSystem.get_team_name(team), reason])


func _on_disconnected(reason: String) -> void:
	_clear_carry_state()  # the bots we were carrying belonged to the server we just left
	_set_game_active(false)
	_unload_map()
	if not reason.is_empty():
		if _lobby:
			_lobby.show_disconnect_popup(reason)


## Works on macOS/Linux.
func _kill_process_on_port(port: int) -> void:
	var output: Array = []
	OS.execute("lsof", ["-t", "-i", "UDP:%d" % port], output)
	var pids := (output[0] as String).strip_edges()
	if pids.is_empty():
		return
	for pid_str in pids.split("\n"):
		var pid := int(pid_str.strip_edges())
		if pid > 0:
			Log.info("Killing orphaned server process PID %d on port %d" % [pid, port])
			OS.kill(pid)


## Binds a UDP socket, not TCP: ENet uses UDP, so a TCP probe would never detect a running server.
func _is_port_in_use(port: int) -> bool:
	var udp := PacketPeerUDP.new()
	var err := udp.bind(port, "127.0.0.1")
	if err != OK:
		return true  # port is in use
	udp.close()
	return false


func _set_status(text: String) -> void:
	if _lobby:
		_lobby.set_status(text)


func _on_map_ready(map_name: String) -> void:
	_local_pending_map_name = map_name
	_local_map_ready = true
	_set_status("Map ready, waiting for resources...")
	_try_activate_local_player()


func _on_map_transfer_failed() -> void:
	if not NetworkManager.is_online():
		return
	NetworkManager._disconnect_reason = "Failed to download map from server."
	NetworkManager.disconnect_from_game()


func _on_resources_ready() -> void:
	Log.info("Resources ready (transferred or cached)")
	_local_resources_ready = true
	_try_activate_local_player()


func _on_resources_transfer_progress(current: int, total: int) -> void:
	if total > 0:
		_set_status("Downloading resources... %d/%d" % [current, total])


## What survives a map change: the bots, read off BotSystem before _unload_map discards them and
## handed back by change_map once the new map is up. The local player's role is not among them —
## the new map re-opens the team/class menu.
func _capture_carry_state() -> void:
	_clear_carry_state()
	if NetworkManager.is_authority():
		_carry_bots = BotSystem.roster_snapshot()


## Rebinds rather than clears: _restore_carried_bots hands the old array out before emptying this.
func _clear_carry_state() -> void:
	_carry_bots = []


## Hand the bots back to BotSystem once the new map is active — add_bot needs a live game and a
## spawn point to place them on, so this can't happen any earlier in the change.
func _restore_carried_bots() -> void:
	if _carry_bots.is_empty():
		return
	var wanted := _carry_bots
	_carry_bots = []
	Log.info("[Server] Restored %d/%d bot(s) after the map change" % [
		BotSystem.restore_roster(wanted), wanted.size()])


## Tear down the current map and wait for the follow-up MapTransfer map info / manifest
## that re-triggers the normal download + _try_activate_local_player flow.
func _on_map_change_requested(new_map_name: String) -> void:
	Log.info("Map change requested by server: %s" % new_map_name)
	_capture_carry_state()
	_set_game_active(false)
	_unload_map()
	if _lobby:
		_lobby._set_controls_disabled(true)
	_set_status("Switching to %s..." % new_map_name)


## Hot-swap to a new map while keeping all clients connected.
func change_map(new_map_name: String) -> void:
	Log.info("[Server] Changing map to: %s" % new_map_name)
	_capture_carry_state()
	_set_game_active(false)
	CommandSystem.clear_noclip()

	if not prepare_host_map(new_map_name):
		push_error("[Server] Failed to prepare map for change: %s" % new_map_name)
		_set_game_active(true)
		# A rotation change gets here with its intermission already expired, so without this the
		# match sits in an intermission nothing can end: no damage, no scoring, no clock.
		MatchSystem.begin_map(_current_map_name)
		return

	# Reliable RPC — await a frame to let it flush before destroying server-side entities.
	NetworkManager.sync_map_change.rpc(new_map_name)
	await get_tree().process_frame

	_unload_map()
	await get_tree().process_frame  # let queue_free settle before loading new scene

	# Dedicated server stays headless; listen-server host reloads with full client setup.
	if _is_dedicated_server:
		load_map_headless(new_map_name)
	else:
		_load_map(new_map_name)
	_current_map_name = new_map_name

	var map_hash: String = _map_converter.get_map_hash(new_map_name)
	MapTransfer.set_host_map(new_map_name, map_hash)
	MapTransfer.load_resource_manifest()
	ServerBrowser.start_beacon(new_map_name, map_hash)

	_set_game_active(true)
	_spawn_missed_players()
	# Listen-server: re-register our own body puppet (the previous registration was wiped by
	# _unload_map -> clear_players). Offline there is no puppet — _load_map already re-registered
	# the LocalPlayer itself.
	if NetworkManager.is_online() and not _is_dedicated_server and _local_player:
		_local_player.peer_id = multiplayer.get_unique_id()
		_register_host_player()

	_restore_carried_bots()
	MatchSystem.begin_map(new_map_name)

	# Re-uses the same map-info / manifest path as initial join.
	MapTransfer.notify_map_change()
	Log.info("[Server] Map changed to: %s, notified %d client(s)" % [
		new_map_name, multiplayer.get_peers().size()])


## Activate the client only when both map and resources are ready.
func _try_activate_local_player() -> void:
	if not _local_map_ready or not _local_resources_ready:
		return
	_local_map_ready = false
	_local_resources_ready = false
	_current_map_name = _local_pending_map_name
	# Wait a frame so the UI actually redraws before the synchronous _load_map blocks the main thread.
	_set_status("Loading %s..." % _local_pending_map_name)
	await get_tree().process_frame
	_load_map(_local_pending_map_name)
	_set_game_active(true)
	_spawn_missed_players()
	NetworkManager._request_entity_state.rpc_id(1)
	NetworkManager.set_player_name(multiplayer.get_unique_id(), _local_player_name)
	NetworkManager.send_request_player_name(_local_player_name)
	NetworkManager.send_request_player_states()


func _unhandled_input(event: InputEvent) -> void:
	if not _game_active:
		return
	if event.is_action_pressed("team_menu") and _team_select_ui:
		_team_select_ui.show_ui()
		if XRManager.is_vr:
			_attach_vr_panel_to_camera()
	elif event.is_action_pressed("class_menu") and _team_select_ui and _local_player \
			and _local_player.team != GameConsts.Team.NONE:
		_team_select_ui.show_class_only(_local_player.team)
		if XRManager.is_vr:
			_attach_vr_panel_to_camera()


func _attach_vr_panel_to_camera() -> void:
	if _vr_lobby_panel == null or _xr_rig_camera == null:
		return
	if _vr_lobby_panel.get_parent() != _xr_rig_camera:
		_vr_lobby_panel.reparent(_xr_rig_camera, false)
	_vr_lobby_panel.position = Vector3(0.0, 0.0, -2.0)
	_vr_lobby_panel.rotation = Vector3.ZERO


func _on_vr_menu_requested(class_only: bool) -> void:
	if not _team_select_ui or not _vr_lobby_panel:
		return
	if class_only and _local_player and _local_player.team != GameConsts.Team.NONE:
		_team_select_ui.show_class_only(_local_player.team)
	else:
		_team_select_ui.show_ui()
	_attach_vr_panel_to_camera()


## First entity of `classname` in the map's entity list, as its raw key/value dict. Maps carry
## duplicates of the map-wide ones (ww_feudal and ww_golem ship three light_environments each,
## left over from compile tools), and GoldSrc uses the first, so this stops at the first too.
func _find_entity(map_root: Node, classname: String) -> Dictionary:
	for child in map_root.get_children():
		if not child.has_meta("entity"):
			continue
		var ent: Dictionary = child.get_meta("entity")
		if ent.get("classname", "") == classname:
			return ent
	return {}


func _collect_sky_surfaces(node: Node) -> void:
	if node is MeshInstance3D and node.has_meta("is_sky_surface"):
		_sky_surfaces.append(node as MeshInstance3D)
	for child in node.get_children():
		_collect_sky_surfaces(child)


func apply_vr_passthrough(enabled: bool) -> void:
	if not XRManager.is_vr:
		return
	# xr/openxr/extensions/meta/passthrough registers XR_FB_passthrough at session creation, so the
	# runtime starts the camera feed automatically when alpha-blend is requested.
	var xr_interface := XRServer.find_interface("OpenXR") as XRInterface
	if xr_interface:
		xr_interface.environment_blend_mode = (
			XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND if enabled
			else XRInterface.XR_ENV_BLEND_MODE_OPAQUE
		)
	get_viewport().transparent_bg = enabled
	for surf in _sky_surfaces:
		if is_instance_valid(surf):
			surf.visible = not enabled
	if _world_env and _world_env.environment:
		_world_env.environment.background_color = Color(0.0, 0.0, 0.0, 0.0 if enabled else 1.0)


func _process(_delta: float) -> void:
	# Main-loop iteration rate is what polls the multiplayer peer and turns pings around, so it
	# (not physics tps) bounds client-seen ping.
	if NetworkManager.is_host():
		_server_process_frames += 1
	if NetworkManager.is_online() and not NetworkManager.is_host():
		NetworkManager.interp_entities()
	if _light_grid and _light_grid.is_valid() and _local_player and _world_env:
		_world_env.environment.ambient_light_color = _light_grid.sample(
			_local_player.global_position)
	if XRManager.is_vr and _game_active and _local_player and _xr_rig and _xr_rig_camera:
		var nominal_eye: Vector3 = _local_player.get_eye_position()
		var allowed_eye: Vector3 = nominal_eye
		if XRManager.advanced_head_tracking:
			# Roomscale: the capsule already tracks the head horizontally, so the camera's
			# remaining XZ lean is only the residual — how far the head has out-run a blocked
			# capsule. Sphere-cast the full 3D offset so walls AND ceilings both clamp the result.
			var head_local := _xr_rig_camera.position
			var residual: Vector3 = _local_player.get_vr_head_residual()
			var desired_eye: Vector3 = Vector3(
				nominal_eye.x + residual.x,
				_local_player.global_position.y + head_local.y,
				nominal_eye.z + residual.z
			)
			if desired_eye.distance_squared_to(nominal_eye) > 0.0001:
				var space := get_world_3d().direct_space_state
				var params := PhysicsShapeQueryParameters3D.new()
				params.shape = _head_probe_shape
				params.transform = Transform3D(Basis.IDENTITY, nominal_eye)
				params.motion = desired_eye - nominal_eye
				params.collision_mask = GameConsts.MASK_WORLD_AND_CLIP
				var motion: PackedFloat32Array = space.cast_motion(params)
				var safe_frac := 1.0 if motion.is_empty() else motion[0]
				allowed_eye = nominal_eye.lerp(desired_eye, safe_frac)
		_xr_rig.global_position = allowed_eye - _xr_rig.global_basis * _xr_rig_camera.position
	if _vr_lobby_panel and _vr_lobby_panel.visible:
		if _xr_right_controller and _xr_right_controller.get_is_active():
			_vr_lobby_panel.update_pointer(_xr_right_controller)
		elif _xr_left_controller and _xr_left_controller.get_is_active():
			_vr_lobby_panel.update_pointer(_xr_left_controller)


## The lobby asked to switch renderers now rather than at the next launch, and the player has
## already confirmed the restart in the dialog.
func _on_lobby_renderer_restart(renderer: String) -> void:
	if not _renderer_trial.relaunch_for(renderer):
		_lobby.set_status("Could not restart — the renderer change applies on the next launch.")


## /scale [fraction] — drop the 3D render resolution without touching the window or the HUD. On a
## HiDPI screen the render target is the window size times the display scale, so a "1280x720" window
## on a Retina panel is really 2560x1440 — four times the pixels, which an older GPU feels. Pair with
## /perf: if halving the scale moves the frame time, the machine is fill-bound and this is the lever.
func _cmd_scale(args: String) -> void:
	var vp := get_viewport()
	var arg := args.strip_edges()
	if arg.is_empty():
		ClientCommandSystem.reply_ok("3D scale %.2f, rendering %s" % [vp.scaling_3d_scale, vp.get_visible_rect().size * vp.scaling_3d_scale])
		return
	if not arg.is_valid_float():
		ClientCommandSystem.reply_err("Usage: /scale [0.25-1.0]")
		return
	vp.scaling_3d_scale = clampf(float(arg), 0.25, 1.0)
	var px: Vector2 = vp.get_visible_rect().size * vp.scaling_3d_scale
	Log.info("[ClientPerf] 3D scale set to %.2f (%dx%d)" % [vp.scaling_3d_scale, px.x, px.y])
	ClientCommandSystem.reply_ok("3D scale %.2f — rendering %dx%d" % [vp.scaling_3d_scale, px.x, px.y])


## /fx [0|1] — freeze the per-frame ImmediateMesh rebuilds behind beams and projectile trails.
## Every active beam and every in-flight projectile frees and reallocates a GPU buffer each frame;
## the buffers are tiny, so the cost is entirely the round trip. Turn it off during a busy fight
## with /perf running and the difference is the size of that prize.
func _cmd_fx(args: String) -> void:
	var arg := args.strip_edges()
	if arg.is_empty():
		BeamSystem.fx_enabled = not BeamSystem.fx_enabled
	elif arg.is_valid_int():
		BeamSystem.fx_enabled = int(arg) != 0
	else:
		ClientCommandSystem.reply_err("Usage: /fx [0|1]")
		return
	Log.info("[ClientPerf] beam/trail rebuilds %s" % ("on" if BeamSystem.fx_enabled else "OFF"))
	ClientCommandSystem.reply_ok("Beam/trail rebuilds %s" % ("on" if BeamSystem.fx_enabled else "OFF — visuals will freeze"))


func _physics_process(delta: float) -> void:
	if not _game_active:
		return
	if _auto_walk and _local_player and not _local_player.is_dead and not _local_player.spectating:
		Input.action_press(&"move_forward")
		_local_player.rotation.y += _auto_walk_turn * delta  # wander in a wide arc into geometry
	if _auto_fire and _local_player and not _local_player.is_dead and not _local_player.spectating:
		if _local_player.current_weapon_idx != _auto_fire_slot and _local_player.weapons.size() > _auto_fire_slot:
			_local_player._switch_weapon_to(_auto_fire_slot)
		# Held; a hold that was denied (out of mana) lets go for a frame and presses again.
		var held := (_local_player._attack_down & FireControl.ATTACK) != 0
		_local_player._set_attack(FireControl.ATTACK, _local_player.fire.auto_firing or not held)
	if NetworkManager.is_host():
		_server_physics_ticks += 1
		if _server_physics_ticks % _CAL_EVERY_N_TICKS == 0:
			_sample_clock_calibration()
		_server_perf_timer += delta
		if _server_perf_timer >= 5.0:
			var _win := _server_perf_timer
			var tps := _server_physics_ticks / _server_perf_timer
			var ent_count := NetworkManager._synced_entities.size()
			var max_queue := 0
			var players := NetworkManager.player_roster()
			for pid in players:
				var r: Player = players[pid]
				if r.has_server_movement():
					max_queue = maxi(max_queue, r.get_server_movement().queue_size())
			# Wall-clock tps is the real health signal: `tps` above is pinned to 60 by construction
			# and cannot show a slow server. When the host tick runs over the 16.6ms budget, the
			# ENet poll rate that turns pings around collapses and clients see ping balloon.
			var wall_tps := _server_physics_ticks * 1e6 / maxf(_server_wall_usec, 1.0)
			# Main-loop rate = ENet poll rate = ping turnaround rate. Low while tick is small means
			# ping is network-path bound, not server-CPU bound.
			var proc_fps := _server_process_frames * 1e6 / maxf(_server_wall_usec, 1.0)
			# Flag: wall_tps < 58 or a growing queue.
			var mem_mb := Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0
			Log.info("[ServerPerf] tps=%.1f wall_tps=%.1f proc_fps=%.0f tick=%.2fms (bot=%.2f move=%.2f bcast=%.2f) ents=%d max_queue=%d players=%d mem=%.1fMB clock=%.2f" % [
				tps, wall_tps, proc_fps, _avg_ms(_server_tick_usec),
				_avg_ms(_server_bot_usec), _avg_ms(_server_move_usec), _avg_ms(_server_bcast_usec),
				ent_count, max_queue, NetworkManager.player_count(), mem_mb, _clock_calibration()])
			_server_physics_ticks = 0
			_server_perf_timer = 0.0
			_server_wall_usec = 0
			_server_tick_usec = 0
			_server_bot_usec = 0
			_server_move_usec = 0
			_server_bcast_usec = 0
			_server_process_frames = 0
			var _bw: Array = NetworkManager.pop_bandwidth()
			var _np2: int = maxi(NetworkManager.player_count(), 1)
			Log.info("[Bandwidth] up=%.0f KB/s down=%.0f KB/s pkts=%.0f/s | per-peer up=%.1f KB/s (%.0f kbit/s)" % [
				_bw[0]/1024.0/_win, _bw[1]/1024.0/_win, _bw[2]/_win,
				_bw[0]/1024.0/_win/_np2, _bw[0]*8.0/1000.0/_win/_np2])
			_server_cal_usec = 0
			_server_cal_samples = 0
	# Internally guards DoT/damage to authority only; frost timer runs on both client and server
	# for movement prediction.
	StatusSystem.tick(delta)
	if NetworkManager.is_authority():  # runs for host + offline; clients learn via death sync
		_kill_players_out_of_world()
	# Eye/camera position, not body origin — BSP PVS was built from eye viewpoint.
	if _local_player:
		var _vis_cam := _local_player.get_node_or_null("Camera3D")
		VisibilitySystem.set_local_position(_vis_cam.global_position if _vis_cam else _local_player.global_position)
	if not NetworkManager.is_online():
		return
	# Listen-server host skips this: we're our own authority, so _local_player.position is already
	# the truth and sending inputs to ourselves over loopback ENet is wasted work.
	if _local_player and not NetworkManager.is_host() and not _local_player.spectating and _local_player._last_input_cmd:
		_send_input(_local_player._last_input_cmd)
	# Process inputs at full physics rate, broadcast at NET_TICKRATE.
	if NetworkManager.is_host():
		# Accumulate real time between consecutive ticks (idle + work), so wall_tps in the
		# ServerPerf report reflects the true engine frame rate.
		var _now := Time.get_ticks_usec()
		if _server_last_tick_end_usec > 0:
			_server_wall_usec += _now - _server_last_tick_end_usec
		# Bot inputs BEFORE _process_player_movements so each bot's command is enqueued the same
		# tick it's consumed, matching a client's input arriving first.
		var _t := Time.get_ticks_usec()
		BotSystem.tick(delta)
		SiegeSystem.tick(delta)
		var _t_bot := Time.get_ticks_usec()
		_server_bot_usec += _t_bot - _t
		_feed_host_puppet()
		_process_player_movements()
		var _t_move := Time.get_ticks_usec()
		_server_move_usec += _t_move - _t_bot
		NetworkManager.net_tick_timer += delta
		if NetworkManager.net_tick_timer >= NetworkManager.NET_TICK_INTERVAL:
			NetworkManager.net_tick_timer -= NetworkManager.NET_TICK_INTERVAL
			_broadcast_player_states()
			NetworkManager.send_entity_transforms()
			# PVS gating and VR hands ride every other net tick: neither feeds a client interp
			# buffer, so a tick of extra age costs nothing visible, while the PVS push is
			# O(syncs × peers) and the most expensive thing in this block.
			_net_half_tick = not _net_half_tick
			if _net_half_tick:
				_broadcast_vr_hand_states()
				NetworkManager.push_pvs_visibility()
			NetworkManager.snapshot_due = true
			_server_bcast_usec += Time.get_ticks_usec() - _t_move
		_server_last_tick_end_usec = Time.get_ticks_usec()
		_server_tick_usec += _server_last_tick_end_usec - _t


## Mean per-physics-tick milliseconds for an accumulated-microseconds counter (ServerPerf report).
func _avg_ms(usec: int) -> float:
	return usec / float(maxi(_server_physics_ticks, 1)) / 1000.0


## Cost of a FIXED amount of work, so the ms figures above can be read at all: wall-clock time per
## unit of work isn't constant, since the OS clocks a busy process up and parks an idle one on
## efficiency cores. Measured 4.2x slower on an idle vs 32-bot server for identical code — enough to
## make an empty server look like it does MORE work per tick than a full one. Compare two ServerPerf
## lines only when their clock= values match, or divide through by the ratio first.
## Sampled on a fraction of ticks and averaged, not once at report time: a single sample catches the
## process at a momentarily-warm instant, which reads the same on idle and loaded servers — the
## clock-down penalty lives in the ticks after an idle sleep, so it has to be spread over the window.
## Reported as microseconds per 1000 iterations. Higher = the CPU is running this process slower.
const _CAL_ITERS := 2000
const _CAL_EVERY_N_TICKS := 8


func _sample_clock_calibration() -> void:
	var t0 := Time.get_ticks_usec()
	var _acc := 0
	for i in _CAL_ITERS:
		_acc += i
	_server_cal_usec += Time.get_ticks_usec() - t0
	_server_cal_samples += 1


func _clock_calibration() -> float:
	if _server_cal_samples == 0:
		return 0.0
	return _server_cal_usec / float(_server_cal_samples) / (_CAL_ITERS / 1000.0)


## The registry holds the host's own body puppet, and offline the LocalPlayer itself, so this is
## the one place all players are checked — RemotePlayer must NOT duplicate it. Free NPCs (e.g. the
## dragon) use their own death paths.
func _kill_players_out_of_world() -> void:
	var players := NetworkManager.player_table()
	for peer_id in players:
		var player: Player = players[peer_id]
		if not is_instance_valid(player) or player.is_dead:
			continue
		var pos: Vector3 = player.global_position
		if absf(pos.x) > GameConsts.WORLD_BOUND or absf(pos.y) > GameConsts.WORLD_BOUND or absf(pos.z) > GameConsts.WORLD_BOUND:
			Log.info("Player %d left world bounds (Y=%.1f) — killing" % [peer_id, pos.y])
			player.die()


## One command per tick. Pacing (cl_cmdrate), backups and resends are the transport's: goldnet's
## uplink carries the command stream (see NetworkManager.submit_input).
func _send_input(cmd) -> void:
	NetworkManager.send_input_cmd(cmd)


## Client puppets, bots, and the host's own body puppet alike.
func _process_player_movements() -> void:
	var players := NetworkManager.player_table()
	var nudge := _nudge_dist > 0.0 and Time.get_ticks_msec() >= _nudge_next_ms
	if nudge:
		_nudge_next_ms = Time.get_ticks_msec() + _nudge_interval_ms
	for peer_id in players:
		var remote: RemotePlayer = players[peer_id]
		if remote.is_dead or not remote.has_server_movement():
			continue
		var sm: ServerMovement = remote.get_server_movement()
		sm.noclip_grant = CommandSystem.is_noclip(peer_id)
		if sm.queue_size() > 0:
			# pmove's one per-command hook, so the trigger steps here too, on each command's own time.
			var modifier_cb := func(cmd) -> Movement.MovementModifiers:
				remote.fire_frame(cmd)
				return remote.get_movement_modifiers(cmd)
			sm.process_queue(remote.get_godot_body(), modifier_cb, remote.apply_fall_damage)
			remote.set("_push_base_vel", Vector3.ZERO)  # consumed for this frame; trigger_push re-sets next frame if still in zone
			remote.sync_crouched = sm.state.is_crouched
			remote.sync_jumping = sm.state.is_jumping
			remote.sync_pitch = sm.last_pitch
			remote.sync_swimming = remote.is_in_water()
			remote.set_sync_velocity(sm.state.velocity)
		if nudge and peer_id > 0 and peer_id != multiplayer.get_unique_id():
			remote.global_position += Vector3(_nudge_dist, 0.0, 0.0)
		# Lag-comp history at the full sim rate: a rewind then never lerps across more than one
		# tick, and an idle player still gets a dense timeline.
		LagCompensation.record(peer_id, Time.get_ticks_msec(), sm.state.position, sm.last_yaw, remote)
		# The owner's own state is published from _broadcast_player_states at NET_TICKRATE.


## The puppet is the authoritative, damageable, collidable body — the same RemotePlayer every
## client gets — processed by the normal server loops. _local_player becomes a pure predicted view:
## collision layer 0, not damageable, reconciled via _on_owner_state.
func _register_host_player() -> void:
	var host_id := multiplayer.get_unique_id()
	if _host_puppet != null and is_instance_valid(_host_puppet):
		_host_puppet.queue_free()  # map change: previous puppet survives scene root
	# Spawn through the spawner so every client gets the same replicated puppet.
	var puppet: RemotePlayer = _player_spawner.spawn({peer_id = host_id, node_name = "HostBody"})
	# `spawned` doesn't fire on the authority; do host bookkeeping explicitly. is_host()==true here,
	# so owner-exclusion does not drop the host's own body.
	_on_puppet_spawned(puppet)
	puppet.is_host_puppet = true
	puppet.setup_server_movement()
	_host_puppet = puppet
	# Late joiners pick this up via request_player_states -> sync_player_name.
	NetworkManager.send_request_player_name(_local_player_name)
	# The view no longer participates in physics or damage. Prediction still collides with OTHER
	# players' capsules; only our own puppet is excluded, both ways.
	_local_player.collision_layer = 0
	_local_player.has_body_puppet = true
	_local_player.set_damageable(false)
	_local_player.add_collision_exception_with(puppet)
	puppet.add_collision_exception_with(_local_player)


## Runs before _process_player_movements, which consumes it like any client's.
func _feed_host_puppet() -> void:
	if not _local_player or _local_player.spectating:
		return
	if _host_puppet == null or not is_instance_valid(_host_puppet) or not _host_puppet.has_server_movement():
		return
	if _host_puppet.is_dead:
		return  # matches submit_input dropping input from dead players
	var cmd = _local_player._last_input_cmd
	if cmd == null:
		return
	# Rebuild a copy from its fields: process_queue mutates cmds and the original instance lives in the
	# prediction replay buffer. This also feeds the sim exactly what a remote client's would deliver.
	_host_puppet.get_server_movement().enqueue(FireControl.command_from_fields(FireControl.command_fields(cmd)))


## Each client's own state goes into its OwnerState, which its next snapshot carries. NET_TICKRATE
## equals the physics rate, so each client gets a correction every tick it predicted (or as often
## as its granted update rate allows) — the shortest prediction-error feedback loop available.
func _broadcast_player_states() -> void:
	# The host's own state rides the generic loop below — its body puppet has a ServerMovement like
	# every client's.
	var players := NetworkManager.player_table()
	for peer_id in players:
		var remote: RemotePlayer = players[peer_id]
		if not remote.has_server_movement():
			continue
		var sm: ServerMovement = remote.get_server_movement()
		# seq=-1 signals no commands processed yet; client skips reconciliation but still reads queue_depth.
		if peer_id == multiplayer.get_unique_id():
			# Host's own view: there is no snapshot to itself, so deliver directly and SYNCHRONOUSLY.
			# Delivery even a tick late means every reconcile
			# replays 1-2 unacked commands (measured: 89 vs 19 corrections/min). Same-tick delivery
			# keeps unacked at 0, the zero-latency loopback advantage.
			NetworkManager.net_input_queue_depth = sm.queue_size()
			if sm.last_processed_seq >= 0:
				_client_sync._on_owner_state(sm.last_processed_seq, sm.state.position, sm.state.velocity,
					sm.state.is_crouched, sm.state.on_floor, sm.state.is_jumping, sm.state.jump_held)
		elif NetworkManager.is_peer_connected(peer_id):
			NetworkManager.publish_owner_state(peer_id, sm.last_processed_seq,
				sm.state.position, sm.state.velocity,
				sm.state.is_crouched, sm.state.on_floor, sm.state.is_jumping, sm.state.jump_held,
				sm.queue_size())
		var eye := sm.state.position + Vector3(0.0, sm.state.eye_y, 0.0)
		VisibilitySystem.set_peer_position(peer_id, eye)
		# The synchronizer streams this shadow state to visible peers (PVS + owner-exclusion +
		# dead/unjoined hiding via _net_visible_to).
		remote.set_net_state(sm.last_processed_seq, sm.state.position, sm.last_yaw,
			sm.last_pitch, sm.state.velocity, remote.get_broadcast_flags(),
			clampi(remote.current_weapon_idx, 0, 255), Time.get_ticks_msec())
		# Feed the SAME data into the host's own local interpolation buffer for this puppet, so the
		# host's screen smooths other players' movement like every other observer (see
		# RemotePlayer._needs_visual_smoothing). Covers bots (negative IDs) too, for free.
		if peer_id != multiplayer.get_unique_id() and sm.last_processed_seq >= 0:
			remote.push_visual_snapshot(Time.get_ticks_msec(), sm.last_processed_seq,
				sm.state.position, sm.last_yaw, sm.state.is_crouched, sm.last_pitch,
				sm.state.is_jumping, sm.state.velocity)



func _broadcast_vr_hand_states() -> void:
	var vr_ids := PackedInt32Array()
	var right_hands := PackedVector3Array()
	var left_hands := PackedVector3Array()
	var hand_flags := PackedByteArray()
	if _local_player and XRManager.is_vr and XRManager.hand_tracking:
		var r_valid := is_instance_valid(_local_player.xr_right)
		var l_valid := is_instance_valid(_local_player.xr_left)
		if r_valid or l_valid:
			vr_ids.append(multiplayer.get_unique_id())
			right_hands.append(_local_player.xr_right.global_position if r_valid else Vector3.INF)
			left_hands.append(_local_player.xr_left.global_position if l_valid else Vector3.INF)
			hand_flags.append(1 if XRManager.left_handed else 0)
	for pid in NetworkManager._vr_hand_positions:
		var entry: Dictionary = NetworkManager._vr_hand_positions[pid]
		vr_ids.append(pid)
		right_hands.append(entry.get("right", Vector3.INF))
		left_hands.append(entry.get("left", Vector3.INF))
		hand_flags.append(entry.get("flags", 0) as int)
	if vr_ids.is_empty():
		return
	NetworkManager.sync_vr_hand_states.rpc(vr_ids, right_hands, left_hands, hand_flags)
	# call_remote excludes the host, so apply locally too.
	_client_sync._on_sync_vr_hand_states(vr_ids, right_hands, left_hands, hand_flags)


## Gives player puppets a replication-ID handshake.
func _setup_player_spawner() -> void:
	_player_spawner = MultiplayerSpawner.new()
	_player_spawner.name = "PlayerSpawner"
	_player_spawner.spawn_path = NodePath("..")  # must be set before entering the tree; ".." = Main
	# spawn() triggers replication (add_child auto-detection didn't fire for late joiners). The
	# client auto-instantiates the registered scene; identity + transform ride the synchronizer's props.
	_player_spawner.spawn_function = _spawn_player_puppet
	_player_spawner.add_spawnable_scene("res://src/remote_player.tscn")
	_player_spawner.spawned.connect(_on_puppet_spawned)
	_player_spawner.despawned.connect(_on_puppet_despawned)
	add_child(_player_spawner)

	# Dynamic-entity spawner: custom spawn only (no registered scene), so the client runs
	# _spawn_dyn_entity(data) to rebuild the projectile/plant from its script_path.
	_dyn_spawner = MultiplayerSpawner.new()
	_dyn_spawner.name = "DynSpawner"
	_dyn_spawner.spawn_path = NodePath("..")  # spawn under Main (where projectiles already live)
	_dyn_spawner.spawn_function = _spawn_dyn_entity
	# Clients only (doesn't fire on the authority): an entity landing can complete an RPC that
	# named it before it existed, e.g. a dragon mount.
	_dyn_spawner.spawned.connect(_on_dyn_entity_spawned)
	add_child(_dyn_spawner)


func _on_dyn_entity_spawned(_node: Node) -> void:
	if _local_player:
		_local_player.retry_pending_dragon_mount()


## Server: create + replicate a dynamic entity through the spawner. Returns the server-side node so the
## caller can set non-serializable fields (owner_node, exclude_rid). data must carry a "script_path".
func spawn_dynamic_entity(data: Dictionary) -> Node:
	# Every dynamic entity gets a network id, allocated here so no caller can forget: it names the
	# node below, and state-sync entities (dragon, plants) also register under it for
	# sync_entity_state. Copied rather than stamped in place — callers reuse their literal.
	data = data.duplicate()
	data["entity_id"] = NetworkManager.alloc_dyn_entity_id()
	# The host clock at the spawn, which is the server clock a client estimates: a create the
	# spawner holds back until the entity enters a peer's PVS arrives stamped with how long ago
	# it really happened (TumblingCorpse._age).
	data["born_ms"] = Time.get_ticks_msec()
	# Offline MultiplayerSpawner.spawn() would fail, so build locally (is_authority() is true
	# offline, so it sets up as host).
	if not NetworkManager.is_online():
		var node := _spawn_dyn_entity(data)
		if node:
			add_child(node)
		return node
	# Packed: the spawn is resent until each client acks it (see SpawnCodec).
	return _dyn_spawner.spawn(SpawnCodec.pack(data))


## spawn_function — runs on the host AND every client. Rebuilds the entity from its script_path, runs
## setup() in the correct host/client mode, and attaches a transform synchronizer. Online it gets
## the bytes spawn_dynamic_entity packed; offline, the dictionary itself.
func _spawn_dyn_entity(spawn_data: Variant) -> Node:
	var data: Dictionary = SpawnCodec.unpack(spawn_data) if spawn_data is PackedByteArray else spawn_data
	var script_path: String = data.get("script_path", "")
	if script_path.is_empty():
		return null
	var script: GDScript = load(script_path)
	if script == null:
		return null
	var base_type := script.get_instance_base_type()
	# GoldSrc units, like every other entity keyvalue. 0 = no brush up front; an entity that turns
	# out to need one builds the default from GoldSrcEntity (see build_brush_stand_in).
	var brush_size := str(data.get("ent", {}).get("size", "0")).to_float()
	# Every brush entity's script says `extends Node3D`, but the importer hands it an
	# AnimatableBody3D and EntityBase._anim_body looks for exactly that — a plain Node3D there is a
	# null deref waiting in func_door_base. Match the importer for every map entity, not just the
	# ones given a size: a shapeless body is inert, so point entities lose nothing by it.
	if data.has("ent") and base_type == &"Node3D":
		base_type = &"AnimatableBody3D"
	var node: Node = ClassDB.instantiate(base_type)
	node.set_script(script)
	# goldnet names a node by its scene path between peers (an RPC's target, a synchronizer within a
	# spawned node), so both peers must land on the same name, and Godot's collision-rename counter is
	# per-process — leave two siblings to it and an RPC meant for one reaches the other, or nothing.
	# The id rides the payload and is unique per spawn; the script stem is decoration so the tree reads
	# "fireball_12".
	node.name = "%s_%d" % [script_path.get_file().get_basename(), data["entity_id"]]
	node.set_meta("_dyn_spawner_entity", true)  # tag for round-reset cleanup (destroy_all_dynamic_entities)
	# Map-entity bridge: `ent` is the keyvalue dictionary the BSP importer would have attached,
	# so an EntityBase reads it in _ready exactly as a map-placed one does. This runs on the host
	# and on every client, so all peers build the identical entity.
	if data.has("ent"):
		node.set_meta("entity", data["ent"])
		if node is Node3D:
			var n3 := node as Node3D
			n3.position = data.get("position", Vector3.ZERO)
			n3.rotation.y = data.get("yaw", 0.0)
		# Kinematic movers write their transform directly; sync_to_physics would silently swallow
		# those writes (the importer's bodies are configured the same way).
		if node is AnimatableBody3D:
			(node as AnimatableBody3D).sync_to_physics = false
		if brush_size > 0.0:
			GoldSrcEntity.build_brush_stand_in(node, brush_size)
	if node.has_method("setup"):
		node.setup(data, NetworkManager.is_authority())
	# Register the shared id so sync_entity_state resolves on both peers. Only the entities that
	# stream state want it — every projectile holding an id would tick send_entity_transforms for
	# nothing.
	if NetworkManager.is_online() and data.get("sync_state"):
		var eid: int = data["entity_id"]
		# Hosts that wrap their EntityBehavior in a composite (SummonBehavior) expose no
		# _entity of their own, so ask for that too — without it their entity_id stays -1
		# and every sync_entity_state push they make is silently dropped.
		if "_entity" in node:
			node._entity.entity_id = eid
		elif "_summon" in node:
			node._summon.entity_id = eid
		NetworkManager.register_dyn_state_entity(eid, node)
		node.tree_exiting.connect(NetworkManager.unregister_dyn_state_entity.bind(eid))
	# Client replicas are driven by the synced transform, so freeze rigid bodies — gravity/contacts
	# must not fight the interpolated position.
	if node is RigidBody3D and not NetworkManager.is_authority():
		(node as RigidBody3D).freeze = true
	if not NetworkManager.is_online():
		return node  # offline: no peers, so skip the synchronizer entirely
	# Shared clock-synced interp buffer (like movers/players); the bridge carries net_pos/net_rot/
	# net_stamp and interp_entities renders at server_time - INTERP_DELAY.
	var bridge := NetInterpBridge.new()
	bridge.name = "NetInterp"
	bridge.born_ms = data.get("born_ms", 0)
	node.add_child(bridge)
	var spec := DYN_ENTITY_SPEC.duplicate()
	# State an entity puts on the snapshot rather than a side-channel RPC: it rides the same
	# stream as the spawn (so it can't arrive first), honors PVS, and comes back with a full
	# baseline on PVS re-entry. Opt-in because every slot costs a path resolve per entity per
	# tick. These declare nothing ({}) — no publish funnel marks them, so goldnet polls them.
	if node.has_method("net_sync_properties"):
		for p in node.net_sync_properties():
			spec[p] = {}
	var sync := SyncSpec.build("NetSync", spec)
	# ALWAYS props arrive on synchronized; wire delta_synchronized too so the apply path is mode-agnostic.
	sync.synchronized.connect(bridge._on_synced)
	sync.delta_synchronized.connect(bridge._on_synced)
	# Per-peer PVS, server-side only: track the entity by instance id and cull the synchronizer to
	# peers who can see it, giving create-on-PVS-enter for free.
	#
	# Tracked on `ready`, NOT here: the node isn't in the tree yet, so track_node can't derive a leaf
	# set and would register handle -1, which is_entity_visible_to_peer reads as "visible to
	# everyone" — every dynamic entity would ship a create to every peer, and that spawn PERSISTS
	# once delivered (clients hold and tick entities they can never see). `ready` fires the same
	# frame the spawner adds the node, before the next server tick, so the first PVS evaluation is
	# real, and a deferred spawn is re-offered every tick until the entity becomes visible.
	if node is Node3D and NetworkManager.is_authority():
		var pvs_id := int(node.get_instance_id())
		node.ready.connect(VisibilitySystem.track_node.bind(pvs_id, node), CONNECT_ONE_SHOT)
		NetworkManager.register_pvs_sync(sync, _dyn_entity_visible.bind(pvs_id),
			VisibilitySystem.entity_epoch.bind(pvs_id))
		node.tree_exiting.connect(VisibilitySystem.untrack_node.bind(pvs_id))
	node.add_child(sync)
	return node


## pvs_id is the node's instance id.
func _dyn_entity_visible(peer: int, pvs_id: int) -> bool:
	# Same reload-window guard the players and movers use: an entity created while a peer is between
	# maps would be streamed into a client with no scene, dropped, and never re-offered.
	if not NetworkManager.is_peer_map_ready(peer):
		return false
	return VisibilitySystem.is_entity_visible_to_peer(pvs_id, peer)


## On the server this stamps peer_id, which the baked synchronizer then spawn-replicates. Clients
## usually auto-instantiate via the registered scene.
func _spawn_player_puppet(data: Dictionary) -> Node:
	var id: int = data["peer_id"]
	var remote: RemotePlayer = RemotePlayerScene.instantiate()
	remote.name = data.get("node_name", "Player_%d" % id)
	remote.peer_id = id
	return remote


## Fires on host + every client. Server-only setup that differs by kind (server_movement, bot brain)
## stays with the caller after spawn() returns.
func _on_puppet_spawned(node: Node) -> void:
	var puppet := node as RemotePlayer
	if puppet == null:
		return
	var id: int = puppet.peer_id
	# Owner-exclusion (client-side): a client already has a predicted LocalPlayer for its own body,
	# so discard the replicated puppet for itself.
	if not NetworkManager.is_host() and id == multiplayer.get_unique_id():
		puppet.queue_free()
		return
	# Idempotent: the authority calls this explicitly after spawn() (`spawned` only fires on
	# receiving peers), so guard against a double-register.
	if NetworkManager.get_player(id) == puppet:
		return
	NetworkManager.register_player(id, puppet)
	# A joining puppet's replicated slots are written by the spawn path before set_net_state ever
	# runs for it, so mark it dirty once here — otherwise a puppet that spawns and never moves
	# (spectating, dead on arrival) would serve its pre-spawn values to everyone.
	NetworkManager.mark_entity_dirty(puppet)
	if not NetworkManager.is_host():
		# element/team ride the spawn packet, so build the model now instead of waiting for the
		# first sync, so it's never briefly blank. Live changes still flow through _on_net_synchronized.
		puppet._ensure_appearance()
	# Initial join: element may not be set on the puppet yet, so apply any team/element appearance
	# that arrived before this spawn registered.
	NetworkManager.apply_pending_team_state(id, puppet)
	if NetworkManager.is_host():
		VisibilitySystem.track_player(id, puppet)


## The authority freeing a spawned puppet replicates a despawn, so clients drop their bookkeeping
## here instead of via a hand-rolled remove RPC.
func _on_puppet_despawned(node: Node) -> void:
	var puppet := node as RemotePlayer
	if puppet == null:
		return
	var id: int = puppet.peer_id
	NetworkManager.unregister_player(id)
	VisibilitySystem.untrack_player(id)
	VisibilitySystem.remove_peer(id)


func _on_peer_connected(id: int) -> void:
	if not _game_active or NetworkManager.has_player(id):
		return
	# Only the host creates puppets; the MultiplayerSpawner replicates them to every client.
	if not NetworkManager.is_host():
		return
	var remote: RemotePlayer = _player_spawner.spawn({peer_id = id, node_name = "Player_%d" % id})
	_on_puppet_spawned(remote)  # `spawned` doesn't fire on the authority
	remote.is_host_puppet = true  # authoritative, collidable body (drives entity touch zones)
	if _local_player:
		remote.position = _local_player.position + Vector3(1, 0, 0)
	elif SpawnSystem.get_all_spawns().size() > 0:
		remote.position = SpawnSystem.get_all_spawns()[0].get_spawn_position()
	# A placeholder until this peer actually spawns: not visible, not a target, not an
	# obstacle. The client may be a long way from finishing its map load, and the placeholder
	# is parked on a spawn point — left in the "damageable" group, a thornplant covering that
	# spawn locks on and kills it, dragging the still-loading client through a death it can't
	# present. spawn_at -> _enable_after_spawn restores the collider and the group.
	remote.visible = false
	remote.set_damageable(false)
	var shape := remote.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if shape:
		shape.disabled = true
	remote.setup_server_movement()
	Log.info("Spawned remote player for peer %d (host puppet)" % id)


## Client join flow: connect first, then download/cache map, then activate.
func _spawn_missed_players() -> void:
	for id in multiplayer.get_peers():
		if not NetworkManager.has_player(id):
			_on_peer_connected(id)


func _on_peer_disconnected(id: int) -> void:
	if NetworkManager.despawn_player(id):
		Log.info("Removed remote player for peer %d" % id)


func _on_assign_spawn(pos: Vector3, yaw: float, team: int, element: int = GameConsts.Element.FIRE) -> void:
	if not _local_player:
		return
	_client_join.clear_watchdog()
	_local_player.team = team
	var previous_speed : float = _local_player.speed_multiplier
	_local_player.spawn_at_transform(pos, yaw, element, true)
	Log.info("[assign_spawn] element=%d wizard_speed=%.3f (before=%.3f)" % [element, _local_player.speed_multiplier, previous_speed])
	Log.info("Assigned spawn by host: team %d (element=%d), pos=%s, yaw=%.1f°" % [
		team, element, pos, rad_to_deg(yaw)])


func _on_teleport_player(pos: Vector3, yaw: float) -> void:
	if not _local_player:
		return
	_local_player.velocity = Vector3.ZERO
	_local_player.position = pos
	_local_player.rotation.y = yaw
	_local_player.move_and_slide()
	_local_player.reset_movement()


func respawn_all_players() -> void:
	NetworkManager.destroy_all_dynamic_entities()
	# Offline the registry holds the LocalPlayer itself rather than a puppet, so respawn it the
	# direct way — the puppet path below sends to a peer that isn't there.
	if not NetworkManager.is_online() and _local_player and _local_player.team != GameConsts.Team.NONE:
		var sp := SpawnSystem.get_spawn_for_team(_local_player.team)
		if sp:
			_local_player.spawn_at(sp, _local_player.element, true)
	# The host's own body puppet rides the same loop; its sync_spawn_to_network delivers
	# assign_spawn to the host's view locally. Offline bots are in here too, and still need it.
	var players := NetworkManager.player_roster()
	for peer_id in players:
		var remote: CharacterBody3D = players[peer_id]
		if remote == _local_player:
			continue  # offline only: already respawned above
		if remote.team == GameConsts.Team.NONE:
			continue
		# The player's own respawn timer may have just fired this frame: is_dead is already false
		# but is_respawning is still true — they're already at their spawn point.
		if not remote.is_dead and remote.is_respawning:
			continue
		var sp := SpawnSystem.get_spawn_for_team(remote.team)
		if sp:
			remote.spawn_at(sp, remote.element, true, false)
			remote.sync_spawn_to_network(sp)
			remote._apply_spawn_point_effects(sp)



func _load_map_scene(scn_path: String) -> Node3D:
	var scene := ResourceLoader.load(scn_path) as PackedScene
	if scene == null:
		push_error("Failed to load scene: %s" % scn_path)
		return null
	var root: Node3D = scene.instantiate()
	_report_map_pipeline(root, scn_path)
	# has_meta guard: get_meta(key, null) errors on absent keys (null default == no default).
	lightstyle_image = root.get_meta("lightstyle_image") if root.has_meta("lightstyle_image") else null
	lightstyle_texture = root.get_meta("lightstyle_texture") if root.has_meta("lightstyle_texture") else null
	EntityRegistry.strip_unscripted(root)
	return root


## A GoldSrc-derived scene has to carry the stripped BSP tree, or hop has no clip hull to trace and
## PVS is off — the map plays with render-face collision and nobody is told. A peer that downloaded
## the .scn can't repair it (no .bsp ships to clients), so logging the pipeline version is the best
## we can do. Blender maps have no worldspawn and never had a tree, so they're not this case.
func _report_map_pipeline(root: Node3D, scn_path: String) -> void:
	if root.has_meta("bsp_data") or root.get_node_or_null("worldspawn") == null:
		return
	Log.warn(("%s was built by pipeline v%d (current is v%d) and carries no BSP tree: "
		+ "no clip-hull collision, PVS off. Re-download it from a host on current code.")
		% [scn_path, int(root.get_meta(MapConverter.VERSION_META, 0)), MapConverter.CACHE_VERSION])





## TFC's game mode code started only home spawns active; our generic entity spawner has no such
## logic. Heuristic: for each team, the lowest-numbered group is the home group — keep it active
## and disable all others.
func _init_spawn_groups() -> void:
	var team_groups: Dictionary = {}  # team_no -> Dictionary(group_no -> int)
	for spawn in SpawnSystem.get_all_spawns():
		if spawn.team_no == 0 or spawn.group_no == 0:
			continue
		if not team_groups.has(spawn.team_no):
			team_groups[spawn.team_no] = {}
		var groups: Dictionary = team_groups[spawn.team_no]
		groups[spawn.group_no] = groups.get(spawn.group_no, 0) + 1

	var any_multi := false
	for team_no in team_groups:
		if team_groups[team_no].size() > 1:
			any_multi = true
			break
	if not any_multi:
		return

	for team_no in team_groups:
		var groups: Dictionary = team_groups[team_no]
		if groups.size() <= 1:
			continue
		# TFC convention: base spawns use the lowest group_no, forward/captured positions use higher.
		var home_group: int = 0
		var home_count: int = 0
		for group_no in groups:
			if home_group == 0 or group_no < home_group:
				home_group = group_no
				home_count = groups[group_no]
		for group_no in groups:
			if group_no != home_group:
				SpawnSystem.remove_group(group_no)
		Log.info("SpawnGroups: team %d home=group %d (%d spawns), disabled %d forward groups" % [
			team_no, home_group, home_count, groups.size() - 1])
