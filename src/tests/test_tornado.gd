extends "res://src/tests/test_base.gd"
## The tornado summon: what /spawn will answer to, the funnel's hunt-grind-and-throw loop,
## who it spares, and the one-shot book that casts it.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.

const TornadoScript = preload("res://src/monsters/tornado.gd")
const Movement = preload("res://addons/pmove/movement.gd")
const MovementConfig = preload("res://addons/pmove/movement_config.gd")
const InputCommand = preload("res://addons/pmove/input_command.gd")
const GodotBodyScript = preload("res://addons/pmove/godot_body.gd")
const TornadoWeaponScript = preload("res://src/weapons/tornado_weapon.gd")
const CorpseScript = preload("res://src/monsters/tumbling_corpse.gd")

const ARENA := Vector3(200.0, 90.0, 0.0)   # clear of any map geometry, and of the plant suite's
const CHASE_FRAMES := 240                  # 4s at 60Hz: enough to close ~10m at 4.4 m/s


## Damageable stand-in for a player.
class DummyTarget extends CharacterBody3D:
	var is_dead := false
	var team := GameConsts.Team.RED
	var damage_taken := 0.0
	var hits := 0

	func take_damage(amount: float, _type: int, _attacker) -> void:
		damage_taken += amount
		hits += 1


## The bare surface Weapon.fire()/get_aim() reach for on a caster.
class DummyCaster extends CharacterBody3D:
	var team := GameConsts.Team.BLUE
	var peer_id := 0
	var is_dead := false

	func _active_camera() -> Camera3D:
		return null


var _weather: WeatherSystem
var _was_weather: WeatherSystem


## The tornado's air is the weather's (WeatherSystem.airflow), so every test has one: no map and no
## rain floor, so no wind of its own, and out of the tree, so its carrier runs only when a test
## drives it (_carry_corpse).
func _setup_test(_test_name: String) -> void:
	_was_weather = Game.weather_system
	_weather = WeatherSystem.new()
	Game.weather_system = _weather


func _teardown_test() -> void:
	Game.weather_system = _was_weather
	_weather.free()
	super._teardown_test()


## Mirrors main._spawn_dyn_entity: setup() first, add_child() after.
func _tornado_at(pos: Vector3, heading := Vector3.FORWARD, owner_peer_id := 0) -> Tornado:
	var t: Tornado = TornadoScript.new()
	t.setup({"position": pos, "direction": heading, "team": GameConsts.Team.BLUE,
		"owner_peer_id": owner_peer_id}, true)
	_root().add_child(t)
	_keep(t)
	return t


## A dead wizard lying where the funnel will find it. Mirrors main._spawn_dyn_entity: setup()
## first, add_child() after.
func _corpse_at(pos: Vector3) -> TumblingCorpse:
	var corpse: TumblingCorpse = CorpseScript.new()
	corpse.setup(TumblingCorpse.wizard_payload(pos, 0.0, GameConsts.Element.FIRE, Vector3.ZERO), true)
	_root().add_child(corpse)
	_keep(corpse)
	return corpse


func _target_at(pos: Vector3) -> DummyTarget:
	return _damageable_at(DummyTarget, pos, 0.4, true) as DummyTarget


## Both halves come from the scripts themselves. Like the giant plant it is a spellbook pickup,
## not any class's spell, so it is grantable to every element and belongs to no loadout.
func test_the_registry_offers_both_halves_of_the_spell() -> void:
	assert_true(SpawnRegistry.has_object("tornado"), "the funnel is a thing in the world")
	assert_true(SpawnRegistry.has_weapon("tornado_weapon"), "the spell that throws it")
	assert_false(SpawnRegistry.has_object("tornado_weapon"), "the spell is not itself an object")
	var w := SpawnRegistry.build_weapon("tornado_weapon")
	assert_true(w is TornadoWeapon, "right class")
	assert_eq(w.player_attack_prefix, "combo", "cast with the shared combo-spell animation")
	assert_eq(w.get_display_name(), "Tornado", "and named for what it makes")


