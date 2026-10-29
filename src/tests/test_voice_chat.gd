extends "res://src/tests/test_base.gd"
## Voice chat: the channel latch, who the server relays a packet to, the budget that keeps a
## client from pushing more voice at the server than it could be speaking, and what a packet from
## another client has to look like before it is allowed to configure a decoder.
##
## The audio itself is TwoVoIP's, and a headless suite has nothing to speak into and nothing to
## hear it on — but opening the microphone is still exercised, because the two mic signals ARE
## the transmit path and leaving one unconnected is a silence nothing else would catch.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.

const ServerRequests = preload("res://src/systems/server_requests.gd")
const VoiceSettings = preload("res://src/systems/voice_settings.gd")

const NONE := VoiceChat.Channel.NONE
const ALL := VoiceChat.Channel.ALL
const TEAM := VoiceChat.Channel.TEAM

var _saved_roster: Dictionary = {}


func _setup_test(_test_name: String) -> void:
	GoalSystem.reset()  # team_allies back to nobody-allied, which is what the team filter reads
	_saved_roster = NetworkManager.swap_roster({})


func _teardown_test() -> void:
	NetworkManager.swap_roster(_saved_roster)
	_saved_roster = {}
	_despawn_all()


## A Player in the roster under `peer_id`, on `team`.
func _player_on(peer_id: int, team: int) -> Player:
	var p := _wizard()
	p.team = team
	NetworkManager.player_table()[peer_id] = p
	return p


# --- The channel latch ---

func test_each_key_opens_its_own_channel() -> void:
	assert_eq(VoiceChat.pick_channel(NONE, false, true, true), ALL,
		"the all-talk key opens the everyone channel")
	assert_eq(VoiceChat.pick_channel(NONE, true, false, true), TEAM,
		"the team key opens the team channel")
	assert_eq(VoiceChat.pick_channel(NONE, false, false, true), NONE,
		"no key held is no channel")


## The whole point of two keys: what a stream was addressed to when it opened is what it stays
## addressed to. Grabbing the other key mid-sentence must not hand the rest of it to the enemy
## team, nor silently promote team talk to everyone.
func test_a_held_channel_is_not_redirected_by_the_other_key() -> void:
	assert_eq(VoiceChat.pick_channel(TEAM, true, true, true), TEAM,
		"an open team stream stays on the team while its own key is held")
	assert_eq(VoiceChat.pick_channel(ALL, true, true, true), ALL,
		"an open all-talk stream is not pulled onto the team channel")


func test_the_team_key_wins_when_both_are_pressed_from_silence() -> void:
	assert_eq(VoiceChat.pick_channel(NONE, true, true, true), TEAM,
		"both keys at once from silence is the narrower channel, not the wider one")


func test_releasing_the_key_closes_the_channel() -> void:
	assert_eq(VoiceChat.pick_channel(TEAM, false, false, true), NONE, "team key released")
	assert_eq(VoiceChat.pick_channel(ALL, false, false, true), NONE, "all-talk key released")


## A spectator (or anyone between teams) pressing team-talk has no recipients. It opens nothing,
## the way ServerRequests drops team text from a team-less sender — the alternative is a stream
## the player believes is private going out to the whole server.
func test_team_voice_needs_a_team() -> void:
	assert_eq(VoiceChat.pick_channel(NONE, true, false, false), NONE,
		"team voice with no team opens nothing")
	assert_eq(VoiceChat.pick_channel(NONE, true, true, false), ALL,
		"with no team the team key is not in the way of all-talk")
	assert_eq(VoiceChat.pick_channel(TEAM, true, false, false), NONE,
		"losing your team mid-sentence closes the stream rather than widening it")


# --- Who hears it ---

func test_a_talker_does_not_hear_themselves() -> void:
	_player_on(1, GameConsts.Team.BLUE)
	_player_on(2, GameConsts.Team.BLUE)
	var listeners := ServerRequests.voice_listeners(1, false)
	assert_eq(Array(listeners), [2], "the sender is never one of their own listeners")


func test_all_talk_reaches_every_team() -> void:
	_player_on(1, GameConsts.Team.BLUE)
	_player_on(2, GameConsts.Team.RED)
	_player_on(3, GameConsts.Team.NONE)
	var listeners := Array(ServerRequests.voice_listeners(1, false))
	listeners.sort()
	assert_eq(listeners, [2, 3], "all-talk reaches the other team and the spectators")


func test_team_voice_reaches_only_allies() -> void:
	_player_on(1, GameConsts.Team.BLUE)
	_player_on(2, GameConsts.Team.BLUE)
	_player_on(3, GameConsts.Team.RED)
	assert_eq(Array(ServerRequests.voice_listeners(1, true)), [2],
		"team voice stops at the team boundary")


