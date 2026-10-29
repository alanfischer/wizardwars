extends "res://src/tests/test_base.gd"
## A satchel's cockleburs are launched by setting linear_velocity in setup(), so they must fly
## and fall under the project's gravity. Regression: hop-godot dropped the space's default-area
## gravity, leaving dynamic bodies on hop's construction-time 9.81 instead of 20.

const CockleburrScript = preload("res://src/monsters/cockleburr.gd")

const SPAWN_POS := Vector3(0.0, 40.0, 0.0)  # clear of map geometry; nothing to land on
const SETTLE_FRAMES := 60  # 1s at 60Hz


func _spawn_like_the_spawner() -> Cockleburr:
	# Mirrors main._spawn_dyn_entity: setup() first, add_child() after.
	var b: Cockleburr = CockleburrScript.new()
	b.setup({"position": SPAWN_POS, "team": 1}, true)
	_root().add_child(b)
	return b


func test_velocity_set_before_tree_entry_survives() -> void:
	var b := _spawn_like_the_spawner()
	await (Engine.get_main_loop() as SceneTree).physics_frame
	assert_gt(b.linear_velocity.length(), 0.1,
		"the launch velocity set before tree entry reached the physics body (got %.3f)"
			% b.linear_velocity.length())
	b.queue_free()


func test_launched_burr_moves() -> void:
	var b := _spawn_like_the_spawner()
	var start := b.global_position
	var tree := Engine.get_main_loop() as SceneTree
	for i in SETTLE_FRAMES:
		await tree.physics_frame
	# Assert descent, not distance travelled: an upward launch returns near its start
	# mid-flight, which a distance check would misread as "didn't move".
	var dy := b.global_position.y - start.y
	assert_lt(dy, -1.0, "a launched cocklebur falls back down (dy %.3f)" % dy)
	b.queue_free()
