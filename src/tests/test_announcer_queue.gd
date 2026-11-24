extends "res://src/tests/test_base.gd"
## Goal speak lines share SentenceSystem's announcer queue: a capture can fire several at
## once (the dropoff's line, the flag's return goal), and they read out in turn.


func _drain_announcer() -> void:
	SentenceSystem._announce_queue.clear()
	if SentenceSystem._announcing:
		SentenceSystem._announcing.cancel()
	SentenceSystem._announcing = null


## A second announcer line waits its turn instead of starting on top of the first.
func test_announcer_lines_queue_instead_of_overlapping() -> void:
	_drain_announcer()
	SentenceSystem.play_speak_global("!CTF_YOUCAP")
	assert_true(SentenceSystem._announcing != null, "first line starts immediately")
	assert_eq(SentenceSystem._announce_queue.size(), 0, "nothing waiting yet")

	SentenceSystem.play_speak_global("!RK_KEYBACK")
	assert_eq(SentenceSystem._announce_queue.size(), 1, "second line waits its turn")

	SentenceSystem.play_speak_global("your key has returned")
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
