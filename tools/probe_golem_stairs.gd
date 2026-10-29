extends SceneTree
## Why is the golem's leg staircase hard to climb here but not in GoldSrc?
##
## ww_golem's left leg (BSP model *38) carries a 12-tread staircase up its back:
## every tread is 16 units of rise on 1 unit of run, then a 32-unit rise onto the
## leg top. GoldSrc walks it because PM_WalkMove lifts sv_stepsize (18) and lands
## on the next tread every tick. This probe replays the real netmove kernel over
## the real (hop/BSP-hull) collision and reports, per tick, what walk_move decided.

const Movement = preload("res://addons/pmove/movement.gd")
const MovementConfig = preload("res://addons/pmove/movement_config.gd")
const InputCommand = preload("res://addons/pmove/input_command.gd")

const S := 0.025  # GoldSrc units -> metres

# Left-leg staircase, in the leg model's own GoldSrc space (read straight off the
# BSP: upward faces of model *38). Tread k top: z = 16k, x in [-44+k, -43+k].
const TREADS := 12
const TREAD_X0 := -44.0
const TREAD_RISE := 16.0
const LEG_Y_MIN := 64.0
const LEG_Y_MAX := 112.0


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
	if not leg:
		printerr("no left leg")
		quit(1)
		return
	print("left leg xform: origin=%s basis_x=%s" % [leg.global_transform.origin, leg.global_transform.basis.x])

	# Tread centres in world space, plus the ascent direction (+x in leg space).
	# LANE_Y picks where across the 48-unit-wide stair channel the hull walks. The
	# passable lane between the golem's crotch chamfer (below y=64) and its hip wing
	# (above y=96) is exactly 32 units — one hull — so this is the interesting knob.
	var mid_y := 88.0
	if OS.get_environment("LANE_Y") != "":
		mid_y = float(OS.get_environment("LANE_Y"))
	print("lane y (GoldSrc, leg-local) = %.1f  [channel is y 64..112; hull is 32 wide]" % mid_y)
	var treads: Array[Vector3] = []
	for k in TREADS:
		var local := gs_to_godot(TREAD_X0 + k + 0.5, mid_y, TREAD_RISE * k)
		treads.append(leg.global_transform * local)
	var ascent: Vector3 = (leg.global_transform.basis * gs_to_godot(1.0, 0.0, 0.0)).normalized()
	print("ascent dir (world) = %s" % ascent)

	var space := root.get_world_3d().direct_space_state
	print("\n--- ground truth: ray down onto each tread centre ---")
	for k in TREADS:
		var t: Vector3 = treads[k]
		var p := PhysicsRayQueryParameters3D.create(t + Vector3.UP * 0.35, t + Vector3.DOWN * 0.35)
		p.collision_mask = 0xFFFFFFFF
		var r := space.intersect_ray(p)
		print("tread %2d expect y=%.3f  ray -> %s" % [k, t.y,
			"MISS" if r.is_empty() else "%.3f (%s)" % [r.position.y, r.collider.name]])

	print("\n--- headroom: ray up from each tread centre (stand needs 72u, duck 36u) ---")
	for k in TREADS + 3:
		var t: Vector3 = treads[min(k, TREADS - 1)]
		if k >= TREADS:
			# past the last tread: onto the leg top (local z=208, x centred on the platform)
			t = leg.global_transform * gs_to_godot(-32.0 + 8.0 * (k - TREADS), mid_y, 208.0)
		var p := PhysicsRayQueryParameters3D.create(t + Vector3.UP * 0.05, t + Vector3.UP * 6.0)
		p.collision_mask = 0xFFFFFFFF
		var r := space.intersect_ray(p)
		var label := "tread %2d" % k if k < TREADS else "top +%2du" % int(8.0 * (k - TREADS) + 32.0)
		print("%s floor y=%.3f  headroom %s" % [label, t.y,
			"OPEN" if r.is_empty() else "%5.1f units (%s)" % [(r.position.y - t.y) / S, r.collider.name]])

	# --- the real movement kernel, walking up the stairs -------------------------
	var char_body := CharacterBody3D.new()
	char_body.collision_layer = 0
	char_body.collision_mask = 33  # player.tscn
	char_body.floor_block_on_wall = false
	char_body.safe_margin = float(OS.get_environment("MARGIN")) if OS.get_environment("MARGIN") != "" else 0.01
	print("safe_margin = %.4f m (%.2f GoldSrc units)" % [char_body.safe_margin, char_body.safe_margin / S])
	char_body.floor_max_angle = acos(Movement.WALK_NORMAL_Y)
	var cs := CollisionShape3D.new()
	cs.name = "CollisionShape3D"  # GodotBody.set_collision_height looks it up by name
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.8
	cs.shape = cap
	cs.position = Vector3(0, 0.9, 0)
	char_body.add_child(cs)
	root.add_child(char_body)

	var cfg := MovementConfig.new()
	var sim := Movement.Simulation.new(cfg)
	var body := GodotBody.new(char_body)
	var state := Movement.MovementState.new()
	state.bind_body(body)

	# Start standing on tread 0, one hull-width back down the stairs so the first
	# ticks are an ordinary approach rather than a spawn-inside-geometry.
	var start: Vector3 = treads[0] - ascent * 0.4 + Vector3.UP * 0.02
	char_body.global_position = start
	body.force_sync_physics()
	await physics_frame
	state.on_floor = true

	var yaw := atan2(ascent.x, ascent.z)
	print("\n--- 90 ticks walking up (yaw=%.1f deg, start=%s, rule=%s, crouch=%s) ---" % [
		rad_to_deg(yaw), start, _rule(), OS.get_environment("CROUCH") != ""])
	print("tick |    y   | dy(units) | on_floor | normal_dh | step_rise | step? | vel_h")
	var strafe := 0.0
	if OS.get_environment("STRAFE") != "":
		strafe = float(OS.get_environment("STRAFE"))
	var cmd := InputCommand.new()
	cmd.move_input = Vector2(strafe, 1).normalized()
	cmd.crouch = OS.get_environment("CROUCH") != ""
	cmd.yaw = yaw
	cmd.delta = 1.0 / 60.0
	var prev_y: float = char_body.global_position.y
	for tick in 90:
		var diag := _tick_with_diag(sim, cfg, body, state, cmd)
		await physics_frame
		var y: float = char_body.global_position.y
		print("%4d | %6.3f | %+8.1f  |   %-5s  | %9.4f | %9.4f | %-5s | %5.2f" % [
			tick, y, (y - prev_y) / S, state.on_floor,
			diag.normal_dh, diag.step_rise, diag.stepped,
			Vector2(state.velocity.x, state.velocity.z).length()])
		if diag.has("up_block"):
			print("       up-move blocked by %s" % diag["up_block"])
		prev_y = y
		if y > treads[TREADS - 1].y + 1.0:
			print("reached the top platform on tick %d" % tick)
			break
	print("\nfinal pos %s (tread 11 top y=%.3f, leg top y=%.3f)" % [
		char_body.global_position, treads[TREADS - 1].y,
		(leg.global_transform * gs_to_godot(0.0, mid_y, 208.0)).y])
	quit(0)


