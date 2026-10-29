extends SceneTree
## Repro: a rider standing at the BACK of the golem's cockpit while it walks forward.
##
## Runs the real netmove kernel with the real mover carry + pusher (the two
## corrections player_movement_context feeds it, reproduced here so the probe needs
## no autoloads), against the real ww_golem hulls, with the golem driven at its own
## walk pace and bob. Prints the rider in the body's own GoldSrc frame: the cockpit
## floor is z=-112 and the rear wall is x=-32, so an x past that is the rider
## leaving through the wall.
##
## Usage: [X=-20] [BACK=1] [BOB=1] [TURN=0] tools/probe_golem_ride.gd

const Movement = preload("res://addons/pmove/movement.gd")
const MovementConfig = preload("res://addons/pmove/movement_config.gd")
const InputCommand = preload("res://addons/pmove/input_command.gd")

const S := 0.025
const MOVER_TELEPORT_DIST := 12.0
const SUPPORT_NORMAL_Y := 0.7
const DEPEN_STEP := 0.1

var body_node: AnimatableBody3D
var player: CharacterBody3D
var shape_node: CollisionShape3D

var carry_query := PhysicsShapeQueryParameters3D.new()
var hull_params := PhysicsTestMotionParameters3D.new()
var hull_result := PhysicsTestMotionResult3D.new()
var carry_ground_id: int = 0
var carry_ground_xform: Transform3D
var push_mover_id: int = 0
var push_mover_xform: Transform3D


func gs_to_godot(x: float, y: float, z: float) -> Vector3:
	return Vector3(-x * S, z * S, y * S)


func local_gs(p: Vector3) -> Vector3:
	var l: Vector3 = body_node.global_transform.affine_inverse() * p
	return Vector3(-l.x / S, l.z / S, l.y / S)


func gated_delta(prior: Transform3D, now: Transform3D, point: Vector3) -> Vector3:
	var moved := now * (prior.affine_inverse() * point) - point
	if moved.length_squared() > MOVER_TELEPORT_DIST * MOVER_TELEPORT_DIST:
		return Vector3.ZERO
	return moved


func compute_carry(on_floor: bool) -> Vector3:
	if not on_floor:
		carry_ground_id = 0
		return Vector3.ZERO
	var pos: Vector3 = player.global_position
	carry_query.transform = Transform3D(Basis.IDENTITY, pos + Vector3(0.0, 0.1, 0.0))
	var hits: Array = player.get_world_3d().direct_space_state.intersect_shape(carry_query, 6)
	var ground: AnimatableBody3D = null
	for h in hits:
		if h.get("collider") is AnimatableBody3D:
			ground = h["collider"]
			break
	if not ground:
		carry_ground_id = 0
		return Vector3.ZERO
	var xform: Transform3D = ground.global_transform
	var carry := Vector3.ZERO
	if ground.get_instance_id() == carry_ground_id and not xform.is_equal_approx(carry_ground_xform):
		carry = gated_delta(carry_ground_xform, xform, pos)
	carry_ground_id = ground.get_instance_id()
	carry_ground_xform = xform
	return carry


## player_movement_context._apply_hull_corrections, verbatim in shape: scan the
## recovery manifold for the deepest contact that is NOT holding us up.
func hull_corrections() -> Array:  # [push, depenetration, note]
	hull_params.from = player.global_transform
	hull_params.margin = player.safe_margin
	PhysicsServer3D.body_test_motion(player.get_rid(), hull_params, hull_result)
	var normal := Vector3.ZERO
	var point := Vector3.ZERO
	var collider: Object = null
	var best_depth := 0.0
	for i in hull_result.get_collision_count():
		var n := hull_result.get_collision_normal(i)
		if n.y > SUPPORT_NORMAL_Y:
			continue
		var hit := instance_from_id(hull_result.get_collider_id(i))
		if hit is CharacterBody3D:
			continue
		var depth := hull_result.get_collision_depth(i)
		if normal != Vector3.ZERO and depth <= best_depth:
			continue
		best_depth = depth
		normal = n
		point = hull_result.get_collision_point(i)
		collider = hit
	if normal == Vector3.ZERO:
		push_mover_id = 0
		return [Vector3.ZERO, Vector3.ZERO, ""]
	var depen: Vector3 = normal * minf(DEPEN_STEP, best_depth)
	var push := Vector3.ZERO
	if collider is AnimatableBody3D:
		var xform: Transform3D = (collider as AnimatableBody3D).global_transform
		if collider.get_instance_id() == push_mover_id and not xform.is_equal_approx(push_mover_xform):
			var moved := gated_delta(push_mover_xform, xform, point)
			var into := moved.dot(normal)
			if into > 0.0:
				push = normal * into
		push_mover_id = collider.get_instance_id()
		push_mover_xform = xform
	else:
		push_mover_id = 0
	return [push, depen, "n=%.2f,%.2f,%.2f d=%.3f" % [normal.x, normal.y, normal.z, best_depth]]


