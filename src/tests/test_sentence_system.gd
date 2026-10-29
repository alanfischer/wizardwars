extends "res://src/tests/test_base.gd"
## SentenceSystem parser tests. Lookups run against the real sounds/sentences.txt; the syntax
## cases feed _parse_words the forms GoldSrc sentence files use.
##
## References the SentenceSystem autoload, so it must run via the scene runner, not `-s`.


func test_simple_sentence() -> void:
	# DOOP vox/doop
	assert_true(SentenceSystem.has_sentence("DOOP"), "DOOP exists")
	var items: Array = SentenceSystem.resolve("DOOP")
	assert_eq(items.size(), 1, "single word")
	assert_eq(items[0].path, "vox/doop.wav")


func test_lookup_strips_bang_and_case() -> void:
	# ambient_generic references arrive as "!name"
	assert_true(SentenceSystem.has_sentence("!doop"))
	assert_eq(SentenceSystem.resolve("!doop")[0].path, "vox/doop.wav")


func test_directory_prefix_persists() -> void:
	var items: Array = SentenceSystem._parse_words("monster/skeleton/skwait(p120) skfollow! skwait")
	assert_eq(items.size(), 3)
	assert_eq(items[0].path, "monster/skeleton/skwait.wav")
	assert_eq(items[0].pitch, 120, "attached (p120)")
	assert_eq(items[1].path, "monster/skeleton/skfollow.wav", "dir persists; trailing '!' is emphasis, not filename")
	assert_false(items[1].has("pitch"), "attached params are per-word")
	assert_eq(items[2].path, "monster/skeleton/skwait.wav")


func test_standalone_block_sets_line_defaults() -> void:
	var items: Array = SentenceSystem._parse_words("vox/(t30) doop red!(e75) team!(s5) doop")
	assert_eq(items.size(), 4, "bare 'vox/(t30)' emits no word")
	for it in items:
		assert_eq(it.time, 30, "standalone t30 applies to every later word")
	assert_eq(items[1].end, 75)
	assert_eq(items[2].start, 5)
	assert_eq(items[1].path, "vox/red.wav", "'!' comes off even with params attached")


func test_bang_is_stripped_without_a_pause() -> void:
	# ww_feudal: speak "Good!" — the '!' is not part of the word, and unlike ',' / '.'
	# it adds no pause.
	var items: Array = SentenceSystem._parse_words("Good!")
	assert_eq(items.size(), 1, "no pause item")
	assert_eq(items[0].path, "vox/good.wav")
	# Mixed punctuation still pauses on the ',' underneath.
	var mixed: Array = SentenceSystem._parse_words("hostiles!,")
	assert_eq(mixed.size(), 2)
	assert_eq(mixed[0].path, "vox/hostiles.wav")
	assert_eq(mixed[1].pause, SentenceSystem.PAUSE_COMMA)


func test_pauses_and_attached_override() -> void:
	var items: Array = SentenceSystem._parse_words("vox/(t30) enemy!, team!(e80) has!(e80) flag!(t20 p105), doop(p110)")
	assert_eq(items.size(), 7, "5 words + 2 comma pauses")
	assert_eq(items[0].path, "vox/enemy.wav", "the '!' before the comma comes off too")
	assert_true(items[1].has("pause"), "trailing comma becomes a pause")
	assert_eq(items[2].end, 80)
	assert_eq(items[4].path, "vox/flag.wav")
	assert_eq(items[4].pitch, 105)
	assert_eq(items[4].time, 20, "attached t20 overrides the line default t30")
	assert_true(items[5].has("pause"))
	assert_eq(items[6].pitch, 110)


func test_groups() -> void:
	# CZ_GOTCP1..CZ_GOTCP5 form the CZ_GOTCP group
	assert_true(SentenceSystem.has_sentence("CZ_GOTCP"), "group name resolves")
	assert_eq((SentenceSystem._groups["CZ_GOTCP"] as Array).size(), 5)
	for i in 8:
		assert_false(SentenceSystem.resolve("CZ_GOTCP").is_empty(), "group pick %d" % i)
	# Exact member lookup bypasses the group pick
	assert_eq(SentenceSystem.resolve("CZ_GOTCP2")[2].path, "vox/two.wav")


