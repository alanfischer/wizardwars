extends Node
## Siege — co-op PvE. Monsters come in waves for an altar the wizards defend.
##
## Phase 2 of the plan: the arena. This owns where the altar stands, where attackers come in, and
## the faction arrangement that makes every wizard an ally and every monster an enemy. The waves
## themselves are Phase 3; `/siege on` today sets the board up and leaves it standing.
##
## Server-authoritative. Clients are told the mode is on (so the HUD can say so) and receive the
## altar as an ordinary replicated entity; nothing about the arena itself crosses the wire, which
## is why none of this needs a cache bump or a map transfer.

const SiegeAltarScript = preload("res://src/entities/siege_altar.gd")

## Monsters get their own side. Any team that is not a playing one would do; GREEN is the last
## slot and no shipped map fields four teams.
const MONSTER_TEAM := GameConsts.Team.GREEN
## Closer than this to the altar and a start is not an approach at all. The only filter on the
## enemy spawns, since the map chose where those go.
const ENTRY_MIN_M := 20.0
## Only used by the graph fallback below, for maps whose own starts cannot reach the altar.
const ENTRY_IDEAL_M := 55.0
const ENTRY_COUNT := 5
const ENTRY_REGION_SPREAD := 18.0
## Nodes the graph fallback will route-test before giving up. One A* per node over a 5k-node
## graph is cheap; a whole map's worth of them, once per approach probe, is not — and a sweep
## that has tried this many without a route is not about to find one.
const ENTRY_PROBE_LIMIT := 2500
## How far the altar may be dropped onto the floor under its spot. An objective's origin is not
## its feet — ww_ravine's grail floats half a metre over its room — and a crystal planted at that
## height is a crystal through the ceiling. Short on purpose: this corrects a floating origin, it
## does not relocate an altar off ww_golem's six-metre pedestal.
const MAX_ALTAR_DROP_M := 1.5
## Nothing is treated as a ceiling further up than this; above it the altar has all the room it
## could want and is left at full size.
const MAX_HEADROOM_M := 12.0
## How far below an entry to look for the floor a wave will land on. Generous: a spawn a storey
## up is still a usable entry once it is brought down to the ground under it.
const MAX_ENTRY_DROP := 30.0
## How far the altar may be moved to find walkable ground under it before the spot is rejected
## outright. A flag on a ledge or across water can be a long way from anything a monster can
## stand on, and an altar snapped that far is no longer the landmark it was chosen for.
const MAX_ALTAR_SNAP_M := 10.0
## How many walkable spots near an altar are tried as its approach before the altar spot itself is
## given up on, and how far apart they must be.
##
## The nearest node is not always one a walker can get TO. Baked edges are DIRECTED
## (WaypointGraph.load_generated connects them one-way), so a courtyard you drop into and climb
## out of by ladder has out-edges and no in-edges once the walkable filter has taken the ladder
## away — which is exactly ww_golem's crystal pit, and why the crystal lost to the spawn room.
## Probing a spread of spots around the altar finds the first with a real route in.
const APPROACH_TRIES := 12
const APPROACH_SPREAD := 3.0

## Altar placement preference, best first. See _altar_candidates.
enum Tier { FIXTURE, GRAIL, CAP, ZONE, SPAWN }
const _TIER_NAMES := ["base crystal", "grail", "capture point", "control zone", "spawn"]

signal state_changed(active: bool)

## Phase 3's clock. OFF is "no siege"; the rest is one round of it.
enum Phase { OFF, BUILD, WAVE, WON, LOST }

## The roster. Each is a monster that has an `objective` it will cross a map for; a monster
## without one holds its ground where it spawned and never reaches the altar.
const SKELETON := "res://src/monsters/skeleton.gd"
const SPIRIT := "res://src/monsters/spirit_wiz.gd"
const WOMBAT := "res://src/monsters/wombat.gd"

## What each wave is made of, in order — one row per wave, spelled out rather than rolled from a
## formula with weights, because tuning a wave should mean editing the row you are looking at.
## Totals run 5, 7, 9, 11, 13, 15, 17, 20.
##
## The shape of the escalation, not just the size of it:
## - **Skeletons** walk and throw. They are the wave, and the first two are nothing else, so the
##   map is learned before it gets complicated.
## - **Spirits** fly, so walls and ledges do not slow them and they arrive with the skeletons
##   rather than behind them. 600 HP of pressure that cannot be held at a doorway.
## - **Wombats** leap. 1000 HP each and they come late, two or three at a time — the thing that
##   breaks a line that has learned to hold one.
const WAVES: Array[Array] = [
	[[SKELETON, 5]],
	[[SKELETON, 7]],
	[[SKELETON, 7], [SPIRIT, 2]],
	[[SKELETON, 9], [SPIRIT, 2]],
	[[SKELETON, 9], [SPIRIT, 2], [WOMBAT, 2]],
	[[SKELETON, 11], [SPIRIT, 3], [WOMBAT, 1]],
	[[SKELETON, 11], [SPIRIT, 4], [WOMBAT, 2]],
	[[SKELETON, 13], [SPIRIT, 4], [WOMBAT, 3]],
]
## Derived, so the table above is the single place a wave is added or removed. A static var
## rather than a const because a const initialiser has to fold at parse time and `.size()` does
## not; every caller still reads it as SiegeSystem.WAVE_COUNT.
static var WAVE_COUNT := WAVES.size()
const BUILD_FIRST := 15.0       # breathing room to find the altar before anything arrives
const BUILD_SECONDS := 20.0     # between waves: respawn, regroup, watch the next one come in
const SPAWN_INTERVAL := 1.1     # seconds between monsters inside one wave
## What the altar gets back at each break. Not a full heal: a wave that got through should still
## be costing something by the end of the round.
const BREAK_HEAL_FRACTION := 0.08

