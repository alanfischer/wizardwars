extends "res://src/tests/test_base.gd"
## The windwall: the cone of air a held spell blows (WindWall), who it spares, what it does to a
## wizard and a spell in flight, and the book's eight seconds.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.

const Movement = preload("res://addons/pmove/movement.gd")
const MovementConfig = preload("res://addons/pmove/movement_config.gd")
const InputCommand = preload("res://addons/pmove/input_command.gd")
const GodotBodyScript = preload("res://addons/pmove/godot_body.gd")

const ARENA := Vector3(-200.0, 90.0, 0.0)   # clear of any map geometry and the other suites'
const DT := 1.0 / 60.0


## The bare surface Weapon.fire()/get_aim() reach for on a caster. Faces -Z, aims level.
class DummyCaster extends CharacterBody3D:
	var team := GameConsts.Team.BLUE
	var peer_id := 0
	var is_dead := false
	var revoked: Array[String] = []

	func _active_camera() -> Camera3D:
		return null

	func revoke_weapon(key: String) -> bool:
		revoked.append(key)
		return true


## A wizard on the real movement kernel, blown as a player is (PlayerMovementContext._blown).
class SimWalker extends CharacterBody3D:
	var is_dead := false
	var team: int = GameConsts.Team.RED
	var sim
	var body
	var state
	var ctx: PlayerMovementContext

	func set_collision_height(_h: float, _c: float) -> void:
		pass

	func begin() -> void:
		sim = Movement.Simulation.new(MovementConfig.new())
		body = GodotBodyScript.new(self)
		state = Movement.MovementState.new()
		state.bind_body(body)
		ctx = PlayerMovementContext.new(self, null, null)

	func step() -> void:
		state.velocity = velocity
		var cmd := InputCommand.new()
		cmd.delta = DT
		var mods := Movement.MovementModifiers.new()
		ctx._blown(mods, sim.cfg, state, cmd)
		state.velocity += mods.velocity_add
		sim.simulate_tick(body, state, cmd)
		velocity = state.velocity


var _weather: WeatherSystem
var _was_weather: WeatherSystem


## A weather with no map: no wind of its own, so all the air is the windwall's.
func _setup_test(_test_name: String) -> void:
	_was_weather = Game.weather_system
	_weather = WeatherSystem.new()
	Game.weather_system = _weather


func _teardown_test() -> void:
	Game.weather_system = _was_weather
	_weather.free()
	super._teardown_test()


func _caster_at(pos: Vector3) -> DummyCaster:
	var c := DummyCaster.new()
	var col := CollisionShape3D.new()
	col.shape = CapsuleShape3D.new()
	col.position.y = 0.9
	c.add_child(col)
	c.collision_layer = GameConsts.MASK_PLAYER
	_root().add_child(c)
	c.global_position = pos
	_keep(c)
	return c


## Blowing at full length (its front already run out), as a hold a moment old is.
func _wall_of(caster: DummyCaster) -> WindWall:
	var wall := WindWall.new(caster, true, false)
	caster.add_child(wall)
	wall._front = WindWall.LENGTH
	return wall


func _walker_at(pos: Vector3, team: int) -> SimWalker:
	var w := SimWalker.new()
	w.team = team
	var col := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.8
	col.shape = cap
	col.position.y = 0.9
	w.add_child(col)
	w.collision_layer = GameConsts.MASK_PLAYER
	w.collision_mask = GameConsts.MASK_WORLD
	_root().add_child(w)
	w.global_position = pos
	w.begin()
	_keep(w)
	return w


func _walk(walker: SimWalker, ticks: int) -> void:
	for i in ticks:
		await _physics_frame()
		walker.step()


## Eye height of a caster with no camera (Combat._eye_origin).
func _eye(caster: Node3D) -> Vector3:
	return caster.global_position + Vector3(0.0, 1.6, 0.0)


func test_the_spell_is_a_pickup_for_every_class() -> void:
	assert_true(SpawnRegistry.has_weapon("windwall_weapon"), "/give windwall_weapon finds it")
	for element in GameConsts.ELEMENT_NAMES:
		var w := SpawnRegistry.build_weapon("windwall_weapon", element)
		assert_true(w is WindwallWeapon, "every class can be handed it")
		assert_eq(w.player_attack_prefix, "combo", "cast with the combo-spell animation")
	assert_false("windwall_weapon" in GameConsts.COMBO_RECIPES.values(), "no recipe makes it yet")


func test_the_air_fills_a_cone_down_the_aim() -> void:
	var caster := _caster_at(ARENA)
	var wall := _wall_of(caster)
	wall._follow()
	var eye := _eye(caster)
	var ahead := wall.airflow(eye + Vector3(0, 0, -3), null)
	assert_lt(ahead.z, -30.0, "straight ahead it blows hard away (%.1f)" % ahead.z)
	var far := wall.airflow(eye + Vector3(0, 0, -8), null)
	assert_lt(ahead.z, far.z, "and softer toward the end (%.1f)" % far.z)
	assert_gt(wall.airflow(eye + Vector3(2.0, 0, -6), null).x, 0.0, "spreading as it goes")
	assert_eq(wall.airflow(eye + Vector3(0, 0, 1), null), Vector3.ZERO, "none behind the caster")
	assert_eq(wall.airflow(eye + Vector3(3.0, 0, -2), null), Vector3.ZERO, "none outside the cone")
	assert_eq(wall.airflow(eye + Vector3(0, 0, -WindWall.LENGTH - 1.0), null), Vector3.ZERO,
		"none past its end")


