class_name PlayerMovementContext

const Movement = preload("res://addons/pmove/movement.gd")
const LadderWater = preload("res://addons/pmove/ladder_water.gd")
const HullContacts = preload("res://addons/pmove/hull_contacts.gd")

## Shared movement-modifier logic for both the local client (local_player.gd) and the
## server puppet (remote_player.gd). Both sides must produce identical modifiers for a
## given (state, cmd) pair — keeping this in one file makes divergence impossible.
##
## Usage:
##   var _move_ctx := PlayerMovementContext.new(self, ladder_detector, water_detector)
##   # each tick:
##   func get_movement_modifiers(cmd): return _move_ctx.get_modifiers(cfg, state, weapons, speed_multiplier, cmd)

const LADDER_KNOCKOFF_SPEED := 10.0
# Dragon flight (CMF_FLYING): the swim's rule with no gravity and its own drag.
const FLIGHT_SPEED := 10.0
const FLIGHT_DRAG := 3.0

# Liquid damage (Half-Life cvars dmg_lava=10, dmg_slime=4 per second).
# Tick on the same 0.5s cadence as trigger_hurt for consistent feel.
const LIQUID_DMG_INTERVAL := 0.5
const LAVA_DMG_PER_TICK := 5.0
const SLIME_DMG_PER_TICK := 2.0

var ladder_normal: Vector3 = Vector3.ZERO
var gravity_scale: float = 1.0
## Last answer check_water() gave inside get_modifiers, so the animation and broadcast sides can
## ask "is this player swimming" without a second shape query of their own.
var in_water := false

var _owner: Node
var _ladder_detector: Area3D
var _water_detector: Area3D
var _ladder_shape_node: CollisionShape3D
var _water_shape_node: CollisionShape3D
var _hull_shape_node: CollisionShape3D  # the player capsule — liquid contact, not submersion

# intersect_shape() instead of Area3D.get_overlapping_areas(): the overlap cache desyncs
# from the player's position after a reconcile snap, which can wrongly read off-ladder for
# multiple ticks and trigger a self-reinforcing correction loop.
var _ladder_query: PhysicsShapeQueryParameters3D
var _water_query: PhysicsShapeQueryParameters3D
var _lava_query: PhysicsShapeQueryParameters3D
var _slime_query: PhysicsShapeQueryParameters3D
var _liquid_dmg_timer: float = 0.0
# Picks ladder, climb-out or swim each tick, and keeps the climb-out clock.
var _ladder_water := LadderWater.Driver.new()

# Ride, push, depenetration and unstick against movers. Null for an owner that isn't a body.
var _hull: HullContacts


func _init(owner: Node, ladder_detector: Area3D, water_detector: Area3D) -> void:
	_owner = owner
	_ladder_detector = ladder_detector
	_water_detector = water_detector
	_ladder_shape_node = _find_shape_child(ladder_detector)
	_water_shape_node = _find_shape_child(water_detector)
	# The player's own capsule, used for liquid CONTACT (see check_lava). Same accessor
	# player.gd uses; RemotePlayer inherits player.tscn, so the puppet has it too.
	_hull_shape_node = owner.get_node_or_null("CollisionShape3D") as CollisionShape3D
	# Detectors are now pure shape holders — disable their built-in monitoring
	# so the physics server doesn't waste work maintaining an overlap list.
	if _ladder_detector:
		_ladder_detector.monitoring = false
	if _water_detector:
		_water_detector.monitoring = false
	_ladder_query = PhysicsShapeQueryParameters3D.new()
	_ladder_query.collide_with_areas = true
	_ladder_query.collide_with_bodies = false
	_ladder_query.collision_mask = GameConsts.MASK_LADDER
	_water_query = PhysicsShapeQueryParameters3D.new()
	_water_query.collide_with_areas = true
	_water_query.collide_with_bodies = false
	_water_query.collision_mask = GameConsts.MASK_WATER
	_lava_query = PhysicsShapeQueryParameters3D.new()
	_lava_query.collide_with_areas = true
	_lava_query.collide_with_bodies = false
	_lava_query.collision_mask = GameConsts.MASK_LAVA
	_slime_query = PhysicsShapeQueryParameters3D.new()
	_slime_query.collide_with_areas = true
	_slime_query.collide_with_bodies = false
	_slime_query.collision_mask = GameConsts.MASK_SLIME
	_ladder_water.ladder_knockoff_speed = LADDER_KNOCKOFF_SPEED
	_ladder_water.wall_mask = GameConsts.MASK_WORLD_AND_CLIP
	if _owner is CharacterBody3D:
		_hull = HullContacts.new(_owner)
		# Matching the interp buffer's distance (rather than a speed guard) keeps a catch-up
		# snap after a stall a carry, not a drop.
		_hull.teleport_distance = GameConsts.MOVER_TELEPORT_DIST
		_hull.unit = GameConsts.SCALE_FACTOR
		_hull.ground_mask = GameConsts.MASK_WORLD_AND_CLIP | GameConsts.MASK_ENTITY
		_hull.mover_velocity = _published_mover_velocity
		_hull.unstuck.connect(func(at: Vector3, offset: Vector3) -> void:
			Log.info("[Player] unstuck %s at %.2f,%.2f,%.2f by %.1f mm" % [
					_owner.name, at.x, at.y, at.z, offset.length() * 1000.0]))
		_hull.pinned.connect(func(at: Vector3) -> void:
			Log.info("[Player] %s is pinned at %.2f,%.2f,%.2f and no offset frees it" % [
					_owner.name, at.x, at.y, at.z]))


