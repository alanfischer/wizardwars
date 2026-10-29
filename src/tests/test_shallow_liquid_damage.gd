extends "res://src/tests/test_base.gd"
## Standing in shallow lava has to burn you.
##
## Liquid damage used to query the same probe check_water uses for swimming: a 0.1-radius sphere
## at y 0.9, the player's waist. That is GoldSrc's waterlevel 2 (the swim threshold), but damage
## in GoldSrc starts at waterlevel 1 — feet in — so anything shallower than 0.8 units could not
## hurt anybody. Sixteen func_water brushes across five maps sit under that line, including
## ww_countryside's four skin -5 lava brushes (28 units deep, never burned a soul) and
## ww_golem's two pads at exactly 0.8, tangent at best.
##
## Damage now tests the player's own capsule. These cases are the depths that were silently
## unreachable.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.

# player.tscn's own capsule, mirrored rather than instantiated: pulling in the real player scene
# drags a skeleton and the global attack-animation cache along with it, and this file runs
# immediately before test_skeleton.gd, which measures bone positions.
const HULL_RADIUS := 0.4
const HULL_HEIGHT := 1.8


## Depths in GoldSrc units, as the maps actually build them, converted at SCALE_FACTOR.
const GOLEM_PAD := 32.0        # ww_golem's lava/slime pads — exactly the old 0.8 threshold
const COUNTRYSIDE_LAVA := 28.0 # ww_countryside *45-*48, skin -5
const SHALLOWEST := 8.0        # ww_countryside *1 etc — ankle deep

var _move_ctx: PlayerMovementContext  # the context belonging to the body _player() last built


## A liquid slab `depth_units` tall (GoldSrc units) sitting on y=0, like a map's pool floor.
func _liquid(layer: int, depth_units: float) -> Area3D:
	var area := Area3D.new()
	area.collision_layer = layer
	area.collision_mask = 0
	area.monitorable = true
	area.monitoring = false
	var box := BoxShape3D.new()
	var depth := depth_units * GameConsts.SCALE_FACTOR
	box.size = Vector3(8.0, depth, 8.0)
	var col := CollisionShape3D.new()
	col.shape = box
	col.position = Vector3(0.0, depth * 0.5, 0.0)  # slab rests on y=0
	area.add_child(col)
	_root().add_child(area)
	_spawned.append(area)
	return area


## A player-shaped body standing on the pool floor, capsule origin at its feet on y=0, with a
## movement context wired to it exactly as player.gd does.
func _player() -> Node3D:
	var body := CharacterBody3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = HULL_RADIUS
	capsule.height = HULL_HEIGHT
	var col := CollisionShape3D.new()
	col.name = "CollisionShape3D"
	col.shape = capsule
	col.position = Vector3(0.0, HULL_HEIGHT * 0.5, 0.0)
	body.add_child(col)

	# The submersion probe player.tscn carries: a 0.1 sphere at the waist.
	var detector := Area3D.new()
	detector.name = "WaterDetector"
	detector.collision_layer = 0
	detector.collision_mask = GameConsts.MASK_WATER
	detector.monitorable = false
	var sphere := SphereShape3D.new()
	sphere.radius = 0.1
	var dcol := CollisionShape3D.new()
	dcol.shape = sphere
	dcol.position = Vector3(0.0, 0.9, 0.0)
	detector.add_child(dcol)
	body.add_child(detector)

	_root().add_child(body)
	body.global_position = Vector3.ZERO
	_move_ctx = PlayerMovementContext.new(body, null, detector)
	_spawned.append(body)
	return body


func test_golem_depth_lava_burns() -> void:
	_liquid(GameConsts.MASK_WATER | GameConsts.MASK_LAVA, GOLEM_PAD)
	_player()
	await _tick(4)
	assert_true(_move_ctx.check_lava(), "a 32-unit lava pad burns the player standing in it")


func test_golem_depth_slime_stings() -> void:
	_liquid(GameConsts.MASK_WATER | GameConsts.MASK_SLIME, GOLEM_PAD)
	_player()
	await _tick(4)
	assert_true(_move_ctx.check_slime(), "and a 32-unit slime pad stings")


func test_countryside_depth_lava_burns() -> void:
	_liquid(GameConsts.MASK_WATER | GameConsts.MASK_LAVA, COUNTRYSIDE_LAVA)
	_player()
	await _tick(4)
	assert_true(_move_ctx.check_lava(), "28-unit lava burns — ww_countryside's, which never did")


func test_ankle_deep_lava_burns() -> void:
	_liquid(GameConsts.MASK_WATER | GameConsts.MASK_LAVA, SHALLOWEST)
	_player()
	await _tick(4)
	assert_true(_move_ctx.check_lava(), "even 8 units of lava burns: contact, not submersion")


## The other half of the rule: contact is not submersion. Shallow liquid must NOT start you
## swimming, or every puddle in the game would become a swim.
func test_shallow_liquid_does_not_start_a_swim() -> void:
	_liquid(GameConsts.MASK_WATER, GOLEM_PAD)
	_player()
	await _tick(4)
	assert_false(_move_ctx.check_water(), "ankle-deep water is walked through, not swum in")


## Deep water still swims — the waist probe is untouched.
func test_deep_water_still_swims() -> void:
	_liquid(GameConsts.MASK_WATER, 200.0)  # 5 units, well over the player's head
	_player()
	await _tick(4)
	assert_true(_move_ctx.check_water(), "deep water still starts a swim")


## Lava you are standing OVER must not burn you: the capsule reaches up from the feet, never down.
func test_lava_below_a_ledge_does_not_burn() -> void:
	var pool := _liquid(GameConsts.MASK_WATER | GameConsts.MASK_LAVA, GOLEM_PAD)
	pool.global_position = Vector3(0.0, -3.0, 0.0)
	_player()
	await _tick(4)
	assert_false(_move_ctx.check_lava(), "lava three units below the floor is scenery")
