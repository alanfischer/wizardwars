extends Node
## Can every map host a siege? Boots one, stands the arena up, and reports what it got.
##
##   godot --headless --path . res://src/tests/siege_arena_probe.tscn -- --server --map ww_2fort
##
## One line per map, so a shell loop over maps/ is the whole survey. The claim being checked is
## the one the plan makes — "auto-derive the arena on all 30 maps" — and the only honest way to
## check it is to try all 30.


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var tree := get_tree()
	var main: Node = load("res://src/main.tscn").instantiate()
	tree.root.add_child(main)
	tree.current_scene = main

	var waited := 0.0
	while waited < 240.0 and not bool(main.get("_game_active")):
		await tree.create_timer(1.0).timeout
		waited += 1.0
	var map_name := str(main.get("_current_map_name"))
	if not bool(main.get("_game_active")):
		print("ARENA %-16s FAIL  map never loaded" % map_name)
		tree.quit(1)
		return

	# SIEGE_PLAY=<seconds> drives the path a player actually uses — the replicated server var,
	# which is what /siege sets — rather than calling begin() directly, then hand-cranks a wave
	# and watches it walk. Headless derivation says the arena exists; only this says it plays.
	var play := float(OS.get_environment("SIEGE_PLAY")) if OS.has_environment("SIEGE_PLAY") else 0.0
	if play > 0.0:
		ServerVars.set_from_string("siege", "on")
	else:
		var err := SiegeSystem.begin()
		if not err.is_empty():
			print("ARENA %-16s FAIL  %s" % [map_name, err])
			tree.quit(1)
			return
	if not SiegeSystem.active:
		print("ARENA %-16s FAIL  siege did not start" % map_name)
		tree.quit(1)
		return

	# Where the altar STANDS and where monsters walk to are two different points on a map whose
	# objective is up a pedestal, and the probe has to report both or ww_golem looks misplaced.
	var stands: Vector3 = SiegeSystem.altar.global_position
	var spot: Vector3 = SiegeSystem.objective_position()
	var g = MonsterNav.graph(main)
	# Route length matters as much as route existence: an entry four metres from the altar is a
	# spawn in the defenders' lap, and one on the far side of the map is a walk nobody watches.
	var hops: Array[int] = []
	var dists: Array[float] = []
	for e in SiegeSystem.entries:
		dists.append(e.distance_to(spot))
		hops.append(g.path_ids(e, spot).size() if g != null else 0)
	var unreachable := hops.count(0)

	print("ARENA %-16s OK    altar %6.0f,%5.0f,%6.0f  walk-to %6.0f,%5.0f,%6.0f   entries %d   approach %.0f-%.0fm   unreachable %d"
			% [map_name, stands.x, stands.y, stands.z, spot.x, spot.y, spot.z, SiegeSystem.entries.size(),
			dists.min() if dists.size() > 0 else 0.0,
			dists.max() if dists.size() > 0 else 0.0, unreachable])

	if play > 0.0:
		if OS.has_environment("SIEGE_WATCH"):
			await _watch(tree, map_name, play)
		else:
			await _play(tree, map_name, spot, play)
	tree.quit(0)


## Watch the round run itself: phases, waves, altar health. SIEGE_PLAY is the seconds to watch.
## Unlike the hand-cranked version this spawns nothing — the point is that the scheduler does.
func _watch(tree: SceneTree, map_name: String, seconds: float) -> void:
	# Defenders, or no wave can ever be cleared and the round sits on wave 1 forever.
	var want := int(OS.get_environment("SIEGE_BOTS")) if OS.has_environment("SIEGE_BOTS") else 4
	while BotSystem._bots.size() < want:
		if BotSystem.add_bot(-1, SiegeSystem.defender_team) == 0:
			break
	print("WATCH %-14s %d defender(s)" % [map_name, BotSystem._bots.size()])
	var t := 0.0
	var last_phase := -1
	var last_wave := -1
	var next_report := 0.0
	var a := SiegeSystem.altar_node()
	while t < seconds and SiegeSystem.phase != SiegeSystem.Phase.WON \
			and SiegeSystem.phase != SiegeSystem.Phase.LOST:
		await tree.create_timer(1.0).timeout
		t += 1.0
		if SiegeSystem.phase != last_phase or SiegeSystem.wave != last_wave or t >= next_report:
			last_phase = SiegeSystem.phase
			last_wave = SiegeSystem.wave
			next_report = t + 20.0
			a = SiegeSystem.altar_node()
			var hp := float(a.get("health")) if a else -1.0
			# How close the nearest attacker has come: an altar at full health is either a wave
			# being killed on the approach or a wave that never arrived, and those are different.
			var near := INF
			for m in SiegeSystem._live:
				if is_instance_valid(m) and a:
					near = minf(near, m.global_position.distance_to(a.global_position))
			print("WAVE  %-14s t=%4.0fs  phase=%-5s wave=%d  live=%2d unspawned=%d  nearest %s  altar %.0f"
					% [map_name, t, SiegeSystem.Phase.keys()[SiegeSystem.phase],
					SiegeSystem.wave, SiegeSystem._live.size(), SiegeSystem._queue.size(),
					("%5.1fm" % near) if near < INF else "    -", hp])
	a = SiegeSystem.altar_node()
	print("DONE  %-14s phase=%s  reached wave %d of %d  altar %.0f"
			% [map_name, SiegeSystem.Phase.keys()[SiegeSystem.phase], SiegeSystem.wave,
			SiegeSystem.WAVE_COUNT, float(a.get("health")) if a else -1.0])


## Fire a wave and watch it. Reports how far the monsters got, which is the thing the arena is
## for — an approach nobody can walk is a derivation that passed and a siege that does not work.
func _play(tree: SceneTree, map_name: String, spot: Vector3, seconds: float) -> void:
	# SIEGE_MONSTER picks the kind, so each rostered monster can be asked the only question that
	# matters on its own: does it actually get there? A mixed wave would average the answers.
	var kind := OS.get_environment("SIEGE_MONSTER") if OS.has_environment("SIEGE_MONSTER") \
			else SiegeSystem.SKELETON
	# One at a time, which is how the scheduler does it — spawn_wave advances the entry cursor on
	# every call, so a wave is spread across the map's approaches rather than piled on the first
	# one. Asking for eight at once measures a single entry and calls it the map.
	var made := 0
	for _n in 8:
		made += SiegeSystem.spawn_wave(1, kind)
	# Whatever it just put in, by asking the siege rather than by matching a script name — the
	# roster is a mix now and "skeleton.gd" would silently track a fraction of a wave.
	var live: Array = SiegeSystem._live.duplicate()
	var start: Array[float] = []
	for n in live:
		start.append(_horiz(n.global_position - spot))

	var closest: Array[float] = start.duplicate()
	var t := 0.0
	while t < seconds:
		await tree.create_timer(0.5).timeout
		t += 0.5
		for i in live.size():
			if is_instance_valid(live[i]):
				closest[i] = minf(closest[i], _horiz(live[i].global_position - spot))

	var gained: Array[float] = []
	for i in live.size():
		gained.append(start[i] - closest[i])
	gained.sort()
	var reached := 0
	for c in closest:
		if c <= 6.0:
			reached += 1
	print("PLAY  %-16s %-12s spawned %d  tracked %d  closed median %.0fm best %.0fm  reached altar %d"
			% [map_name, kind.get_file().get_basename(), made, live.size(),
			gained[gained.size() / 2] if gained.size() > 0 else 0.0,
			gained.max() if gained.size() > 0 else 0.0, reached])


static func _horiz(v: Vector3) -> float:
	return Vector2(v.x, v.z).length()
