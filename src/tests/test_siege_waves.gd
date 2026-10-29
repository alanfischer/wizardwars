extends "res://src/tests/test_base.gd"
## The wave table is the mode's difficulty curve, so the queue built from it has to say exactly
## what the table says — and say it in an order worth watching.
##
## The drip is one monster every SPAWN_INTERVAL, so a wave queued kind by kind would send eleven
## skeletons and then, twenty seconds later, the spirits — two fights rather than one. The
## interleave is the whole reason _wave_queue exists rather than a pair of nested loops.
##
## Scene-run only (needs the SiegeSystem autoload): res://src/tests/run_tests.tscn.


func _counts(queue: Array) -> Dictionary:
	var out := {}
	for path in queue:
		out[path] = int(out.get(path, 0)) + 1
	return out


func test_every_wave_queues_exactly_what_the_table_says() -> void:
	for n in range(1, SiegeSystem.WAVE_COUNT + 1):
		var want := {}
		var total := 0
		for entry: Array in SiegeSystem.WAVES[n - 1]:
			want[entry[0]] = int(entry[1])
			total += int(entry[1])
		var queue := SiegeSystem._wave_queue(n)
		assert_eq(queue.size(), total, "wave %d should queue %d monsters" % [n, total])
		assert_eq(_counts(queue), want, "wave %d should queue the kinds the table lists" % n)


func test_the_wave_gets_bigger() -> void:
	var last := 0
	for n in range(1, SiegeSystem.WAVE_COUNT + 1):
		var size := SiegeSystem._wave_queue(n).size()
		assert_gt(size, last - 1, "wave %d must not be smaller than wave %d" % [n, n - 1])
		last = size
	assert_gt(last, SiegeSystem._wave_queue(1).size(),
		"the last wave has to be a step up from the first or there is no curve")


## The interleave. A kind holding k of n slots must not be queued as one unbroken block —
## measured as the span from its first slot to its last, which for a block is exactly k.
func test_each_kind_is_spread_across_its_wave() -> void:
	for n in range(1, SiegeSystem.WAVE_COUNT + 1):
		var queue := SiegeSystem._wave_queue(n)
		if SiegeSystem.WAVES[n - 1].size() < 2:
			continue   # a single-kind wave has nothing to interleave
		for path in _counts(queue):
			var first := queue.find(path)
			var last := queue.rfind(path)
			var count := int(_counts(queue)[path])
			if count <= 1:
				continue
			assert_gt(last - first + 1, count,
				"wave %d queues %s as one block — the drip would deliver it as its own fight" % [n, path])


## Every monster in the table must be one that will actually cross a map. A monster with no
## `objective` holds its ground where it spawned, so adding one to a wave is a silent no-op that
## looks like a pathing bug.
func test_every_rostered_monster_takes_an_objective() -> void:
	var seen := {}
	for row: Array in SiegeSystem.WAVES:
		for entry: Array in row:
			seen[entry[0]] = true
	for path in seen:
		var script: GDScript = load(path)
		assert_true(script != null, "%s should load" % path)
		if script == null:
			continue
		var m = script.new()
		assert_true("objective" in m,
			"%s is in the wave table but has no `objective` — it would stand where it spawned" % path)
		m.free()
