extends Node
# SentenceSystem — GoldSrc speech-system sentences (sounds/sentences.txt).
#
# Format, per line:  NAME word word(p120) hgrunt/word!, (t30) word ...
#   * Words resolve against a running directory, default "vox/"; a token
#     containing '/' switches the directory for itself and later words.
#   * (…) blocks carry parameters: pNN pitch (100 = normal), vNN volume %,
#     sNN start %, eNN end %, tNN time-compression %. Attached to a word they
#     affect that word; standalone they set defaults for the rest of the line.
#     Time compression is parsed but not applied (needs DSP; GoldSrc squashed
#     silence out of the word — we play the word as-is).
#   * ',' and '.' (standalone or trailing a word) insert short pauses.
#   * Names sharing a base with trailing digits (HG_GREN0..6) form a group;
#     resolving the base name picks a random member, avoiding immediate repeats.
#
# Playback is LOCAL — no RPCs here. Map-driven sentences (ambient_generic) ride
# the entity's own "playing" state sync, so every peer plays its own copy.

# Approximations of the GoldSrc VOX pause lengths, in seconds.
const PAUSE_COMMA := 0.15
const PAUSE_PERIOD := 0.35

# name -> Array of items; each item is {path, pitch?, volume?, start?, end?, time?}
# for a word or {pause: seconds} for a gap.
var _sentences: Dictionary = {}
var _groups: Dictionary = {}          # base name -> Array[String] member names
var _last_group_pick: Dictionary = {} # base name -> last index (no immediate repeat)

# Sentences still speaking. A Playback is a RefCounted whose word chain hangs off
# signal callbacks, and a Callable doesn't keep its object alive — without holding
# them here, a caller that drops the handle (nearly every one) frees the Playback
# after the first word and the rest of the sentence never plays.
var _active: Array = []


func _ready() -> void:
	var text := _load_file()
	if text.is_empty():
		Log.info("[Sentences] no sentences.txt found")
		return
	_parse(text)
	Log.info("[Sentences] %d sentences, %d groups" % [_sentences.size(), _groups.size()])
	ClientCommandSystem.register("sentence", _cmd_sentence,
		"/sentence <NAME>", "Play a sentences.txt entry (debug).")


func has_sentence(sentence_name: String) -> bool:
	sentence_name = sentence_name.trim_prefix("!").to_upper()
	return _sentences.has(sentence_name) or _groups.has(sentence_name)


## Resolve a sentence (or group) name to its word/pause item list. Group names
## pick a random member. Returns [] when unknown.
func resolve(sentence_name: String) -> Array:
	sentence_name = sentence_name.trim_prefix("!").to_upper()
	if _sentences.has(sentence_name):
		return _sentences[sentence_name]
	if _groups.has(sentence_name):
		var members: Array = _groups[sentence_name]
		var pick := randi() % members.size()
		if members.size() > 1 and pick == int(_last_group_pick.get(sentence_name, -1)):
			pick = (pick + 1) % members.size()
		_last_group_pick[sentence_name] = pick
		return _sentences[members[pick]]
	return []


## Warm the word wav cache for a sentence, or for every member of a group.
func precache(sentence_name: String) -> void:
	sentence_name = sentence_name.trim_prefix("!").to_upper()
	var names: Array = _groups.get(sentence_name, [sentence_name] if _sentences.has(sentence_name) else [])
	for n in names:
		for item in _sentences.get(n, []):
			if item.has("path"):
				SoundSystem.precache(item.path)


## Speak a sentence from 3D players attached to `parent` (an entity). Returns a
## Playback handle (call .cancel() to cut it off) or null for unknown names.
func play_on(parent: Node3D, sentence_name: String, base_volume_db := 0.0, base_pitch := 1.0,
		max_dist := 25.0, unit_size := 12.0) -> Playback:
	return _start(resolve(sentence_name), parent, base_volume_db, base_pitch, max_dist, unit_size)


## Speak a sentence non-positionally (PLAY_EVERYWHERE ambients, debug).
func play_global(sentence_name: String, base_volume_db := 0.0, base_pitch := 1.0) -> Playback:
	return _start(resolve(sentence_name), null, base_volume_db, base_pitch, 0.0, 0.0)


# Goal "speak" sentences and the score/flag word stingers are both announcer lines, and
# a capture fires both at once — queue them so they read out one after the other instead
# of talking over each other. Map ambients (play_on/play_global) are world sounds and
# stay immediate; a looping PLAY_EVERYWHERE ambient would wedge this queue forever.
var _announce_queue: Array = []   # item lists waiting their turn
var _announcing: Playback = null


## Queue a TFC goal "speak" value. "!NAME" plays a registered sentence; anything
## else is an ad-hoc word stream in sentences.txt syntax ("ambience/bell bell bell",
## "you have the enemy key" → vox words). Also the authority's RPC into one client,
## for an announcement only that player hears.
@rpc("authority", "call_remote", "reliable")
func play_speak_global(spec: String) -> void:
	_enqueue_announce(resolve(spec) if spec.begins_with("!") else _parse_words(spec))


