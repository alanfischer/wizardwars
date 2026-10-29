extends Node
## Ride the REAL golem: real entity scripts driving the torso and all 44 parts, the
## real PlayerMovementContext supplying carry/pusher/depenetration, and the real
## netmove simulation. Every earlier probe hand-rolled those and hand-moved a single
## body, and none of them reproduced the back-corner ejection.
##
## Usage:
##   X=-14 Y=-70 STRAFE=-1 BACK=1 [TURN=1] tools/probe_golem_real.gd
##     X,Y     start spot in the cockpit, body-local GoldSrc (right is -y)
##     BACK    1 = hold back
##     STRAFE  -1 / +1 = hold a strafe
##     TURN    1 = golem turns instead of walking ("r" turns right)
##     NET=0   stop publishing the golem's transform. The real game publishes every
##             registered mover once per net tick (main.gd; NET_TICK_INTERVAL is the physics
##             tick), and the carry reads that; without it the rider gets the no-publisher
##             path, which every number this probe printed before 2026-10-12 was measured on.
##     FOLLOW  1 = the rider's view yaw turns with the mover underfoot, as
##             local_player._apply_rotating_ground_yaw does in game. Without it the rider
##             holds a world-fixed heading, so "back" drifts off the golem's back as it turns
##             and they walk along the wall under their own power.
##     DBG_TICKS  61[,62] — trace hop's push-out answers for the stride-lift query of
##             these ticks. Needs tools/golem_corner/instrument_pushout.py applied to
##             hop; tick 61 is where the golem-corner regression starts (see TODO.md).
##     SHOVE   tick:units — at `tick`, displace the rider `units` along body-local -x,
##             standing in for a second rider's depenetration driving this one into the
##             rear wall. Nothing else in a one-rider sim pushes a rider INTO a wall —
##             the carry and the pusher both hold them off it — which is why every
##             earlier probe here came up clean while four players on a live server did
##             not. Pair it with JUMP: the control brushes' expanded hulls only reach
##             down to 22 units above the deck.
##
## Each tick prints a POSE line holding the hull trace point in the golem's own frame.
## Pipe them through the independent oracle to get the same per-axis intervals read off
## the raw .bsp instead of out of the engine:
##
##   X=-14 Y=-70 STRAFE=-1 BACK=1 godot --headless --path . \
##       res://tools/probe_golem_real.tscn | grep POSE > /tmp/poses.txt
##   python3 tools/bsp_hull_oracle.py maps/ww_golem.bsp \
##       --classname func_golem_body --poses /tmp/poses.txt

const Movement = preload("res://addons/pmove/movement.gd")
const MovementConfig = preload("res://addons/pmove/movement_config.gd")
const InputCommand = preload("res://addons/pmove/input_command.gd")
const ServerMovement = preload("res://addons/pmove/server_movement.gd")

const S := 0.025
## How far each engine span probe reaches, GoldSrc units. Wide enough to clear the
## cockpit (it is 60 deep) so an unobstructed axis reads as the limit, not as a wall.
const SPAN_PROBE := 48.0


## Drives the rider's tick AFTER the map's own entities have moved for the frame.
##
## `get_tree().physics_frame` fires BEFORE any node's `_physics_process`, so a probe that
## awaited it moved the rider first and the golem second — the opposite of the real game,
## where main.gd adds the map (line 590) before the player (line 760) and Godot therefore
## calls the golem's `_physics_process` first.
##
## That inversion is not cosmetic. It makes the carry read LAST frame's mover motion, and at
## the bottom of the golem's stride bob, where the vertical motion reverses, a one-frame-stale
## carry sinks the rider 1.67 units into the deck in a single tick — twice the per-frame
## travel, because the carry still pulls down while the deck has started rising. That looked
## exactly like a carry bug and is not one; it cost a session. A high
## `process_physics_priority` puts this after every default-priority node, so the golem has
## already moved when the tick runs.
class TickDriver:
	extends Node
	signal ticked

	func _physics_process(_delta: float) -> void:
		ticked.emit()
