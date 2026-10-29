extends SceneTree
## The cockpit floor in plan view: where does a STANDING rider get thrown, and how far?
##
## Every earlier probe walked the centreline (y = 0) and so only ever saw the rear wall.
## The back corners are where two walls meet, and that is a different problem: an axis
## probe out of the rear wall stays inside the side wall and vice versa, so no single
## axis escapes and the push-out falls through to the leaf-plane guess.
##
## Golem forward is GoldSrc +x and up is +z, so its RIGHT is -y. Prints body-local GS.
##
## Usage: [Z=-112] [H=1.8] tools/probe_golem_corner.gd

const S := 0.025

var body_node: AnimatableBody3D
var player: CharacterBody3D


func gs_to_godot(x: float, y: float, z: float) -> Vector3:
	return Vector3(-x * S, z * S, y * S)


func vec_local_gs(v: Vector3) -> Vector3:
	var l: Vector3 = body_node.global_transform.basis.inverse() * v
	return Vector3(-l.x / S, l.z / S, l.y / S)


func _initialize() -> void:
	var root: Node3D = (load("user://resources/maps/ww_golem.scn") as PackedScene).instantiate()
	get_root().add_child(root)
	for i in 20:
		await physics_frame
	for n in root.find_children("*", "AnimatableBody3D", true, false):
		if String(n.get_meta("entity", {}).get("classname", "")) == "func_golem_body":
			body_node = n

	var h := float(OS.get_environment("H")) if OS.get_environment("H") != "" else 1.8
	player = CharacterBody3D.new()
	player.collision_layer = 0
	player.collision_mask = 33
	player.safe_margin = 0.01
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = h
	cs.shape = cap
	cs.position = Vector3(0, h * 0.5, 0)
	player.add_child(cs)
	root.add_child(player)

	var p := PhysicsTestMotionParameters3D.new()
	p.motion = Vector3.ZERO
	p.recovery_as_collision = true
	p.max_collisions = 4
	p.margin = player.safe_margin
	var res := PhysicsTestMotionResult3D.new()

	var feet_z := float(OS.get_environment("Z")) if OS.get_environment("Z") != "" else -112.0
	print("standing hull %.1f m, feet at body-local GS z=%.1f" % [h, feet_z])
	print("rows = x (forward +, rear -), cols = y (LEFT + ... RIGHT -)")
	print("'.' free   digit = units the recovery throws it (9 = 9+)   '*' = thrown 16+\n")

	print("BACK-RIGHT corner, sweeping feet height (the bob drives the deck up into the")
	print("rider). '+y' = pushed back into the cockpit, '-y' = pushed OUT through the wall.\n")
	print(" feet z |" + "".join(range(-64, -89, -4).map(func(y): return "     y=%d" % y)))
	for zi in range(-110, -125, -1):
		var line := "%7d |" % zi
		for yi in range(-64, -89, -4):
			player.global_position = body_node.global_transform * gs_to_godot(-16.0, float(yi), float(zi))
			PhysicsServer3D.body_set_state(
				player.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, player.global_transform)
			await physics_frame
			p.from = player.global_transform
			PhysicsServer3D.body_test_motion(player.get_rid(), p, res)
			var mv := vec_local_gs(res.get_travel())
			if Vector3(mv.x, mv.y, 0.0).length() < 0.6:
				line += "       . "
			else:
				line += "%5.0f,%3.0f " % [mv.x, mv.y]
		print(line)
	print("\n(cells are x,y push in GS units; negative y = ejected outward)")
	quit(0)
