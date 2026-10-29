extends SceneTree
## How wide is the gap the player must thread between the golem's crotch chamfer
## and its hip wing, and does the collision margin change it?
##
## Sweeps the standing hull across the stair channel at the pinch height and asks
## the physics server, at several margins, how far a step-up lift gets. GoldSrc's
## hull trace inflates nothing, so the margin-0 column is the original's answer.

const S := 0.025

const TREAD_X0 := -44.0
const TREAD_RISE := 16.0


func gs_to_godot(x: float, y: float, z: float) -> Vector3:
	return Vector3(-x * S, z * S, y * S)


func _initialize() -> void:
	var root: Node3D = (load("user://resources/maps/ww_golem.scn") as PackedScene).instantiate()
	get_root().add_child(root)
	for i in 20:
		await physics_frame

	var leg: AnimatableBody3D = null
	for n in root.find_children("*", "AnimatableBody3D", true, false):
		if "leftleg" in String(n.get_meta("entity", {}).get("classname", "")):
			leg = n

	var char_body := CharacterBody3D.new()
	char_body.collision_layer = 0
	char_body.collision_mask = 33
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.8
	cs.shape = cap
	cs.position = Vector3(0, 0.9, 0)
	char_body.add_child(cs)
	root.add_child(char_body)

	var ascent: Vector3 = (leg.global_transform.basis * gs_to_godot(1.0, 0.0, 0.0)).normalized()
	print("Step-up lift as a fraction of the 0.450 m sv_stepsize, per tread (rows) and lane (cols).")
	print("'##' = full lift (the hull threads the gap); '..' = blocked by the golem's own hull.\n")
	var lanes: Array[float] = []
	var lane := 66.0
	while lane <= 102.01:
		lanes.append(lane)
		lane += 2.0
	var header := "tread |"
	for l in lanes:
		header += " %3d" % int(l)
	print(header)
	for tread in 12:
		var line := "  %3d |" % tread
		for l in lanes:
			var surface: Vector3 = leg.global_transform * gs_to_godot(
				TREAD_X0 + tread + 0.5, l, TREAD_RISE * tread)
			var params := PhysicsTestMotionParameters3D.new()
			params.from = Transform3D(Basis(), surface - ascent * 0.4 + Vector3.UP * 0.002)
			params.motion = Vector3.UP * 0.45
			params.margin = 0.001
			params.recovery_as_collision = false
			var res := PhysicsTestMotionResult3D.new()
			PhysicsServer3D.body_test_motion(char_body.get_rid(), params, res)
			var frac := res.get_travel().y / 0.45
			line += "  %s" % ("##" if frac > 0.97 else (".." if frac < 0.5 else "%2d" % int(frac * 10)))
		print(line)
	quit(0)