## Queue a plain word list (["vox/flag.wav", "vox/captured.wav"]) as one announcer line.
func play_words(paths: Array) -> void:
	_enqueue_announce(paths.map(func(p): return {"path": String(p)}))


func _enqueue_announce(items: Array) -> void:
	if items.is_empty():
		return
	_announce_queue.append(items)
	_pump_announce()


func _pump_announce() -> void:
	if _announcing != null or _announce_queue.is_empty():
		return
	# Map change / shutdown teardown — drop the backlog rather than spin through it.
	var tree := get_tree() if is_inside_tree() else null
	var scene := tree.current_scene if tree else null
	if scene == null or not scene.is_inside_tree():
		_announce_queue.clear()
		return
	_announcing = _start(_announce_queue.pop_front(), null, 0.0, 1.0, 0.0, 0.0)
	if _announcing == null:
		_pump_announce()  # nothing playable in that line — move on


func _start(items: Array, parent: Node3D, base_volume_db: float, base_pitch: float,
		max_dist: float, unit_size: float) -> Playback:
	if items.is_empty():
		return null
	var pb := Playback.new()
	pb.sys = self
	pb.items = items
	pb.parent = parent
	pb.base_volume_db = base_volume_db
	pb.base_pitch = base_pitch
	pb.max_dist = max_dist
	pb.unit_size = unit_size
	_active.append(pb)
	pb.advance()
	return pb


## Drop a finished/cancelled sentence. Deferred: the call comes from inside the
## Playback's own method, and _active often holds its last reference.
func _retire(pb: Playback) -> void:
	_active.erase(pb)
	if pb == _announcing:
		_announcing = null
		_pump_announce()


func _cmd_sentence(args: String) -> void:
	var sentence_name := args.strip_edges()
	if sentence_name.is_empty() or not has_sentence(sentence_name):
		ClientCommandSystem.reply_err("Unknown sentence: '%s'" % sentence_name)
		return
	play_global(sentence_name)
	ClientCommandSystem.reply_ok("sentence: %s" % sentence_name.to_upper())


func _load_file() -> String:
	for path in ["res://sounds/sentences.txt",
			AssetLoader.RESOURCE_DIR + "/sounds/sentences.txt"]:
		if FileAccess.file_exists(path):
			var f := FileAccess.open(path, FileAccess.READ)
			if f:
				# get_string_from_ascii: the stock file has stray high-bit bytes
				# that make it invalid UTF-8.
				return f.get_buffer(f.get_length()).get_string_from_ascii()
	return ""


func _parse(text: String) -> void:
	for raw_line in text.split("\n"):
		var line := raw_line.strip_edges()
		if line.is_empty() or line.begins_with("//"):
			continue
		line = line.replace("\t", " ")
		var sp := line.find(" ")
		if sp < 0:
			continue
		var sentence_name := line.substr(0, sp).to_upper()
		var items := _parse_words(line.substr(sp + 1))
		if items.is_empty():
			continue
		_sentences[sentence_name] = items
		var base := sentence_name.rstrip("0123456789")
		if base != sentence_name and not base.is_empty():
			if not _groups.has(base):
				_groups[base] = []
			_groups[base].append(sentence_name)


func _parse_words(stream: String) -> Array:
	# Mappers write goal "speak" values like message text, trailing the escape they end
	# every printed line with: "vox/buzwarn blue team captured\n". That is a separator
	# here, not part of a word — left on, the last word resolves to vox/captured\n.wav
	# (which the loader sanitizes to vox/captured/n.wav) and silently drops.
	stream = stream.replace("\\n", " ").replace("\n", " ").replace("\r", " ").replace("\t", " ")
	# Tokenize on spaces, but keep (...) blocks atomic — parameter lists may
	# contain spaces ("freeman!(t20 p105),").
	var tokens: Array[String] = []
	var cur := ""
	var depth := 0
	for ch in stream:
		if ch == "(":
			depth += 1
		elif ch == ")":
			depth = maxi(depth - 1, 0)
		if ch == " " and depth == 0:
			if not cur.is_empty():
				tokens.append(cur)
			cur = ""
		else:
			cur += ch
	if not cur.is_empty():
		tokens.append(cur)

	var items: Array = []
	var dir := "vox/"
	var defaults := {}
	for tok in tokens:
		# Pull out (...) parameter blocks wherever they sit in the token.
		var params := {}
		while true:
			var open := tok.find("(")
			if open < 0:
				break
			var close := tok.find(")", open)
			if close < 0:  # malformed — drop the rest of the token
				tok = tok.substr(0, open)
				break
			_parse_params(tok.substr(open + 1, close - open - 1), params)
			tok = tok.substr(0, open) + tok.substr(close + 1)
		# Trailing punctuation becomes pauses after the word. '!' is emphasis the
		# recording already carries, so it just falls off the filename — GoldSrc writes
		# the same word both ways ("got!" / "got") against one wav.
		var pauses: Array = []
		while tok.ends_with(",") or tok.ends_with(".") or tok.ends_with("!"):
			if not tok.ends_with("!"):
				pauses.push_front(PAUSE_COMMA if tok.ends_with(",") else PAUSE_PERIOD)
			tok = tok.substr(0, tok.length() - 1)
		# A '/' switches the running directory for this and later words.
		var slash := tok.rfind("/")
		if slash >= 0:
			dir = tok.substr(0, slash + 1)
			tok = tok.substr(slash + 1)
		if tok.is_empty():
			# Bare directory switch and/or standalone parameter block:
			# fold params into the running defaults for later words.
			defaults.merge(params, true)
		else:
			# GoldSrc VOX lookups are case-insensitive, but sentence text carries mixed
			# case ("The") while the converted wavs are all lowercase — normalize the path.
			var item := {"path": (dir + tok + ".wav").to_lower()}
			item.merge(defaults)      # line defaults where not set
			item.merge(params, true)  # attached params win
			items.append(item)
		items.append_array(pauses.map(func(p): return {"pause": p}))
	return items


