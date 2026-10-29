extends Node
## Which way the physics server would depenetrate a rider buried in ww_golem's cockpit
## walls, measured in-engine on the real map with the real golem walking. Places a
## player-shaped hull at a table of poses and reads body_test_motion's recovery.
##
##   [STILL=1] godot --headless --path . res://tools/probe_golem_pushout.tscn
##
## This is the measurement behind hop's against_the_sweep: before it, feet x -48 and -56
## answered "out the back of the golem". A pose table rather than a ride, because a ride
## cannot hold a rider at a chosen depth, and because the per-pose answer is the thing
## under test — see tools/probe_golem_real.gd for the ride, and read its note on the entry
## shaft before calling any position in the rear of the cockpit an ejection.

const S := 0.025

# Poses as (x, y, z) of the rider's FEET in the body's local GoldSrc frame. The first
# block is the rear wall behind the driver; the second is the rear-RIGHT path along which
# tools/probe_golem_real.gd loses a rider, where the torso is solid from x -16 to -64 and
# hop nonetheless reports every contact at depth zero.
const POSES := [
	[-20.0, 0.0, -66.0], [-26.0, 0.0, -66.0], [-30.0, 0.0, -66.0], [-34.0, 0.0, -66.0],
	[-40.0, 0.0, -66.0], [-44.0, 0.0, -66.0], [-48.0, 0.0, -66.0],
	[-26.0, 0.0, -76.0], [-34.0, 0.0, -76.0],
	[-44.0, 0.0, -110.0], [-48.0, 0.0, -110.0], [-56.0, 0.0, -110.0],
	[-17.0, -80.0, -113.0], [-20.0, -80.0, -116.0], [-24.0, -80.0, -117.0],
	[-30.0, -80.0, -120.0], [-40.0, -80.0, -124.0], [-54.0, -84.0, -128.0],
	[-15.0, -74.0, -111.0], [-15.0, -78.0, -111.0], [-15.0, -79.5, -111.0],
	[-15.0, -79.8, -111.0], [-15.0, -80.5, -111.0], [-15.0, -82.0, -111.0],
	[-15.0, 70.0, -111.0], [-15.0, 75.0, -111.0], [-15.0, 77.0, -111.0],
	# Known penetrations into the rear wall at a y with room to spare. The free x run at
	# standing height starts at -16.00, so the true penetration is -16.00 minus feet x:
	# 0.0, 0.2, 0.4, 0.8, 1.5. Compare against the depth hop reports.
	[-16.0, -70.0, -111.0], [-16.2, -70.0, -111.0], [-16.4, -70.0, -111.0],
	[-16.8, -70.0, -111.0], [-17.5, -70.0, -111.0], [-15.0, -70.0, -111.0],
]
const GOLEM_CLASSES := {
	"func_golem_body": "FuncGolemBody",
	"func_golem_leftleg": "FuncGolemLimb", "func_golem_rightleg": "FuncGolemLimb",
	"func_golem_leftarm": "FuncGolemLimb", "func_golem_rightarm": "FuncGolemLimb",
	"func_golem_controls_forward": "FuncGolemControls",
	"func_golem_controls_left": "FuncGolemControls",
	"func_golem_controls_right": "FuncGolemControls",
	"func_golem_controls_attack": "FuncGolemControls",
}

var golem: Node3D
var body: AnimatableBody3D
var player: CharacterBody3D


func gs(x: float, y: float, z: float) -> Vector3:
	return Vector3(-x * S, z * S, y * S)


func to_local_gs(p: Vector3) -> Vector3:
	var l: Vector3 = body.global_transform.affine_inverse() * p
	return Vector3(-l.x / S, l.z / S, l.y / S)


func dir_to_local_gs(d: Vector3) -> Vector3:
	var l: Vector3 = body.global_transform.basis.inverse() * d
	return Vector3(-l.x / S, l.z / S, l.y / S)


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var root: Node3D = (load("user://resources/maps/ww_golem.scn") as PackedScene).instantiate()
	var scripts := {"FuncGolemBody": FuncGolemBody, "FuncGolemLimb": FuncGolemLimb,
			"FuncGolemControls": FuncGolemControls}
	for child in root.get_children():
		if not child.has_meta("entity"):
			continue
		var cn: String = child.get_meta("entity").get("classname", "")
		if GOLEM_CLASSES.has(cn):
			child.set_script(scripts[GOLEM_CLASSES[cn]])
			if cn == "func_golem_body":
				golem = child
	get_tree().root.add_child(root)
	for i in 40:
		await get_tree().physics_frame
	body = golem as AnimatableBody3D

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

	# STILL=1 keeps the golem standing. The poses are body-local, so the geometry each
	# one sits in is identical either way — the only thing that changes is whether the
	# model has an owner_motion, which is what gives hop's push-out its `prefer` and so
	# turns against_the_sweep on. Run both and the difference IS that filter's effect.
	var still := OS.get_environment("STILL") != ""
	if not still:
		golem.golem_walk()
	for i in 10:
		await get_tree().physics_frame

	var params := PhysicsTestMotionParameters3D.new()
	params.motion = Vector3.ZERO
	params.margin = player.safe_margin
	params.recovery_as_collision = true
	params.max_collisions = 4
	var res := PhysicsTestMotionResult3D.new()

	print("rider FEET at body-local GoldSrc (x, 0, z); the hull-1 trace point is 36 higher.")
	print("deck is at feet z=-110; the control brushes' hulls start at feet z=-88.")
	print("golem is %s." % ("STANDING STILL — no owner_motion, so no against_the_sweep"
			if still else "WALKING"))
	print("")
	print("  feet x   feet y   feet z   push (body-local GS)        contacts")
	for pose in POSES:
		var world: Vector3 = body.global_transform * gs(pose[0], pose[1], pose[2])
		# Pin the hull in the WORLD while the golem walks on: that drift — the rider
		# standing still, the cockpit leaving under them — is what the push-out direction
		# is read from.
		for i in 2:
			player.global_position = world
			await get_tree().physics_frame
		player.global_position = world
		params.from = player.global_transform
		PhysicsServer3D.body_test_motion(player.get_rid(), params, res)
		var push := dir_to_local_gs(res.get_travel())
		var who := ""
		for i in res.get_collision_count():
			var n: Object = instance_from_id(res.get_collider_id(i))
			var label := "?"
			if n is Node:
				label = String((n as Node).get_meta("entity", {}).get("classname", ""))
				if label == "":
					label = (n as Node).name
			who += " %s d=%.1f" % [label.replace("func_golem_", ""), res.get_collision_depth(i) / S]
		if res.get_collision_count() == 0:
			who = " (clear)"
		var verdict := ""
		if push.x < -0.5:
			verdict = "   <<< BACKWARD, out of the golem"
		elif push.x > 0.5:
			verdict = "   forward, into the cockpit"
		print("  %+6.0f   %+6.0f   %+6.0f   (%+7.2f,%+6.2f,%+6.2f)%s%s" % [
			pose[0], pose[1], pose[2], push.x, push.y, push.z, verdict, who])
	get_tree().quit()