func test_the_spell_is_a_pickup_not_a_class_spell() -> void:
	for element in GameConsts.ELEMENT_NAMES:
		var w := SpawnRegistry.build_weapon("tornado_weapon", element)
		assert_ne(w, null, "every class can be handed the spell")
		assert_eq(w.hand_model_path, "models/hands/%s.mdl" % GameConsts.ELEMENT_NAMES[element],
			"cast with the %s wizard's own hands" % GameConsts.ELEMENT_NAMES[element])
		for carried in Wizard.create(element).weapons:
			assert_false(carried is TornadoWeapon,
				"no %s wizard spawns holding it" % GameConsts.ELEMENT_NAMES[element])


func test_it_chases_an_enemy_and_grinds_it_down() -> void:
	_floor_at(ARENA - Vector3(0.0, 0.5, 0.0))
	# Thrown the wrong way on purpose: it should turn around and come back.
	var funnel := _tornado_at(ARENA, Vector3.BACK)
	var target := _target_at(ARENA + Vector3(0.0, 0.0, -12.0))
	var start_dist := funnel.global_position.distance_to(target.global_position)

	await _tick(CHASE_FRAMES)

	assert_lt(funnel.global_position.distance_to(target.global_position), start_dist,
		"the tornado turned toward an enemy it could see and closed on it")
	assert_gt(target.damage_taken, 0.0, "and ground it down once it arrived")


## A victim wired to the real movement kernel — the same Simulation PmoveServerMovement runs, reading
## body.velocity the way its tick() does. A stub body is what hid this bug: it has no notion of
## standing on the floor, so it accepted lifts a real player's movement would have thrown away.
class SimVictim extends CharacterBody3D:
	var is_dead := false
	var team := GameConsts.Team.RED
	var damage_taken := 0.0
	var sim
	var body
	var state
	var ctx: PlayerMovementContext
	var peak_rise := 0.0
	var peak_vy := 0.0
	var _floor_y := 0.0

	func take_damage(amount: float, _type: int, _attacker) -> void:
		damage_taken += amount

	func set_collision_height(_h: float, _c: float) -> void:
		pass

	func begin(floor_y: float) -> void:
		_floor_y = floor_y
		sim = Movement.Simulation.new(MovementConfig.new())
		body = GodotBodyScript.new(self)
		state = Movement.MovementState.new()
		state.bind_body(body)
		ctx = PlayerMovementContext.new(self, null, null)

	## One server tick: blown as a player is (PlayerMovementContext._blown), then simulated.
	func step() -> void:
		state.velocity = velocity
		var cmd := InputCommand.new()
		cmd.delta = 1.0 / 60.0
		var mods := Movement.MovementModifiers.new()
		ctx._blown(mods, sim.cfg, state, cmd)
		state.velocity += mods.velocity_add
		sim.simulate_tick(body, state, cmd)
		velocity = state.velocity
		peak_rise = maxf(peak_rise, global_position.y - _floor_y)
		peak_vy = maxf(peak_vy, velocity.y)


func _sim_victim_at(pos: Vector3, floor_y: float) -> SimVictim:
	var v := SimVictim.new()
	var col := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.8
	col.shape = cap
	col.position.y = 0.9
	v.add_child(col)
	v.collision_layer = GameConsts.MASK_PLAYER
	v.collision_mask = GameConsts.MASK_WORLD
	v.add_to_group("damageable")
	_root().add_child(v)
	v.global_position = pos
	v.begin(floor_y)
	_keep(v)
	return v


func _run_victim(victim: SimVictim, ticks: int) -> void:
	for i in ticks:
		await _physics_frame()
		victim.step()


