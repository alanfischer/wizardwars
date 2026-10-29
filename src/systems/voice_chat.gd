extends Node

## Push-to-talk voice chat on two keys: voice_all reaches everyone, voice_team only the allied
## wizards. TwoVoIP (addons/twovoip, MIT) does the audio — Opus, RNNoise, AGC and a per-speaker
## jitter buffer — and this owns the game's half of it: when the microphone is open, which channel
## a stream went out on, and one speaker node per talking peer. Who hears a packet is
## ServerRequests.voice, next to the same team test chat uses; the wire is NetworkManager.
##
## The channel is latched when a stream opens and held until that key comes back up, so swapping
## keys mid-sentence cannot redirect audio already in flight — the half-sentence a listener keeps
## would otherwise be the half they were never meant to hear.
##
## Everything rides the unreliable channel, which is what TwoVoIP is built for: a lost frame is a
## click in a word, not retransmit pressure on the stream goldnet exists to keep clear. The cost
## is that losing a stream's header would orphan the whole sentence behind it, so the markers that
## open and close a stream are sent MARKER_COPIES times back to back, and a receiver holding no
## header drops chunks rather than feeding a speaker with nothing to decode them into.
##
## libtwovoip is optional exactly like libgoldnet: a client without it logs once and plays on in
## silence, so a missing binary costs voice and not the session. Nothing here may NAME a TwoVoIP
## class, because the helper scripts do — which is why their scenes are load()ed on demand rather
## than preloaded, and why the denoiser and AGC modes below are written as the numbers they are.

const VoiceSettings = preload("res://src/systems/voice_settings.gd")
const KeyBindings = preload("res://src/systems/key_bindings.gd")

const MIC_SCENE := "res://addons/twovoip/voiphelper/two_voip_mic.tscn"
const SPEAKER_SCENE := "res://addons/twovoip/voiphelper/two_voip_speaker.tscn"

## Voice gets a bus of its own so its volume is one setting rather than per-speaker arithmetic,
## and so it stays out of the World bus's reverb — a teammate's voice is in your ear, not in the
## room with you.
const VOICE_BUS := &"Voice"

## RNNoise only runs on mono 48 kHz in multiples of 480 samples, so the rate, the channel count
## and the frame length are its requirements rather than preferences (initialize() refuses
## anything else). 24 kbit/s of voice-optimized Opus is around 50 bytes per 20 ms frame, so one
## talker costs a listener ~2.5 KB/s.
const OPUS_SAMPLE_RATE := 48000
const OPUS_FRAME_MS := 20
const OPUS_CHANNELS := 1
const OPUS_BITRATE := 24000
const OPUS_COMPLEXITY := 5

## TwovoipOpusEncoder.DENOISER_RNNOISE and AGC_APPLIED as plain numbers: naming the class would
## make this script fail to parse on a client whose libtwovoip is missing, which is the one case
## the fallback exists for.
const DENOISER_RNNOISE := 2
const AGC_APPLIED := 1

## How much of the stream a speaker holds before playing it, trading mouth-to-ear delay against
## gaps when a packet is late. TwoVoIP defaults to 0.6 s, which is built for radio rather than for
## people calling targets at each other.
const LAG_TARGET_S := 0.25
const LAG_TOLERANCE_S := 0.15

## Copies of each stream marker. The header is the one packet whose loss costs a whole sentence
## rather than a click, and the footer's loss leaves a listener's buffer waiting out
## SPEAKER_TIMEOUT_S — while a ~100 byte marker costs less than two frames of audio. They go out
## back to back rather than spread over the stream: TwoVoIP treats a repeat as a mid-stream header
## and clears its reorder queue, which is free before any chunk has been sent and a swallowed
## 60 ms of someone's voice once a sentence is under way.
##
## What this does not buy is a listener who arrives mid-sentence; they pick the talker up on the
## next one.
const MARKER_COPIES := 3

## No packet for this long and the speaker is told the stream ended, so its buffer drains instead
## of holding the tail of a sentence the network ate.
const SPEAKER_TIMEOUT_S := 0.5

## Channels, and the action that opens each one.
enum Channel { NONE, ALL, TEAM }
const ACTIONS := {Channel.ALL: &"voice_all", Channel.TEAM: &"voice_team"}

