extends Node
## This peer's own view of a loaded map: the predicted LocalPlayer, the HUD, the VR HUD panel, the
## team/class menu, and the map's briefing (/motd, /mapinfo) and controls card (/intro).
##
## Parented to main.gd as "LocalView". What it builds goes under the injected parent (Main), where
## the rest of the game finds it through Game.local_player and Game.hud.

const LocalPlayerScene = preload("res://src/local_player.tscn")
const IntroGuide = preload("res://src/systems/intro_guide.gd")

var _parent: Node
var _client_join: Node
var _rig: VRRig
var _vr_hud_panel: VRHUDPanel  # on the persistent rig camera


func bind(parent: Node, client_join: Node, rig: VRRig) -> void:
	_parent = parent
	_client_join = client_join
	_rig = rig


func _ready() -> void:
	ClientCommandSystem.register("motd", _cmd_motd, "/motd", "Re-show the current map's description.")
	ClientCommandSystem.register("mapinfo", _cmd_motd, "/mapinfo", "Re-show the current map's description.")
	ClientCommandSystem.register("intro", _cmd_intro, "/intro", "Re-show the controls card for new players.")


## After MapWorld has loaded the map. A map with no spawn point gets no player and no HUD.
func build() -> void:
	var all_spawns := SpawnSystem.get_all_spawns()
	Log.info("Spawn points found: %d" % all_spawns.size())
	if all_spawns.is_empty():
		return
	var player: LocalPlayer = LocalPlayerScene.instantiate()
	# ENet is brought up before the map loads, so get_unique_id() is the real id here (offline it's
	# 1). Consumers read peer_id directly, no fallback needed downstream.
	player.peer_id = multiplayer.get_unique_id()
	# The first non-team spawn point (info_player_start).
	var sp := all_spawns[0]
	for candidate in all_spawns:
		if candidate.team_no == 0:
			sp = candidate
			break
	player.position = sp.get_spawn_position()
	player.rotation.y = sp.rotation.y
	if XRManager.is_vr:
		player.xr_camera = _rig.camera
		player.xr_rig = _rig
		player.xr_left = _rig.left
		player.xr_right = _rig.right
		player.vr_menu_requested.connect(_on_vr_menu)
	Game.local_player = player  # before add_child, so the player's own _ready finds itself there
	_parent.add_child(player)
	# Offline the LocalPlayer IS the server-side player, so register it for get_player() lookups.
	# Online the cache entry is the body puppet instead (main._register_host_player).
	if not NetworkManager.is_online():
		NetworkManager.register_player(player.peer_id, player)
	player.set_spectating(true)
	Log.info("Player spawned at: %s, yaw: %s" % [player.position, player.rotation.y])

	Game.weather_system.attach_player(player)

	var hud := HUD.create()
	Game.hud = hud
	_parent.add_child(hud)
	player._hud = hud
	hud.chat_submitted.connect(player._on_chat_submitted)

	# A player who has never been here gets the controls card first, with the map description
	# queued behind it. Showing it is what clears the tick, so it costs one reading and then never
	# appears again unless the lobby (or /intro) asks for it.
	if IntroGuide.should_show():
		IntroGuide.set_show(false)
		hud.show_intro(IntroGuide.body(XRManager.is_vr), _show_map_info_panel)
	else:
		_show_map_info_panel()
	if XRManager.is_vr:
		_vr_hud_panel = VRHUDPanel.new()
		_vr_hud_panel.name = "VRHUDPanel"
		_rig.camera.add_child(_vr_hud_panel)
		_vr_hud_panel.position = Vector3(0.0, -0.1, -1.2)
		hud.move_to_vr_panel(_vr_hud_panel.viewport)

	var menu: CanvasLayer = _client_join.build_menu()
	if _rig.lobby_panel:
		_rig.lobby_panel.add_ui(menu)
	else:
		_parent.add_child(menu)


## The controller's menu button.
func _on_vr_menu(class_only: bool) -> void:
	if (class_only and _client_join.open_class_menu()) or _client_join.open_team_menu():
		_rig.attach_panel()


func teardown() -> void:
	var player := Game.local_player
	if player:
		player.free_debug_render()
		EntityRender.release_override_materials(player)
		player.queue_free()
	if Game.hud:
		Game.hud.queue_free()
	Game.local_player = null
	Game.hud = null
	_client_join.teardown_menu()  # in VR it lives in the lobby panel's SubViewport
	if _vr_hud_panel:
		_vr_hud_panel.queue_free()
		_vr_hud_panel = null


## Returns {} if the text is malformed or the named world image isn't bundled. Format: world name
## (names maps/worlds/<name>.tga), then the marker's X and Y in per-mille (0-1000) of the image.
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


## Returns false when the map has neither sheet. Both are baked into the .scn by MapConverter
## (maps/<map>.txt and maps/<map>.ww); downloaded custom maps may have neither.
func _show_map_info_panel() -> bool:
	var info: String = Game.map_root.get_meta("map_description", "")
	var world := _parse_map_world(Game.map_root.get_meta("map_world_info", ""))
	if info.is_empty() and world.is_empty():
		return false
	Game.hud.show_map_info(Game.current_map_name, info,
		world.get("texture"), world.get("marker", Vector2(-1, -1)))
	return true


## Deliberately doesn't touch the "seen it" tick: asking for the card is not the same as wanting
## it back at every map start.
func _cmd_intro(_args: String) -> void:
	if Game.hud == null:
		ClientCommandSystem.reply_err("No map loaded.")
		return
	Game.hud.show_intro(IntroGuide.body(XRManager.is_vr))


func _cmd_motd(_args: String) -> void:
	if Game.hud == null:
		ClientCommandSystem.reply_err("No map loaded.")
		return
	if not _show_map_info_panel():
		Game.hud.show_center_message("No description for %s" % Game.current_map_name)
