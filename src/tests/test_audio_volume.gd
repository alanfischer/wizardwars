extends "res://src/tests/test_base.gd"
## The effects volume: every game sound lands on the Effects bus and voice chat does not, so the
## two menu sliders are independent. Scene-run only (SoundSystem and LobbyUI are autoload-bound).

const AudioSettings = preload("res://src/systems/audio_settings.gd")
const LobbyUIScript = preload("res://src/systems/lobby_ui.gd")

var _saved_effects: int


func _run_tests() -> void:
	_saved_effects = AudioSettings.load_effects()
	await super()
	SoundSystem.set_effects_volume(_saved_effects)


func test_world_sounds_pass_through_effects() -> void:
	var effects := AudioServer.get_bus_index(SoundSystem.EFFECTS_BUS)
	var world := AudioServer.get_bus_index(SoundSystem.WORLD_BUS)
	assert_ne(effects, -1, "there is no Effects bus")
	assert_eq(AudioServer.get_bus_send(world), SoundSystem.EFFECTS_BUS, "World skips Effects")
	assert_lt(effects, world, "a bus can only send to a lower index, so World's send is dropped")
	assert_eq(AudioServer.get_bus_send(effects), &"Master", "Effects does not reach the output")


func test_voice_skips_effects() -> void:
	if not VoiceChat.available:
		return
	assert_eq(AudioServer.get_bus_send(AudioServer.get_bus_index(VoiceChat.VOICE_BUS)), &"Master",
		"voice chat would follow the effects slider")


func test_effects_volume_sets_the_bus_and_saves() -> void:
	var idx := AudioServer.get_bus_index(SoundSystem.EFFECTS_BUS)
	SoundSystem.set_effects_volume(50)
	assert_almost_eq(AudioServer.get_bus_volume_db(idx), linear_to_db(0.5), 0.01, "the bus is not at half")
	assert_eq(AudioSettings.load_effects(), 50, "the volume was not saved")
	SoundSystem.set_effects_volume(0)
	assert_almost_eq(AudioServer.get_bus_volume_db(idx), -80.0, 0.01, "zero is not silence")
	SoundSystem.set_effects_volume(400)
	assert_eq(SoundSystem.effects_volume(), AudioSettings.EFFECTS_MAX, "the volume is not capped")


func test_the_menu_slider_drives_the_volume() -> void:
	SoundSystem.set_effects_volume(100)
	var lobby: CanvasLayer = _keep(LobbyUIScript.new())
	_root().add_child(lobby)
	assert_true(lobby._effects_slider != null, "the menu has no effects slider")
	assert_eq(lobby._voice_slider != null, VoiceChat.available, "the voice slider follows voice chat")
	lobby._effects_slider.value = 35
	assert_eq(SoundSystem.effects_volume(), 35, "moving the slider did not set the volume")
	assert_eq(AudioSettings.load_effects(), 35, "moving the slider did not save the volume")
