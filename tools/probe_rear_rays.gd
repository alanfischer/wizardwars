extends SceneTree
## Ground truth on the golem's rear cockpit geometry, using RAYS only.
##
## Rays trace hull 0 — the raw brush planes, with no box expansion, no push-out and no
## margin — so nothing here depends on the solid-query machinery under test. Every
## measurement I made with hull queries is suspect while those queries are the thing
## being debugged; these are not.
##
## Q1: at each height, how far back does the rear wall's face sit?
## Q2: straight down behind that face, is there floor or a cavity?

const S := 0.025

var body_node: AnimatableBody3D
var space: PhysicsDirectSpaceState3D


func gs_to_godot(x: float, y: float, z: float) -> Vector3:
	return Vector3(-x * S, z * S, y * S)


func shoot(from_gs: Vector3, to_gs: Vector3) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(
		body_node.global_transform * gs_to_godot(from_gs.x, from_gs.y, from_gs.z),
		body_node.global_transform * gs_to_godot(to_gs.x, to_gs.y, to_gs.z))
	q.collision_mask = GameConsts.MASK_WORLD_AND_CLIP | GameConsts.MASK_ENTITY
	return space.intersect_ray(q)


func local_gs(p: Vector3) -> Vector3:
	var l: Vector3 = body_node.global_transform.affine_inverse() * p
	return Vector3(-l.x / S, l.z / S, l.y / S)


func _initialize() -> void:
	var root: Node3D = (load("user://resources/maps/ww_golem.scn") as PackedScene).instantiate()
	get_root().add_child(root)
	for i in 20:
		await physics_frame
	for n in root.find_children("*", "AnimatableBody3D", true, false):
		if String(n.get_meta("entity", {}).get("classname", "")) == "func_golem_body":
			body_node = n
	space = body_node.get_world_3d().direct_space_state

	print("Q1: rear wall face, shooting BACKWARD from x=-4 at y=-80 (back right).\n")
	print("      z | wall face x")
	for zi in range(-124, -20, 2):
		var hit := shoot(Vector3(-4, -80, zi), Vector3(-60, -80, zi))
		if hit.is_empty():
			print("%7d | %s" % [zi, "MISS — open all the way back"])
		else:
			print("%7d | %11.2f" % [zi, local_gs(hit["position"]).x])

	print("\nQ2: straight DOWN at y=-80 from z=-100, at a range of x.\n")
	print("      x | floor z")
	for xi in [-8.0, -12.0, -14.0, -15.0, -15.6, -16.0, -17.0, -18.0, -20.0, -24.0]:
		var hit := shoot(Vector3(xi, -80, -100), Vector3(xi, -80, -170))
		if hit.is_empty():
			print("%7.1f | %s" % [xi, "no floor within 70 units"])
		else:
			print("%7.1f | %7.2f" % [xi, local_gs(hit["position"]).z])
	quit(0)
