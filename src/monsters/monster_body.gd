class_name MonsterBody
extends RefCounted

## GoldSrc locomotion for a walking monster — the same kernel the players and the bots walk on.
##
## A behavior rather than a base class, like [SummonBehavior] and [MonsterNav].
##
## Monsters used to drive themselves with move_and_slide plus SpatialQuery.step_up, which is fine for
## a summon crossing the room it was cast in and fails over a map. Measured on ww_2fort with the
## routing already working: a skeleton following a valid route on a 1 m grid was pressed against
## geometry on 42% of the ticks it was trying to walk, and never finished a 45-150 m trip. The
## control, walking straight at the goal, was blocked 80% of the time. Doorframes, step lips and
## brush seams are what netmove's walk_move exists to get over, so a monster walks on it too.
##
## Movement.Simulation takes a MovementConfig per instance, so each monster keeps the speed and
## hull it was authored with — only the acceleration, friction, stepping and sliding change hands.
##
## It swims as well as walks (see _swim), because water is otherwise a hole a wave walks into and
## never comes back out of.

const Movement = preload("res://addons/pmove/movement.gd")
const MovementConfig = preload("res://addons/pmove/movement_config.gd")
const InputCommand = preload("res://addons/pmove/input_command.gd")
const LadderWater = preload("res://addons/pmove/ladder_water.gd")
const HullContacts = preload("res://addons/pmove/hull_contacts.gd")

## The player's swim speed is 200 of its 320 unit maxspeed; a monster keeps that ratio against
## its own walk rather than inheriting the player's absolute 5 m/s, which a skeleton would swim
## faster than it runs.
const WATER_SPEED_FRAC := 200.0 / 320.0
## How high above its feet a monster will haul itself to get out of water. GoldSrc's rule stops at
## the swimmer's own standing height, which is only about 0.9 m above the surface it floats in — and
## the bake links a climb-out to any bank up to 1.8 m above the waterline, so most of the exits it
## promises a monster are above a player's reach. Measured in ww_2fort: a skeleton surfaced right
## under the bank its route ended on, 1.1 m above the water, and pressed into it for thirty seconds.
## A player would swim round to a ramp; a monster has no such idea, so it climbs.
const CLIMB_REACH := 2.8
## Quiet time after a climb-out attempt, so a monster that is still in the water afterwards spends
## the next while swimming its route instead of hauling at the same ledge again.
const CLIMB_COOLDOWN := 1.5

## Movers and GoldSrc PM_CheckStuck come from pmove's [HullContacts], the same as the player's:
## a monster rides lifts, is shoved by doors, and is unstuck from the pose walk_move leaves it in
## after sliding flush into a wall. A monster makes that pose far more often than a player — the
## 42% above is how much of its walking it spends pressed against geometry, and a soak logs 152-238
## pins per 90 s against 14 in 72 bot-minutes for a player. Measured on ww_2fort before the unstick,
## skeletons froze in mid-air at one step height, pressed against a wall, for the rest of the round.
##
## A monster is host-only, so it has no reason to route those corrections through per-tick
## modifiers for replay: they go straight into its state and the next tick consumes them.

var state: Movement.MovementState
var cfg: MovementConfig
## Waist-deep or deeper, as of the last tick — GoldSrc waterlevel 2, the swim threshold. Public
## so a host can pick a clip or hold its fire while its monster is in the drink.
var in_water := false

var _sim: Movement.Simulation
var _body: GodotBody
var _host: CharacterBody3D
var _cmd
## Countdown on a water-jump launch, during which the swim clamp is off so ordinary air movement
## carries the monster over the bank (PlayerMovementContext keeps the same clock for the player).
var _waterjump_t := 0.0
var _climb_t := 0.0
var _hull: HullContacts