## Chunk is one Opus frame; header and footer are TwoVoIP's JSON stream markers. The kind is on
## the wire so a receiver never has to guess from the bytes which one it has.
enum Kind { CHUNK, HEADER, FOOTER }

## What a stream header is allowed to say, checked before TwoVoIP acts on it (see _packet_ok).
## The rates are Opus's own; the braces are how TwoVoipSpeaker recognises a marker.
const HEADER_SAMPLE_RATES := [8000, 12000, 16000, 24000, 48000]
const BRACE_OPEN := 0x7B
const BRACE_CLOSE := 0x7D

## A token bucket per sender, so no client can hand the server more voice than it could possibly
## be speaking. The budget lives here because server_requests.gd is stateless by design, and it
## works with or without libtwovoip — a server relays bytes, it never decodes them.
const BUDGET_BYTES_PER_S := 8192
const BUDGET_BURST := 16384

## True when libtwovoip answered; false leaves the client silent but playable.
var available := false

## What the keys are asking for right now, and what the open (or most recent) stream actually went
## out on. They differ for the frame a key is released on, which is the frame TwoVoIP emits the
## footer — that footer belongs to the stream, not to the silence after it.
var channel := Channel.NONE
var _tx_channel := Channel.NONE

var _enabled := true
var _volume := VoiceSettings.DEFAULT_VOLUME
var _mic: Node = null
var _mic_on: Button = null
var _ptt: Button = null
var _vox: Button = null
var _mix_rate := 0.0

## Set when capture is impossible on this machine (no input device, no scene, an encoder that
## refused the configuration). Playback is unaffected, and nothing retries every frame.
var _capture_blocked := false

var _speakers := {}  # peer -> { player, speaker, silence: float, streaming: bool }
var _muted := {}     # peer -> true
var _budgets := {}   # peer -> { tokens: float, ms: int }


func _ready() -> void:
	# Before the availability check: a dedicated server relays voice for its players whether or
	# not it could ever play any, and the budgets it keeps have to be dropped with the peer.
	NetworkManager.peer_disconnected.connect(_on_peer_disconnected)

	_enabled = VoiceSettings.load_enabled()
	_volume = VoiceSettings.load_volume()
	available = ClassDB.class_exists(&"TwovoipOpusEncoder")
	if not available:
		set_process(false)
		Log.warn("voice: libtwovoip is missing from the game folder — voice chat is off")
		return
	_ensure_voice_bus()
	_register_commands()


## The Voice bus, routed straight to Master. SoundSystem builds the World bus the same way, for
## the same reason: a bus the game owns cannot be assumed to exist in default_bus_layout.tres.
func _ensure_voice_bus() -> void:
	if AudioServer.get_bus_index(VOICE_BUS) != -1:
		return
	var idx := AudioServer.bus_count
	AudioServer.add_bus(idx)
	AudioServer.set_bus_name(idx, VOICE_BUS)
	AudioServer.set_bus_send(idx, &"Master")


func _process(delta: float) -> void:
	_update_capture()
	if _mic:
		_update_mix_rate()
		_update_ptt()
	_update_speakers(delta)
	_update_hud()


# --- Capture ---

## The microphone is open for exactly as long as this client is in a live session with voice on —
## deliberately NOT "has a body". It stays open between sentences rather than opening per
## keypress: TwoVoIP's lead time captures the moment before the key went down, which is the
## difference between "go left" and "o left", and device activation is far too slow to put in
## front of a keypress.
##
## Nor does it close across a map change, even though the local player goes with the map. macOS
## asks for microphone permission when a process opens an input device, and the grant does not
## reliably persist for a bundle whose code signature does not verify — which ours does not, the
## export template's signature being left in place over an inserted pck. Reopening per map turned
## that into a permission prompt per map on the rotation. Whether to talk is the channel latch's
## question (_wanted_channel needs a body); whether the device is open is this one.
func _update_capture() -> void:
	var want := _enabled and not _capture_blocked and NetworkManager.is_online()
	if want == (_mic != null):
		return
	if want:
		_start_capture()
	else:
		_stop_capture()