var active := false
var phase: Phase = Phase.OFF
var wave := 0                   # 1-based once a wave is running
var phase_end_ms := 0           # absolute server time the BUILD phase ends
var altar: Node3D = null
## Where monsters walk to. Usually the altar's own feet; on a map whose objective stands on a
## pedestal or a ledge it is the nearest ground a walker can reach, and the last few metres are
## the monster's own business (the skeleton throws from where it can stand).
var approach := Vector3.INF
var entries: PackedVector3Array = PackedVector3Array()
## The team the wizards defend for. Whoever is on it keeps their own colour; the other playing
## teams are allied to it for the duration (see _ally_the_players).
var defender_team := GameConsts.Team.BLUE

var _saved_allies: Array[int] = []
var _allied := false
var _wave_cursor := 0
var _shown_phase: Phase = Phase.OFF   # what _present has already announced
var _shown_wave := -1
## The arena's graph component, resolved once per begin(). -2 is "not asked yet": working it out
## costs a component_sizes() and a full node sweep, and begin() asks for it once per approach
## probe and again per entry derivation — two dozen times on a map with several candidates.
var _arena_comp := -2
var _live: Array = []           # monsters of the current wave still standing
## What is left of this wave to put in, one script path per monster, in arrival order. A queue
## rather than a count because a wave is a mix now — see WAVES and _wave_queue.
var _queue: Array[String] = []
var _spawn_t := 0.0


func _ready() -> void:
	ServerVars.value_changed.connect(_on_server_var_changed)


# --- public API ----------------------------------------------------------

## Stand the arena up on the current map. Returns "" on success, or why it could not.
func begin() -> String:
	if active:
		return "Siege is already running."
	if not Game.game_active:
		return "No active map."
	if not NetworkManager.is_authority():
		return "Only the server starts a siege."

	_arena_comp = -2
	var candidates := _altar_candidates()
	if candidates.is_empty():
		return "This map has nowhere to put an altar (no goals and no spawn points)."
	# The first spot something can actually walk to. A beautiful altar nobody can reach is a
	# siege that cannot be lost, which is worse than an altar in the second-best room.
	# Two passes. The first asks only the map's own starts, which is a couple of dozen route
	# tests per probe; the second falls back to picking approach points off the graph, which is
	# hundreds. Running the cheap question against every candidate before the expensive one
	# against any keeps a map with a dozen approach probes from taking minutes to set up.
	var spot := Vector3.INF
	for allow_fallback in [false, true]:
		for pair: Array in candidates:
			entries = _derive_entries(pair[1], allow_fallback)
			if entries.is_empty():
				continue
			spot = pair[0]
			approach = pair[1]
			break
		if spot != Vector3.INF:
			break
	if spot == Vector3.INF:
		return "No monster approach to any altar spot on this map — nothing could reach it."

	_ally_the_players()
	var footing := _footing(spot)
	spot = footing[0]
	altar = NetworkManager.spawn_dynamic_entity({
		"script_path": "res://src/entities/siege_altar.gd",
		"position": spot,
		"headroom": footing[1],
		"team": defender_team,
		"sync_state": true,
	})
	if altar == null:
		_restore_allies()
		return "Could not spawn the altar."
	# The round wipe frees every dynamic entity, which is right for leftover monsters at a wave
	# break and fatal for the thing they are attacking. See NetworkManager.destroy_all_dynamic_entities.
	altar.set_meta("_persist_round", true)
	active = true
	wave = 0
	_live.clear()
	_queue.clear()
	_enter_build(BUILD_FIRST)
	state_changed.emit(true)
	Log.info("[Siege] altar at %.0f,%.0f,%.0f — %d entry point(s)" % [spot.x, spot.y, spot.z, entries.size()])
	return ""


func end() -> void:
	if not active:
		return
	active = false
	phase = Phase.OFF
	wave = 0
	_free_live()
	_broadcast()
	if is_instance_valid(altar):
		altar.queue_free()
	altar = null
	approach = Vector3.INF
	entries = PackedVector3Array()
	_restore_allies()
	state_changed.emit(false)
	Log.info("[Siege] over")


## The altar, on either peer. The host holds it directly; a client finds the replica by group.
func altar_node() -> Node3D:
	if is_instance_valid(altar):
		return altar
	var found := get_tree().get_nodes_in_group(SiegeAltarScript.GROUP)
	return found[0] if not found.is_empty() else null