func test_team_voice_follows_declared_alliances() -> void:
	_player_on(1, GameConsts.Team.BLUE)
	_player_on(2, GameConsts.Team.RED)
	GoalSystem.team_allies[GameConsts.Team.BLUE - 1] = 1 << (GameConsts.Team.RED - 1)
	assert_eq(Array(ServerRequests.voice_listeners(1, true)), [2],
		"an allied team hears team voice, the same as it reads team chat")


## Bots are in the roster and hold negative peer ids. An rpc_id to one goes nowhere, and relaying
## to them would spend the sender's budget on listeners that cannot listen.
func test_bots_are_not_listeners() -> void:
	_player_on(1, GameConsts.Team.BLUE)
	_player_on(-2, GameConsts.Team.BLUE)
	assert_eq(Array(ServerRequests.voice_listeners(1, true)), [],
		"a bot teammate is not relayed to")


func test_a_sender_with_no_player_reaches_nobody() -> void:
	_player_on(2, GameConsts.Team.BLUE)
	assert_eq(Array(ServerRequests.voice_listeners(99, false)), [],
		"a peer with no body in the roster has nothing to say through")


func test_team_voice_from_no_team_reaches_nobody() -> void:
	_player_on(1, GameConsts.Team.NONE)
	_player_on(2, GameConsts.Team.BLUE)
	assert_eq(Array(ServerRequests.voice_listeners(1, true)), [],
		"team voice from a team-less sender is dropped, not widened")
	assert_eq(Array(ServerRequests.voice_listeners(1, false)), [2],
		"the same sender still reaches everyone on all-talk")


# --- The budget ---

func test_the_budget_refuses_a_flood_then_refills() -> void:
	var peer := 7101
	VoiceChat._budgets.erase(peer)
	var spent := 0
	var ceiling := VoiceChat.BUDGET_BURST * 4
	while spent < ceiling and VoiceChat.budget_allows(peer, 256):
		spent += 256
	assert_lt(spent, ceiling, "a client spraying voice is cut off rather than relayed")
	assert_gt(spent, VoiceChat.BUDGET_BURST / 2, "a burst of real speech is not cut off early")
	# A second of silence, without making the suite sit through one: the bucket refills off the
	# clock, so winding its last-spend stamp back is the same thing — and unlike a few awaited
	# frames (which headless runs through in no time at all) it measures the refill rate itself.
	VoiceChat._budgets[peer]["ms"] = int(VoiceChat._budgets[peer]["ms"]) - 1000
	assert_true(VoiceChat.budget_allows(peer, VoiceChat.BUDGET_BYTES_PER_S / 2),
		"a second of quiet refills about a second's worth of talking")
	VoiceChat._budgets.erase(peer)


## The size cap is checked before the budget, so a peer cannot drain its own allowance (or the
## server's attention) with packets that were never going to be relayed.
func test_an_oversized_packet_is_refused_before_it_can_spend() -> void:
	var peer := 7102
	VoiceChat._budgets.erase(peer)
	var huge := PackedByteArray()
	huge.resize(ServerRequests.VOICE_MAX_PACKET + 1)
	for _i in 4:
		ServerRequests.voice(peer, VoiceChat.Kind.CHUNK, huge, false)
	assert_true(VoiceChat.budget_allows(peer, VoiceChat.BUDGET_BURST),
		"an oversized packet costs the sender nothing because it never got that far")
	VoiceChat._budgets.erase(peer)


# --- The wire ---

## Voice must stay on the unreliable channel: a retransmitted voice frame arrives after the word
## it belonged to, and the retransmit pressure is the thing goldnet exists to avoid.
func test_voice_rpcs_are_unreliable() -> void:
	var cfg: Dictionary = NetworkManager.get_script().get_rpc_config()
	for rpc_name in ["request_voice", "sync_voice"]:
		assert_true(cfg.has(rpc_name), "%s is no longer an @rpc; this test needs a new target" % rpc_name)
		assert_eq(cfg[rpc_name]["transfer_mode"], MultiplayerPeer.TRANSFER_MODE_UNRELIABLE,
			"%s must not be reliable" % rpc_name)
	assert_false(bool(cfg["sync_voice"]["call_local"]),
		"sync_voice is handed to the listen host by a direct call, so a local call here would double it")


# --- Playback gating ---

