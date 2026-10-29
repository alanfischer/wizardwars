extends SceneTree
## The last move of the golem climb: from the top tread, up into the golem's belly.
##
## The torso deck sits 48 units above the top tread — past a plain jump's 45, but
## inside a duck-jump. This is the regression check for Simulation.update_crouch's
## airborne branch: GoldSrc PM_Duck only pulls the origin down to keep the feet
## planted when ducking ON THE GROUND, so ducking mid-air raises the feet instead.
## Without that lift the peak lands 12 mm short of the lip and the player slides
## back down the stairs.

const Movement = preload("res://addons/pmove/movement.gd")
const MovementConfig = preload("res://addons/pmove/movement_config.gd")
const InputCommand = preload("res://addons/pmove/input_command.gd")

const S := 0.025


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
	char_body.floor_block_on_wall = false
	char_body.safe_margin = 0.01
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

	var ascent: Vector3 = (leg.global_transform.basis * gs_to_godot(1.0, 0.0, 0.0)).normalized()
	# Top tread (11): z = 176, x in [-33,-32]. Stand half a hull back from the riser.
	var top: Vector3 = leg.global_transform * gs_to_godot(-32.5, 88.0, 176.0)
	var deck_y: float = (leg.global_transform * gs_to_godot(0.0, 88.0, 224.0)).y
	char_body.global_position = top - ascent * 0.4
	body.force_sync_physics()
	await physics_frame
	state.on_floor = true

	print("top tread y=%.3f   torso deck y=%.3f   (%.0f units apart)" % [
		top.y, deck_y, (deck_y - top.y) / S])
	print("jump_speed %.3f -> %.3f m of plain-jump rise\n" % [
		cfg.jump_speed, cfg.jump_speed * cfg.jump_speed / (2.0 * cfg.gravity)])

	var cmd := InputCommand.new()
	cmd.yaw = atan2(ascent.x, ascent.z)
	cmd.delta = 1.0 / 60.0
	var peak: float = char_body.global_position.y
	# Duck-jump in, then RELEASE crouch and see whether the player stands back up.
	for tick in 150:
		cmd.move_input = Vector2(0, 1) if tick < 40 else Vector2.ZERO
		cmd.jump = tick >= 2 and tick < 40
		cmd.jump_just_pressed = tick == 2
		cmd.crouch = tick >= 5 and tick < 60   # crouch released at tick 60
		sim.simulate_tick(body, state, cmd)
		await physics_frame
		peak = maxf(peak, char_body.global_position.y)
		if tick >= 58 and tick <= 70:
			print("  t%3d crouch_in=%s is_crouched=%s on_floor=%s y=%.3f headroom=%s vel.y=%+.3f" % [
				tick, cmd.crouch, state.is_crouched, state.on_floor,
				char_body.global_position.y, body.has_headroom(cfg.stand_height - cfg.crouch_height), state.velocity.y])
	print("  ... 90 ticks after release: is_crouched=%s" % state.is_crouched)

	var final_y: float = char_body.global_position.y
	print("peak feet y=%.3f (%.0f units above the top tread)" % [peak, (peak - top.y) / S])
	var inv := leg.global_transform.affine_inverse()
	var l: Vector3 = inv * char_body.global_position
	print("ended at leg-local GS (%.1f, %.1f, %.1f)" % [-l.x / S, l.z / S, l.y / S])
	print("ended at y=%.3f -> %s" % [final_y,
		"ON THE DECK, inside the golem" if final_y > deck_y - 0.05 else "fell back onto the stairs"])
	quit(0)
