extends Node
## Does a bot hit a target that MOVES? bot_soak measures where bots go; this measures whether they
## can shoot, which a soak cannot: bots run their routes in straight lines, so bot-versus-bot says
## almost nothing about aiming at something that dodges.
##
## Pins one bot and one dummy at a fixed range on clear ground, strafes the dummy across the bot's
## line like a player sidestepping, and reports the damage landed per shot. LEAD=0 turns the lead
## off, WANDER=1 leaves the aim wobble on, and VERBOSE=1 traces the engagement every 10s, so each
## part can be weighed on its own.
##
##   LEAD=1 WANDER=1 godot --headless --path . res://src/tests/bot_aim_probe.tscn \
##       -- --server --map ww_2fort
##
## Measured on ww_2fort at 20m, skill 0.9, a +-8m strafe at 0.10 Hz (2026-09-30), ~56 shots each:
##   lead on, wobble on   15.8 damage/shot      lead off, wobble on   2.7
##   lead on, wobble off  22.9 damage/shot      lead off, wobble off  6.6
## A mind missile hits for 30, so as shipped that is a 53% hit rate against a sidestepping target
## and 9% without the lead. Before the aim origin was moved to the eye, every one of these read
## 0.00: a direct-hit projectile aimed from the feet but fired from the eye passes over the head
## of a target standing on the same floor.

## Env-overridable: RANGE/AMP/FREQ/SECONDS.
## A reversal inside the shot's flight time is not what leading is for — linear extrapolation of a
## sinusoid is wrong near its turnaround — so the default strafe is slow enough that the target's
## velocity is near-constant over the ~0.5s a missile is in the air.
var RANGE := 20.0
var AMP := 8.0
var FREQ := 0.10
var SECONDS := 120.0


func _env(key: String, dflt: float) -> float:
	return float(OS.get_environment(key)) if OS.has_environment(key) else dflt

var _main: Node = null
var _live := {}
var _min_d := INF
var _verbose := false


func _ready() -> void:
	RANGE = _env("RANGE", RANGE)
	AMP = _env("AMP", AMP)
	FREQ = _env("FREQ", FREQ)
	SECONDS = _env("SECONDS", SECONDS)
	Engine.time_scale = 4.0
	Engine.physics_ticks_per_second = 240
	Engine.max_fps = 0
	_run.call_deferred()