## "rise" = movement.gd's rule today (take the step only if it gained height);
## "goldsrc" = PM_WalkMove's rule (take whichever move went further horizontally).
func _rule() -> String:
	var r := OS.get_environment("RULE")
	return r if r != "" else "rise"


## One simulate_tick, but with walk_move re-run inline so the step decision is visible.
## Mirrors movement.gd walk_move exactly; any divergence here is a bug in the probe.
func _tick_with_diag(sim, cfg, body, state, cmd) -> Dictionary:
	var diag := {"normal_dh": 0.0, "step_rise": 0.0, "stepped": "n/a"}

	state.bind_body(body)
	body.rotation_y = cmd.yaw
	sim.update_crouch(body, state, cmd)
	sim.normal_movement(state, cmd)
	sim.clamp_velocity(state)
	body.velocity = state.velocity

	if state.on_floor and state.velocity.y <= 0.0:
		var saved_pos: Vector3 = body.global_position
		var saved_vel: Vector3 = body.velocity
		body.move_and_slide()
		var normal_pos: Vector3 = body.global_position
		var normal_vel: Vector3 = body.velocity
		var normal_on_floor: bool = body.is_on_floor()
		diag.normal_dh = Vector2(normal_pos.x - saved_pos.x, normal_pos.z - saved_pos.z).length()

		var wanted_h: float = Vector2(saved_vel.x, saved_vel.z).length() * float(cmd.delta)
		if wanted_h < 0.001:
			state.velocity = normal_vel
			state.on_floor = normal_on_floor if normal_on_floor else sim.step_down(body, state)
			diag.stepped = "skip"
			return diag

		body.global_position = saved_pos
		body.velocity = saved_vel
		body.force_sync_physics()
		var up_col = body.move_and_collide(Vector3.UP * cfg.step_height)
		body.force_sync_physics()
		var lifted: float = body.global_position.y - saved_pos.y
		if up_col != null:
			var c := up_col as KinematicCollision3D
			diag["up_block"] = "%s n=%s at %s (from %s)" % [
				c.get_collider().name, c.get_normal(), c.get_position(), saved_pos]
		body.velocity = Vector3(saved_vel.x, 0.0, saved_vel.z)
		body.move_and_slide()
		body.force_sync_physics()
		var down_col = body.move_and_collide(Vector3.DOWN * (cfg.step_height + 0.01))
		var stepped_pos: Vector3 = body.global_position
		var step_rise: float = stepped_pos.y - saved_pos.y
		diag.step_rise = step_rise
		var landed := false
		if down_col != null:
			landed = (down_col as KinematicCollision3D).get_normal().dot(Vector3.UP) >= 0.5
		if step_rise >= cfg.min_step_rise and landed:
			body.velocity = Vector3(saved_vel.x, 0.0, saved_vel.z)
			body.apply_floor_snap()
			state.velocity = body.velocity
			state.on_floor = true
			diag.stepped = "STEP(lift %.3f, dh %.4f)" % [lifted,
				Vector2(stepped_pos.x - saved_pos.x, stepped_pos.z - saved_pos.z).length()]
		else:
			body.global_position = normal_pos
			body.velocity = normal_vel
			body.force_sync_physics()
			state.velocity = normal_vel
			state.on_floor = normal_on_floor if normal_on_floor else sim.step_down(body, state)
			diag.stepped = "no(lift %.3f, land %s)" % [lifted, landed]
	else:
		body.move_and_slide()
		state.velocity = body.velocity
		state.on_floor = body.is_on_floor()
		diag.stepped = "air"
	body.velocity = state.velocity
	return diag
