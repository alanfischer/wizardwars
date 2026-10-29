extends "res://src/tests/test_base.gd"
## A func_water is a door: GoldSrc's doors.cpp does LINK_ENTITY_TO_CLASS(func_water, CFuncDoor),
## which is how a map floods. ww_volcano ships one — "volc", a lava brush with lip 160 that
## rises on trigger — though nothing in that map ever fires it, so this is the only thing
## standing between the feature and a silent regression.
##
## The other half is what SOLID_NOT costs a door: no touch activation, nothing to crush, and
## an unnamed pool must stay plain scenery rather than paying a mover's overhead. The game has
## well over a hundred static pools.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.


func _teardown_test() -> void:
	_despawn_all()
	TriggerSystem.reset()


## Untyped on purpose: an AnimatableBody3D only becomes a mover once the script is attached.
## Built like the BSP converter leaves one — brush collision plus the liquid Volume Area3D.
func _water(keys := {}):
	var body = AnimatableBody3D.new()
	var shape := ConcavePolygonShape3D.new()
	# Spans 8 Godot units on every axis, which is ww_volcano *75's real 320-unit cube. The size
	# is not arbitrary: travel is |brush measured along move_dir| - lip, so a brush SMALLER than
	# its own lip travels a negative distance and floods downward. A toy 2-unit brush against
	# volcano's 160-unit (= 4.0 Godot) lip does exactly that.
	shape.set_faces(PackedVector3Array([
		Vector3.ZERO, Vector3(8, 8, 8), Vector3(8, 0, 0),
		Vector3.ZERO, Vector3(0, 8, 8), Vector3(0, 0, 8),
	]))
	var col := CollisionShape3D.new()
	col.shape = shape
	body.add_child(col)

	var volume := Area3D.new()
	volume.name = "Volume"
	body.add_child(volume)

	var e := {"classname": "func_water", "skin": "-3", "speed": "500"}
	e.merge(keys, true)
	body.set_meta("entity", e)
	body.set_script(FuncWater)
	_root().add_child(body)
	_spawned.append(body)
	return body


## ww_volcano's "volc", verbatim from the entity lump: a lava flood that rises on trigger.
func _volc(keys := {}):
	var e := {
		"classname": "func_water", "targetname": "volc", "skin": "-5",
		"angles": "-90 0 0", "lip": "160", "speed": "25", "wait": "5",
		"WaveHeight": "3.2", "rendercolor": "0 0 0",
	}
	e.merge(keys, true)
	return _water(e)


# --- A named water brush is a working door ---

func test_named_water_rises_when_triggered() -> void:
	var w = _volc()
	assert_eq(w.state, FuncDoorBase.State.AT_BOTTOM, "the flood starts down")
	var start: Vector3 = w.position

	TriggerSystem.fire("volc")
	await _tick(10)
	assert_gt(w.position.y, start.y, "triggering 'volc' raises the lava")


func test_volcano_keys_travel_upward() -> void:
	var w = _volc()
	# angles "-90 0 0" is straight up in GoldSrc's convention; travel is the brush measured
	# along that axis, less the lip. Sign is what matters — the map's own numbers decide size.
	assert_gt(w.move_dir.y, 0.9, "angles -90 points the flood up")
	assert_gt(w.position2.y, w.position1.y, "its open position is above its closed one")
	# 320-unit cube less a 160-unit lip = 160 units of travel, half its own height.
	assert_almost_eq(w.position2.y, 160.0 * GameConsts.SCALE_FACTOR, 0.001,
		"and it rises by exactly the brush height less the lip")


func test_water_returns_after_its_wait() -> void:
	# wait 1 rather than volcano's 5: the test should not sit through a five second flood.
	var w = _volc({"wait": "1", "speed": "2000"})
	TriggerSystem.fire("volc")
	await _tick(20)
	assert_eq(w.state, FuncDoorBase.State.AT_TOP, "it reaches the top")
	await _tick(120)
	assert_eq(w.state, FuncDoorBase.State.AT_BOTTOM, "and falls back once the wait expires")


## The swimmable volume is a CHILD of the brush, so it has to ride the tween. If it ever stops
## doing so the water would render in one place and be swimmable in another.
func test_liquid_volume_rides_the_move() -> void:
	var w = _volc()
	var volume: Area3D = w.get_node("Volume")
	var start := volume.global_position.y
	TriggerSystem.fire("volc")
	await _tick(10)
	assert_gt(volume.global_position.y, start, "the liquid volume follows the surface up")


## SOLID_NOT: nothing can be caught between water and where it is going, so it must not build
## the detector — and must not take the door's coplanar depth-bias fix either, which rebuilds
## the ArrayMesh the depth-prepass twin shares.
func test_water_has_no_blocked_detector() -> void:
	var w = _volc()
	assert_eq(w.get_node_or_null("BlockedDetector"), null, "water crushes nobody")


# --- An unnamed water brush stays scenery ---

func test_unnamed_water_is_not_a_mover() -> void:
	var w = _water()  # no targetname: nothing can ever trigger it
	assert_eq(w.get_node_or_null("MoverSync"), null,
		"a static pool pays for no mover synchroniser")
	assert_eq(MoverNetPublisher.of(w), null,
		"nor for the publisher that feeds it")
	assert_eq(w.get_node_or_null("TouchArea"), null,
		"and SOLID_NOT means it could not be touch-activated anyway")


func test_unnamed_water_ignores_a_trigger() -> void:
	var w = _water()
	var start: Vector3 = w.position
	w.trigger(null, TriggerSystem.Type.TOGGLE)
	await _tick(10)
	assert_vec3_almost_eq(w.position, start, 0.001, "scenery water does not move")


## The liquid still has to work: layers are what make it swimmable, and they are set before
## any of the movement code runs.
func test_static_water_still_configures_its_volume() -> void:
	var w = _water({"skin": "-5"})
	var volume: Area3D = w.get_node("Volume")
	assert_true((volume.collision_layer & GameConsts.MASK_WATER) != 0, "lava still swims")
	assert_true((volume.collision_layer & GameConsts.MASK_LAVA) != 0, "and still burns")
