extends "res://src/tests/test_base.gd"
## Announcer de-duplication on a capture: a TFC dropoff fires both the generic score stinger and
## the goal's own speak keys, which used to run on separate queues and talk over each other. Both
## now ride SentenceSystem's announcer queue, and a goal whose speak keys already cover a
## listener group suppresses the stinger for that group.

const TFGoalBaseScript = preload("res://src/entities/tf_goal_base.gd")

const BOTH := GoalSystem.SPOKEN_FRIENDLY | GoalSystem.SPOKEN_ENEMY


func _make_goal(ent: Dictionary) -> Node:
	var g: Node3D = TFGoalBaseScript.new()
	_root().add_child(g)
	g._parse_tf_properties(ent)
	return g


func _drain_announcer() -> void:
	SentenceSystem._announce_queue.clear()
	if SentenceSystem._announcing:
		SentenceSystem._announcing.cancel()
	SentenceSystem._announcing = null


## The shipped CTF maps (ww_2fort, ww_wstland4, …) set all three tiers.
func test_ctf_dropoff_covers_every_listener() -> void:
	var g := _make_goal({
		"AP_speak": "!CTF_YOUCAP",
		"team_speak": "!CTF_TEAMCAP",
		"non_team_speak": "!CTF_THEYCAP",
	})
	assert_eq(g.speak_coverage(), BOTH, "all three tiers cover friend and foe")
	g.free()


## AP_speak only reaches the capturer — teammates fall through to an empty tier 1 and
## would hear nothing, so the stinger must still play for them.
func test_ap_speak_alone_leaves_teammates_uncovered() -> void:
	var g := _make_goal({"AP_speak": "!CTF_YOUCAP"})
	assert_eq(g.speak_coverage(), 0, "AP_speak alone claims no group")
	g.free()

	var g2 := _make_goal({"AP_speak": "!CTF_YOUCAP", "non_team_speak": "!CTF_THEYCAP"})
	assert_eq(g2.speak_coverage(), GoalSystem.SPOKEN_ENEMY, "enemies covered, friendlies not")
	g2.free()


func test_silent_goal_covers_nobody() -> void:
	var g := _make_goal({"netname": "quiet"})
	assert_eq(g.speak_coverage(), 0, "no speak keys — stinger carries the news")
	g.free()


## The bare "speak" key is the catch-all tier, so it covers everyone on its own.
func test_bare_speak_covers_every_listener() -> void:
	var g := _make_goal({"speak": "vox/doop you captured the enemy grail"})
	assert_eq(g.speak_coverage(), BOTH, "speak is the all-listeners tier")
	g.free()


## The overlap fix: a second announcer line waits its turn instead of starting on top
## of the first, whichever source it came from.
func test_announcer_lines_queue_instead_of_overlapping() -> void:
	_drain_announcer()
	SentenceSystem.play_words(["vox/flag.wav", "vox/captured.wav"])
	assert_true(SentenceSystem._announcing != null, "first line starts immediately")
	assert_eq(SentenceSystem._announce_queue.size(), 0, "nothing waiting yet")

	SentenceSystem.play_speak_global("!CTF_YOUCAP")
	assert_eq(SentenceSystem._announce_queue.size(), 1, "second line waits its turn")

	SentenceSystem.play_words(["vox/doop.wav"])
	assert_eq(SentenceSystem._announce_queue.size(), 2, "and so does a third")
	_drain_announcer()


## Map ambients are world sounds, not announcements — a looping PLAY_EVERYWHERE
## ambient on the announcer queue would wedge it forever.
func test_ambient_sentences_bypass_the_announcer_queue() -> void:
	_drain_announcer()
	var pb = SentenceSystem.play_global("CTF_YOUCAP")
	assert_true(pb != null, "ambient plays immediately and returns its handle")
	assert_eq(SentenceSystem._announce_queue.size(), 0, "ambient never enters the queue")
	assert_true(SentenceSystem._announcing == null, "ambient does not own the announcer slot")
	pb.cancel()
	_drain_announcer()


## ww_roc2 carries keycards; its announcer says "key captured", not "flag captured".
func test_item_word_follows_the_model() -> void:
	var item: Node3D = preload("res://src/entities/item_tfgoal.gd").new()
	item.ent = {"mdl": "models/keycard.mdl"}
	assert_eq(item.vox_word(), "key", "keycard is a key")
	item.ent = {"mdl": "models/flag.mdl"}
	assert_eq(item.vox_word(), "flag", "flag stays a flag")
	item.free()


## ww_roc2's key-return goals speak to the owner and everyone else themselves, so the
## generic "returned" stinger stays quiet.
func test_return_goal_speaks_to_everyone() -> void:
	var g := _make_goal({"owned_by": "1", "owners_team_speak": "!RK_KEYBACK",
		"non_team_speak": "!RK_EKEYBACK"})
	assert_true(g.speaks_without_activator(), "owner and non-team tiers cover a return")
	g.free()
	var quiet := _make_goal({"owners_team_speak": "!RK_KEYBACK"})
	assert_false(quiet.speaks_without_activator(), "other teams would hear nothing")
	quiet.free()