## What the physics server says at the instant simulate_tick starts — after the golem
## has moved for this frame, before anything has responded to it. Sampling after the
## tick instead shows only the settled result, which is always clean.
func probe_now(tag: String) -> void:
	var tp := PhysicsTestMotionParameters3D.new()
	tp.from = player.global_transform
	tp.motion = Vector3.ZERO
	tp.margin = player.safe_margin
	tp.recovery_as_collision = true
	tp.max_collisions = 4
	var tr := PhysicsTestMotionResult3D.new()
	PhysicsServer3D.body_test_motion(player.get_rid(), tp, tr)
	var here := local_gs(player.global_position)
	var rl := local_gs(player.global_position + tr.get_travel()) - here
	var ns := ""
	for i in tr.get_collision_count():
		ns += " n%d=%s d=%.4f" % [i, tr.get_collision_normal(i), tr.get_collision_depth(i)]
	print("      %s recovery would move (local GS) (%6.2f,%6.2f,%6.2f)%s" % [tag, rl.x, rl.y, rl.z, ns])

func _initialize() -> void:
	var root: Node3D = (load("user://resources/maps/ww_golem.scn") as PackedScene).instantiate()
	get_root().add_child(root)
	for i in 20:
		await physics_frame

	for n in root.find_children("*", "AnimatableBody3D", true, false):
		if String(n.get_meta("entity", {}).get("classname", "")) == "func_golem_body":
			body_node = n
	body_node.sync_to_physics = false

	player = CharacterBody3D.new()
	player.collision_layer = 0
	player.collision_mask = 33
	player.safe_margin = 0.01
	player.floor_block_on_wall = false
	player.floor_max_angle = acos(Movement.WALK_NORMAL_Y)
	shape_node = CollisionShape3D.new()
	shape_node.name = "CollisionShape3D"
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.8
	shape_node.shape = cap
	shape_node.position = Vector3(0, 0.9, 0)
	player.add_child(shape_node)
	root.add_child(player)

	carry_query.collision_mask = 417
	var sphere := SphereShape3D.new()
	sphere.radius = 0.3
	carry_query.shape = sphere
	carry_query.exclude = [player.get_rid()]
	hull_params.motion = Vector3.ZERO
	hull_params.recovery_as_collision = true
	hull_params.max_collisions = 4

	var cfg := MovementConfig.new()
	var sim := Movement.Simulation.new(cfg)
	var gbody := GodotBody.new(player)
	var state := Movement.MovementState.new()
	state.bind_body(gbody)

	var start_x := -20.0
	if OS.get_environment("X") != "":
		start_x = float(OS.get_environment("X"))
	# Y: across the cockpit. Golem forward is GS +x and up is +z, so its RIGHT is -y.
	# Every earlier run of this probe sat at y=0 and so only ever met the rear wall.
	var start_y := 0.0
	if OS.get_environment("Y") != "":
		start_y = float(OS.get_environment("Y"))
	player.global_position = body_node.global_transform * gs_to_godot(start_x, start_y, -110.0)
	gbody.force_sync_physics()
	await physics_frame
	state.on_floor = true

	var forward: Vector3 = (body_node.global_transform.basis * gs_to_godot(1.0, 0.0, 0.0)).normalized()
	var walk := forward * (50.0 * S) / 60.0            # 1.25 m/s
	var bob_on := OS.get_environment("BOB") != "0"
	var back := 0.0 if OS.get_environment("BACK") == "0" else -1.0
	var turn := float(OS.get_environment("TURN")) if OS.get_environment("TURN") != "" else 0.0
	var duck_at := int(OS.get_environment("DUCK")) if OS.get_environment("DUCK") != "" else -1
	# STAND=N: release crouch at tick N (with DUCK=0, that is "ride crouched, then
	# stand up mid-stride" — the reported repro).
	var stand_at := int(OS.get_environment("STAND")) if OS.get_environment("STAND") != "" else -1

	var cmd := InputCommand.new()
	cmd.delta = 1.0 / 60.0
	cmd.yaw = atan2(forward.x, forward.z)
	# STRAFE: sideways input, so the rider can push INTO a corner instead of only
	# straight back. Pressing into the back-right corner is back + right together.
	var strafe := float(OS.get_environment("STRAFE")) if OS.get_environment("STRAFE") != "" else 0.0
	cmd.move_input = Vector2(strafe, back)

	print("golem forward=%s   rider starts at body-local GS %s" % [forward, local_gs(player.global_position)])
	print("input: back=%s strafe=%.1f bob=%s turn=%.1f deg/s\n" % [back != 0.0, strafe, bob_on, turn])

	var base_y: float = body_node.global_position.y
	var worst := 0.0
	for tick in 600:
		# --- drive the golem exactly as func_golem_body does ---
		var t: float = fmod(float(tick) / 60.0, 1.0)
		body_node.global_position += walk
		if bob_on:
			body_node.global_position.y = base_y + (1.0 - absf(2.0 * t - 1.0)) * (50.0 * S) * 0.5
		if turn != 0.0:
			body_node.rotation.y += deg_to_rad(turn) / 60.0

		# --- the two corrections player_movement_context feeds netmove ---
		cmd.crouch = (duck_at >= 0 and tick >= duck_at) and (stand_at < 0 or tick < stand_at)
		# FAKEAIR: force the off-floor read on the stand tick. The golem's down-bob does
		# this in play — the deck drops at 1.25 m/s and gravity needs ~4 ticks to catch
		# up — but the probe's carry tracks the deck too well to hit the window, and it
		# is the ONLY way into update_crouch's airborne stand-up branch.
		if OS.get_environment("FAKEAIR") != "" and tick == stand_at:
			state.on_floor = false
		var carry := compute_carry(state.on_floor)
		var hc := hull_corrections()
		state.carry_motion = carry + (hc[0] as Vector3)
		if OS.get_environment("NOCARRY") != "":
			state.carry_motion = Vector3.ZERO
		state.depenetration = hc[1]

		var before: Vector3 = player.global_position
		var before_l := local_gs(before)
		var show: bool = tick <= 50 or tick % 60 == 0 or (duck_at >= 0 and absi(tick - duck_at) <= 6) \
			or (stand_at >= 0 and absi(tick - stand_at) <= 6)
		if show:
			print("      golem x=%.4f  rider x=%.4f" % [body_node.global_position.x, before.x])
		sim.simulate_tick(gbody, state, cmd)
		var after_l := local_gs(player.global_position)
		var slip: float = (after_l - before_l).length()
		worst = maxf(worst, slip)
		if tick <= 50 or tick % 60 == 0 or (duck_at >= 0 and absi(tick - duck_at) <= 12) \
				or (stand_at >= 0 and absi(tick - stand_at) <= 12):
			var cl := local_gs(before + carry) - before_l
			var pl := local_gs(before + (hc[0] as Vector3)) - before_l
			var dl := local_gs(before + (hc[1] as Vector3)) - before_l
			print("t%3d x=%7.2f y=%7.2f z=%7.2f | dx=%6.2f dy=%6.2f dz=%6.2f | crouch=%s floor=%s | carry(%5.2f,%5.2f) push(%5.2f,%5.2f) depen(%5.2f,%5.2f) | vel.y=%6.2f | rest %s" % [
				tick, after_l.x, after_l.y, after_l.z,
				after_l.x - before_l.x, after_l.y - before_l.y, after_l.z - before_l.z,
				"Y" if state.is_crouched else "n", "Y" if state.on_floor else "n",
				cl.x, cl.z, pl.x, pl.z, dl.x, dl.z, state.velocity.y, hc[2]])
		if after_l.x < -60.0 or after_l.z < -140.0 or after_l.x > 60.0 or after_l.z > -40.0:
			var how := "out the back"
			if after_l.z < -140.0:
				how = "fell through the floor"
			elif after_l.x > 60.0:
				how = "out the front"
			elif after_l.z > -40.0:
				how = "launched up through the roof"
			print("\nrider has left the golem (%s) — stopping at tick %d" % [how, tick])
			break
		await physics_frame
	print("\nfinal body-local GS %s   worst single-tick slip %.2f units" % [
		local_gs(player.global_position), worst])
	quit(0)