func test_a_wall_in_the_way_cuts_it_short() -> void:
	var caster := _caster_at(ARENA)
	_wall_at(_eye(caster) + Vector3(0, 0, -4.5), Vector3(10, 10, 0.5))
	var wall := _wall_of(caster)
	await _physics_frame()
	await _physics_frame()
	var eye := _eye(caster)
	assert_ne(wall.airflow(eye + Vector3(0, 0, -2.5), null), Vector3.ZERO, "this side of the wall")
	assert_eq(wall.airflow(eye + Vector3(0, 0, -6), null), Vector3.ZERO, "nothing through it")


func test_it_spares_the_caster_and_their_side() -> void:
	var caster := _caster_at(ARENA)
	var wall := _wall_of(caster)
	wall._follow()
	var p := _eye(caster) + Vector3(0, 0, -3)
	var ally := _walker_at(ARENA + Vector3(0, 0, -20), GameConsts.Team.BLUE)
	var enemy := _walker_at(ARENA + Vector3(0, 0, -22), GameConsts.Team.RED)
	assert_eq(wall.airflow(p, caster), Vector3.ZERO, "not the caster")
	assert_eq(wall.airflow(p, ally), Vector3.ZERO, "not an ally")
	assert_ne(wall.airflow(p, enemy), Vector3.ZERO, "an enemy")
	var own_shot := Projectile.new()
	own_shot.team = GameConsts.Team.BLUE
	_keep(own_shot)
	assert_eq(wall.airflow(p, own_shot), Vector3.ZERO, "nor a spell of their side's")


## An enemy standing in it is shoved back off their feet's grip, faster than they can run.
func test_an_enemy_in_it_is_shoved_away() -> void:
	_floor_at(ARENA - Vector3(0, 0.5, 0))
	var caster := _caster_at(ARENA)
	_wall_of(caster)
	var enemy := _walker_at(ARENA + Vector3(0, 0, -2.0), GameConsts.Team.RED)
	var ally := _walker_at(ARENA + Vector3(1.0, 0, -2.0), GameConsts.Team.BLUE)
	ally.collision_layer = 0
	await _walk(enemy, 30)
	await _walk(ally, 1)
	var pushed := ARENA.z - 2.0 - enemy.global_position.z
	assert_gt(pushed, 2.0, "half a second of it shoves an enemy metres away (%.1f m)" % pushed)
	assert_almost_eq(ally.global_position.z, ARENA.z - 2.0, 0.01, "and leaves an ally be")


## A spell flown into it head on is slowed, stopped and blown back the way it came.
func test_a_fireball_flown_into_it_is_blown_back() -> void:
	var caster := _caster_at(ARENA)
	var wall := _wall_of(caster)
	wall._follow()
	var shot := Projectile.new()
	shot.set_physics_process(false)
	shot.set_process(false)
	shot.team = GameConsts.Team.RED
	_root().add_child(shot)
	_keep(shot)
	shot.global_position = _eye(caster) + Vector3(0, 0, -WindWall.LENGTH)
	shot.direction = Vector3(0, 0, 1)
	shot.speed = 18.0
	var closest := INF
	for i in 120:
		shot._blow(DT)
		shot.global_position += shot.direction * shot.speed * DT
		closest = minf(closest, shot.global_position.distance_to(_eye(caster)))
	assert_lt(shot.direction.z, 0.0, "turned round, away from the caster")
	assert_gt(closest, 1.0, "before it reached them (%.1f m off)" % closest)


func test_the_book_holds_eight_seconds_of_wind() -> void:
	var caster := _caster_at(ARENA)
	var weapon := SpawnRegistry.build_weapon("windwall_weapon") as WindwallWeapon
	var repeats := roundi(WindwallWeapon.BLOWING / weapon.cooldown)
	for i in repeats - 1:
		assert_true(weapon.can_fire(caster), "still blowing at %d" % i)
		weapon.fire(caster)
	assert_eq(_weather._wind_sources().size(), 1, "one wind for the whole hold")
	assert_true(weapon.can_fire(caster), "the last repeat left")
	weapon.fire(caster)
	assert_false(weapon.can_fire(caster), "spent")
	await _physics_frame()
	assert_eq(caster.revoked, ["windwall_weapon"], "and the spell leaves the loadout")
	assert_eq(_weather.local_airflow(_eye(caster) + Vector3(0, 0, -3)), Vector3.ZERO, "the air stops")


func test_letting_go_stops_the_air_at_once() -> void:
	var caster := _caster_at(ARENA)
	var weapon := SpawnRegistry.build_weapon("windwall_weapon") as WindwallWeapon
	weapon.fire(caster)
	await _physics_frame()
	await _physics_frame()
	await _physics_frame()
	await _physics_frame()
	var p := _eye(caster) + Vector3(0, 0, -2)
	assert_ne(_weather.local_airflow(p), Vector3.ZERO, "held, it blows")
	weapon.stop_firing(caster)
	assert_eq(_weather.local_airflow(p), Vector3.ZERO, "let go, it stops")
	var again := weapon.fire(caster)
	assert_true(again, "and a fresh press blows again")
	weapon.stop_firing(caster)