## Where the attackers are headed, for a monster with nothing in sight. INF when no siege is up.
## The approach rather than the altar: an altar on a pedestal has no standable ground under it,
## and a route to a place nothing can stand is a route that ends in a wall.
func objective_position() -> Vector3:
	if not is_instance_valid(altar):
		return Vector3.INF
	return approach if approach != Vector3.INF else altar.global_position


## A spot to bring a wave in at. Round-robin so successive spawns use different approaches.
func entry_point(index: int) -> Vector3:
	if entries.is_empty():
		return Vector3.INF
	return entries[index % entries.size()]


## Put `count` monsters of one kind in, one per entry point, pointed at the altar. Returns how
## many stood up.
##
## The scheduler calls this one monster at a time off the wave queue; `/siege_wave [n]` calls it
## with a count, which is the hand crank for seeing whether an approach is any good.
##
## One monster per entry, the cursor stepping per monster rather than per call. A wave used to be
## spread around its entry on a 1-3 m ring, which put monsters on ground nobody had checked: a
## spawn room is smaller than the ring, so the points past its walls found no floor to stand on
## and the monster was left in the air to fall through to whatever was below. That is what the
## skeletons walking around under ww_2fort's spawn room were. The entries need no such help --
## they are the map's own starts, standable by construction, and there are a dozen of them on a
## two-base map.
func spawn_wave(count: int, script_path := SKELETON) -> int:
	if not active:
		return 0
	if entries.is_empty():
		return 0
	var made := 0
	for _i in count:
		var at := entry_point(_wave_cursor)
		_wave_cursor += 1
		var m := NetworkManager.spawn_dynamic_entity({
			"script_path": script_path,
			"position": at,
			"team": MONSTER_TEAM,
			# A summon is a spell that wears off; an attacker is not. The wombat and the spirit
			# both have one (40 s and 30 s), and either would expire mid-approach on a map whose
			# entries are a hundred metres out. 0 = forever; a monster with no lifetime at all
			# ignores the key.
			"lifetime": 0.0,
		})
		if m == null:
			continue
		# A base's team doors are keyed to the playing teams, and a monster is on none of them.
		# Without this the wave walks as far as the first door and stops. See FuncDoorBase._check_team.
		m.set_meta(GameConsts.META_IGNORES_TEAM_DOORS, true)
		if "objective" in m:
			m.objective = objective_position()
		_live.append(m)
		made += 1
	return made


## True while the dead should stay dead — see RemotePlayer._host_respawn. Dying in a wave costs
## you the rest of it; the break is what the break is for.
func holds_respawn() -> bool:
	return active and phase == Phase.WAVE


func reset() -> void:
	# Map unload frees the altar with the scene; drop the references and the alliance with it.
	active = false
	phase = Phase.OFF
	wave = 0
	_live.clear()
	altar = null
	approach = Vector3.INF
	entries = PackedVector3Array()
	_arena_comp = -2   # component ids belong to one map's graph; never carry one across a load
	_restore_allies()


# --- the round ------------------------------------------------------------

## Host tick, from main's server block beside BotSystem.tick.
func tick(delta: float) -> void:
	if not active or not NetworkManager.is_authority():
		return
	# The altar is the lose condition and nothing else needs checking first.
	if not is_instance_valid(altar) or bool(altar.get("is_dead")):
		_finish(false)
		return
	match phase:
		Phase.BUILD:
			if _now_ms() >= phase_end_ms:
				_enter_wave()
		Phase.WAVE:
			_tick_wave(delta)
		_:
			pass


func _tick_wave(delta: float) -> void:
	# Drip the wave in rather than dropping it whole: a pile spawned on one tick walks as one body
	# and shoves itself into the nearest wall.
	if not _queue.is_empty():
		_spawn_t -= delta
		if _spawn_t <= 0.0:
			_spawn_t = SPAWN_INTERVAL
			if spawn_wave(1, _queue[0]) > 0:
				_queue.remove_at(0)
	for i in range(_live.size() - 1, -1, -1):
		var m = _live[i]
		if not is_instance_valid(m) or bool(m.get("is_dead")) or _lost(m):
			_live.remove_at(i)
	if _queue.is_empty() and _live.is_empty():
		_clear_wave()


func _enter_build(seconds: float) -> void:
	phase = Phase.BUILD
	phase_end_ms = _now_ms() + int(seconds * 1000.0)
	_broadcast()


func _enter_wave() -> void:
	wave += 1
	_queue = _wave_queue(wave)
	_spawn_t = 0.0
	_live.clear()
	phase = Phase.WAVE
	_broadcast()


## Has this monster left the map? If so it is freed, because a wave ends when the last of it is
## dead and something falling forever is neither dead nor arriving.
##
## Players are caught centrally by main._kill_players_out_of_world; free NPCs never have been,
## which did not matter while every summon expired on its own timer. A siege attacker has no
## timer (see spawn_wave), so this is the backstop that replaces it. Measured on ww_2fort: two
## monsters of a four-monster wave at Y = -2000 and still counted as live, which freezes the
## round for good.
func _lost(m) -> bool:
	var n := m as Node3D
	if n == null:
		return false
	var p: Vector3 = n.global_position
	if absf(p.x) <= GameConsts.WORLD_BOUND and absf(p.y) <= GameConsts.WORLD_BOUND \
			and absf(p.z) <= GameConsts.WORLD_BOUND:
		return false
	Log.info("[Siege] a monster left the world at %.0f,%.0f,%.0f — freeing it" % [p.x, p.y, p.z])
	n.queue_free()
	return true