# func_golem_body's brush bounds in its own GoldSrc frame, which is what "still inside the
# golem" means. The rider's FEET are compared against them; the hull-1 trace point sits 36
# higher, so the z floor is deliberately generous.
const TORSO_MINS := Vector3(-96.0, -112.0, -176.0)
const TORSO_MAXS := Vector3(60.0, 114.0, 184.0)
const GOLEM_CLASSES := {
	"func_golem_body": "FuncGolemBody",
	"func_golem_leftleg": "FuncGolemLimb",
	"func_golem_rightleg": "FuncGolemLimb",
	"func_golem_leftarm": "FuncGolemLimb",
	"func_golem_rightarm": "FuncGolemLimb",
	"func_golem_controls_forward": "FuncGolemControls",
	"func_golem_controls_left": "FuncGolemControls",
	"func_golem_controls_right": "FuncGolemControls",
	"func_golem_controls_attack": "FuncGolemControls",
}

var golem: Node3D          # the scripted FuncGolemBody
var golem_body: AnimatableBody3D
var player: CharacterBody3D


func gs_to_godot(x: float, y: float, z: float) -> Vector3:
	return Vector3(-x * S, z * S, y * S)


func local_gs(p: Vector3) -> Vector3:
	var l: Vector3 = golem_body.global_transform.affine_inverse() * p
	return Vector3(-l.x / S, l.z / S, l.y / S)


## A contact normal in the golem's own GoldSrc frame.
func gs_normal(n_world: Vector3) -> Vector3:
	var l: Vector3 = golem_body.global_transform.basis.inverse() * n_world
	return Vector3(-l.x, l.z, l.y)


## Which of the brush model's six faces a normal belongs to, e.g. "-y". Four successive
## wrong diagnoses of this escape all came of reading the axis I expected to matter
## instead of the one that did, so every contact now says which axis it is rather than
## leaving it to be inferred from three printed components. A trailing "~" is a plane
## that is not axis-aligned — a clipnode bevel, or a limb at some other yaw — and those
## are not one of the faces the span lines measure against.
func axis_label(n_gs: Vector3) -> String:
	var ax := 0
	for i in 3:
		if absf(n_gs[i]) > absf(n_gs[ax]):
			ax = i
	return ("+" if n_gs[ax] > 0.0 else "-") + "xyz"[ax] + ("" if absf(n_gs[ax]) > 0.99 else "~")


func _capsule() -> CapsuleShape3D:
	return ((player.get_node("CollisionShape3D") as CollisionShape3D).shape as CapsuleShape3D)


## The point hop reduces the capsule to. A GoldSrc hull is baked around the body's
## CENTRE, so a standing player traces hull 1 at feet+36 and a ducked one hull 3 at
## feet+18 — every answer bsp_hull_oracle.py gives is about this point, not the feet,
## and comparing the oracle against a feet position is how the "sinking through the
## deck" diagnosis went wrong.
func hull_trace_point() -> Vector3:
	var p := local_gs(player.global_position)
	p.z += _capsule().height * 0.5 / S
	return p


func hull_index() -> int:
	return 1 if _capsule().height > 1.35 else 3


## How far the body may travel along each of the golem's own six face directions, as the
## ENGINE answers it. The counterpart to `bsp_hull_oracle.py --span`, which answers the
## same question off the raw .bsp: run both and a disagreement is the evidence, rather
## than hop's single reported contact having to be believed on its own.
func engine_spans() -> String:
	var tp := PhysicsTestMotionParameters3D.new()
	tp.from = player.global_transform
	tp.margin = player.safe_margin
	tp.recovery_as_collision = false
	var tr := PhysicsTestMotionResult3D.new()
	var basis_inv := golem_body.global_transform.basis.inverse()
	var out := PackedStringArray()
	for ax in 3:
		for sgn in [-1.0, 1.0]:
			var gs := Vector3.ZERO
			gs[ax] = sgn
			var dir: Vector3 = (golem_body.global_transform.basis * gs_to_godot(gs.x, gs.y, gs.z)).normalized()
			tp.motion = dir * (SPAN_PROBE * S)
			PhysicsServer3D.body_test_motion(player.get_rid(), tp, tr)
			var t: Vector3 = basis_inv * tr.get_travel()
			var trav: float = Vector3(-t.x, t.z, t.y)[ax] * sgn / S
			var who := "open"
			if tr.get_collision_count() > 0:
				who = axis_label(gs_normal(tr.get_collision_normal(0)))
			out.append("%s%s=%6.2f %-3s" % [
				"-" if sgn < 0.0 else "+", "xyz"[ax], trav, who])
	return " ".join(out)


