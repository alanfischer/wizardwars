extends "res://src/tests/test_base.gd"
## Riding ww_2fort's lift, which is the shape that breaks recovery.
##
## The lift is a func_door that rises 20 m. Its brush is a deck with four rope plates
## pitched over it, and in the GoldSrc hull a player standing on the deck has the ropes'
## solid a clear 33 units above their head. hop measured the way out of a solid by
## sweeping BACK from the far end of its search budget, so with that second band in
## range it answered with the far side of the ropes — a player one centimetre inside the
## rising deck was told they were 1.2 m deep, move_and_slide's recovery launched them
## that far, and the lift read a rider it could not lift clear and reversed halfway up.
##
## The map is the fixture on purpose: a hand-built one cannot hold the shape, because the
## second band only lands inside the budget when the plate making it is SLOPED.
##
## COVERAGE, measured against the hop build before the fix: depth_tracks_the_penetration
## reports 1.2157 for a 1 cm sink (every sink reads ~1.2), and the rider is thrown off and
## the lift reverses, so rides_to_the_top ends with the lift back at the bottom.

const Movement = preload("res://addons/pmove/movement.gd")
const InputCommand = preload("res://addons/pmove/input_command.gd")
const MovementConfig = preload("res://addons/pmove/movement_config.gd")
const GodotBodyC = preload("res://addons/pmove/godot_body.gd")

const MAP := "ww_2fort"
const LIFT := "blue_lift"
const TICK := 1.0 / 60.0

var _map_root: Node3D
var _lift: Node3D
var _deck: Vector3
var _rider: CharacterBody3D


## The map, with the entity scripts main.gd would have attached before it entered the tree.
func _load_map() -> bool:
	var converter := MapConverter.new()
	_root().add_child(converter)
	var ok: bool = converter.convert(MAP)
	converter.queue_free()
	if not ok:
		return false
	var scn := ResourceLoader.load("user://resources/maps/%s.scn" % MAP, "",
			ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	_map_root = scn.instantiate()
	var scripts := {"func_door": FuncDoor, "trigger_multiple": TriggerMultiple}
	for child in _map_root.get_children():
		if not child.has_meta("entity"):
			continue
		var e: Dictionary = child.get_meta("entity")
		if scripts.has(e.get("classname", "")):
			child.set_script(scripts[e.get("classname", "")])
		if e.get("targetname", "") == LIFT:
			_lift = child
	_root().add_child(_map_root)
	return _lift != null


## Top centre of the lift deck, from the lift's own collision.
func _deck_top() -> Vector3:
	var box := AABB()
	var first := true
	for cs in _lift.find_children("*", "CollisionShape3D", true, false):
		if cs.shape == null:
			continue
		for v in cs.shape.get_debug_mesh().get_faces():
			var w: Vector3 = cs.global_transform * v
			if first:
				box = AABB(w, Vector3.ZERO)
				first = false
			else:
				box = box.expand(w)
	return Vector3(box.position.x + box.size.x * 0.5, box.position.y + 0.1,
		box.position.z + box.size.z * 0.5)


func _make_rider(cfg: MovementConfig) -> CharacterBody3D:
	var p := _pmove_body(cfg.stand_height)
	p.collision_mask = 33  # world + the elevator's layer
	_root().add_child(p)
	return p


func _teardown_test() -> void:
	if is_instance_valid(_rider):
		_rider.free()
	if is_instance_valid(_map_root):
		_map_root.free()
	_rider = null
	_map_root = null
	_lift = null


## How deep the physics server thinks the rider is, sunk `sink` metres into the deck.
func _reported_depth(sink: float) -> float:
	_rider.global_position = Vector3(_deck.x, _deck.y - sink, _deck.z + 1.1)
	await _physics_frame()
	var mp := PhysicsTestMotionParameters3D.new()
	mp.from = _rider.global_transform
	mp.motion = Vector3.ZERO
	mp.margin = _rider.safe_margin
	mp.recovery_as_collision = true
	mp.max_collisions = 6
	var mr := PhysicsTestMotionResult3D.new()
	PhysicsServer3D.body_test_motion(_rider.get_rid(), mp, mr)
	var deepest := 0.0
	for k in mr.get_collision_count():
		deepest = maxf(deepest, mr.get_collision_depth(k))
	return deepest


func test_depth_tracks_the_penetration() -> void:
	if not _load_map():
		assert_true(false, "%s has a %s to ride" % [MAP, LIFT])
		return
	var cfg := MovementConfig.new()
	_rider = _make_rider(cfg)
	_deck = _deck_top()
	await _settle()
	# One physics frame per probe, and the answer must be the sink itself — this is the
	# spot where the ropes' hull stands 33 units overhead.
	for sink in [0.01, 0.0625, 0.1]:
		var got: float = await _reported_depth(sink)
		assert_lt(got, sink + 0.02,
			"sunk %.4f m into the deck, the server should report about that, not %.4f"
			% [sink, got])


func test_rides_to_the_top() -> void:
	if not _load_map():
		assert_true(false, "%s has a %s to ride" % [MAP, LIFT])
		return
	var cfg := MovementConfig.new()
	_rider = _make_rider(cfg)
	_deck = _deck_top()
	await _settle()
	_rider.global_position = Vector3(_deck.x, _deck.y + 0.05, _deck.z)

	var sim := Movement.Simulation.new(cfg)
	var body = GodotBodyC.new(_rider)
	var state := Movement.MovementState.new()
	state.bind_body(body)
	state.on_floor = true
	var seq := 0
	var step := func() -> void:
		var cmd := InputCommand.new()
		cmd.seq = seq
		seq += 1
		cmd.delta = TICK
		sim.simulate_tick(body, state, cmd)
	for i in 30:
		step.call()
		await _physics_frame()

	var start_lift: float = _lift.global_position.y
	var start_rel: float = _rider.global_position.y - start_lift
	TriggerSystem.fire(LIFT, _rider, TriggerSystem.Type.TOGGLE)
	var worst_rel := 0.0
	for i in 200:
		step.call()
		await _physics_frame()
		worst_rel = maxf(worst_rel, absf(_rider.global_position.y - _lift.global_position.y - start_rel))

	assert_gt(_lift.global_position.y - start_lift, 10.0,
		"200 ticks in, the lift should be well up its 20 m of travel, not reversed")
	assert_lt(worst_rel, 0.15,
		"the rider should ride the deck, not be thrown off it (worst %.3f m)" % worst_rel)