## One wave's monsters in arrival order, from the WAVES table. `n` is 1-based; a round that
## somehow runs past the table repeats its last row rather than ending early.
##
## Interleaved rather than queued kind by kind. The drip is one monster every SPAWN_INTERVAL, so
## a wave listed as eleven skeletons then four spirits would send the whole skeleton block first
## and the spirits a quarter of a minute later, against defenders who had already finished the
## first fight. Spreading each kind evenly across the wave is what makes it read as one attack.
func _wave_queue(n: int) -> Array[String]:
	var row: Array = WAVES[clampi(n - 1, 0, WAVES.size() - 1)]
	var total := 0
	for entry: Array in row:
		total += int(entry[1])
	# Each kind gets slots spaced total/count apart, offset so two kinds of equal count do not
	# land on the same slot. First come, first served where two still collide.
	var slots: Array[String] = []
	slots.resize(total)
	slots.fill("")
	for i in row.size():
		var path: String = row[i][0]
		var count := int(row[i][1])
		if count <= 0:
			continue
		var step := float(total) / float(count)
		for k in count:
			var at := int(step * (float(k) + 0.5 * float(i + 1) / float(row.size() + 1)))
			while at < total and slots[at] != "":
				at += 1
			if at >= total:
				at = slots.rfind("")      # the spacing ran off the end; take the last gap
			if at >= 0:
				slots[at] = path
	# Any slot the spacing never claimed (two kinds colliding at the tail) takes the commonest
	# monster in the row, which is the first one listed.
	var filler: String = row[0][0] if not row.is_empty() else SKELETON
	for i in slots.size():
		if slots[i] == "":
			slots[i] = filler
	return slots


## Wave survived. Heal a little, put the fallen back on their feet, and start the next clock.
func _clear_wave() -> void:
	if wave >= WAVE_COUNT:
		_finish(true)
		return
	if is_instance_valid(altar) and altar.has_method("heal"):
		altar.heal(float(altar.get("max_health")) * BREAK_HEAL_FRACTION)
	# Clears whatever a wave left lying about AND brings back everyone it killed. The altar rides
	# through it on its _persist_round meta.
	var main := get_tree().current_scene
	if main and main.has_method("respawn_all_players"):
		main.respawn_all_players()
	_live.clear()
	_enter_build(BUILD_SECONDS)


func _finish(won: bool) -> void:
	phase = Phase.WON if won else Phase.LOST
	_free_live()
	_broadcast()
	# Hand the ending to MatchSystem so rotation, intermission and the vote all behave as usual.
	MatchSystem.end_match("Siege survived — %d waves" % WAVE_COUNT if won
			else "The altar fell on wave %d" % wave)


func _free_live() -> void:
	for m in _live:
		if is_instance_valid(m):
			m.queue_free()
	_live.clear()
	_queue.clear()


func _now_ms() -> int:
	return int(Time.get_ticks_msec())


# --- replication -----------------------------------------------------------

## Host: push the phase and show it locally. The announcement is derived from the change rather
## than sent as its own message, so a client and the host say the same thing for the same reason
## and a late joiner is never told about a wave that started before they arrived.
func _broadcast() -> void:
	if NetworkManager.is_online() and NetworkManager.is_host():
		apply_remote.rpc(int(phase), wave, WAVE_COUNT, phase_end_ms)
	_present()


## Client receive, and the late-joiner snapshot. A client runs no siege logic — it is told the
## phase so the HUD can say what is happening, and the altar arrives as an ordinary entity.
## Like the match clock, the deadline is an absolute server time rather than a remaining count.
@rpc("authority", "call_remote", "reliable")
func apply_remote(p_phase: int, p_wave: int, _p_total: int, p_phase_end_ms: int) -> void:
	phase = p_phase as Phase
	wave = p_wave
	phase_end_ms = p_phase_end_ms
	active = phase != Phase.OFF
	_present()
	state_changed.emit(active)


func _hud():
	return Game.hud


## Say what just changed, once. Driven off the phase/wave pair rather than called at each
## transition, so the host and every client announce from the same state.
func _present() -> void:
	if phase == _shown_phase and wave == _shown_wave:
		return
	var was := _shown_phase
	_shown_phase = phase
	_shown_wave = wave
	var hud = _hud()
	if hud == null or not hud.has_method("show_center_message"):
		return
	match phase:
		Phase.WAVE:
			hud.show_center_message("Wave %d of %d" % [wave, WAVE_COUNT], Color(1.0, 0.5, 0.2))
		Phase.BUILD:
			if was == Phase.WAVE:
				hud.show_center_message("Wave %d cleared" % wave, Color(0.4, 0.9, 0.4))
			elif was == Phase.OFF:
				hud.show_center_message("Defend the altar", Color(0.6, 0.8, 1.0))
		Phase.WON:
			hud.show_center_message("The altar holds!", Color(0.4, 0.9, 0.4), 6.0)
		Phase.LOST:
			hud.show_center_message("The altar has fallen.", Color(0.9, 0.3, 0.2), 6.0)
		_:
			pass