## Along the ground the air drags a victim in toward the middle, feet still down.
func test_it_drags_you_in_along_the_ground() -> void:
	var ground := _floor_at(ARENA - Vector3(0.0, 0.5, 0.0))
	var funnel := _tornado_at(ARENA)
	funnel.set_physics_process(false)  # stands still, so the victim's distance is the air's doing
	var victim := _sim_victim_at(ARENA + Vector3(2.4, 0.0, 0.0), ground.global_position.y + 0.5)
	await _run_victim(victim, 10)
	assert_true(victim.state.on_floor, "dragged, feet down")
	var r := Vector2(victim.global_position.x - ARENA.x, victim.global_position.z - ARENA.z).length()
	assert_lt(r, 2.3, "and in toward the middle (%.2f m out)" % r)


## ...but not from beyond its reach: the way out is to outrun it.
func test_beyond_its_field_the_air_is_still() -> void:
	var funnel := _tornado_at(ARENA)
	funnel.set_physics_process(false)
	assert_eq(funnel.airflow(ARENA + Vector3(Tornado.FIELD + 0.1, 0.5, 0.0)), Vector3.ZERO, "out past its field")
	assert_eq(funnel.airflow(ARENA + Vector3(0.0, Tornado.OUTFLOW_BAND.y + 0.1, 0.0)), Vector3.ZERO, "and above it")
	var at_reach := funnel.airflow(ARENA + Vector3(Tornado.REACH, 0.5, 0.0))
	assert_lt(at_reach.x, -30.0, "at its reach, hard inward (%.1f)" % at_reach.x)
	assert_gt(funnel.airflow(ARENA + Vector3(0.2, 1.0, 0.0)).y, 25.0, "up its core")
	assert_gt(funnel.airflow(ARENA + Vector3(1.0, Tornado.LIFT_TOP + 1.0, 0.0)).x, 10.0, "and out over its top")


## And when it does get on top of them, the throw is a throw: metres, not a bob.
func test_a_victim_it_reaches_is_launched_not_floated() -> void:
	var ground := _floor_at(ARENA - Vector3(0.0, 0.5, 0.0))
	var floor_y: float = ground.global_position.y + 0.5
	_tornado_at(ARENA, Vector3.FORWARD)
	var victim := _sim_victim_at(ARENA + Vector3(0.0, 0.0, -5.0), floor_y)
	await _run_victim(victim, 300)  # five seconds: it has to cross the gap first
	assert_gt(victim.damage_taken, 0.0, "it reached them")
	assert_gt(victim.peak_vy, 6.0, "and threw them properly, not in nudges (peak %.1f m/s)" % victim.peak_vy)
	assert_gt(victim.peak_rise, 3.0, "well off the ground (%.1f m)" % victim.peak_rise)


## Up its core and out over the top: a victim comes down beside the funnel, to be run down again,
## not back into its eye. Thrown inward (as the original did) you simply came back to the eye and
## died there.
func test_it_throws_what_it_catches_up_and_outward() -> void:
	var ground := _floor_at(ARENA - Vector3(0.0, 0.5, 0.0))
	var floor_y: float = ground.global_position.y + 0.5
	var funnel := _tornado_at(ARENA)
	funnel.set_physics_process(false)
	var victim := _sim_victim_at(ARENA + Vector3(0.4, 0.0, 0.0), floor_y)
	var landed_at := -1.0
	for i in 240:
		await _physics_frame()
		victim.step()
		if victim.peak_rise > 3.0 and victim.state.on_floor:
			landed_at = Vector2(victim.global_position.x - ARENA.x, victim.global_position.z - ARENA.z).length()
			break
	assert_gt(victim.peak_rise, 3.0, "up its core (%.1f m)" % victim.peak_rise)
	assert_gt(landed_at, Tornado.REACH, "and down outside its reach (%.1f m out)" % landed_at)