func _start_capture() -> void:
	var devices := AudioServer.get_input_device_list()
	if devices.is_empty() or devices[0] != "Default":
		# TwoVoipMic.init_voip_mic asserts on exactly this shape, and an assert takes the frame
		# down rather than the microphone — so a machine with no usable input device is refused
		# here instead, and can still hear everyone else.
		Log.warn("voice: no usable audio input device — this client can listen but not talk")
		_capture_blocked = true
		return
	var scene: PackedScene = load(MIC_SCENE)
	if scene == null:
		Log.warn("voice: %s is missing — this client can listen but not talk" % MIC_SCENE)
		_capture_blocked = true
		return
	_mic = scene.instantiate()
	# Connected by name rather than through the member, which a Node-typed reference cannot see:
	# the encoded frames come out of one signal and the stream markers out of the other, and that
	# split is what puts the kind on the wire instead of leaving a receiver to sniff for braces.
	_mic.connect("transmit_audio_packet", _on_mic_packet)
	_mic.connect("transmit_audio_json_packet", _on_mic_control)
	# Deliberately not in the tree: they are the switches init_voip_mic wants to read, not UI.
	_mic_on = _toggle(true)
	_ptt = _toggle(false)
	_vox = _toggle(false)  # the keys are the gate, not the room's noise floor
	add_child(_mic)
	# init_voip_mic opens the input device (and asks Android for RECORD_AUDIO), and opening it is
	# what settles the mix rate the encoder resamples from — so it runs BEFORE set_opus_values,
	# with the mic's own _process held off until the encoder it reads through exists.
	_mic.init_voip_mic(false, _mic_on, null, _ptt, _vox, null)
	_mic.set_process(false)
	if not _configure_encoder():
		Log.warn("voice: Opus encoder refused %d Hz/%d ms — this client can listen but not talk" % [
				OPUS_SAMPLE_RATE, OPUS_FRAME_MS])
		_capture_blocked = true
		_stop_capture()
		return
	_ptt.toggle_mode = true  # init_voip_mic clears this when Vox is off; the keys drive it instead
	_mic.set_process(true)
	Log.info("voice: microphone open (%s, %.0f Hz in, Opus %d kbit/s mono, %d ms frames)" % [
			AudioServer.input_device, _mix_rate, int(OPUS_BITRATE / 1000.0), OPUS_FRAME_MS])


func _stop_capture() -> void:
	if _mic:
		_mic.queue_free()
		_mic = null
	for button in [_mic_on, _ptt, _vox]:
		if button:
			button.queue_free()
	_mic_on = null
	_ptt = null
	_vox = null
	channel = Channel.NONE
	_tx_channel = Channel.NONE
	AudioServer.set_input_device_active(false)


func _configure_encoder() -> bool:
	_mix_rate = AudioServer.get_input_mix_rate()
	return bool(_mic.set_opus_values(OPUS_SAMPLE_RATE, OPUS_FRAME_MS, OPUS_CHANNELS, OPUS_BITRATE,
			OPUS_COMPLEXITY, true, DENOISER_RNNOISE, AGC_APPLIED))


## An input device can come up at a different rate than it was listed at — Android grants
## RECORD_AUDIO after the fact, a desktop player swaps headsets mid-game — and an encoder
## resampling from a rate the device no longer runs at garbles every word. One comparison a frame
## is cheap enough to just do.
func _update_mix_rate() -> void:
	var rate := AudioServer.get_input_mix_rate()
	if is_equal_approx(rate, _mix_rate):
		return
	Log.info("voice: input mix rate %.0f -> %.0f Hz, rebuilding the encoder" % [_mix_rate, rate])
	# set_opus_values only rebuilds when an Opus setting changed, and none of them did: the input
	# rate is read but not compared. Dropping the encoder is what makes it reinitialize.
	_mic.opusencoder = null
	if not _configure_encoder():
		_capture_blocked = true
		_stop_capture()


func _update_ptt() -> void:
	var want := _wanted_channel()
	if want == channel:
		return
	channel = want
	if channel != Channel.NONE:
		_tx_channel = channel  # held through the footer, and until the next stream opens
	_ptt.button_pressed = channel != Channel.NONE


