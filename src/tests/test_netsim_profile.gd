extends "res://src/tests/test_base.gd"
## The lobby's Netsim menu: a simulated connection run on this client alone. Pins that every
## profile is a config goldnet accepts on both legs, and that the menu beside Join lists them,
## persists the choice, and shows it.
##
## Scene-run only (LobbyUI reaches for the XRManager and NetworkManager autoloads). Writes the real
## settings.cfg, so the file's own value is put back after the suite, as is the one in memory.

const NetProfiles = preload("res://src/systems/net_profiles.gd")
const LobbyUIScript = preload("res://src/systems/lobby_ui.gd")

var _saved_profile: String
var _saved_cfg: Variant  ## the file's own value, null when it has none


func _run_tests() -> void:
	_saved_profile = NetworkManager.net_profile
	var cfg := ConfigFile.new()
	cfg.load(NetworkManager.SETTINGS_PATH)
	_saved_cfg = cfg.get_value("net", "sim_profile", null)
	await super()
	NetworkManager.net_profile = _saved_profile
	cfg = ConfigFile.new()
	cfg.load(NetworkManager.SETTINGS_PATH)
	if _saved_cfg == null:
		if cfg.has_section_key("net", "sim_profile"):
			cfg.erase_section_key("net", "sim_profile")
	else:
		cfg.set_value("net", "sim_profile", _saved_cfg)
	cfg.save(NetworkManager.SETTINGS_PATH)


## A goldnet whose config is never installed on the tree, so nothing here touches a live session.
func _goldnet() -> MultiplayerAPI:
	if not ClassDB.class_exists(&"GoldNetMultiplayer"):
		return null
	return ClassDB.instantiate(&"GoldNetMultiplayer")


func test_every_profile_sets_both_legs() -> void:
	var mp := _goldnet()
	if mp == null:
		return
	for id in NetProfiles.PROFILES:
		var p: Dictionary = NetProfiles.PROFILES[id]
		assert_true(NetProfiles.apply(mp, id), "goldnet refused profile %s" % id)
		_assert_config(mp.sim_config, p["up"], "%s: send leg" % id)
		_assert_config(mp.recv_sim_config, p["down"], "%s: receive leg" % id)


## Every key the profile sets reads back; goldnet keeps the float ones as float32.
func _assert_config(got: Dictionary, want: Dictionary, context: String) -> void:
	for key in want:
		if want[key] is float:
			assert_almost_eq(got[key], want[key], 0.0001, "%s %s" % [context, key])
		else:
			assert_eq(got[key], want[key], "%s %s" % [context, key])


func test_off_clears_a_profile() -> void:
	var mp := _goldnet()
	if mp == null:
		return
	NetProfiles.apply(mp, "modem28")
	NetProfiles.apply(mp, NetProfiles.OFF)
	assert_eq(mp.sim_config["link_bps"], 0, "Off left the send leg capped")
	assert_eq(mp.recv_sim_config["link_bps"], 0, "Off left the receive leg capped")
	assert_eq(mp.recv_sim_config["latency_max_ms"], 0, "Off left the receive leg delayed")


func test_the_menu_lists_persists_and_shows_the_choice() -> void:
	NetworkManager.set_net_profile(NetProfiles.OFF)
	var lobby: CanvasLayer = _keep(LobbyUIScript.new())
	_root().add_child(lobby)
	var menu: PopupMenu = lobby._netsim_btn.get_popup()
	assert_eq(menu.item_count, NetProfiles.PROFILES.size(), "the menu is missing a profile")
	assert_eq(lobby._netsim_btn.text, "Netsim: Off", "the button does not show the profile in force")

	var ids: Array = NetProfiles.PROFILES.keys()
	var i := ids.find("modem28")
	menu.id_pressed.emit(menu.get_item_id(i))
	assert_eq(NetworkManager.net_profile, "modem28", "picking a profile did not select it")
	assert_eq(lobby._netsim_btn.text, "Netsim: 28.8k modem", "the button did not follow the choice")
	assert_true(menu.is_item_checked(i), "the chosen profile is not ticked")
	assert_false(menu.is_item_checked(ids.find(NetProfiles.OFF)), "Off is still ticked")
	var cfg := ConfigFile.new()
	cfg.load(NetworkManager.SETTINGS_PATH)
	assert_eq(cfg.get_value("net", "sim_profile", ""), "modem28", "the choice did not reach settings.cfg")