## Thrown up its core it still bites: the air throws a victim clear, so the bite is what a catch
## costs. One catch is most of a wizard; two are any of them.
func test_a_catch_costs_most_of_a_wizard() -> void:
	var ground := _floor_at(ARENA - Vector3(0.0, 0.5, 0.0))
	var funnel := _tornado_at(ARENA)
	funnel.set_physics_process(false)
	var victim := _sim_victim_at(ARENA + Vector3(0.4, 0.0, 0.0), ground.global_position.y + 0.5)
	for i in 240:
		await _physics_frame()
		if i % 6 == 0:
			funnel._whirl()  # its think, at 10 Hz
		victim.step()
		if victim.peak_rise > 3.0 and victim.state.on_floor:
			break
	assert_gt(victim.damage_taken, 50.0, "most of a wizard (%.0f)" % victim.damage_taken)
	assert_lt(victim.damage_taken, 100.0, "but not all of one in a single catch")


## Drive the weather's rigid-body carrier over a corpse for `ticks`, as WeatherSystem does each
## physics frame in a match. Returns the fastest any bone rose.
func _carry_corpse(corpse: TumblingCorpse, ticks: int) -> float:
	var lifted := 0.0
	for i in ticks:
		await _physics_frame()
		for bone in corpse._bones:
			if not _weather._carried.has(bone):
				_weather._track_blown(bone)
		_weather._carry(1.0 / 60.0)
		for bone in corpse._bones:
			lifted = maxf(lifted, bone.linear_velocity.y)
	return lifted


## What a tornado kills it goes on throwing: a corpse's bones are in its air like anything else.
func test_it_goes_on_throwing_what_it_killed() -> void:
	_floor_at(ARENA - Vector3(0.0, 0.5, 0.0))
	var funnel := _tornado_at(ARENA)
	funnel.set_physics_process(false)
	var corpse := _corpse_at(ARENA + Vector3(0.0, 0.0, -0.5))
	await _tick(2)
	var lifted := await _carry_corpse(corpse, 45)
	assert_gt(lifted, 3.0, "the funnel lifted the corpse it stood over (peak %.1f m/s up)" % lifted)
	assert_false(corpse._baked, "and a corpse being thrown around has not settled")


## ...but only while there is a rig to throw. A corpse that has lain still long enough to bake
## has stopped being a simulation at all, and the funnel leaves it where it lies rather than
## rebuilding one to play with.
func test_a_settled_corpse_is_left_where_it_lies() -> void:
	_floor_at(ARENA - Vector3(0.0, 0.5, 0.0))
	var corpse := _corpse_at(ARENA)
	for i in 540:  # only as long as it takes: a corpse settles well inside MAX_SIM_TIME
		await _tick(1)
		if corpse._baked:
			break
	assert_true(corpse._baked, "the corpse settled and baked")
	var rest := corpse.global_position
	_tornado_at(corpse.global_position)
	await _carry_corpse(corpse, 45)
	assert_true(corpse.global_position.distance_to(rest) < 0.01, "the funnel passed over it")


## A spell flying past bends into it.
func test_a_spell_flying_past_is_drawn_in() -> void:
	var funnel := _tornado_at(ARENA)
	funnel.set_physics_process(false)
	var shot := Projectile.new()
	shot.set_physics_process(false)
	shot.set_process(false)
	_root().add_child(shot)
	_keep(shot)
	shot.global_position = ARENA + Vector3(2.0, 0.5, -1.0)
	shot.direction = Vector3(0, 0, 1)
	shot.speed = 20.0
	shot._blow(0.1)
	assert_lt(shot.direction.x, 0.0, "a shot passing beside it bends toward it")


## The grind is on the original's 0.1s think, so being in one costs 80/s — not
## 8 per physics frame.
func test_it_grinds_on_a_timer_not_every_frame() -> void:
	_floor_at(ARENA - Vector3(0.0, 0.5, 0.0))
	_tornado_at(ARENA)
	var target := _target_at(ARENA + Vector3(0.5, 0.0, 0.0))

	await _tick(60)  # one second

	assert_gt(target.hits, 5, "it ground away for the whole second")
	assert_lt(target.hits, 15, "on its think, not every frame (%d hits)" % target.hits)


