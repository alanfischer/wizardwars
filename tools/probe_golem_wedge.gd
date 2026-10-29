extends Node
## ONE query at ONE pose in ww_golem's cockpit, for the questions a ride cannot isolate:
## does the engine report a FLOOR here, and will it deliver the carry's lift?
##
##   [POSE="x,y,z"] godot --headless --path . res://tools/probe_golem_wedge.tscn
##     POSE   the rider's FEET in the golem's body-local GoldSrc frame; the default is the
##            pose a turning rider is lost from, feet (-16.034, -79.907, -112.515), which
##            is the 0.283-unit slot between two clipnode bevels at the rear-right corner.
##
## The golem TURNS while the hull is pinned in the world, so the model has an owner_motion
## and hop's push-out gets its `prefer` — without that the answer is a different one.
## Prints, in the golem's frame: the zero-motion manifold (which is where "is there a
## floor?" is decided — a bevel normal with no upward component is not one), then the
## 0.83-unit stride lift at move_and_collide's own 0.001 margin and at the body's 0.01.
## A `safe` of 0 on that lift is the rider not being carried.
##
## Pair it with hop's debug scaffolding on the golem-corner-clearance branch: HOP_DBG=1
## traces the recovery and retry loops for each query, and HOP_CLEARANCE_SCALE=0 answers
## the same pose as hop did before 013606a. See TODO.md for what those measured.

const S := 0.025
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


func dir_local_gs(d: Vector3) -> Vector3:
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

	golem.golem_turn_left()
	for i in 10:
		await get_tree().physics_frame

	var parts := (OS.get_environment("POSE") if OS.get_environment("POSE") != ""
			else "-16.034,-79.907,-112.515").split(",")
	var feet := Vector3(float(parts[0]), float(parts[1]), float(parts[2]))
	var world: Vector3 = body.global_transform * gs(feet.x, feet.y, feet.z)
	for i in 2:
		player.global_position = world
		await get_tree().physics_frame
	player.global_position = world
	print("\n=== pose feet body-local GS %s -> trace point %s" % [
		feet, to_local_gs(player.global_position) + Vector3(0, 0, 36)])

	var res := PhysicsTestMotionResult3D.new()
	var p := PhysicsTestMotionParameters3D.new()
	p.recovery_as_collision = true
	p.max_collisions = 8
	# The two queries the ride depends on: the zero-motion manifold (does a floor get
	# reported?) and the 0.83-unit lift the carry asks for, at move_and_collide's margin.
	for q in [{"name": "manifold m=0.010", "motion": Vector3.ZERO, "margin": 0.01},
			{"name": "lift     m=0.001", "motion": body.global_transform.basis * gs(0.0, 0.0, 0.83),
				"margin": 0.001},
			{"name": "lift     m=0.010", "motion": body.global_transform.basis * gs(0.0, 0.0, 0.83),
				"margin": 0.01}]:
		p.from = player.global_transform
		p.motion = q["motion"]
		p.margin = q["margin"]
		PhysicsServer3D.body_test_motion(player.get_rid(), p, res)
		var out := "%s  safe=%.2f unsafe=%.2f travel_gs=%s  contacts:" % [
			q["name"], res.get_collision_safe_fraction(), res.get_collision_unsafe_fraction(),
			dir_local_gs(res.get_travel())]
		for i in res.get_collision_count():
			out += " [n=%s d=%.3fu]" % [dir_local_gs(res.get_collision_normal(i)).normalized(),
				res.get_collision_depth(i) / S]
		print(out)
	get_tree().quit()