## The two skeleton lines the mod ships. sentences.txt named them `skeleton/...`, but the wavs
## ship under `monster/skeleton/` — so as written neither line had a file behind it. The paths
## are corrected in the data; this pins them to something that is actually on disk.
func test_mod_sentences_present() -> void:
	for name in ["SK_FOLLOW", "SK_WAIT"]:
		var items: Array = SentenceSystem.resolve(name)
		assert_true(items.size() > 0, "%s is defined" % name)
		assert_true(AssetLoader.load_sound(items[0].path) != null,
			"%s -> %s is on disk" % [name, items[0].path])
	assert_eq(SentenceSystem.resolve("SK_FOLLOW")[0].path, "monster/skeleton/skfollow.wav")
	assert_eq(SentenceSystem.resolve("SK_WAIT")[0].path, "monster/skeleton/skwait.wav")


func test_map_sentences_have_every_word_on_disk() -> void:
	# The four lines written for ww_library/ww_pushed (football) and ww_roc2 (key return):
	# each was referenced by a map long before it was defined here.
	for name in ["FBALL_BSCORE", "FBALL_RSCORE", "RK_KEYBACK", "RK_EKEYBACK"]:
		var items: Array = SentenceSystem.resolve(name)
		assert_true(items.size() > 0, "%s is defined" % name)
		for it in items:
			assert_ne(AssetLoader.load_sound(it.path), null, "%s: %s loads" % [name, it.path])


func test_speak_key_escape_is_a_separator() -> void:
	# ww_december: "speak" "vox/buzwarn blue team captured\n" — mappers end the value with
	# the same escape they end printed messages with. Left on the last word it became
	# vox/captured\n.wav (sanitized to vox/captured/n.wav) and never loaded.
	var items: Array = SentenceSystem._parse_words("vox/buzwarn blue team captured\\n")
	assert_eq(items.size(), 4, "four words, no empty trailing token")
	assert_eq(items[0].path, "vox/buzwarn.wav")
	assert_eq(items[3].path, "vox/captured.wav", "the escape is stripped from the last word")


func test_sound_alias_resolves_digit_words() -> void:
	# sounds/aliases.txt points the digit spellings at the word wavs, so "point 3 secured"
	# and "point three secured" both play without shipping the file twice.
	assert_eq(AssetLoader.resolve_sound_alias("vox/3.wav"), "vox/three.wav")
	assert_eq(AssetLoader.resolve_sound_alias("VOX/3.WAV"), "vox/three.wav", "lookup is case-insensitive")
	assert_eq(AssetLoader.resolve_sound_alias("vox/three.wav"), "vox/three.wav", "a real file is left alone")
	assert_ne(AssetLoader.load_sound("vox/3.wav"), null, "and the alias actually loads")


func test_unknown_sentence() -> void:
	assert_false(SentenceSystem.has_sentence("WW_NO_SUCH"))
	assert_eq(SentenceSystem.resolve("WW_NO_SUCH").size(), 0)


func test_playback_spawns_player() -> void:
	assert_eq(SentenceSystem.play_global("WW_NO_SUCH"), null, "unknown name → null handle")
	var pb = SentenceSystem.play_global("DOOP")
	assert_ne(pb, null, "known name → playback handle")
	var found := false
	for child in SentenceSystem.get_tree().current_scene.get_children():
		if child is AudioStreamPlayer:
			found = true
	assert_true(found, "first word spawned a player on the scene")
	pb.cancel()


func test_playback_outlives_dropped_handle() -> void:
	# The word chain hangs off signal callbacks, and a Callable holds no reference to
	# its object: every caller that discards the handle (goal speak keys, /sentence)
	# used to free the Playback after its first word.
	var pb = SentenceSystem.play_global("CZ_GOTCP3")
	var id: int = pb.get_instance_id()
	pb = null
	assert_true(is_instance_id_valid(id), "sentence survives the caller dropping it")
	instance_from_id(id).call("cancel")


func test_sentence_plays_every_word() -> void:
	# CZ_GOTCP3: "command point three secured" — the ww_monoliths capture announcer.
	var tree := Engine.get_main_loop() as SceneTree
	var scene := tree.current_scene
	var items: Array = SentenceSystem.resolve("CZ_GOTCP3")
	assert_eq(items.size(), 4, "four words")
	var seen := {}
	for c in scene.get_children():  # ignore players the earlier tests left behind
		if c is AudioStreamPlayer:
			seen[c.get_instance_id()] = true
	var ignored := seen.size()
	SentenceSystem.play_global("CZ_GOTCP3")
	var deadline := Time.get_ticks_msec() + 10000
	while not SentenceSystem._active.is_empty() and Time.get_ticks_msec() < deadline:
		await tree.process_frame
		for c in scene.get_children():
			if c is AudioStreamPlayer:
				seen[c.get_instance_id()] = true
	assert_eq(seen.size() - ignored, items.size(), "every word got its own player")