static func _find_shape_child(node: Area3D) -> CollisionShape3D:
	if not node:
		return null
	for c in node.get_children():
		if c is CollisionShape3D:
			return c
	return null


func check_ladder() -> bool:
	if not _ladder_shape_node or not _ladder_shape_node.shape:
		return false
	_ladder_query.shape = _ladder_shape_node.shape
	_ladder_query.transform = _ladder_shape_node.global_transform
	var hits = _owner.get_world_3d().direct_space_state.intersect_shape(_ladder_query, 4)
	if hits.is_empty():
		# Clear so a stale normal can't leak to the next ladder. Inside-the-brush hits
		# keep the last good normal intentionally: func_ladder returns zero there.
		ladder_normal = Vector3.ZERO
		return false
	var ladder_node: Node = hits[0].collider.get_parent()
	if not ladder_node.has_method("get_ladder_normal"):
		return false
	var normal: Vector3 = ladder_node.get_ladder_normal(_owner.global_position)
	if normal.length_squared() > 0.001:
		ladder_normal = normal
	return true


func check_water() -> bool:
	if not _water_shape_node or not _water_shape_node.shape:
		return false
	_water_query.shape = _water_shape_node.shape
	_water_query.transform = _water_shape_node.global_transform
	return not _owner.get_world_3d().direct_space_state.intersect_shape(_water_query, 1).is_empty()


## Whether any part of the player is in lava. Contact, not submersion — GoldSrc burns you from
## waterlevel 1 (feet in), while the waist sphere check_water uses is its waterlevel 2, the
## threshold for swimming. Sharing that sphere made damage start at the waist instead, so no
## liquid shallower than 0.8 units could hurt anyone: ww_countryside's four skin -5 lava brushes
## are 28 units deep and had never burned a soul, and ww_golem's pads are exactly 0.8, tangent at
## best. The hull is the honest test, needs no magic offset, and tracks crouching for free
## because godot_body rewrites the capsule's height in place.
func check_lava() -> bool:
	return _hull_touches(_lava_query)


## Query with the player's capsule, falling back to the submersion sphere if a body somehow has
## no hull — better a waist-height test than none.
func _hull_touches(query: PhysicsShapeQueryParameters3D) -> bool:
	var node := _hull_shape_node if (_hull_shape_node and _hull_shape_node.shape) else _water_shape_node
	if not node or not node.shape:
		return false
	query.shape = node.shape
	query.transform = node.global_transform
	return not _owner.get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty()


func check_slime() -> bool:
	return _hull_touches(_slime_query)


## Host-only: tick periodic damage from lava/slime exposure.
## Caller is responsible for the authority check; this just runs the timer.
func tick_liquid_damage(delta: float) -> void:
	_liquid_dmg_timer -= delta
	if _liquid_dmg_timer > 0.0:
		return
	_liquid_dmg_timer = LIQUID_DMG_INTERVAL
	if check_lava():
		_owner.take_damage(LAVA_DMG_PER_TICK, GameConsts.DamageType.FIRE)
	elif check_slime():
		_owner.take_damage(SLIME_DMG_PER_TICK, GameConsts.DamageType.PHYSICAL)


