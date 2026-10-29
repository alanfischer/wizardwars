extends SceneTree
## Is the drop behind the cockpit deck a narrow slot all along the rear wall, or is it
## the entrance / the front window?
##
## For each y across the cockpit, walk x backwards and find the last position whose
## dropped hull still lands on the deck, and the first that falls through. A uniform
## rear edge with a consistent small gap before the wall is a slot; a wide opening at
## particular y values is a doorway.
##
## Golem forward is GoldSrc +x, up +z, LEFT is +y. Cockpit spans about y = -84..+84.

const S := 0.025
const DECK_Z := -112.0

var body_node: AnimatableBody3D
var player: CharacterBody3D


func gs_to_godot(x: float, y: float, z: float) -> Vector3:
	return Vector3(-x * S, z * S, y * S)


## Drop a standing hull from `z` at (x,y); returns the body-local GS z it lands at.
func drop_at(x: float, y: float, from_z: float, dist: float) -> float:
	player.global_position = body_node.global_transform * gs_to_godot(x, y, from_z)
	PhysicsServer3D.body_set_state(
		player.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, player.global_transform)
	await physics_frame
	var p := PhysicsTestMotionParameters3D.new()
	p.margin = player.safe_margin
	p.from = player.global_transform
	p.motion = (body_node.global_transform.basis * gs_to_godot(0.0, 0.0, -1.0)).normalized() * (dist * S)
	var res := PhysicsTestMotionResult3D.new()
	PhysicsServer3D.body_test_motion(player.get_rid(), p, res)
	var travel: Vector3 = body_node.global_transform.basis.inverse() * res.get_travel()
	return from_z + travel.y / S


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

	print("Cockpit floor plan, dropping a standing hull from z=-105 (7 units above the deck).")
	print("For each y: the rear-most x that still lands on the deck, the first x that")
	print("falls through, and how far that fall goes.  LEFT is +y.\n")
	print("     y | last deck x | first drop x | lands at z | fall")
	for yi in range(-84, 89, 6):
		var last_deck := 999.0
		var first_drop := 999.0
		var drop_z := 0.0
		var xi := -13.0
		while xi > -20.0:
			var z: float = await drop_at(xi, float(yi), -105.0, 60.0)
			if z > DECK_Z - 4.0:
				last_deck = xi
			elif first_drop == 999.0:
				first_drop = xi
				drop_z = z
				break
			xi -= 0.2
		if first_drop == 999.0:
			print("%6d | %11.1f | %12s | %10s |" % [yi, last_deck, "(none)", "-"])
		else:
			print("%6d | %11.1f | %12.1f | %10.1f | %.1f" % [
				yi, last_deck, first_drop, drop_z, DECK_Z - drop_z])
	quit(0)
