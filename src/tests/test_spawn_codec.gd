extends "res://src/tests/test_base.gd"
## SpawnCodec: whatever goes in comes back equal, and a projectile's spawn shrinks to a fraction
## of var_to_bytes, since it is resent until each client acks it.


func _missile() -> Dictionary:
	return {
		"position": Vector3(1.5, 2.25, -3.75),
		"direction": Vector3(0.6, 0.0, 0.8),
		"damage_type": 0,
		"script_path": "res://src/projectiles/magic_missile.gd",
		"entity_id": 1234,
		"born_ms": 123456789,
	}


func test_a_missile_round_trips() -> void:
	var d := _missile()
	assert_eq(SpawnCodec.unpack(SpawnCodec.pack(d)), d)


func test_a_missile_packs_small() -> void:
	var packed := SpawnCodec.pack(_missile())
	var plain := var_to_bytes(_missile()).size()
	var wire := var_to_bytes(packed).size()  # what goldnet actually ships
	assert_true(wire * 2.5 < plain, "%d bytes on the wire, was %d" % [wire, plain])


func test_every_value_type_round_trips() -> void:
	var d := {
		"speed": 50.0,
		"start_angle": 0.1,  # needs a double
		"team": -1,
		"born_ms": 1 << 40,
		"is_first": true,
		"lead": false,
		"model_path": "models/missile.mdl",
		"ring_color": Color(0.2, 0.4, 0.6, 1.0),
		"ent": {"classname": "func_door", "size": "64"},
		"players": [3, 4],
		"not_in_the_table": Vector3.UP,
		7: "a non-string key",
	}
	assert_eq(SpawnCodec.unpack(SpawnCodec.pack(d)), d)


func test_a_path_outside_src_goes_whole() -> void:
	var d := {"script_path": "res://addons/elsewhere/thing.gd"}
	assert_eq(SpawnCodec.unpack(SpawnCodec.pack(d)), d)


func test_extreme_ints_round_trip() -> void:
	for v in [0, 1, -1, 63, -64, 64, 1 << 62, -(1 << 62), 9223372036854775807, -9223372036854775807 - 1]:
		var d := {"damage": v}
		assert_eq(SpawnCodec.unpack(SpawnCodec.pack(d)), d, "int %d" % v)
