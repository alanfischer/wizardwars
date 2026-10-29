extends SceneTree
## One body_test_motion at one body-local GoldSrc spot, with HOP_DEBUG tracing.
## Env: X, Y, Z (body-local GS), DX, DY, DZ (motion in GS units), H (hull height).
const S := 0.025
func _env(n: String, d: float) -> float:
	return float(OS.get_environment(n)) if OS.get_environment(n) != "" else d
func gs(x: float, y: float, z: float) -> Vector3:
	return Vector3(-x * S, z * S, y * S)
func _initialize() -> void:
	var root: Node3D = (load("user://resources/maps/ww_golem.scn") as PackedScene).instantiate()
	get_root().add_child(root)
	for i in 20: await physics_frame
	var body: AnimatableBody3D
	for n in root.find_children("*", "AnimatableBody3D", true, false):
		if String(n.get_meta("entity", {}).get("classname", "")) == "func_golem_body":
			body = n
	var h := _env("H", 1.8)
	var player := CharacterBody3D.new()
	player.collision_layer = 0
	player.collision_mask = GameConsts.MASK_WORLD_AND_CLIP | GameConsts.MASK_ENTITY
	player.safe_margin = 0.01
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = h
	cs.shape = cap
	cs.position = Vector3(0, h * 0.5, 0)
	player.add_child(cs)
	root.add_child(player)
	player.global_position = body.global_transform * gs(_env("X", -18.04), _env("Y", -80.09), _env("Z", -111.63))
	PhysicsServer3D.body_set_state(player.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, player.global_transform)
	await physics_frame
	await physics_frame
	var p := PhysicsTestMotionParameters3D.new()
	p.margin = 0.01
	p.max_collisions = 4
	p.recovery_as_collision = true
	p.from = player.global_transform
	p.motion = body.global_transform.basis * gs(_env("DX", -3.3), _env("DY", 0.0), _env("DZ", 0.0))
	var res := PhysicsTestMotionResult3D.new()
	print("=== THE ONE QUERY ===")
	PhysicsServer3D.body_test_motion(player.get_rid(), p, res)
	var t: Vector3 = body.global_transform.basis.inverse() * res.get_travel()
	print("=== unsafe=%.3f travel(GS local)=(%.2f,%.2f,%.2f) contacts=%d" % [
		res.get_collision_unsafe_fraction(), -t.x / S, t.z / S, t.y / S, res.get_collision_count()])
	for i in res.get_collision_count():
		var n: Vector3 = body.global_transform.basis.inverse() * res.get_collision_normal(i)
		print("    n=(%.2f,%.2f,%.2f) d=%.2f" % [-n.x, n.z, n.y, res.get_collision_depth(i) / S])
	quit(0)
