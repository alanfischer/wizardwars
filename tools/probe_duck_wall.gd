extends SceneTree
## Does the golem's rear cockpit wall still block a DUCKED rider?
##
## Riding the walking golem and ducking in the back-right corner ejects the rider out the
## back: the tick the crouch lands, a backward step goes from unsafe_frac 0.07 (blocked)
## to 1.00 (wide open) and the rider simply walks out through the wall. Standing is 1.8 m
## (GoldSrc hull 1), crouched is 0.9 m (hull 3) — so this asks the same question of both
## hulls at the same spot.

const S := 0.025

var body_node: AnimatableBody3D
var player: CharacterBody3D
var shape: CollisionShape3D
var cap: CapsuleShape3D


func gs_to_godot(x: float, y: float, z: float) -> Vector3:
	return Vector3(-x * S, z * S, y * S)


func vec_local_gs(v: Vector3) -> Vector3:
	var l: Vector3 = body_node.global_transform.basis.inverse() * v
	return Vector3(-l.x / S, l.z / S, l.y / S)


func _set_height(h: float) -> void:
	cap.height = h
	shape.position = Vector3(0, h * 0.5, 0)


func _initialize() -> void:
	var root: Node3D = (load("user://resources/maps/ww_golem.scn") as PackedScene).instantiate()
	get_root().add_child(root)
	for i in 20:
		await physics_frame
	for n in root.find_children("*", "AnimatableBody3D", true, false):
		if String(n.get_meta("entity", {}).get("classname", "")) == "func_golem_body":
			body_node = n

	player = CharacterBody3D.new()
	player.collision_layer = 0
	player.collision_mask = GameConsts.MASK_WORLD_AND_CLIP | GameConsts.MASK_ENTITY
	player.safe_margin = 0.01
	shape = CollisionShape3D.new()
	cap = CapsuleShape3D.new()
	cap.radius = 0.4
	shape.shape = cap
	player.add_child(shape)
	root.add_child(player)

	var p := PhysicsTestMotionParameters3D.new()
	p.margin = player.safe_margin
	p.recovery_as_collision = true
	p.max_collisions = 4
	var res := PhysicsTestMotionResult3D.new()
	# Straight back, away from the cockpit: golem forward is GoldSrc +x.
	var back: Vector3 = (body_node.global_transform.basis * gs_to_godot(-1.0, 0.0, 0.0)).normalized()

	print("A step at the rear wall. unsafe=1.00 means nothing blocks it.\n")
	print("  height |    x |  unsafe | travel back (GS units) | manifold")
	for h in [1.8, 0.9]:
		_set_height(h)
		for xi in [-15.5, -15.57, -15.8, -15.95]:
			player.global_position = body_node.global_transform * gs_to_godot(xi, -79.87, -111.93)
			PhysicsServer3D.body_set_state(
				player.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, player.global_transform)
			await physics_frame
			p.from = player.global_transform
			p.motion = back * 0.15
			PhysicsServer3D.body_test_motion(player.get_rid(), p, res)
			var moved := vec_local_gs(res.get_travel())
			var man := ""
			for i in res.get_collision_count():
				var n := vec_local_gs(res.get_collision_normal(i))
				man += " n=(%.2f,%.2f,%.2f)d=%.1f" % [n.x, n.y, n.z, res.get_collision_depth(i) / S]
			print("  %6.1f | %6.2f | %7.2f | %6.2f | %s" % [
				h, xi, res.get_collision_unsafe_fraction(), moved.x,
				man if man != "" else "(none)"])
		print("")

	# Sideways into the RIGHT wall: standing (hull 1, 72u tall) and crouched (hull 3, 36u)
	# can meet solid at different places from the same feet position.
	var right: Vector3 = (body_node.global_transform.basis * gs_to_godot(0.0, -1.0, 0.0)).normalized()
	print("A step RIGHT (-y) toward the side wall, feet at x=-15.6 z=-111.93.\n")
	print("  height |    y |  unsafe | travel right (GS) | manifold")
	for h in [1.8, 0.9]:
		_set_height(h)
		for yi in [-78.0, -79.97, -80.5, -81.5, -82.25]:
			player.global_position = body_node.global_transform * gs_to_godot(-15.6, yi, -111.93)
			PhysicsServer3D.body_set_state(
				player.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, player.global_transform)
			await physics_frame
			p.from = player.global_transform
			p.motion = right * 0.15
			PhysicsServer3D.body_test_motion(player.get_rid(), p, res)
			var moved := vec_local_gs(res.get_travel())
			var man := ""
			for i in res.get_collision_count():
				var n := vec_local_gs(res.get_collision_normal(i))
				man += " n=(%.2f,%.2f,%.2f)d=%.1f" % [n.x, n.y, n.z, res.get_collision_depth(i) / S]
			print("  %6.1f | %6.2f | %7.2f | %6.2f | %s" % [
				h, yi, res.get_collision_unsafe_fraction(), moved.y,
				man if man != "" else "(none)"])
		print("")
	quit(0)