## `speed` and `height` are the monster's own constants; everything else stays at the GoldSrc
## defaults, which is the point — a monster that steps and slides like a player goes where a
## player can go, which is exactly what the waypoint bake promises.
func setup(host: CharacterBody3D, speed: float, height: float) -> void:
	cfg = MovementConfig.new()
	cfg.max_speed = speed
	cfg.stand_height = height
	# Nothing in the roster ducks. Collapsing the crouch hull onto the standing one keeps
	# update_crouch from ever resizing a monster out from under its own hitboxes.
	cfg.crouch_height = height
	cfg.stand_eye = height * 0.9
	cfg.crouch_eye = cfg.stand_eye
	cfg.water_speed = speed * WATER_SPEED_FRAC
	_sim = Movement.Simulation.new(cfg)
	state = Movement.MovementState.new()
	_host = host
	_body = GodotBody.new(host)
	_cmd = InputCommand.new()
	state.bind_body(_body)
	_hull = HullContacts.new(host)
	_hull.teleport_distance = GameConsts.MOVER_TELEPORT_DIST
	_hull.unit = GameConsts.SCALE_FACTOR
	_hull.ground_mask = GameConsts.MASK_WORLD_AND_CLIP | GameConsts.MASK_ENTITY
	# A monster this buried is a map or a mover problem, and the log is the only way anyone finds out.
	_hull.unstuck.connect(func(at: Vector3, offset: Vector3) -> void:
		Log.info("[MonsterBody] unstuck %s at %.2f,%.2f,%.2f by %.1f mm %v" % [
				host.name, at.x, at.y, at.z, offset.length() * 1000.0, offset.normalized()]))
	_hull.pinned.connect(func(at: Vector3) -> void:
		Log.info("[MonsterBody] %s is pinned at %.2f,%.2f,%.2f and no offset frees it" % [
				host.name, at.x, at.y, at.z]))


## One tick of walking in `dir` (world-space horizontal; zero to stand still and let friction
## stop it). The host keeps its own facing — walking and looking are separate for a monster, the
## way the skeleton plants its feet and throws at something off to one side. `swim_to` is the point
## the host is heading for, which only matters in water (see _swim) — pass MonsterNav.waypoint().
##
## The command carries the host's CURRENT yaw, and `dir` is handed over rotated into that frame.
## Both halves matter. simulate_tick assigns `body.yaw = cmd.yaw` every tick, so a command that
## says yaw 0 silently pins the monster facing north — which it did: skeletons walked their route
## while facing a fixed direction, and read as walking backwards. And since the kernel resolves
## move_input through that same yaw, the direction has to be de-rotated or the fix would send
## them off at an angle instead.
func walk(delta: float, dir: Vector3, swim_to := Vector3.INF) -> void:
	# The host's own `velocity` is the source of truth between ticks, the way it is for a player
	# (see ServerMovement), so an external write — a forceblast, a blast wave, trigger_push — is
	# picked up instead of being overwritten by the state we were carrying.
	state.velocity = _body.velocity
	var yaw: float = _host_yaw()
	_cmd.delta = delta
	_cmd.yaw = yaw
	if dir == Vector3.ZERO:
		_cmd.move_input = Vector2.ZERO
	else:
		var local := dir.rotated(Vector3.UP, -yaw)
		_cmd.move_input = Vector2(local.x, local.z)
	_swim(delta, dir, swim_to)
	# The walk direction is the intent unstick gates on: a monster standing still on purpose —
	# idling, or planting its feet to throw — has no symptom to rescue.
	if _host.is_inside_tree():
		_hull.apply(state, state, _cmd, _body)
	_sim.simulate_tick(_body, state, _cmd)
	# GoldSrc SV_PushRotate turns a rider's angles with the pusher, monsters included.
	_body.yaw += _hull.carry_yaw_delta