## Every contact a motion test reports: which body, which face, the normal in the
## golem's frame, and the depth in GoldSrc units. `*` marks the deepest, because that
## single contact is the one PlayerMovementContext._apply_hull_corrections turns into
## the tick's depenetration — so the governing contact is named here, not assumed.
func contacts_str(res: PhysicsTestMotionResult3D) -> String:
	var deepest := -1
	for i in res.get_collision_count():
		if deepest < 0 or res.get_collision_depth(i) > res.get_collision_depth(deepest):
			deepest = i
	var out := PackedStringArray()
	for i in res.get_collision_count():
		var n := gs_normal(res.get_collision_normal(i))
		var who: Object = instance_from_id(res.get_collider_id(i))
		var who_name := "?"
		if who is Node:
			who_name = String((who as Node).get_meta("entity", {}).get("classname", ""))
			if who_name == "":
				who_name = (who as Node).name
		out.append("%s%s %s n=(%5.2f,%5.2f,%5.2f) d=%6.2f" % [
			"*" if i == deepest else " ", who_name, axis_label(n), n.x, n.y, n.z,
			res.get_collision_depth(i) / S])
	if out.is_empty():
		return "(none)"
	return " | ".join(out)


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var root: Node3D = (load("user://resources/maps/ww_golem.scn") as PackedScene).instantiate()

	# EntityRegistry.apply_scripts, for the golem only: set_script on the existing BSP node.
	# This MUST happen before the map enters the tree — set_script on a node that is
	# already inside it does not re-run _ready(), so the entity never initialises and
	# just sits there (which is exactly what the first version of this probe did).
	var scripts := {
		"FuncGolemBody": FuncGolemBody,
		"FuncGolemLimb": FuncGolemLimb,
		"FuncGolemControls": FuncGolemControls,
	}
	var spawned := 0
	for child in root.get_children():
		if not child.has_meta("entity"):
			continue
		var cn: String = child.get_meta("entity").get("classname", "")
		if not GOLEM_CLASSES.has(cn):
			continue
		child.set_script(scripts[GOLEM_CLASSES[cn]])
		spawned += 1
		if cn == "func_golem_body":
			golem = child
	get_tree().root.add_child(root)
	print("attached %d golem entity scripts; body=%s" % [spawned, golem])
	for i in 40:
		await get_tree().physics_frame
	golem_body = golem as AnimatableBody3D

	# --- a player body shaped like player.tscn ---
	player = CharacterBody3D.new()
	player.collision_layer = 0
	player.collision_mask = GameConsts.MASK_WORLD_AND_CLIP | GameConsts.MASK_ENTITY
	# MARGIN: CharacterBody3D.safe_margin, metres. The game ships 0.01 (player.tscn:19),
	# which is 0.4 GoldSrc units — and a clip hull has no tolerance for that, so the knob
	# is here to test whether the penetration a wall-pressed rider holds is the margin.
	player.safe_margin = float(OS.get_environment("MARGIN")) if OS.get_environment("MARGIN") != "" else 0.01
	player.floor_block_on_wall = false
	player.floor_max_angle = acos(Movement.WALK_NORMAL_Y)
	var cs := CollisionShape3D.new()
	cs.name = "CollisionShape3D"
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.8
	cs.shape = cap
	cs.position = Vector3(0, 0.9, 0)
	player.add_child(cs)
	var ladder := Area3D.new()
	ladder.name = "LadderDetector"
	ladder.collision_layer = 0
	ladder.collision_mask = GameConsts.MASK_LADDER
	ladder.monitorable = false
	var lcs := CollisionShape3D.new()
	var lcyl := CylinderShape3D.new()
	lcyl.height = 1.8
	lcyl.radius = 0.4
	lcs.shape = lcyl
	lcs.position = Vector3(0, 0.9, 0)
	ladder.add_child(lcs)
	player.add_child(ladder)
	var water := Area3D.new()
	water.name = "WaterDetector"
	water.collision_layer = 0
	water.collision_mask = GameConsts.MASK_WATER
	water.monitorable = false
	var wcs := CollisionShape3D.new()
	var wsph := SphereShape3D.new()
	wsph.radius = 0.1
	wcs.shape = wsph
	wcs.position = Vector3(0, 0.9, 0)
	water.add_child(wcs)
	player.add_child(water)
	root.add_child(player)

	var start_x := float(OS.get_environment("X")) if OS.get_environment("X") != "" else -14.0
	var start_y := float(OS.get_environment("Y")) if OS.get_environment("Y") != "" else -70.0
	player.global_position = golem_body.global_transform * gs_to_godot(start_x, start_y, -110.0)

	# --- the REAL movement context and server simulation ---
	var ctx := PlayerMovementContext.new(player, ladder, water)
	var cfg := MovementConfig.new()
	var server := ServerMovement.new(cfg)
	var gbody := GodotBody.new(player)
	server.bind_body(gbody)
	gbody.force_sync_physics()
	await get_tree().physics_frame
	server.state.on_floor = true

	var back := 0.0 if OS.get_environment("BACK") == "0" else -1.0
	var strafe := float(OS.get_environment("STRAFE")) if OS.get_environment("STRAFE") != "" else -1.0
	var turning := OS.get_environment("TURN") != ""
	var follow := OS.get_environment("FOLLOW") != ""
	var publishing := OS.get_environment("NET") != "0"
	# NetworkManager.send_entity_transforms' loop, over the movers this map actually built one
	# for: the torso and any part that registered a sync of its own.
	var publishers: Array[MoverNetPublisher] = []
	for child in root.get_children():
		var pub := MoverNetPublisher.of(child)
		if pub != null:
			publishers.append(pub)
	# DUCK=n: hold crouch from tick n onward (the user's repro: walk into the back-right
	# corner, then duck). DUCK=hold ducks the whole run.
	# DUCK=cycle holds crouch for `period/2` ticks then releases, over and over, so the
	# duck and the stand-up each land at every phase of the golem's stride — a fixed
	# DUCK=n only ever tests the one phase it happens to fall on.
	var duck_env := OS.get_environment("DUCK")
	var duck_from := 1 << 30
	var duck_period := 0
	if duck_env == "hold":
		duck_from = 0
	elif duck_env == "cycle":
		duck_from = 0
		duck_period = int(OS.get_environment("PERIOD")) if OS.get_environment("PERIOD") != "" else 17
	elif duck_env != "":
		duck_from = int(duck_env)

	# JUMP=n: press jump every n ticks (a player mashing space). jump_just_pressed is
	# what actually launches, so it rides the same tick as the hold.
	var jump_every := int(OS.get_environment("JUMP")) if OS.get_environment("JUMP") != "" else 0

	# DBG_TICKS=61[,62]: turn hop's push-out trace on for the 0.001-margin lift query of
	# these ticks and nothing else (see the lift block below). A whole tick is 1500 lines
	# and a whole ride is unreadable, so narrowing it to one query is what makes two
	# builds diffable. Needs a hop built by tools/golem_corner/instrument_pushout.py;
	# inert otherwise.
	var dbg_ticks := {}
	for t in OS.get_environment("DBG_TICKS").split(",", false):
		dbg_ticks[int(t)] = true
	# One-element holder, for the same reason last_mods is an Array: a lambda captures
	# locals by value, so the loop and `grab` need a reference to share a flag through.
	var dbg_now := [false]

	var shove_tick := -1
	var shove_units := 0.0
	if OS.get_environment("SHOVE") != "":
		var parts := OS.get_environment("SHOVE").split(":")
		shove_tick = int(parts[0])
		shove_units = float(parts[1]) if parts.size() > 1 else 10.0

	# Face the way the golem faces, so "back" is the golem's back.
	var forward: Vector3 = (golem_body.global_transform.basis * gs_to_godot(1.0, 0.0, 0.0)).normalized()
	var yaw := atan2(forward.x, forward.z)

	if OS.get_environment("STILL") != "":
		pass  # golem stands still — isolates "the wall advancing into you"
	elif turning:
		if OS.get_environment("TURN") == "r":
			golem.golem_turn_right()
		else:
			golem.golem_turn_left()
	else:
		golem.golem_walk()
	print("golem %s. %d mover publisher(s), publishing=%s. rider starts at body-local GS %s, back=%.0f strafe=%.0f view=%s\n" % [
		"TURNING" if turning else "WALKING", publishers.size(), publishing,
		local_gs(player.global_position), back, strafe,
		"follows the golem" if follow else "world-fixed"])

	var seq := 0
	var prev_after := local_gs(player.global_position)
	var prev_golem_yaw := golem_body.rotation.y
	var last_mods: Array = [Vector3.ZERO, Vector3.ZERO, 0.0, Vector3.ZERO, "", Vector3.ZERO, "", 1,
			Vector3.ZERO, ""]
	var rec_probe := PhysicsTestMotionParameters3D.new()
	rec_probe.motion = Vector3.ZERO
	rec_probe.margin = player.safe_margin
	rec_probe.recovery_as_collision = true
	rec_probe.max_collisions = 8
	var rec_res := PhysicsTestMotionResult3D.new()
	var start_probe := PhysicsTestMotionParameters3D.new()
	start_probe.margin = player.safe_margin
	start_probe.recovery_as_collision = true
	start_probe.max_collisions = 8
	var start_res := PhysicsTestMotionResult3D.new()
	var grab := func(c):
		last_mods[2] = golem_body.rotation.y
		last_mods[3] = local_gs(player.global_position)
		last_mods[5] = hull_trace_point()
		last_mods[6] = engine_spans()
		last_mods[7] = hull_index()
		# What hop sees at TICK START — the pose that actually matters. The body is
		# ~0.4 units inside the rear wall here every tick (the golem advanced into it
		# after last tick's correction), and the locomotion sweep is about to start
		# from it. The end-of-tick manifold cannot show this; by then it is resolved.
		var bdir: Vector3 = (golem_body.global_transform.basis * gs_to_godot(-1.0, 0.0, 0.0)).normalized()
		start_probe.from = player.global_transform
		start_probe.motion = bdir * (3.8 * S)  # the backpedal the player is about to attempt
		PhysicsServer3D.body_test_motion(player.get_rid(), start_probe, start_res)
		# hop folds its depenetration into `travel`, so a ZERO-motion probe's travel is
		# exactly the recovery the next move_and_collide of this tick will apply before
		# it sweeps. A rider that holds penetration tick after tick is either not being
		# offered a correction here, or having it taken back after the fact — and those
		# are different bugs in different layers.
		rec_probe.from = player.global_transform
		PhysicsServer3D.body_test_motion(player.get_rid(), rec_probe, rec_res)
		last_mods[8] = local_gs(player.global_position + rec_res.get_travel()) \
				- local_gs(player.global_position)
		# What the engine would actually DELIVER for the ride this tick. The carry is
		# applied as a swept move (Movement.slide_move), so a refused sweep is a ride
		# silently dropped — and a rider leaning on a moving brush starts every tick a
		# fraction inside it, which is the state where a sweep answers nothing. Asked at
		# move_and_collide's own default margin (0.001 m) and at the body's safe_margin,
		# because the margin is subtracted from the answer and the two differ by 10x.
		# gs_to_godot already scales, so this is 0.83 GoldSrc units straight up in the
		# golem's frame — one tick of the stride's rise, the lift a rider lives on.
		var carry_probe := golem_body.global_transform.basis * gs_to_godot(0.0, 0.0, 0.83)
		last_mods[9] = ""
		for m in [0.001, player.safe_margin]:
			rec_probe.motion = carry_probe
			rec_probe.margin = m
			# Only the 0.001 query: stdout markers do not interleave with hop's stderr
			# trace, so the log has to belong to exactly one query to be readable.
			# `m == 0.001` and not a threshold — safe_margin is configurable and a value
			# under one would quietly trace both.
			var trace_this: bool = dbg_now[0] and m == 0.001
			if trace_this:
				print("  [lift probe margin=%.3f]" % m)
				OS.set_environment("HOP_PUSHOUT_DBG", "1")
			PhysicsServer3D.body_test_motion(player.get_rid(), rec_probe, rec_res)
			if trace_this:
				OS.set_environment("HOP_PUSHOUT_DBG", "0")
			var got: Vector3 = local_gs(player.global_position + rec_res.get_travel()) \
					- local_gs(player.global_position)
			last_mods[9] += "lift@%.3f safe=%.2f unsafe=%.2f got(%.2f,%.2f,%.2f)  " % [
					m, rec_res.get_collision_safe_fraction(),
					rec_res.get_collision_unsafe_fraction(), got.x, got.y, got.z]
		rec_probe.motion = Vector3.ZERO
		rec_probe.margin = player.safe_margin
		last_mods[4] = "unsafe=%.2f safe=%.2f trav=%.2f || %s" % [
			start_res.get_collision_unsafe_fraction(), start_res.get_collision_safe_fraction(),
			-(golem_body.global_transform.basis.inverse() * start_res.get_travel()).x / S,
			contacts_str(start_res)]
		var m = ctx.get_modifiers(cfg, server.state, [], 1.0, c)
		last_mods[0] = m.carry_motion
		last_mods[1] = m.depenetration
		return m
	var ticks := int(OS.get_environment("TICKS")) if OS.get_environment("TICKS") != "" else 600
	var driver := TickDriver.new()
	driver.process_physics_priority = 100  # after the golem; see TickDriver
	add_child(driver)
	for tick in ticks:
		var cmd := InputCommand.new()
		seq += 1
		cmd.seq = seq
		cmd.delta = 1.0 / 60.0
		cmd.yaw = yaw
		cmd.move_input = Vector2(strafe, back)
		if jump_every > 0 and tick % jump_every == 0:
			cmd.jump = true
			cmd.jump_just_pressed = true
		cmd.crouch = tick >= duck_from
		if duck_period > 0:
			cmd.crouch = (tick % duck_period) * 2 < duck_period
		if tick == shove_tick:
			var shove_dir: Vector3 = (golem_body.global_transform.basis * gs_to_godot(-1.0, 0.0, 0.0)).normalized()
			player.global_position += shove_dir * (shove_units * S)
			gbody.force_sync_physics()
			print("  SHOVE %.0f units along body-local -x -> local GS %s" % [
				shove_units, local_gs(player.global_position)])
		server.enqueue(cmd)
		var before := local_gs(player.global_position)
		dbg_now[0] = dbg_ticks.has(tick)
		server.process_queue(gbody, grab)
		dbg_now[0] = false
		# The yaw the rider is OFFERED this tick against the yaw the golem actually turned
		# between the two ticks: a rider whose view under-rotates walks sideways across the
		# cockpit even while the linear carry holds them perfectly against the wall.
		var ride_yaw := ctx.get_carry_yaw_delta()
		var golem_dyaw := wrapf(float(last_mods[2]) - prev_golem_yaw, -PI, PI)
		prev_golem_yaw = float(last_mods[2])
		# After the rider's tick, as in main.gd: _process_player_movements() runs before
		# send_entity_transforms(), so the velocity a carry reads is always one frame old.
		if publishing:
			for pub in publishers:
				pub.publish()
		if follow and server.state.on_floor:
			yaw += ctx.get_carry_yaw_delta()
		var after := local_gs(player.global_position)
		if true:
			print("t%3d  local GS (%7.2f,%8.2f,%8.2f)  d=(%6.2f,%6.2f,%6.2f) floor=%s  golem world=(%.3f,%.3f,%.3f) yaw=%.1f" % [
				tick, after.x, after.y, after.z,
				after.x - before.x, after.y - before.y, after.z - before.z,
				("Y" if server.state.on_floor else "n") + ("/duck" if server.state.is_crouched else "/stand"),
				golem_body.global_position.x, golem_body.global_position.y,
				golem_body.global_position.z, rad_to_deg(golem_body.rotation.y)])
			print("        at tick start: yaw=%.3f localGS=%s | at end: yaw=%.3f" % [
				rad_to_deg(last_mods[2]), last_mods[3], rad_to_deg(golem_body.rotation.y)])
			# The tick-start pose, as the oracle wants it. Greppable on purpose.
			var hp: Vector3 = last_mods[5]
			print("        POSE t%d hull=%d %.3f %.3f %.3f" % [tick, last_mods[7], hp.x, hp.y, hp.z])
			print("        SPANS(%du) %s" % [int(SPAN_PROBE), last_mods[6]])
			print("        START SWEEP back 3.8: %s" % last_mods[4])
			var cl := local_gs(player.global_position + (last_mods[0] as Vector3)) - after
			var dl := local_gs(player.global_position + (last_mods[1] as Vector3)) - after
			# Velocity in the golem's frame, so a backward lurch is separable from the
			# carry/depen corrections: those are position deltas and never touch it.
			var vl: Vector3 = golem_body.global_transform.basis.inverse() * server.state.velocity
			var rl: Vector3 = last_mods[8]
			print("        carry(%6.2f,%6.2f,%6.2f)  depen(%6.2f,%6.2f,%6.2f)  recover(%6.2f,%6.2f,%6.2f)  vel GS(%7.2f,%7.2f,%7.2f)" % [
				cl.x, cl.y, cl.z, dl.x, dl.y, dl.z, rl.x, rl.y, rl.z,
				-vl.x / S, vl.z / S, vl.y / S])
			# What the golem did to the rider's body-local pose BETWEEN ticks, while the
			# rider's world position sat still: the cockpit sliding out from under them.
			# A working carry cancels it, so this and `carry` above should be equal and
			# opposite — printed side by side because reading the drift off two
			# consecutive position lines is what made it look like the rider was walking.
			var drift: Vector3 = (last_mods[3] as Vector3) - prev_after
			print("        YAW ride=%.4f deg  golem turned=%.4f deg  deficit=%.4f" % [
				rad_to_deg(ride_yaw), rad_to_deg(golem_dyaw),
				rad_to_deg(golem_dyaw - ride_yaw)])
			print("        golem slid the frame under the rider by (%6.2f,%6.2f,%6.2f)" % [
				drift.x, drift.y, drift.z])
			print("        LIFT %s" % last_mods[9])
			prev_after = after
			# What the physics server reports where the rider now is, and whether a
			# backward step is allowed to proceed.
			var tp := PhysicsTestMotionParameters3D.new()
			tp.from = player.global_transform
			tp.motion = Vector3.ZERO
			tp.margin = player.safe_margin
			tp.recovery_as_collision = true
			tp.max_collisions = 8
			var tr := PhysicsTestMotionResult3D.new()
			PhysicsServer3D.body_test_motion(player.get_rid(), tp, tr)
			# WHICH body, and which of its faces. A normal alone cannot tell the torso's
			# cockpit wall from a limb sweeping through it, and that distinction is the
			# whole question for the one-tick anomalies.
			var msg := "        manifold: " + contacts_str(tr)
			# Can a backward step still proceed?
			var back_dir: Vector3 = (golem_body.global_transform.basis * gs_to_godot(-1.0, 0.0, 0.0)).normalized()
			tp.motion = back_dir * 0.15
			PhysicsServer3D.body_test_motion(player.get_rid(), tp, tr)
			msg += "   back step unsafe_frac=%.2f" % tr.get_collision_unsafe_fraction()
			print(msg)
		# Left the golem, judged against the TORSO'S OWN BRUSH BOUNDS rather than a
		# threshold on x. An earlier `after.x < -60` called three of this probe's
		# scenarios an ejection when the rider was standing in the entry shaft: at
		# body-local y +48..+76 the cockpit opens backward to x = -72, and below the deck
		# that shaft runs down to feet -156, which is how you climb in. x = -64 there is
		# as legitimate a place to stand as the driver's spot, and chasing it wasted a
		# session. These bounds come from model *41's mins/maxs (see
		# tools/bsp_hull_oracle.py --model 41).
		var out_of_bounds := after.x < TORSO_MINS.x or after.x > TORSO_MAXS.x \
			or after.y < TORSO_MINS.y or after.y > TORSO_MAXS.y \
			or after.z < TORSO_MINS.z
		if out_of_bounds:
			var how := "below the golem" if after.z < TORSO_MINS.z else (
				"out the back" if after.x < TORSO_MINS.x else "out the side")
			# NOT a verdict on its own. Every scenario here holds BACK forever, so a rider
			# who is being carried perfectly still walks to the rear of the cockpit and
			# out through the entry shaft eventually — legitimately, the same way they got
			# in. What distinguishes a bug is whether they passed through SOLID geometry
			# on the way, which this does not yet check. Read the ticks before this line:
			# a bug looks like the rider holding position in the WORLD (per-tick d near
			# zero) while their body-local x marches backward at the golem's own pace,
			# which is the carry having switched off, or like a backward step the START
			# SWEEP reported as unobstructed through a wall that is right there.
			print("\nLEFT THE GOLEM (%s) at tick %d — local GS %s" % [how, tick, after])
			get_tree().quit(0)
		await driver.ticked
	print("\nsurvived 600 ticks; final local GS %s" % local_gs(player.global_position))
	get_tree().quit(0)