## Seconds left of the break, or -1 when not in one.
func build_time_left() -> float:
	if phase != Phase.BUILD:
		return -1.0
	return maxf(float(phase_end_ms - _now_ms()) / 1000.0, 0.0)


# --- arena ---------------------------------------------------------------

## Where the altar stands.
##
## The grail first — the team's own carriable goal, sitting on its stand in their base. That is
## the treasure a siege is about; everyone already knows where it is and already defends it.
##
## Then the capture point (the plate you bring an enemy grail to), derived the way BotBrain
## derives it: a scoring goal that needs a carried item and awards this team. Then a territorial
## control zone — ww_monoliths' runes, which are not carriable so the grail test misses them —
## and only with nothing else on the map, the place the team spawns.
##
## Ordered by WHAT THE SPOT IS, not by how near it is. Ranking by distance to the team's start
## put the altar on a spawn point whenever the real objective was rejected for being too far from
## walkable ground — the start is zero metres from itself, so it won every tie it was allowed
## into. Distance only breaks ties inside a tier.
func _altar_candidates() -> Array:
	var anchor := _team_anchor(defender_team)
	var tiers: Array[Array] = []
	tiers.resize(Tier.size())
	for t in Tier.size():
		tiers[t] = []
	var _any_grails: Array[Vector3] = []
	var _any_fixtures: Array[Vector3] = []
	for g in GoalSystem.get_all_goals():
		if not (g is Node3D) or not g.is_inside_tree():
			continue
		# The first two tiers are goal PROPS — a model standing on the floor — so global_position
		# is the spot. _goal_center would answer the middle of the mesh, which hangs the altar in
		# the air above the crystal; it is for the brush goals below, which carry no origin.
		#
		# A fixture outranks a grail. Both are the heart of a base, but the grail is the thing the
		# enemy carries OFF and the fixture is the thing they come to smash — which is the siege,
		# exactly. ww_golem's crystal is the one in the shipped maps, and before this it matched no
		# tier at all and the altar went to the spawn room.
		if GoalSystem.is_base_fixture(g):
			if int(g.get("owned_by")) == defender_team:
				tiers[Tier.FIXTURE].append(g.global_position)
			else:
				_any_fixtures.append(g.global_position)
			continue
		if GoalSystem.is_carriable_flag(g):
			# owned_by, NOT req_team. req_team on a grail is who is allowed to CARRY it, which on
			# the enemy's grail is us — matching on it put both teams' grails in the running and
			# left the right one to be picked by distance, which is luck rather than a rule.
			if int(g.get("owned_by")) == defender_team:
				tiers[Tier.GRAIL].append(g.global_position)
			else:
				_any_grails.append(g.global_position)
			continue
		# The cap: a goal that only scores for someone carrying something, and scores for us.
		var scores: Array = g.get("team_scores")
		if int(g.get("item_is_needed")) != 0 and scores != null \
				and defender_team < scores.size() and int(scores[defender_team]) != 0:
			tiers[Tier.CAP].append(_goal_center(g))
		elif g is InfoTFGoal and g.is_brush_entity() and int(g.get("goal_no")) != 0 \
				and int(g.get("req_team")) == defender_team \
				and int(g.get("item_is_needed")) == 0 and int(g.get("item_to_give")) == 0:
			tiers[Tier.ZONE].append(_goal_center(g))
	# A map whose grails declare no owner at all (a single neutral grail) would otherwise have
	# none in the top tier. Same for a fixture the defenders do not own — better the enemy's
	# crystal, which is still a landmark in a room, than the spawn point of last resort.
	if tiers[Tier.FIXTURE].is_empty():
		tiers[Tier.FIXTURE].append_array(_any_fixtures)
	if tiers[Tier.GRAIL].is_empty():
		tiers[Tier.GRAIL].append_array(_any_grails)
	if anchor != Vector3.INF:
		tiers[Tier.SPAWN].append(anchor)

	# Every usable spot, best tier first and nearest-to-start within a tier. A LIST rather than
	# one answer because "near walkable ground" is not the same as "something can walk here from
	# the rest of the map": ww_storm's capture point rides a func_platrot, so it snaps cleanly
	# onto a node in a pocket of the graph with no approach to it at all. begin() walks these
	# until one yields entry points.
	# Each entry is [where the altar stands, where monsters walk to]. The two are the same spot on
	# most maps and not on ww_golem, whose crystal is six metres up a pedestal.
	var out: Array = []
	var stranded: Array = []
	for tier in tiers.size():
		var ranked: Array = []
		for c: Vector3 in tiers[tier]:
			var near := _approaches(c)
			var d: float = c.distance_to(anchor) if anchor != Vector3.INF else 0.0
			if near.is_empty():
				stranded.append([c, c])
				continue
			ranked.append([d, near, _TIER_NAMES[tier], c])
		ranked.sort_custom(func(a, b): return a[0] < b[0])
		for r in ranked:
			var first: Vector3 = r[1][0]
			Log.info("[Siege] altar candidate: %s at %.0f,%.0f,%.0f — %d approach(es), nearest %.1fm" % [
					r[2], r[3].x, r[3].y, r[3].z, r[1].size(), r[3].distance_to(first)])
			for ap: Vector3 in r[1]:
				out.append([r[3], ap])
	out.append_array(stranded)   # better a badly placed altar than no siege at all
	return out