## A networked mover's velocity, exact the instant a snapshot arrives, where its rendered
## transform lags by the interpolation delay.
static func _published_mover_velocity(mover: Node) -> Array:
	var pub := MoverNetPublisher.of(mover)
	return [pub.mover_net_vel, pub.mover_net_angvel] if pub != null else []


## How deep this hull is inside `mover`, per the last probe; 0.0 for a mover it never touched,
## -1.0 for no measurement at all (the caller holds its decision on that). A sample one frame
## old counts, because nothing orders a mover's _physics_process against the player's.
func mover_obstruction(mover: Object) -> float:
	return _hull.mover_obstruction(mover) if _hull else -1.0


## Yaw (radians) the mover underfoot rotated this frame, derived from the carry
## transform pair. A rider adds it to their view yaw to turn with the mover.
func get_carry_yaw_delta() -> float:
	return _hull.carry_yaw_delta if _hull else 0.0


## Pitch-directed 3D flight; jump ascends.
static func _flight_velocity(cfg, current_velocity: Vector3, cmd) -> Vector3:
	var cam_basis := Movement.camera_basis(cmd)
	var wish_vel: Vector3 = (-cam_basis.z) * (-cmd.move_input.y * FLIGHT_SPEED) \
			+ cam_basis.x * (cmd.move_input.x * FLIGHT_SPEED)
	if cmd.jump:
		wish_vel.y += FLIGHT_SPEED
	return LadderWater.drag_accelerate(current_velocity, wish_vel, float(cmd.delta), FLIGHT_DRAG,
			cfg.accelerate)


func get_modifiers(
		cfg,
		state: Movement.MovementState,
		weapons: Array,
		speed_multiplier: float,
		cmd) -> Movement.MovementModifiers:
	var mods := Movement.MovementModifiers.new()
	# Noclip flies through solids on purpose, so every environmental correction (unstick,
	# pusher, carry, ladder, water) must be suppressed or it'd eject/fight the free-fly move.
	if cmd.noclip:
		in_water = false
		return mods
	mods.speed_scale = speed_multiplier
	mods.gravity_scale = gravity_scale
	if _hull:
		# get_godot_body() rather than a handed-over reference: it is the adapter the owner's own
		# Simulation drives, and asking lazily sidesteps the construction order. Null on a machine
		# with no server-side simulation for this player, which has nothing to unstick.
		_hull.apply(mods, state, cmd,
				_owner.get_godot_body() if _owner.has_method("get_godot_body") else null)
	for w in weapons:
		w.contribute_modifiers(mods, cmd, state)
	in_water = check_water()
	_ladder_water.apply(mods, cfg, state, cmd, check_ladder(), ladder_normal, in_water,
			_owner.get_world_3d().direct_space_state)
	if in_water:
		# Pure water extinguishes burning; lava/slime don't (lava obviously, slime is acid).
		# Status mutation is server-authoritative — clients run get_modifiers for movement
		# prediction only. (Was previously a no-op on clients since _states is host-only,
		# but the explicit gate makes the boundary unambiguous.)
		if NetworkManager.is_authority() and not check_lava() and not check_slime():
			StatusSystem.clear_status(_owner, GameConsts.StatusType.BURNING)
	if cmd.custom_flags & GameConsts.CMF_FLYING:
		mods.velocity_override_active = true
		mods.override_velocity = _flight_velocity(cfg, state.velocity, cmd)
	StatusSystem.contribute_movement_modifiers(_owner, mods)
	# GoldSrc basevelocity: applied to position without altering the player's own state
	# velocity. Do NOT clear _push_base_vel here — it must survive every command in a
	# server batch; the caller clears it once per frame.
	var pbv = _owner.get("_push_base_vel")
	if pbv != null and (pbv as Vector3).length_squared() > 0.0:
		var full_push := pbv as Vector3
		# Y comes from body.velocity.y (set directly in trigger_push so it persists after
		# leaving the zone); only horizontal goes here to avoid double-applying Y.
		mods.base_velocity = Vector3(full_push.x, 0.0, full_push.z)
		mods.no_friction = true
	return mods
