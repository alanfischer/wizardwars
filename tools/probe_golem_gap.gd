extends SceneTree
## Is the opening in the golem's rear cockpit wall real, or only in the player hull?
##
## Walking back along the rear wall and sliding sideways drops a rider straight out of
## the cockpit around body-local GS y = +50..+78. The player hull (BSP hull 1) is empty
## there. Hull 0 is what rays use, so if a ray crosses the same span the hole is real
## geometry; if the ray is blocked, the wall is there for bullets and eyes and only the
## player's clip hull has the hole.

const S := 0.025

var body_node: AnimatableBody3D


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

	var space := body_node.get_world_3d().direct_space_state
	print("Ray straight back (-x) through the rear wall, at deck height + 22 units.")
	print("'HIT' = the wall is there for rays.  'through' = the ray sails out.\n")
	print("   y | rays (hull 0, MASK_WORLD) | player hull (mask 33)")
	for yi in range(-96, 97, 8):
		var from: Vector3 = body_node.global_transform * gs_to_godot(0.0, float(yi), -90.0)
		var to: Vector3 = body_node.global_transform * gs_to_godot(-64.0, float(yi), -90.0)

		var rp := PhysicsRayQueryParameters3D.create(from, to)
		rp.collision_mask = GameConsts.MASK_WORLD
		var ray: Dictionary = space.intersect_ray(rp)

		var rp2 := PhysicsRayQueryParameters3D.create(from, to)
		rp2.collision_mask = 33
		var ray2: Dictionary = space.intersect_ray(rp2)

		var a := "HIT" if not ray.is_empty() else "through"
		var b := "HIT" if not ray2.is_empty() else "through"
		var flag := "   <-- wall for rays, hole for the player" if a == "HIT" and b == "through" else ""
		print("%4d | %-25s | %s%s" % [yi, a, b, flag])
	quit(0)