## Swimming, so that water is not a hole in the map.
##
## A walker that drops into a moat has nothing to accelerate against on the bottom and no jump to
## get out with, and the bake makes the same point from the other side: the only edge out of a
## submerged node is the swim-up pop-out, which [MonsterNav] used to drop along with every other
## jump. So a wave that walked into ww_2fort's moat stayed in it for the rest of the round.
##
## The rule is the player's, called through pmove's [LadderWater] — water drag, accelerate toward a
## wish velocity, then GoldSrc's water-jump to climb the bank. What differs is that a monster has no
## camera and no hands on the keys: it swims where it was walking, and it swims UP the way a player
## holding jump does, so it floats as high as the waist threshold allows and climbs from there.
func _swim(delta: float, dir: Vector3, swim_to: Vector3) -> void:
	state.velocity_override_active = false
	_climb_t = maxf(_climb_t - delta, 0.0)
	in_water = _submerged(cfg.stand_height * 0.5)
	if _waterjump_t > 0.0:
		# Mid-launch: leave the override off so ordinary air movement finishes the climb, as it does
		# for a player. Landing ends it early, and so does a launch still in the water that has
		# stopped rising — that one hit the underside of something, and the rest of the clock would
		# be gravity instead of a swim (it sank hulls 1.7 m under ww_2fort's bridge, repeatedly).
		if state.on_floor or (in_water and state.velocity.y <= 0.0):
			_waterjump_t = 0.0
		else:
			_waterjump_t = maxf(_waterjump_t - delta, 0.0)
			return
	if not in_water:
		return
	# A probe above its own head reads a submerged shelf as a bank, so the extra reach is offered
	# only at the surface, and any attempt is followed by a cooldown. Both are about the same
	# measured failure: one monster beside a ledge in a flooded tunnel hauled at it 49 times in
	# thirty seconds and swam 15 m. Below the surface it still gets GoldSrc's own rule, which is
	# enough to pull itself up onto a step — that is how two of ww_2fort's tunnels are left.
	var launch := Vector3.ZERO
	if _climb_t <= 0.0:
		var reach := CLIMB_REACH if not _submerged(cfg.stand_eye) else 0.0
		launch = LadderWater.water_jump(_space(), cfg, state.position, dir,
				state.velocity.y, reach, GameConsts.MASK_WORLD_AND_CLIP)
	if launch != Vector3.ZERO:
		_waterjump_t = LadderWater.WATERJUMP_TIME
		_climb_t = LadderWater.WATERJUMP_TIME + CLIMB_COOLDOWN
		state.velocity_override_active = true
		state.override_velocity = launch
		return
	# Up by default, which is how a monster finds the surface and the bank beside it — but DOWN when
	# the route says down. ww_2fort's water tunnels are entered and left through submerged openings,
	# and a swimmer that only ever rises is pinned under their roof with its route running past it.
	var wish := dir * cfg.water_speed
	wish.y = cfg.water_speed
	if swim_to != Vector3.INF:
		var rise: float = (swim_to.y + cfg.stand_height * 0.5) - state.position.y
		wish.y = clampf(rise, -1.0, 1.0) * cfg.water_speed
	state.velocity_override_active = true
	state.override_velocity = LadderWater.swim(cfg, state.velocity, wish, delta)


## Whether the point `height` above the monster's feet is inside a liquid. Lava and slime count:
## they are swum the same, and the burning is the hazard's business rather than movement's.
func _submerged(height: float) -> bool:
	return _host != null and _host.is_inside_tree() \
			and SpatialQuery.is_point_in_water(_host, state.position + Vector3(0.0, height, 0.0))


func _space() -> PhysicsDirectSpaceState3D:
	if _host == null or not _host.is_inside_tree():
		return null
	return _host.get_world_3d().direct_space_state


func _host_yaw() -> float:
	return _body.yaw if _body != null else 0.0


func is_on_floor() -> bool:
	return state.on_floor


func velocity() -> Vector3:
	return state.velocity


## Drop accumulated motion — for a host that has just been teleported or placed.
func reset() -> void:
	state.velocity = Vector3.ZERO
	if _body != null:
		_body.velocity = Vector3.ZERO  # walk() reads it back, so leaving it behind undoes this
	state.velocity_override_active = false
	_waterjump_t = 0.0
	_climb_t = 0.0
	if _hull:
		_hull.reset()
