extends SceneTree
## What is BEHIND the golem's rear cockpit wall, at rider height? The step path lifts a
## walker 18 units (0.45 m) before sliding, so a wall it cannot walk through it may still
## step over — this maps how solid the rear wall is from the deck up.

const S := 0.025

var body_node: AnimatableBody3D
var player: CharacterBody3D
var shape: CollisionShape3D


func gs_to_godot(x: float, y: float, z: float) -> Vector3:
	return Vector3(-x * S, z * S, y * S)


func _initialize() -> void:
	var root: Node3D = (load("user://resources/maps/ww_golem.scn") as PackedScene).instantiate()
	get_root().add_child(root)
	for i in 20: await physics_frame
	for n in root.find_children("*", "AnimatableBody3D", true, false):
		if String(n.get_meta("entity", {}).get("classname", "")) == "func_golem_body":
			body_node = n

	player = CharacterBody3D.new()
	player.collision_layer = 0
	player.collision_mask = GameConsts.MASK_WORLD_AND_CLIP | GameConsts.MASK_ENTITY
	player.safe_margin = 0.01
	shape = CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.8
	shape.shape = cap
	shape.position = Vector3(0, 0.9, 0)
	player.add_child(shape)
	root.add_child(player)

	var p := PhysicsTestMotionParameters3D.new()
	p.motion = Vector3.ZERO
	p.margin = player.safe_margin
	p.recovery_as_collision = true
	p.max_collisions = 4
	var res := PhysicsTestMotionResult3D.new()

	print("Standing hull at body-local GS, y=-80 (back-right). '#' = overlapping solid,")
	print("'.' = free. rows = feet z, cols = x (cockpit at x>-16, outside at x<-16).\n")
	var xs := range(-8, -40, -3)
	var head := "  feet z |"
	for x in xs: head += "%5d" % x
	print(head)
	for zi in range(-150, -60, 4):
		var line := "%8d |" % zi
		for xi in xs:
			player.global_position = body_node.global_transform * gs_to_godot(float(xi), -80.0, float(zi))
			PhysicsServer3D.body_set_state(
				player.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, player.global_transform)
			await physics_frame
			p.from = player.global_transform
			PhysicsServer3D.body_test_motion(player.get_rid(), p, res)
			var deep := 0.0
			for i in res.get_collision_count():
				deep = maxf(deep, res.get_collision_depth(i))
			line += "    #" if deep > player.safe_margin else "    ."
		print(line)
	quit(0)