## Standable spots around `pos` to walk a wave to, nearest first and spread out, all of them in
## the arena's own component and within MAX_ALTAR_SNAP_M. A list rather than one answer because
## the nearest is not always reachable — see APPROACH_TRIES.
##
## The component restriction is not a nicety. A goal entity often sits in a sealed flag room or on
## a ledge whose nearest waypoint belongs to some tiny pocket of the graph, and an approach taken
## in there is one nothing can route to. Six of thirty maps failed exactly that way (castle,
## countryside, golem, leyline, osaka, skytower) before the snap was told to prefer the body of
## the map.
func _approaches(pos: Vector3) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var g = MonsterNav.graph(self)
	if g == null:
		return out
	var comp_id := _arena_component(g)
	var comp: Dictionary = g.node_component_map() if comp_id >= 0 else {}
	var ranked: Array = []
	var limit := MAX_ALTAR_SNAP_M * MAX_ALTAR_SNAP_M
	for i in g.positions.size():
		if comp_id >= 0 and comp.get(i, -1) != comp_id:
			continue
		var d: float = g.position_of(i).distance_squared_to(pos)
		if d <= limit:
			ranked.append([d, i])
	ranked.sort_custom(func(a, b): return a[0] < b[0])
	for r in ranked:
		if out.size() >= APPROACH_TRIES:
			break
		var p: Vector3 = g.position_of(r[1])
		if not _crowded(p, out, APPROACH_SPREAD):
			out.append(p)
	return out


## Is `p` so close to something already picked that taking it adds nothing? Both the approach
## probes and the entry points want a spread rather than a cluster — two nodes a metre apart are
## one probe, and the same doorway twice is not two approaches.
static func _crowded(p: Vector3, taken, spread: float) -> bool:
	for t in taken:
		if p.distance_to(t) < spread:
			return true
	return false


## Centre of a goal's brush volume. A cap plate carries no `origin` — the node sits at world zero
## and the geometry is the entity — so the AABB is the only honest answer. Same shape as
## BotBrain._goal_center, which reads the same entities for the same reason.
func _goal_center(node: Node3D) -> Vector3:
	var out := AABB()
	var have := false
	for m in node.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		if mi.mesh == null:
			continue
		var w := mi.global_transform * mi.mesh.get_aabb()
		out = w if not have else out.merge(w)
		have = true
	if not have:
		for c in node.find_children("*", "CollisionShape3D", true, false):
			var cs := c as CollisionShape3D
			if cs.shape == null:
				continue
			var w := cs.global_transform * cs.shape.get_debug_mesh().get_aabb()
			out = w if not have else out.merge(w)
			have = true
	return out.get_center() if have else node.global_position


## Where a team starts, as a REAL spawn point — the one nearest the middle of its spawn cluster.
##
## Not SpawnSystem.get_spawn_for_team, which picks at random among them: the arena has to come
## out the same every time a map loads, and it did not — ww_skytower derived a working arena on
## one run and none at all on the next, purely because a different spawn was drawn.
##
## And not the centroid itself, which is a position nobody necessarily stands in. Averaging two
## opposing bases lands in the middle of the map, which on ww_osaka is out over the water; taken
## as a candidate it snapped 108 m to find ground.
func _team_anchor(team: int) -> Vector3:
	var pts: Array[Vector3] = []
	for sp in SpawnSystem.get_all_spawns():
		if sp.team_no == team and SpawnSystem.is_active(sp):
			pts.append(sp.get_spawn_position())
	if pts.is_empty():  # deathmatch map, or a team with no starts of its own
		for sp in SpawnSystem.get_all_spawns():
			if sp.team_no == 0 and SpawnSystem.is_active(sp):
				pts.append(sp.get_spawn_position())
	if pts.is_empty():
		return Vector3.INF
	var mid := Vector3.ZERO
	for p in pts:
		mid += p
	mid /= float(pts.size())
	var best := pts[0]
	for p in pts:
		if p.distance_to(mid) < best.distance_to(mid):
			best = p
	return best