func _wanted_channel() -> VoiceChat.Channel:
	var hud := Game.hud
	# A key is only held if it can mean anything: not while someone is typing (then it is a
	# letter), not behind the pause panel (a key being rebound there is not a call), and not
	# without a body to talk through (the lobby, or mid map change — the
	# microphone stays open across those, but nothing goes out).
	var held: bool = Game.local_player != null and not (hud != null and hud.is_chat_open()) \
			and not LobbyUI.pause_open
	return pick_channel(channel,
			held and Input.is_action_pressed(ACTIONS[Channel.TEAM]),
			held and Input.is_action_pressed(ACTIONS[Channel.ALL]),
			_has_team())


## Which channel is open, given the one already open, the two keys and whether this player has a
## team at all. Pure, and static, so the latch can be read back in a test without a microphone or
## a keyboard — it is the rule the whole feature rests on.
##
## A held channel wins over the other key: a stream cannot change who it is addressed to
## mid-sentence. From silence the team key wins, so someone holding both never broadcasts what
## they meant for the team — and with no team to talk to, that key does nothing at all, the way
## ServerRequests drops team text from a team-less sender.
static func pick_channel(current: VoiceChat.Channel, team_held: bool, all_held: bool, has_team: bool) -> VoiceChat.Channel:
	# Team voice with no team has no recipients, so that key counts as not held at all: it opens
	# nothing, and it does not sit on top of all-talk either.
	var team := team_held and has_team
	if current == Channel.TEAM and team:
		return Channel.TEAM
	if current == Channel.ALL and all_held:
		return Channel.ALL
	if team:
		return Channel.TEAM
	if all_held:
		return Channel.ALL
	return Channel.NONE


func _has_team() -> bool:
	var player := Game.local_player
	return player != null and player.team != GameConsts.Team.NONE


func _on_mic_packet(packet: PackedByteArray) -> void:
	_send(Kind.CHUNK, packet)


## TwoVoIP hands the stream header and footer over as dictionaries (json_packets_as_binary is
## false), so the kind is known without sniffing the bytes for braces — which is what lets a
## receiver gate chunks on having seen a header.
func _on_mic_control(control: Dictionary) -> void:
	var kind := Kind.HEADER if control.has("talkingtimestart") else Kind.FOOTER
	var bytes := JSON.stringify(control).to_ascii_buffer()
	for _i in MARKER_COPIES:
		_send(kind, bytes)


func _send(kind: int, packet: PackedByteArray) -> void:
	if _tx_channel == Channel.NONE or packet.is_empty():
		return
	NetworkManager.send_voice_packet(kind, packet, _tx_channel == Channel.TEAM)


# --- Playback ---

## One packet the server relayed to this client. Here rather than in NetworkManager because what
## becomes of a voice packet is audio, not wire.
func receive(sender_peer: int, kind: int, packet: PackedByteArray) -> void:
	if not available or not _enabled or _muted.has(sender_peer):
		return
	if not _packet_ok(kind, packet):
		return
	var entry: Dictionary = _speakers.get(sender_peer, {})
	if entry.is_empty():
		if kind != Kind.HEADER:
			return  # mid-stream: nothing to decode a chunk into until a header says how
		entry = _open_speaker(sender_peer)
	entry["silence"] = 0.0
	if kind == Kind.HEADER:
		entry["streaming"] = true
	entry["speaker"].receive_audio_packet(packet)
	if kind == Kind.FOOTER:
		entry["streaming"] = false


## A stream header is the one packet from another client that configures a decoder and the buffer
## behind it — TwoVoipSpeaker hands AudioStreamOpus whatever rate the sender wrote — so the values
## that choose an allocation are checked before they get there.
##
## The kinds are checked against the bytes as well, because TwoVoipSpeaker decides what a packet
## is by looking for braces at both ends, not by what the wire called it: a chunk shaped like JSON
## would be read as a header no matter what `kind` said. Refusing those costs a real Opus frame
## about once in 65536 (frame 123 ending in a closing brace), which is a click nobody can hear.
func _packet_ok(kind: int, packet: PackedByteArray) -> bool:
	var json_shaped: bool = packet.size() > 3 \
			and packet[0] == BRACE_OPEN and packet[-1] == BRACE_CLOSE
	if kind == Kind.CHUNK:
		return not json_shaped
	if not json_shaped:
		return false
	var parsed = JSON.parse_string(packet.get_string_from_ascii())
	if typeof(parsed) != TYPE_DICTIONARY:
		return false
	var marker: Dictionary = parsed
	if kind == Kind.FOOTER:
		return marker.has("talkingtimeend") and not marker.has("talkingtimestart")
	if not marker.has("talkingtimestart"):
		return false
	return HEADER_SAMPLE_RATES.has(int(marker.get("opussamplerate", 0))) \
			and int(marker.get("opuschannels", 0)) in [1, 2] \
			and int(marker.get("lenchunkprefix", -1)) == 2


