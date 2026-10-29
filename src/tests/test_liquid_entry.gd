extends "res://src/tests/test_base.gd"
## What anything falling does when it hits a pool: one splash, on the surface, sized by the
## body — the sound out of LiquidSounds and the spray out of SplashEffect. A rolling stone is
## the subject here; the corpse half of the same path lives in test_ragdoll.gd.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.

const StoneScript = preload("res://src/projectiles/rolling_stone.gd")
const CorpseScript = preload("res://src/monsters/tumbling_corpse.gd")
const ARENA := Vector3(400.0, 200.0, -400.0)  # clear of map geometry, and of the other suites'

var _splashes: Array[AudioStreamPlayer3D] = []
var _sprays: Array[SplashEffect] = []


func _setup_test(_name: String) -> void:
	_splashes.clear()
	_sprays.clear()
	var scene := _scene()
	if scene and not scene.child_entered_tree.is_connected(_note_child):
		scene.child_entered_tree.connect(_note_child)


func _teardown_test() -> void:
	var scene := _scene()
	if scene and scene.child_entered_tree.is_connected(_note_child):
		scene.child_entered_tree.disconnect(_note_child)
	for spray in _sprays:
		if is_instance_valid(spray) and not spray.is_queued_for_deletion():
			spray.free()
	super()


## Both halves of a splash are parented to the current scene — SoundSystem's one-shots and the
## effect itself — so watching that node catches the lot.
func _note_child(node: Node) -> void:
	if node is SplashEffect:
		_sprays.append(node)
		return
	var player := node as AudioStreamPlayer3D
	if player and player.stream and player.stream.resource_path.contains("/misc/splash"):
		_splashes.append(player)


func _scene() -> Node:
	return (Engine.get_main_loop() as SceneTree).current_scene


## A pool whose surface sits `below` metres under `pos`: an Area3D on a liquid layer that
## nothing collides with and only a point query finds.
func _pool_below(pos: Vector3, below: float, layer := GameConsts.MASK_WATER) -> Area3D:
	var area := Area3D.new()
	area.collision_layer = layer
	area.collision_mask = 0
	area.monitorable = true
	area.monitoring = false
	var box := BoxShape3D.new()
	box.size = Vector3(40.0, 6.0, 40.0)
	var col := CollisionShape3D.new()
	col.shape = box
	area.add_child(col)
	_root().add_child(area)
	area.global_position = pos - Vector3(0.0, below + 3.0, 0.0)
	_keep(area)
	return area


func _stone_at(pos: Vector3) -> RollingStone:
	var stone: RollingStone = StoneScript.new()
	stone.setup({"position": pos, "direction": Vector3.DOWN, "lifetime": 2.0}, true)
	_root().add_child(stone)
	_keep(stone)
	return stone


## The base _tick plus an idle process frame, because the splash this suite looks for is parented
## by add_child.call_deferred and does not exist until the deferred queue flushes.
func _tick_flushed(frames: int) -> void:
	await _tick(frames)
	await _tree().process_frame


## The droplets of a spray, as the one-shot particle burst it was built with.
func _drops(spray: SplashEffect) -> GPUParticles3D:
	for child in spray.get_children():
		if child is GPUParticles3D:
			return child
	return null


func test_a_stone_splashes_going_into_the_water() -> void:
	_pool_below(ARENA, 1.0)
	_stone_at(ARENA)
	await _tick_flushed(30)

	assert_eq(_splashes.size(), 1, "one splash, on the way in (%d)" % _splashes.size())
	assert_eq(_sprays.size(), 1, "and one spray with it (%d)" % _sprays.size())


## A stone thrown across a dry room is not a splash waiting to happen.
func test_a_stone_that_never_meets_water_is_silent() -> void:
	_stone_at(ARENA)
	await _tick_flushed(30)

	assert_true(_splashes.is_empty(), "nothing to splash into (%d)" % _splashes.size())
	assert_true(_sprays.is_empty(), "and nothing sprayed (%d)" % _sprays.size())


## A stone that starts under the surface was already in there — it did not arrive.
func test_a_stone_born_under_the_surface_does_not_splash() -> void:
	_pool_below(ARENA, -1.0)  # surface a metre ABOVE the spawn
	_stone_at(ARENA)
	await _tick_flushed(30)

	assert_true(_splashes.is_empty(), "no entry to sound (%d)" % _splashes.size())
	assert_true(_sprays.is_empty(), "and no spray (%d)" % _sprays.size())


