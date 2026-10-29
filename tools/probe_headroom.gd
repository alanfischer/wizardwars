extends SceneTree
## Does has_headroom() notice that the pose it is asked about is already inside solid?
##
## update_crouch's airborne stand-up drops the feet half a hull (0.45 m) and guards it
## with has_headroom(grow, DOWN * drop) — a sweep UPWARD from the dropped pose. If that
## pose is buried in the golem's deck, the question "is the 0.9 m above it clear?" is
## the wrong question, and body_test_motion answers it from the RECOVERED position, so
## it comes back clear anyway.

const S := 0.025
const Movement = preload("res://addons/pmove/movement.gd")

var body_node: AnimatableBody3D
var player: CharacterBody3D


func gs_to_godot(x: float, y: float, z: float) -> Vector3:
	return Vector3(-x * S, z * S, y * S)


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
	player.collision_mask = 33
	player.safe_margin = 0.01
	var cs := CollisionShape3D.new()
	cs.name = "CollisionShape3D"
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 0.9        # crouched, as update_crouch has it at this moment
	cs.shape = cap
	cs.position = Vector3(0, 0.45, 0)
	player.add_child(cs)
	root.add_child(player)

	var gbody := GodotBody.new(player)
	# Feet on the cockpit deck, mid-floor — a spot the earlier scan proved is a
	# perfectly good place to stand up.
	player.global_position = body_node.global_transform * gs_to_godot(0.0, 0.0, -112.0)
	gbody.force_sync_physics()
	await physics_frame

	var grow: float = 1.8 - 0.9
	var drop: float = grow * 0.5   # what update_crouch uses when state.on_floor is false

	print("crouched on the deck at body-local GS (0,0,-112); stand-up grows %.2f m\n" % grow)
	print("  has_headroom(grow, no offset)          = %s   <- grounded path, correct" % [
		gbody.has_headroom(grow)])
	print("  has_headroom(grow, DOWN * %.2f)         = %s   <- airborne path" % [
		drop, gbody.has_headroom(grow, Vector3.DOWN * drop)])

	# What is actually at the dropped pose?
	var p := PhysicsTestMotionParameters3D.new()
	p.from = player.global_transform.translated(Vector3.DOWN * drop)
	p.motion = Vector3.ZERO
	p.margin = player.safe_margin
	p.recovery_as_collision = true
	p.max_collisions = 4
	var r := PhysicsTestMotionResult3D.new()
	PhysicsServer3D.body_test_motion(player.get_rid(), p, r)
	print("\n  the dropped pose itself: recovery wants to move it %.3f m" % r.get_travel().length())
	for i in r.get_collision_count():
		print("      contact n=%s depth=%.3f m" % [r.get_collision_normal(i), r.get_collision_depth(i)])
	print("\n  => %.2f m below the deck is solid, and the airborne stand-up would move" % drop)
	print("     the player there anyway if has_headroom says yes.")
	quit(0)