## Entry points: waypoints a monster can actually walk to the altar from, far enough away to be an
## approach, spread so they are different approaches rather than one doorway five times.
##
## Picking them off the monster graph rather than off the map is the whole trick — a node that
## path_ids returns a route from is a node a wave can leave, and the map is not consulted about it.
func _derive_entries(altar_spot: Vector3, allow_fallback := true) -> PackedVector3Array:
	var out := PackedVector3Array()
	var g = MonsterNav.graph(self)

	# Monsters come out of the enemy's spawn points. The map already decided where an attacking
	# side enters the field, and those places are standable by construction, connected to
	# everywhere a player goes, and read correctly to anyone who knows the map — a wave appearing
	# out of the red base is a thing you can anticipate in a way a derived waypoint is not.
	var spots: Array[Vector3] = []
	for sp in SpawnSystem.get_all_spawns():
		# team_no 0 is NOT "the enemy". It is the map's lone info_player_start, which an editor
		# drops wherever and which no team ever uses — on ww_2fort it hangs over the middle of
		# the map. `!= defender_team` let it through, and because entry_point round-robins from
		# zero it was the entry EVERY first wave came out of. The teamless case has its own
		# branch below.
		if not SpawnSystem.is_active(sp) or sp.team_no == 0 or sp.team_no == defender_team:
			continue
		# A dragonrider start puts you on a dragon, not on the floor — nothing walks out of one.
		if sp is InfoDragonriderSpawn:
			continue
		spots.append(sp.get_spawn_position())
	# Deathmatch: every start is teamless, so "the enemy's" means nothing. Any start far enough
	# from the altar will do.
	if spots.is_empty():
		for sp in SpawnSystem.get_all_spawns():
			if SpawnSystem.is_active(sp) and not (sp is InfoDragonriderSpawn):
				spots.append(sp.get_spawn_position())

	for raw in spots:
		# Where the monster will actually be standing, not where it is put down. A spawn point is
		# placed for a player, whom the spawn code sets on the floor; a monster dropped at one
		# falls. Validating the route from the spot in the air is how a wave came to be fed into
		# a hole: path_ids snapped the floating point to a walkway overhead and reported a fine
		# 214-hop route from a place the monster would never stand.
		# Grounded here as well as in _grounded, because the route test below reads this
		# position: an ungrounded point does NOT fail it — path_ids snaps whatever is
		# overhead and reports a fine route from a place nothing can stand, which is the
		# hole the note above describes.
		var p := _entry_ground(raw)
		if p == Vector3.INF:
			continue
		# A start in the defenders' lap is not an approach — on a map whose teams share a base,
		# or a DM map, some of them will be.
		if p.distance_to(altar_spot) < ENTRY_MIN_M:
			continue
		# Confirmed with a real route: a spawn the monsters cannot walk out of toward the altar
		# would quietly feed every wave into a wall.
		if g != null and g.path_ids(p, altar_spot).is_empty():
			continue
		out.append(p)
	if not out.is_empty():
		return _grounded(out)
	# No enemy start can reach the altar — ww_checkmate and ww_wstland4 are both like this. Rather
	# than refuse the map, fall back to picking approach points off the graph itself.
	if not allow_fallback:
		return out
	return _grounded(_derive_entries_from_graph(altar_spot, g))


## Every entry put on the floor beneath it, dropping any with no floor under it at all.
##
## Both producers come through here, which is the point: spawn_wave puts a monster directly ON
## its entry with nothing to catch a bad one, so "an entry is standable" has to be true of the
## graph fallback as well as of the map's own spawn points. It was true of only the spawn points,
## and the per-point grounding that used to cover the rest went with the spawn ring.
##
## A waypoint is not already floor-level: the bake puts nodes at hull CENTRE height, and a hand
## file's are a metre up (see the HPB notes), so a node taken straight from the graph hangs.
func _grounded(entries_in: PackedVector3Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	for p in entries_in:
		var g := _entry_ground(p)
		if g != Vector3.INF:
			out.append(g)
	return out


## The floor under an entry, so a wave is brought in standing rather than falling.
##
## Measured on ww_2fort: twelve of its thirteen entries sat 0.4 m over their floor, and the
## thirteenth sat 13.8 m over it. Everything spawned there fell into the space below the bridge,
## which the bake can route INTO and not out of (edges are directed), so every monster asked for
## a route forever, got none, and spent the match walking the straight-line fallback into a wall.
## That is the "wedging" — they were never wedged, they were stranded.
## INF when there is no floor within MAX_ENTRY_DROP, rather than the point handed in. Returning
## the input was the shape of the bug that put monsters under ww_2fort's spawn room: a caller
## reads it as "already on the ground" and puts something down in mid-air. Same vocabulary as
## entry_point, so a caller tests one value for "no answer".
func _entry_ground(p: Vector3) -> Vector3:
	var main := get_tree().current_scene
	if main == null:
		return Vector3.INF
	var space: PhysicsDirectSpaceState3D = main.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 0.3,
			p + Vector3.DOWN * MAX_ENTRY_DROP)
	q.collision_mask = GameConsts.MASK_WORLD_AND_CLIP
	var hit: Dictionary = space.intersect_ray(q)
	if hit.is_empty():
		return Vector3.INF
	return (hit.position as Vector3) + Vector3.UP * 0.1


## Where the altar actually stands: [the floor under `pos`, the room over that floor]. The altar
## sits on the first and sizes itself to the second (see SiegeAltar._fit_model).
##
## Measured host-side and sent with the spawn rather than probed on both peers, like everything
## else about the arena — a client is handed a finished altar, not the reasoning behind it.
func _footing(pos: Vector3) -> Array:
	var main := get_tree().current_scene
	if main == null:
		return [pos, INF]
	var space: PhysicsDirectSpaceState3D = main.get_world_3d().direct_space_state
	# The world as it is drawn, not as it is walked: what the crystal must not come through is
	# the visible ceiling, and what it should stand on is the visible floor.
	var down := PhysicsRayQueryParameters3D.create(pos + Vector3.UP * 0.3,
			pos + Vector3.DOWN * MAX_ALTAR_DROP_M)
	down.collision_mask = GameConsts.MASK_WORLD
	var floor_hit: Dictionary = space.intersect_ray(down)
	var foot: Vector3 = (floor_hit.position as Vector3) if not floor_hit.is_empty() else pos
	var up := PhysicsRayQueryParameters3D.create(foot + Vector3.UP * 0.3,
			foot + Vector3.UP * MAX_HEADROOM_M)
	up.collision_mask = GameConsts.MASK_WORLD
	var ceil_hit: Dictionary = space.intersect_ray(up)
	var head: float = (float((ceil_hit.position as Vector3).y) - foot.y) if not ceil_hit.is_empty() else INF
	return [foot, head]