## It is wind, not a monster: it never climbs, and it never falls through the floor either.
func test_it_hugs_the_ground() -> void:
	var ground := _floor_at(ARENA - Vector3(0.0, 0.5, 0.0))
	var funnel := _tornado_at(ARENA + Vector3(0.0, 3.0, 0.0))  # dropped in from above

	await _tick(120)

	var floor_y: float = ground.global_position.y + 0.5
	assert_lt(absf(funnel.global_position.y - floor_y), 0.2,
		"it settled onto the floor and stayed there")
	assert_lt(funnel.velocity.y, Tornado.RISE + 0.001, "and never climbs faster than a crawl")


## The model carries a single looping "idle" sequence and nothing else — a re-export that
## renamed it would leave a still funnel sliding around the map, which is easy to miss.
func test_it_spins() -> void:
	var funnel := _tornado_at(ARENA)
	assert_ne(funnel._model, null, "the funnel model loaded")
	var anim: AnimationPlayer = funnel._model.find_child("AnimationPlayer")
	assert_ne(anim, null, "with its animation")
	assert_eq(anim.current_animation, "idle", "which is playing")
	assert_eq(anim.get_animation("idle").loop_mode, Animation.LOOP_LINEAR, "and looping")


## The regression this guards: a wandering tornado that slid into a wall would grind against it
## for the rest of its life instead of coming off, because move_and_slide keeps zeroing the
## component that would have carried it away.
func test_it_comes_off_a_wall_instead_of_pinning_itself() -> void:
	_floor_at(ARENA - Vector3(0.0, 0.5, 0.0))
	_floor_at(ARENA + Vector3(0.0, 2.0, -6.0), Vector3(40.0, 6.0, 1.0))  # wall straight ahead
	var funnel := _tornado_at(ARENA, Vector3.FORWARD)  # -Z, into the wall

	await _tick(180)

	assert_gt(funnel.global_position.z, ARENA.z, "it bounced back off the wall it ran into")
	var speed := Vector2(funnel.velocity.x, funnel.velocity.z).length()
	assert_gt(speed, Tornado.SPEED * 0.9, "and is still moving at full speed, not scraping")


func test_it_spares_its_own_side() -> void:
	_floor_at(ARENA - Vector3(0.0, 0.5, 0.0))
	_tornado_at(ARENA)  # team BLUE
	var ally := _target_at(ARENA + Vector3(0.5, 0.0, 0.0))
	ally.team = GameConsts.Team.BLUE

	await _tick(30)

	assert_eq(ally.damage_taken, 0.0, "a teammate standing in it is not ground down (its air throws anyone)")


## The tornado reasons from teams, like the giant plant: only a teamless one still spares
## whoever cast it by name.
func test_a_caster_who_changes_sides_is_in_the_wind() -> void:
	_floor_at(ARENA - Vector3(0.0, 0.5, 0.0))
	var funnel := _tornado_at(ARENA)  # team BLUE
	var caster := _target_at(ARENA + Vector3(0.5, 0.0, 0.0))
	caster.team = GameConsts.Team.BLUE
	funnel.owner_node = caster

	await _tick(30)
	assert_eq(caster.damage_taken, 0.0, "an ally who cast it is left alone")

	caster.team = GameConsts.Team.RED  # switched sides
	await _tick(30)
	assert_gt(caster.damage_taken, 0.0, "and is ground down once they are on the other side")

	var loose := _tornado_at(ARENA + Vector3(0.0, 0.0, 20.0))
	loose.team = GameConsts.Team.NONE
	loose.owner_node = caster
	var before := caster.damage_taken
	caster.global_position = loose.global_position + Vector3(0.5, 0.0, 0.0)
	await _tick(2)
	assert_eq(caster.damage_taken, before,
		"a teamless tornado never turns on the wizard who cast it")


