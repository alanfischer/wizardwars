extends SceneTree
## Two checks the slot claim has to survive:
##
##  1. Is the column at the slot genuinely EMPTY, or is the hull inside the wall there
##     (in which case the "fall" is a failed trace, not a hole)? A zero-motion query
##     reports how deep the hull is in solid at each height.
##  2. Where is the blocking surface behind the cockpit at each height? If a kerb at
##     deck level sits further forward than the wall above it, that is the slot.

const S := 0.025

var body_node: AnimatableBody3D
var player: CharacterBody3D


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
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.8
	cs.shape = cap
	cs.position = Vector3(0, 0.9, 0)
	player.add_child(cs)
	root.add_child(player)

	var p := PhysicsTestMotionParameters3D.new()
	p.margin = player.safe_margin
	p.recovery_as_collision = true
	p.max_collisions = 4
	var res := PhysicsTestMotionResult3D.new()

	print("(1) Is the slot column empty?  Hull at body-local GS x=-16.3, y=-80.")
	print("    depth 0 = free space; a real depth means the hull is inside the wall.\n")
	print("      z | overlap depth (GS units)")
	for zi in range(-100, -132, -3):
		player.global_position = body_node.global_transform * gs_to_godot(-16.3, -80.0, float(zi))
		PhysicsServer3D.body_set_state(
			player.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, player.global_transform)
		await physics_frame
		p.from = player.global_transform
		p.motion = Vector3.ZERO
		PhysicsServer3D.body_test_motion(player.get_rid(), p, res)
		var deep := 0.0
		for i in res.get_collision_count():
			deep = maxf(deep, res.get_collision_depth(i))
		print("%7d | %.2f%s" % [zi, deep / S, "   <-- FREE" if deep / S < 0.5 else ""])

	print("\n(2) How far back can the hull go, at each height? (sweep straight back 8 units)")
	print("    A kerb at deck level further forward than the wall above it IS the slot.\n")
	print("      z | blocked at x | travel")
	var back: Vector3 = (body_node.global_transform.basis * gs_to_godot(-1.0, 0.0, 0.0)).normalized()
	for zi in [-112.5, -112.0, -111.93, -111.5, -111.0, -110.0, -108.0, -104.0, -100.0, -95.0, -90.0]:
		player.global_position = body_node.global_transform * gs_to_godot(-13.0, -80.0, zi)
		PhysicsServer3D.body_set_state(
			player.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, player.global_transform)
		await physics_frame
		p.from = player.global_transform
		p.motion = back * (8.0 * S)
		PhysicsServer3D.body_test_motion(player.get_rid(), p, res)
		var travel: Vector3 = body_node.global_transform.basis.inverse() * res.get_travel()
		var moved := -travel.x / S          # body-local GoldSrc x displacement
		print("%7.2f | %11.2f | moved %5.2f%s" % [
			zi, -13.0 + moved, moved, "   <-- unobstructed" if absf(moved) > 7.9 else ""])
	quit(0)