## The spray goes where the water is, not where the stone had sunk to by the time the probe
## caught it — it is bisected back onto the surface out of the tick that crossed it.
func test_the_spray_sits_on_the_surface() -> void:
	var surface_y := ARENA.y - 1.0
	_pool_below(ARENA, 1.0)
	_stone_at(ARENA)
	await _tick_flushed(30)

	assert_eq(_sprays.size(), 1, "the stone went in")
	var dy := _sprays[0].global_position.y - surface_y
	assert_true(dy > -0.05, "the spray is on the surface, not under it (%.2f below)" % -dy)
	assert_true(dy < 0.1, "and not left up where the stone was a moment ago (%.2f above)" % dy)


## Slime throws up slime. Water and slime share a sound, so the colour is the only thing that
## tells the two entries apart, and it rides the cached process material.
func test_slime_sprays_slime() -> void:
	_pool_below(ARENA, 1.0, GameConsts.MASK_SLIME)
	_stone_at(ARENA)
	await _tick_flushed(30)

	assert_eq(_sprays.size(), 1, "the stone went into the slime")
	var drops := _drops(_sprays[0])
	assert_ne(drops, null, "the spray has droplets")
	assert_eq(drops.process_material, AssetLoader.get_spark_particle_material("splash_slime"),
		"and they are the slime ones")


## The body makes the splash: a wizard displaces a pool, a stone dents it.
func test_a_body_sprays_harder_than_a_stone() -> void:
	_pool_below(ARENA, 1.0)
	_stone_at(ARENA)
	await _tick_flushed(30)
	assert_eq(_sprays.size(), 1, "the stone went in (%d)" % _sprays.size())
	var stone_drops := _drops(_sprays[0]).amount
	_sprays.clear()

	var corpse: TumblingCorpse = CorpseScript.new()
	corpse.setup(TumblingCorpse.wizard_payload(ARENA + Vector3(8.0, 0.0, 0.0), 0.0,
		GameConsts.Element.FIRE, Vector3.ZERO), true)
	_root().add_child(corpse)
	_keep(corpse)
	await _tick_flushed(60)  # a ragdoll probes with its pelvis, which starts a body's height higher up

	assert_eq(_sprays.size(), 1, "and so did the wizard (%d)" % _sprays.size())
	assert_gt(_drops(_sprays[0]).amount, stone_drops,
		"a body throws up more than a stone (%d vs %d)" % [_drops(_sprays[0]).amount, stone_drops])


## Debris goes in like anything else: a gib is a small fast body that falls THROUGH water,
## so it needs the same point query the corpse and the stone use.
func test_a_gib_splashes_going_into_the_water() -> void:
	_pool_below(ARENA, 1.0)
	var gib := GibEffect.SplashingGib.new()
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.2, 0.2, 0.2)
	col.shape = box
	gib.add_child(col)
	gib.collision_layer = 0
	gib.collision_mask = GameConsts.MASK_WORLD
	_root().add_child(gib)
	_keep(gib)
	gib.global_position = ARENA
	await _tick_flushed(30)

	assert_eq(_splashes.size(), 1, "the chunk went in (%d)" % _splashes.size())
	assert_eq(_sprays.size(), 1, "and threw up a spray (%d)" % _sprays.size())


## A burst is a shower, and a plop each would be a machine gun: only a few of it are built to
## hear the water, however big the break was.
func test_only_a_few_of_a_burst_splash() -> void:
	assert_eq(GibEffect.splashers_for(5), 2, "the smallest break still marks the water")
	assert_eq(GibEffect.splashers_for(48), GibEffect.MAX_SPLASHERS, "a house does not machine-gun")
	assert_true(GibEffect.splashers_for(48) < 48, "most of a big burst goes in unmarked")


## The replicated copy: online the host's effect is freed and every peer rebuilds one from the
## payload, so what setup() makes of it has to be the same spray.
func test_a_replicated_spray_rebuilds_from_its_payload() -> void:
	var spray := SplashEffect.new()
	spray.setup({"position": ARENA, "liquid": GameConsts.Liquid.LAVA, "size": 2.0}, false)
	_scene().add_child(spray)
	_keep(spray)
	await _tick_flushed(1)

	assert_vec3_almost_eq(spray.global_position, ARENA, 0.01, "rebuilt where it went in")
	var drops := _drops(spray)
	assert_ne(drops, null, "and with droplets")
	assert_eq(drops.process_material, AssetLoader.get_spark_particle_material("splash_lava"),
		"of the liquid it named")