## A chunk is only decodable against the stream header that opened it. One arriving first (the
## header was lost, or this client joined mid-sentence) must not build a speaker, because
## TwoVoipSpeaker has no playback object to push it into until a header has configured one.
func test_a_chunk_before_the_header_opens_no_speaker() -> void:
	var peer := 7103
	VoiceChat.receive(peer, VoiceChat.Kind.CHUNK, PackedByteArray([1, 2, 3, 4]))
	assert_false(VoiceChat._speakers.has(peer), "no speaker is built for a mid-stream chunk")
	assert_false(VoiceChat.is_speaking(peer), "and nobody is shown as talking")


## A well-formed header is what builds the speaker a stream decodes into. Needs the extension —
## AudioStreamOpus is TwoVoIP's — so a build without it skips rather than failing.
func test_a_valid_header_opens_a_speaker() -> void:
	if not VoiceChat.available:
		return
	var peer := 7106
	VoiceChat.receive(peer, VoiceChat.Kind.HEADER, _header())
	assert_true(VoiceChat._speakers.has(peer), "a stream header opens a speaker for its talker")
	assert_true(VoiceChat.is_speaking(peer), "and its talker reads as speaking")
	VoiceChat.receive(peer, VoiceChat.Kind.FOOTER,
		JSON.stringify({"talkingtimeend": 1.0, "opusstreamcount": 0, "opusframecount": 1}).to_ascii_buffer())
	assert_false(VoiceChat.is_speaking(peer), "and stops when the stream closes")
	VoiceChat._close_speaker(peer)


## TwoVoipSpeaker decides what a packet is by looking for braces at both ends, not by what the
## wire called it — so a chunk carrying a stream header would configure a decoder if it got
## through. The rate and channel count in a header choose an allocation, and they come from
## another client.
func test_a_chunk_carrying_a_header_is_refused() -> void:
	var peer := 7107
	VoiceChat.receive(peer, VoiceChat.Kind.CHUNK, _header())
	assert_false(VoiceChat._speakers.has(peer), "a chunk shaped like a header opens no speaker")


func test_a_header_with_an_impossible_sample_rate_is_refused() -> void:
	var peer := 7108
	VoiceChat.receive(peer, VoiceChat.Kind.HEADER, _header(1 << 30))
	assert_false(VoiceChat._speakers.has(peer),
		"a rate Opus cannot decode never reaches the buffer that would be sized for it")
	VoiceChat.receive(peer, VoiceChat.Kind.HEADER, _header(48000, 9))
	assert_false(VoiceChat._speakers.has(peer), "nor does an impossible channel count")


## A stream header as VoiceChat sends one, with the parts a receiver checks spelled out.
func _header(sample_rate := 48000, channels := 1) -> PackedByteArray:
	return JSON.stringify({
		"opusframesize": 960, "opussamplerate": sample_rate, "opuschannels": channels,
		"lenchunkprefix": 2, "opusstreamcount": 0, "opusframecount": 0, "talkingtimestart": 0.0,
	}).to_ascii_buffer()


# --- Capture wiring ---

## The two mic signals ARE the transmit path: encoded frames come out of one, stream markers out
## of the other. Leaving them unconnected is silent — the microphone opens, the log says so, and
## not one packet ever leaves the machine — so it gets an assertion rather than a playtest.
func test_opening_the_microphone_wires_both_mic_signals() -> void:
	if not VoiceChat.available:
		return
	VoiceChat._start_capture()
	if VoiceChat._capture_blocked:
		VoiceChat._capture_blocked = false
		return  # no input device here; nothing to assert about a microphone that refused to open
	assert_true(VoiceChat._mic.is_connected("transmit_audio_packet", VoiceChat._on_mic_packet),
		"encoded frames reach the wire")
	assert_true(VoiceChat._mic.is_connected("transmit_audio_json_packet", VoiceChat._on_mic_control),
		"stream markers reach the wire, so a receiver is never left sniffing for braces")
	VoiceChat._stop_capture()
	assert_eq(VoiceChat._mic, null, "and closing it puts the microphone away")


# --- Settings ---

func test_volume_maps_to_decibels() -> void:
	assert_almost_eq(VoiceSettings.volume_to_db(100), 0.0, 0.001, "100% is the stream as encoded")
	assert_almost_eq(VoiceSettings.volume_to_db(0), -80.0, 0.001,
		"0% is silence, not linear_to_db(0)'s -INF, which an AudioStreamPlayer rejects")
	assert_lt(VoiceSettings.volume_to_db(50), 0.0, "half volume is quieter")
	assert_gt(VoiceSettings.volume_to_db(150), 0.0, "150% is louder")
	assert_eq(VoiceSettings.clamp_volume(400), VoiceSettings.VOLUME_MAX, "volume is capped")
	assert_eq(VoiceSettings.clamp_volume(-10), VoiceSettings.VOLUME_MIN, "and floored")