func _open_speaker(peer_id: int) -> Dictionary:
	var player := AudioStreamPlayer.new()
	player.name = "Voice%d" % peer_id
	player.bus = VOICE_BUS
	player.volume_db = VoiceSettings.volume_to_db(_volume)
	add_child(player)
	var speaker: Node = (load(SPEAKER_SCENE) as PackedScene).instantiate()
	speaker.audio_buffer_lag_time_target = LAG_TARGET_S
	speaker.audio_buffer_lag_time_target_tolerance = LAG_TOLERANCE_S
	player.add_child(speaker)  # TwoVoipSpeaker puts its AudioStreamOpus on its parent, so order matters
	var entry := {"player": player, "speaker": speaker, "silence": 0.0, "streaming": false}
	_speakers[peer_id] = entry
	return entry


func _update_speakers(delta: float) -> void:
	for peer_id in _speakers:
		var entry: Dictionary = _speakers[peer_id]
		entry["silence"] += delta
		if entry["streaming"] and entry["silence"] > SPEAKER_TIMEOUT_S:
			# The footer was lost, or the talker dropped mid-sentence: let the jitter buffer drain
			# rather than hold the tail of the sentence forever.
			entry["streaming"] = false
			entry["speaker"].external_end_stream()
	# A map change rebuilds every player, so the speakers have to go with them: a stream that
	# survived the change would be decoding into a buffer the next map has no talker for.
	if Game.local_player == null and not _speakers.is_empty():
		_close_speakers()


func _close_speaker(peer_id: int) -> void:
	var entry = _speakers.get(peer_id)
	if entry == null:
		return
	entry["player"].queue_free()  # the TwoVoipSpeaker is its child and goes with it
	_speakers.erase(peer_id)


func _close_speakers() -> void:
	for peer_id in _speakers.keys():
		_close_speaker(peer_id)


func is_speaking(peer_id: int) -> bool:
	var entry = _speakers.get(peer_id)
	return entry != null and entry["streaming"]


func _on_peer_disconnected(peer_id: int) -> void:
	_close_speaker(peer_id)
	_budgets.erase(peer_id)


func _update_hud() -> void:
	var hud := Game.hud
	if hud == null:
		return
	var talkers := PackedStringArray()
	for peer_id in _speakers:
		if is_speaking(peer_id):
			talkers.append(NetworkManager.display_name(peer_id))
	var label := ""
	if channel == Channel.TEAM:
		label = "TEAM"
	elif channel == Channel.ALL:
		label = "ALL"
	hud.set_voice_status(label, talkers)


# --- Server side ---

## Whether `peer_id` may spend `bytes` of relay on voice right now. A client sending at the rate
## it is configured for spends about 2.5 KB/s, so the bucket refills three times faster than that
## and still refuses a peer trying to push audio at the lobby as fast as the link allows.
func budget_allows(peer_id: int, bytes: int) -> bool:
	var now := Time.get_ticks_msec()
	var entry: Dictionary = _budgets.get(peer_id, {"tokens": float(BUDGET_BURST), "ms": now})
	_budgets[peer_id] = entry
	var elapsed_s := (now - int(entry["ms"])) * 0.001
	entry["tokens"] = minf(BUDGET_BURST, float(entry["tokens"]) + elapsed_s * BUDGET_BYTES_PER_S)
	entry["ms"] = now
	if float(entry["tokens"]) < bytes:
		return false
	entry["tokens"] = float(entry["tokens"]) - bytes
	return true