## Nothing can destroy one — it has to run out. Half a minute is too long to sit through, so
## this ages it by hand and takes the last step for real.
func test_it_blows_itself_out() -> void:
	_floor_at(ARENA - Vector3(0.0, 0.5, 0.0))
	var funnel := _tornado_at(ARENA)
	assert_false(funnel.has_method("take_damage"), "there is nothing to kill")
	assert_false(funnel.is_in_group("damageable"), "and nothing can target it")

	funnel._age = Tornado.LIFETIME - 0.05
	await _tick(6)
	assert_false(is_instance_valid(funnel), "it blew itself out on its own clock")


## A cast tornado belongs to the world, not to the wizard, and casts don't know about each
## other: a second spellbook means a second funnel, not a replacement.
func test_it_is_not_the_casters_to_take_away() -> void:
	_floor_at(ARENA - Vector3(0.0, 0.5, 0.0))
	var first := _tornado_at(ARENA, Vector3.FORWARD, 7)
	var second := _tornado_at(ARENA + Vector3(10.0, 0.0, 0.0), Vector3.FORWARD, 7)

	await _tick(3)
	assert_true(is_instance_valid(first), "casting again left the earlier tornado blowing")
	assert_true(is_instance_valid(second), "and the new one alongside it")

	var caster := DummyCaster.new()
	_root().add_child(caster)
	first.owner_node = caster
	caster.free()
	await _tick(3)
	assert_true(is_instance_valid(first), "the tornado outlives the wizard who cast it")
	assert_eq(first.owner_node, null, "with the freed owner cleared, not left dangling")


func test_the_book_holds_one_free_cast() -> void:
	var w := SpawnRegistry.build_weapon("tornado_weapon")
	assert_eq(w.mana_cost, 0.0, "the book is the cost, not mana")
	assert_eq(w.min_mana_to_fire(null), 0.0, "so an empty caster can still cast it")

	var p := _wizard()
	var base := p.weapons.size()
	assert_true(p.add_granted_weapon("tornado_weapon"), "picked the book up")
	assert_eq(p.weapons.size(), base + 1, "and it joined the loadout")
	assert_true(p.remove_granted_weapon("tornado_weapon"), "casting spends it")
	assert_eq(p.weapons.size(), base, "the spell is gone again")
	assert_true(p.granted_weapons.is_empty(), "and not replayed to a late joiner")
	assert_true(p.add_granted_weapon("tornado_weapon"), "another book grants it again")
	p.free()


## The original dropped the funnel a flat 2.5 m ahead, which puts it inside the wall a caster
## is standing against. The trace keeps it on this side of whatever is in the way.
func test_the_cast_stays_out_of_the_wall_in_front_of_it() -> void:
	_floor_at(ARENA - Vector3(0.0, 0.5, 0.0))
	var caster := DummyCaster.new()
	_root().add_child(caster)
	_keep(caster)
	caster.global_position = ARENA
	var weapon: TornadoWeapon = TornadoWeaponScript.new()

	var forward := Vector3.FORWARD  # -Z
	await _tick(1)
	var open := weapon._cast_spot(caster, forward)
	assert_almost_eq(open.distance_to(ARENA), TornadoWeapon.CAST_DISTANCE, 0.01,
		"open ground puts it the full distance out")
	assert_almost_eq(open.y, ARENA.y, 0.001, "at the caster's feet, to settle from there")

	# A wall a metre out: the funnel has to land short of it.
	_floor_at(ARENA + Vector3(0.0, 2.0, -1.0), Vector3(20.0, 6.0, 0.5))
	await _tick(1)
	var blocked := weapon._cast_spot(caster, forward)
	assert_lt(blocked.distance_to(ARENA), 1.0, "a wall in the way pulls the cast in short of it")