## Approach points taken from the waypoint graph rather than from the map's own starts. The
## fallback for a map whose enemy spawns cannot reach the altar.
func _derive_entries_from_graph(altar_spot: Vector3, g) -> PackedVector3Array:
	var out := PackedVector3Array()
	if g == null:
		return out
	var altar_comp := _arena_component(g)
	if altar_comp < 0:
		return out
	var comp: Dictionary = g.node_component_map()
	# Ranked by closeness to an ideal approach length rather than by "far": simply taking the
	# furthest nodes put entries 133-152 m out on ww_2fort, a forty-second march before anyone
	# sees anything. [distance from ideal, id], sorted once — a comparator that recomputed the
	# distance per comparison was most of the cost.
	var ranked: Array = []
	for i in g.positions.size():
		if comp.get(i, -1) != altar_comp:
			continue
		var d: float = g.position_of(i).distance_to(altar_spot)
		if d >= ENTRY_MIN_M:
			ranked.append([absf(d - ENTRY_IDEAL_M), i])
	ranked.sort_custom(func(a, b): return a[0] < b[0])
	var probed := 0
	for entry in ranked:
		if out.size() >= ENTRY_COUNT or probed >= ENTRY_PROBE_LIMIT:
			break
		var p: Vector3 = g.position_of(entry[1])
		if _crowded(p, out, ENTRY_REGION_SPREAD):
			continue
		probed += 1
		if g.path_ids(p, altar_spot).is_empty():
			continue
		out.append(p)
	return out


## Graph node nearest a world point, by id. `only_comp` >= 0 restricts the answer to one
## connected component; -1 considers every node.
func _nearest_graph_id(g, pos: Vector3, only_comp := -1) -> int:
	var comp: Dictionary = g.node_component_map() if only_comp >= 0 else {}
	var best := -1
	var best_d := INF
	for i in g.positions.size():
		if only_comp >= 0 and comp.get(i, -1) != only_comp:
			continue
		var d: float = g.position_of(i).distance_squared_to(pos)
		if d < best_d:
			best_d = d
			best = i
	return best


## The component the siege is fought in: the one the defenders spawn in.
##
## Not simply the biggest. "Biggest" is right on most maps and wrong where the bake is fragmented
## — ww_osaka and ww_chasm put the players' own spawns outside the largest component, so every
## candidate snapped to the far side of the map (108 m and 55 m) to reach it. Where the players
## stand is the part of the map that matters; the size check is only there to reject a spawn
## stranded in some two-node pocket.
func _arena_component(g) -> int:
	if _arena_comp != -2:
		return _arena_comp
	_arena_comp = _resolve_arena_component(g)
	return _arena_comp


func _resolve_arena_component(g) -> int:
	var sizes: Dictionary = g.component_sizes()
	var largest := -1
	var largest_n := -1
	for root in sizes:
		if int(sizes[root]) > largest_n:
			largest_n = int(sizes[root])
			largest = int(root)
	var anchor := _team_anchor(defender_team)
	if anchor == Vector3.INF:
		return largest
	var here := _nearest_graph_id(g, anchor)
	if here < 0:
		return largest
	var comp: Dictionary = g.node_component_map()
	var mine: int = comp.get(here, largest)
	return mine if int(sizes.get(mine, 0)) >= largest_n / 5.0 else largest


# --- factions ------------------------------------------------------------

## Everyone human is on the same side for the duration.
##
## No new friend-or-foe code: Teams.teams_friendly already resolves through
## GoalSystem.team_allies, so setting the alliance bits makes wizards spare each other and leaves
## MONSTER_TEAM an enemy to all of them, in both directions, for every spell and summon in the game.
func _ally_the_players() -> void:
	if _allied:
		return
	_saved_allies = GoalSystem.team_allies.duplicate()
	var playing := GoalSystem.get_team_count()
	for a in range(1, playing + 1):
		if a == MONSTER_TEAM:
			continue
		for b in range(1, playing + 1):
			if b == MONSTER_TEAM or a == b:
				continue
			GoalSystem.team_allies[a - 1] |= 1 << (b - 1)
	_allied = true


func _restore_allies() -> void:
	if not _allied:
		return
	for i in mini(_saved_allies.size(), GoalSystem.team_allies.size()):
		GoalSystem.team_allies[i] = _saved_allies[i]
	_allied = false


func _on_server_var_changed(key: String, value: Variant) -> void:
	if key != "siege":
		return
	if bool(value):
		var err := begin()
		if not err.is_empty():
			Log.info("[Siege] %s" % err)
	else:
		end()