# --- Settings, and the commands that reach them ---

func is_enabled() -> bool:
	return _enabled


func set_enabled(enabled: bool) -> void:
	if enabled == _enabled:
		return
	_enabled = enabled
	VoiceSettings.save_enabled(enabled)
	if not enabled:
		_close_speakers()
		_capture_blocked = false  # a refusal from last time shouldn't outlive being switched off


func volume() -> int:
	return _volume


func set_volume(percent: int) -> void:
	_volume = VoiceSettings.clamp_volume(percent)
	VoiceSettings.save_volume(_volume)
	var db := VoiceSettings.volume_to_db(_volume)
	for peer_id in _speakers:
		_speakers[peer_id]["player"].volume_db = db


func _toggle(pressed: bool) -> Button:
	var button := Button.new()
	button.toggle_mode = true  # init_voip_mic asserts on this for the mic and vox switches
	button.button_pressed = pressed
	return button


func _register_commands() -> void:
	ClientCommandSystem.register("voice", _cmd_voice, "/voice [on|off|<volume 0-150>]",
			"Voice chat: hold a key to talk. Shows who is bound to what, and the volume.")
	ClientCommandSystem.register("mute", _cmd_mute, "/mute <player>",
			"Stop hearing one player's voice. Lasts for this session.")
	ClientCommandSystem.register("unmute", _cmd_unmute, "/unmute <player|all>",
			"Hear a muted player again.")


func _cmd_voice(args: String) -> void:
	args = args.strip_edges().to_lower()
	if args == "on" or args == "off":
		set_enabled(args == "on")
		ClientCommandSystem.reply_ok("Voice chat %s." % ("on" if _enabled else "off"))
		return
	if args.is_valid_int():
		set_volume(int(args))
		ClientCommandSystem.reply_ok("Voice volume %d%%." % _volume)
		return
	if not args.is_empty():
		ClientCommandSystem.reply_err("Usage: /voice [on|off|<volume 0-150>]")
		return
	ClientCommandSystem.reply_ok("Voice chat %s at %d%%: hold %s for everyone, %s for your team." % [
			"on" if _enabled else "off", _volume,
			KeyBindings.display_for("voice_all"), KeyBindings.display_for("voice_team")])
	if not available:
		ClientCommandSystem.reply_err("libtwovoip is missing from the game folder, so voice is off.")
	elif _capture_blocked:
		ClientCommandSystem.reply_err("No usable microphone, so this client can listen but not talk.")
	if not _muted.is_empty():
		var names := PackedStringArray()
		for peer_id in _muted:
			names.append(NetworkManager.display_name(peer_id))
		ClientCommandSystem.reply_ok("Muted: " + ", ".join(names))


func _cmd_mute(args: String) -> void:
	var peer_id := _resolve_peer(args)
	if peer_id == 0:
		ClientCommandSystem.reply_err("No such player: %s" % args)
		return
	_muted[peer_id] = true
	_close_speaker(peer_id)
	ClientCommandSystem.reply_ok("Muted %s." % NetworkManager.display_name(peer_id))


func _cmd_unmute(args: String) -> void:
	if args.strip_edges().to_lower() == "all":
		_muted.clear()
		ClientCommandSystem.reply_ok("Nobody is muted.")
		return
	var peer_id := _resolve_peer(args)
	if peer_id == 0 or not _muted.has(peer_id):
		ClientCommandSystem.reply_err("Not muted: %s" % args)
		return
	_muted.erase(peer_id)
	ClientCommandSystem.reply_ok("Unmuted %s." % NetworkManager.display_name(peer_id))


## A player by name (case-insensitively, and by prefix so a long name can be typed short) or by
## peer id. 0 for no match, which no peer ever is.
func _resolve_peer(args: String) -> int:
	var text := args.strip_edges()
	if text.is_empty():
		return 0
	if text.is_valid_int():
		var id := int(text)
		return id if NetworkManager.has_player_name(id) else 0
	var wanted := text.to_lower()
	for peer_id in NetworkManager.player_roster():
		var display := NetworkManager.display_name(peer_id).to_lower()
		if display == wanted or display.begins_with(wanted):
			return peer_id
	return 0
