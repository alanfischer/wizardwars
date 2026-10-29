extends SceneTree
## Does body_test_motion ever say "collided" without naming a surface?
##
## Godot's callers read collisions[0] the moment the query returns true, without
## consulting collision_count: PhysicsBody3D wants its depth, CharacterBody3D slides
## the remainder along its normal. A true carrying zero contacts therefore surfaces as
## "The normal Vector3 (0,0,0) must be normalized" out of move_and_slide, followed by a
## slide along nothing.
##
## Two poses are swept here, both the kind a player is in constantly:
##   (a) flush against a wall, airborne, moving parallel to it — recovery pushes off a
##       surface the sweep never hits and the ground probe never sees;
##   (b) standing on a ledge and walking off it — the resting-gap nudge is the whole of
##       the "collision", and the ground probe looks from where the motion ENDS, which
##       is past the edge.
##
## Usage: godot --headless -s tools/probe_zero_normal.gd

const RADIUS := 0.4
const HEIGHT := 1.8
const MARGIN := 0.01

var _params := PhysicsTestMotionParameters3D.new()
var _result := PhysicsTestMotionResult3D.new()
var _body: CharacterBody3D
var _bad := 0
var _checked := 0


func _initialize() -> void:
	_add_box(Vector3(2, 20, 20), Vector3(3.0, 0, 0))        # wall, near face at x = 2
	_add_box(Vector3(10, 2, 10), Vector3(-5.0, -1.0, 0))    # floor, top y = 0, edge at x = 0

	_body = CharacterBody3D.new()
	_body.safe_margin = MARGIN
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = RADIUS
	cap.height = HEIGHT
	cs.shape = cap
	_body.add_child(cs)
	get_root().add_child(_body)

	for i in 5:
		await physics_frame

	_params.max_collisions = 6
	_params.margin = MARGIN
	_params.recovery_as_collision = true

	print("--- (a) flush against a wall, sliding along it ---")
	for step in 41:
		var pen: float = step * 5e-5  # 0 .. 2 mm into the wall
		_check(Vector3(2.0 - RADIUS + pen, 5.0, 0), Vector3(0, 0, 0.05))

	print("--- (b) standing on a ledge, walking off it ---")
	for xs in 20:
		var x: float = -0.95 + xs * 0.05
		for ys in 9:
			var lift: float = ys * 2.5e-4  # 0 .. 2 mm of resting gap
			_check(Vector3(x, HEIGHT * 0.5 + lift, 0), Vector3(1.2, -0.02, 0))

	print("")
	print("%d poses checked" % _checked)
	if _bad > 0:
		print("FAIL: %d returned true with no contact" % _bad)
	else:
		print("PASS: every true carried at least one contact")
	quit(1 if _bad > 0 else 0)


func _add_box(size: Vector3, pos: Vector3) -> void:
	var b := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	b.add_child(cs)
	b.position = pos
	get_root().add_child(b)


func _check(from: Vector3, motion: Vector3) -> void:
	_checked += 1
	_params.from = Transform3D(Basis(), from)
	_params.motion = motion
	var hit := PhysicsServer3D.body_test_motion(_body.get_rid(), _params, _result)
	if hit and _result.get_collision_count() == 0:
		_bad += 1
		print("  BAD  from=%s motion=%s -> true, 0 contacts" % [from, motion])

	# The symptom itself: the same pose through move_and_slide, which is where the
	# unnamed contact turns into a slide along the zero vector.
	_body.global_position = from
	_body.velocity = motion * 60.0
	_body.move_and_slide()