func _parse_params(s: String, out: Dictionary) -> void:
	for part in s.split(" ", false):
		var p := String(part)
		var val := p.substr(1).to_int()
		match p[0]:
			"p": out["pitch"] = val
			"v": out["volume"] = val
			"s": out["start"] = val
			"e": out["end"] = val
			"t": out["time"] = val  # parsed, not applied (see header)


## One in-flight sentence: spawns an audio player per word, chained on
## tree_exited (survives map unloads mid-word), with timers for pauses.
class Playback:
	extends RefCounted

	var sys: Node               # SentenceSystem, for tree/timer access
	var items: Array
	var parent: Node3D          # 3D attach point; null = non-positional
	var base_volume_db := 0.0
	var base_pitch := 1.0
	var max_dist := 25.0
	var unit_size := 12.0
	var _idx := 0
	var _current: Node = null
	var _cancelled := false

	func cancel() -> void:
		if _cancelled:
			return
		_cancelled = true
		if is_instance_valid(_current):
			_current.queue_free()
		_current = null
		_retire()

	# Hand the last reference back to the system, one frame out — see
	# SentenceSystem._retire.
	func _retire() -> void:
		if is_instance_valid(sys):
			sys._retire.call_deferred(self)

	func advance() -> void:
		if _cancelled:
			return
		_current = null
		# is_inside_tree() first: an autoload is pulled out of the tree before it is
		# freed, and get_tree() on a detached node errors instead of just returning null.
		var tree := sys.get_tree() if is_instance_valid(sys) and sys.is_inside_tree() else null
		if tree == null:  # shutdown teardown — drop the rest of the line
			_cancelled = true
			_retire()
			return
		while _idx < items.size():
			var item: Dictionary = items[_idx]
			_idx += 1
			if item.has("pause"):
				tree.create_timer(item.pause).timeout.connect(advance)
				return
			var stream: AudioStream = SoundSystem._get_or_load(item.path)
			if stream == null:
				continue  # missing word wav (legacy HL asset) — skip it
			var player := _make_player()
			if player == null:  # attach point gone — abort the sentence
				_cancelled = true
				_retire()
				return
			player.stream = stream
			player.pitch_scale = clampf(base_pitch * item.get("pitch", 100) / 100.0, 0.01, 2.55)
			player.volume_db = base_volume_db + linear_to_db(clampf(item.get("volume", 100) / 100.0, 0.01, 1.0))
			player.finished.connect(player.queue_free)
			player.tree_exited.connect(advance)
			_current = player
			var length: float = stream.get_length()
			var start_pct: int = item.get("start", 0)
			var end_pct: int = item.get("end", 100)
			player.play(length * start_pct / 100.0 if start_pct > 0 else 0.0)
			if end_pct < 100:
				# Cut the word early; freeing fires tree_exited, which advances.
				# Captured by id, not by node: a cancel (or a short word) can free the
				# player first, and a freed lambda capture is an error, not a null.
				var stop_after: float = maxf(length * (end_pct - start_pct) / 100.0, 0.05) / player.pitch_scale
				var player_id := player.get_instance_id()
				tree.create_timer(stop_after).timeout.connect(func():
					var p := instance_from_id(player_id)
					if p != null:
						p.queue_free())
			return
		_retire()  # sentence complete

	func _make_player() -> Node:
		if parent != null:
			if not is_instance_valid(parent) or not parent.is_inside_tree():
				return null
			var p := AudioStreamPlayer3D.new()
			p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_LOGARITHMIC
			p.max_distance = max_dist
			p.unit_size = unit_size
			p.bus = SoundSystem.EFFECTS_BUS
			parent.add_child(p)
			return p
		if not is_instance_valid(sys) or not sys.is_inside_tree():
			return null
		var scene := sys.get_tree().current_scene
		if scene == null or not scene.is_inside_tree():
			return null
		var p2 := AudioStreamPlayer.new()
		p2.bus = SoundSystem.EFFECTS_BUS
		scene.add_child(p2)
		return p2
