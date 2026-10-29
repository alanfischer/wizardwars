extends SceneTree
## Where does the cockpit deck actually end, and what is behind its rear edge?
##
## A rider pressed against the rear wall while airborne settles at body-local GS
## x = -16.4, but a rider standing on the deck rests at x = -15.6. If the deck stops
## short of the wall there is a slot between them — and the golem is hollow below the
## deck, so anything that fits down the slot ends up inside the model.
##
## Drops a standing hull from well above the deck at a range of x and reports where it
## lands.

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
	var res := PhysicsTestMotionResult3D.new()
	var down: Vector3 = (body_node.global_transform.basis * gs_to_godot(0.0, 0.0, -1.0)).normalized()

	print("Drop a standing hull 60 units from body-local GS z=-105, at y=-80 (back right).")
	print("'deck' = it lands on the cockpit floor. Anything lower is through the slot.\n")
	print("      x | lands at z | drop")
	for xi in [-14.0, -15.0, -15.6, -15.9, -16.0, -16.2, -16.4, -16.6, -17.0]:
		player.global_position = body_node.global_transform * gs_to_godot(xi, -80.0, -105.0)
		PhysicsServer3D.body_set_state(
			player.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, player.global_transform)
		await physics_frame
		p.from = player.global_transform
		p.motion = down * (60.0 * S)
		PhysicsServer3D.body_test_motion(player.get_rid(), p, res)
		var travel: Vector3 = body_node.global_transform.basis.inverse() * res.get_travel()
		var dropped := travel.y / S
		print("  %5.1f | %10.1f | %.1f%s" % [
			xi, -105.0 - dropped, dropped,
			"   <-- deck" if -105.0 - dropped > -115.0 else "   <-- FELL THROUGH"])
	quit(0)