func _run() -> void:
	var tree := get_tree()
	_main = load("res://src/main.tscn").instantiate()
	tree.root.add_child(_main)
	tree.current_scene = _main
	var waited := 0.0
	while waited < 240.0 and not bool(_main.get("_game_active")):
		await tree.create_timer(1.0).timeout
		waited += 1.0
	if not bool(_main.get("_game_active")):
		print("[Aim] game never started"); tree.quit(1); return

	var lead := not (OS.get_environment("LEAD") == "0")
	_verbose = OS.get_environment("VERBOSE") == "1"
	# WIND on purpose: the mind missile (bot_range 30) is the ONLY weapon its loadout offers a
	# bot, and it is a direct-hit projectile. A splash weapon measures nothing here — a fireball's
	# 4m radius covers the whole miss, which is why the first run of this probe read the same with
	# the lead on and off.
	var shooter_id := BotSystem.add_bot(GameConsts.Element.WIND, 1, 0.9)
	var dummy_id := BotSystem.add_bot(GameConsts.Element.WIND, 2, 0.9)
	if shooter_id == 0 or dummy_id == 0:
		print("[Aim] could not add both bots"); tree.quit(1); return
	var shooter: Node3D = _bot_by_id(shooter_id)
	var dummy: Node3D = _bot_by_id(dummy_id)
	var brain = shooter.get_node("BotBrain")
	# The dummy is a prop: no AI of its own, and it never shoots back.
	dummy.get_node("BotBrain").queue_free()
	await tree.physics_frame
	brain._lead_frac = 1.0 if lead else 0.0
	# Both arms with the aim wobble off. It is 0.034 rad at this range even for a 0.9-skill bot,
	# which is +-0.7m at 20m — bigger than a direct-hit projectile's 0.5m contact radius, so
	# leaving it on measures the wobble and nothing else (measured: closest approach 1.46m on
	# every shot, lead on or off).
	var wobble := OS.get_environment("WANDER") == "1"
	if not wobble:
		brain._aim_err = 0.0
		brain._wander = Vector2.ZERO
		brain._wander_to = Vector2.ZERO

	# Somewhere the shooter can actually see all the way across the dummy's swing. A spawn is
	# usually indoors, so walk the bake's own waypoints looking for open ground.
	var base: Vector3 = shooter.global_position
	var dir := _clear_dir(shooter, base)
	if dir == Vector3.INF:
		var g = BotSystem._waypoints
		var n: int = 0 if g == null else g.positions.size()
		for i in range(0, n, maxi(1, n / 400)):
			base = g.positions[i]
			dir = _clear_dir(shooter, base)
			if dir != Vector3.INF:
				break
	if dir == Vector3.INF:
		print("[Aim] nowhere on this map has a clear %.0fm line across a %.0fm swing"
				% [RANGE, AMP * 2.0])
		tree.quit(1); return
	print("[Aim] firing ground %v heading %v" % [base, dir])
	var right := Vector3(-dir.z, 0.0, dir.x)

	var t := 0.0
	var shots := 0.0
	var damage := 0.0
	var cost := 0.0
	var prev_mana: float = shooter.mana
	while t < SECONDS:
		await tree.physics_frame
		t += 1.0 / 60.0
		# Both pinned: this measures aim, not pathing, so neither is allowed to wander off.
		shooter.global_position = base
		shooter.velocity = Vector3.ZERO
		dummy.global_position = base + dir * RANGE + right * (AMP * sin(TAU * FREQ * t))
		dummy.velocity = Vector3.ZERO
		# Count what the shooter spent (mana is the only honest shot counter from out here) and
		# what the dummy lost, then top both up so the run never ends early.
		# Point the shooter's head at the dummy only while it has NOT acquired it. Pinned in place,
		# the brain keeps facing wherever its route wants to go, so whether the duel happens at all
		# came down to which way the spawn's route pointed — measured as runs that engaged
		# constantly and runs that never engaged once. This settles the acquisition and nothing
		# else: from the first sighting on, the real aim (lead, wobble, turn rate) has the head.
		if brain._seen == null:
			var to_dummy: Vector3 = dummy.global_position - shooter.global_position
			brain._face_yaw = atan2(-to_dummy.x, -to_dummy.z)
		var w: Weapon = shooter.weapon_at(shooter.current_weapon_idx)
		if w != null and w.mana_cost > 0.0:
			cost = w.mana_cost
		if cost > 0.0 and shooter.mana < prev_mana:
			shots += (prev_mana - shooter.mana) / cost
		damage += maxf(dummy.max_health - dummy.health, 0.0)
		for pr in tree.get_nodes_in_group("projectile"):
			if not is_instance_valid(pr):
				continue
			_live[pr] = true
			var d: float = pr.global_position.distance_to(SpatialQuery.collision_center(dummy))
			if d < _min_d:
				_min_d = d

		if _verbose and int(t * 60.0) % 600 == 0:
			print("[Aim] t=%5.1f w=%s seen=%s vel=%.1f blocked=%s d=%.1f mana=%.0f" % [
					t, "-" if w == null else w.get_script().resource_path.get_file(),
					brain._seen != null, brain._lead_vel.length(),
					brain.steer_tally.get("shot_blocked", 0),
					shooter.global_position.distance_to(dummy.global_position), shooter.mana])
		dummy.health = dummy.max_health
		dummy.is_dead = false
		shooter.mana = shooter.max_mana
		prev_mana = shooter.mana

	print("\n[Aim] lead=%s wobble=%s  range=%.0fm  strafe +-%.0fm at %.2f Hz  %.0fs" % [
			"on" if lead else "OFF", "on" if wobble else "OFF",
			RANGE, AMP, FREQ, SECONDS])
	print("[Aim] shots %.0f   damage %.0f   damage/shot %.2f" % [
			shots, damage, damage / maxf(shots, 1.0)])
	print("[Aim] projectiles seen %d, closest any came to the target: %.2fm" % [_live.size(), _min_d])
	tree.quit(0)


func _bot_by_id(id: int) -> Node3D:
	for b in BotSystem._bots:
		if is_instance_valid(b) and b.peer_id == id:
			return b
	return null


## A heading whose whole swept line is clear from the shooter's eye — the centre and both ends of
## the dummy's swing — so a miss is the aim's fault and not a wall's.
func _clear_dir(shooter: Node3D, base: Vector3) -> Vector3:
	var eye := base + Vector3(0.0, 1.6, 0.0)
	var space := shooter.get_world_3d().direct_space_state
	for i in 32:
		var a := TAU * float(i) / 32.0
		var dir := Vector3(sin(a), 0.0, cos(a))
		var right := Vector3(-dir.z, 0.0, dir.x)
		var ok := true
		for off in [-AMP, -AMP * 0.5, 0.0, AMP * 0.5, AMP]:
			var to: Vector3 = base + dir * RANGE + right * off + Vector3(0.0, 0.9, 0.0)
			var q := PhysicsRayQueryParameters3D.create(eye, to)
			q.collision_mask = GameConsts.MASK_WORLD | GameConsts.MASK_ENTITY
			q.exclude = [shooter.get_rid()]
			if not space.intersect_ray(q).is_empty():
				ok = false
				break
		if ok:
			return dir
	return Vector3.INF
