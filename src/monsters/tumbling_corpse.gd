class_name TumblingCorpse
extends RigidBody3D

## What is left of something that stopped. `kind` picks the body's shape:
##  - PROP    a spent projectile: a ball, or a ragdoll if the payload carries a pose. A dead
##            beast is a PROP with its own linger/width/topple on the payload (spawn_monster).
##  - WIZARD  a dead player: a ragdoll (or box + death clip), in the `"corpses"` group.

enum Kind { PROP, WIZARD }

const LINGER := 2.0        # seconds on the ground before the fade starts (prop)
const FADE := 0.6          # matches RollingStone's fade-out
const RAGDOLL_PROP_LINGER := 5.0
const RAGDOLL_PROP_FADE := 1.0
const WIZARD_LINGER := 60.0
const WIZARD_FADE := 2.0
const MONSTER_LINGER := 30.0
const MONSTER_FADE := 2.0
## Shadow half-width when the payload names no `body_radius`.
const SHADOW_RADIUS := {Kind.PROP: 0.25, Kind.WIZARD: 0.4}
const WIZARD_TOPPLE_SPEED := 2.5  # rad/s a body pitches over at, across the direction it was hit
const BOUNCE_SPEED := 0.35 # fraction of the flight speed kept off a surface it bounced from
## Ball corpses start this far off the surface they hit; rigs use _push_bones_clear instead.
const STANDOFF := 0.2
const PUSH_PASSES := 4
const PUSH_SKIN := 0.01
## Sanity bar on one bone's total push; more than this means it was deep inside something.
const MAX_PUSH := 2.0
const TUMBLE_SPEED := 9.0  # rad/s about a random axis across the body
const RAGDOLL_TUMBLE_SPEED := 3.0  # ... and the same for a rigged one, which takes it per bone
const ANGULAR_DAMP := 2.0  # sheds the tumble as it settles, like a gib
## Fallback extent when the model is missing (nothing to measure).
const DEFAULT_AABB := AABB(Vector3(-0.15, -0.08, -0.15), Vector3(0.3, 0.16, 0.3))
## Only /spawn names no model.
const DEFAULT_MODEL := Skeleton.MODEL

## Centred on the body origin, since hop spins about it. Box, not capsule: a resting capsule
## spins from nothing (plans/rotating_gibs.md).
const WIZARD_EXTENTS := Vector3(0.3, 0.5, 0.3)
## GoldSrc player models are centred on the waist (RemotePlayer.get_model_offset).
const WIZARD_MODEL_Y := 0.4
const WIZARD_GIB_EXTENT := Vector3(0.6, 1.2, 0.6)
const WIZARD_GIB_COUNT := 8
const DEATH_ANIMS := ["die_simple", "die_backwards1", "die_backwards", "die_forwards", "die_spin", "gutshot"]
const DEATH_SOUNDS := ["player/death1.wav", "player/death2.wav", "player/death3.wav", "player/death4.wav"]

## Landing sounds by model; unlisted models fall silently.
const IMPACT_SOUNDS := {
	"models/flyingskull.mdl": ["debris/bone_clink1.wav", "debris/bone_clink2.wav",
		"debris/bone_clink3.wav"],
	"models/npc/bird.mdl": ["debris/flesh_flop1.wav", "debris/flesh_flop2.wav"],
	Skeleton.MODEL: ["debris/bone_clink1.wav", "debris/bone_clink2.wav",
		"debris/bone_clink3.wav"],
}
const IMPACT_MIN_SPEED := 2.0    # below this a corpse is settling, not landing
const IMPACT_FULL_SPEED := 8.0   # ... and at this it is as loud as it gets
const IMPACT_FLOOR := 0.3        # quietest an impact plays, as a fraction of full volume
const IMPACT_VOLUME := 2.0       # ... and how much louder than the clip's own level full is
const IMPACT_COOLDOWN := 0.12    # one knock per this long, or a tumble reads as a rattle

## Splash size (LiquidSounds: 1.0 = a person) when the payload names no width...
const SPLASH_SIZE := {Kind.PROP: 0.35, Kind.WIZARD: 1.0}
## ...and per metre of width when it does (a person: 0.4 m -> 1.0).
const SPLASH_PER_RADIUS := 2.5

## Bake once every bone sleeps, or once the busiest bone travels less than SETTLE_DISTANCE in a
## SETTLE_WINDOW — dangling limbs never sleep, and a fixed reference point never stops creeping.
const SETTLE_WINDOW := 0.5
const SETTLE_DISTANCE := 0.10
## Hard cap on simulation, also capped by the corpse's linger (_sim_deadline).
const MAX_SIM_TIME := 8.0
## Client drift from the host's pelvis before correcting. Must clear the ~5cm of vec3_half
## dither in net_pos, or the noise alone keeps kicking the rig.
const CORRECTION_THRESHOLD := 0.25
## Fraction of the gap closed per tick, so a correction reads as settling, not a snap.
const CORRECTION_SLEW := 0.25
## Once started, a correction runs down to here; stopping at the deadband left the rig
## twitching forever and never asleep.
const CORRECTION_SETTLE := 0.10

## Jitter slack on the host's bake age (_accept_bake).
const BAKE_SLACK := 0.25

## Older than this on arrival, a corpse arrives as a body rather than as a death.
const LATE_AGE := 0.5

## Host clock at this corpse's tick 0, so a client can map its own sim age to the interp
## buffer's stamp. Constant on purpose: a per-tick age would come apart from the pelvis
## whenever NetInterpBridge skips a publish, and a constant slot is sent once.
var net_epoch := 0

var _entity := EntityBehavior.new()
var _model: Node3D
var _anim_player: AnimationPlayer
var _sim: PhysicalBoneSimulator3D
var _bones: Array[PhysicalBone3D] = []
var _root_bone: PhysicalBone3D
var _sim_time := 0.0
var _sim_started := false
var _correcting := false
## A client too far behind the host's bake to take it settles itself (_accept_bake).
var _settle_alone := false
## How old the corpse was when this peer built it. Always 0 on the host.
var _age := 0.0
var _sim_deadline := MAX_SIM_TIME
var _still_time := 0.0
var _still_from: Array[Vector3] = []
var _baked := false
var _model_path := ""
## No model on the payload (only /spawn): rig off the model's rest pose.
var _rig_from_rest := false
var _model_yaw := 0.0
var _pose := PackedFloat32Array()
var _kind := Kind.PROP
var _body_radius := 0.0
## Zero means take the kind's default (see _linger).
var _linger_override := 0.0
var _fade_override := 0.0
var _topple := false
var _launch_velocity := Vector3.ZERO
## Nonzero stands the rig's head along this direction and launches it without spin.
var _head_dir := Vector3.ZERO
## Sounded in place of the death scream when the payload names one.
var _sound := ""
## The surface the corpse stopped against, or zero.
var _surface_normal := Vector3.ZERO
var _impact_sounds: Array = []
var _impact_at := -1.0
var _was_touching := false
var _bone_velocity: PackedVector3Array
var _entry := LiquidEntry.new()
## Seeded off the payload so every peer rolls the same death (plans/one_corpse_ragdoll.md).
var _rng := RandomNumberGenerator.new()


func setup(data: Dictionary, is_host := true) -> void:
	position = data.get("position", Vector3.ZERO)
	_launch_velocity = data.get("velocity", Vector3.ZERO)
	_head_dir = data.get("head_dir", Vector3.ZERO)
	_sound = data.get("sound", "")
	_surface_normal = data.get("normal", Vector3.ZERO)
	_model_path = data.get("model", DEFAULT_MODEL)
	_rig_from_rest = not data.has("model")
	_impact_sounds = IMPACT_SOUNDS.get(_model_path, [])
	_model_yaw = data.get("model_yaw", 0.0)
	_kind = data.get("kind", Kind.PROP)
	_linger_override = data.get("linger", 0.0)
	_fade_override = data.get("fade", 0.0)
	_topple = data.get("topple", _kind == Kind.WIZARD)
	_body_radius = data.get("body_radius", 0.0)
	if _body_radius <= 0.0:
		_body_radius = SHADOW_RADIUS[_kind]
		_entry.size = SPLASH_SIZE[_kind]
	else:
		_entry.size = SPLASH_PER_RADIUS * _body_radius
	_pose = data.get("pose", PackedFloat32Array())
	_rng.seed = int(data.get("seed", 0))
	if not is_host and data.has("born_ms") and NetworkManager.is_clock_synced():
		_age = maxf(0.0, NetworkManager.get_estimated_server_time()
			- float(data["born_ms"]) / 1000.0)
	_entity.initialize(self, is_host)


func _ready() -> void:
	# On MASK_CORPSE so descending platforms find it (EntityBase._wake_touching_props). Clients
	# freeze and drop the layer; the authority's transform drives them.
	collision_layer = GameConsts.MASK_CORPSE
	collision_mask = GameConsts.MASK_WORLD
	angular_damp = ANGULAR_DAMP
	continuous_cd = true
	if not _entity.is_host:
		freeze = true
		collision_layer = 0

	set_physics_process(false)  # only a ragdoll ticks; everything else is pure physics
	if _kind == Kind.WIZARD:
		_build_wizard()
	else:
		_build_prop()

	add_to_group("pushable")

	add_child(BlobShadow.new(_body_radius))

	# The strike that made the corpse happened to the projectile, so sound it here, on every
	# peer, from the speed it kept off the surface.
	if _age < LATE_AGE and not _impact_sounds.is_empty() \
			and _surface_normal.length_squared() > 0.001:
		_play_impact(_launch_velocity.length() / BOUNCE_SPEED)

	if _entity.is_host and _sim == null:
		linear_velocity = _launch_velocity
		angular_velocity = _initial_spin()

	# A late corpse gets the life the host's has left, picking the fade up where it is.
	var linger := maxf(0.0, _linger() - _age)
	var fade := clampf(_linger() + _fade() - _age, 0.0, _fade())
	var tween := create_tween()
	if linger > 0.0:
		tween.tween_interval(linger)
	if fade > 0.0:
		tween.tween_method(func(alpha: float) -> void:
			if _model:
				AssetLoader.set_model_alpha(_model, alpha)
		, fade / _fade(), 0.0, fade)
	tween.tween_callback(_entity.destroy)


## A toppling body pitches over along the blow; anything else tumbles about a random axis.
func _initial_spin() -> Vector3:
	if _head_dir != Vector3.ZERO:
		return Vector3.ZERO
	if not _topple:
		var spin: float = RAGDOLL_TUMBLE_SPEED if _sim else TUMBLE_SPEED
		return Vector3(_rng.randf() - 0.5, _rng.randf() - 0.5, _rng.randf() - 0.5) \
			.normalized() * spin
	var horizontal := Vector3(_launch_velocity.x, 0.0, _launch_velocity.z)
	if horizontal.length_squared() < 0.01:
		return Vector3.ZERO
	return Vector3.UP.cross(horizontal.normalized()) * WIZARD_TOPPLE_SPEED


## Also the simulation budget (_sim_deadline caps against it), so a long faller needs a long linger.
func _linger() -> float:
	if _linger_override > 0.0:
		return _linger_override
	if _kind == Kind.WIZARD:
		return WIZARD_LINGER
	return RAGDOLL_PROP_LINGER if _sim else LINGER


func _fade() -> float:
	if _fade_override > 0.0:
		return _fade_override
	if _kind == Kind.WIZARD:
		return WIZARD_FADE
	return RAGDOLL_PROP_FADE if _sim else FADE


## A posed prop is rigged; anything else is a ball.
func _build_prop() -> void:
	_model = AssetLoader.load_model(_model_path) if not _model_path.is_empty() else null
	# Captured before the model enters the tree, so no autoplaying clip has moved it off rest.
	if _model and _pose.is_empty() and _rig_from_rest:
		_pose = RagdollBuilder.capture_pose(RagdollBuilder.find_skeleton(_model))
	if _model and not _pose.is_empty() and RagdollBuilder.enabled():
		var anim_player: AnimationPlayer = _model.find_child("AnimationPlayer")
		if anim_player:
			anim_player.stop()  # or an autoplaying clip overwrites the pose we just set
		# A pose that doesn't fit is a peer with a different model: fall back to the ball.
		if RagdollBuilder.apply_pose(RagdollBuilder.find_skeleton(_model), _pose):
			_sim = RagdollBuilder.build(_model, GameConsts.MASK_CORPSE, GameConsts.MASK_WORLD)
	if _sim:
		# After the builder: stripping frees the BoneAttachment3D the bone index lives on.
		AssetLoader.strip_hitboxes(_model)
		_strip_collision(_model)
		add_child(_model)
		_start_ragdoll()
		return
	_build_prop_ball()


## The model frozen mid-frame inside a ball as tall as it is; a hull tracing wings would snag.
func _build_prop_ball() -> void:
	if _surface_normal.length_squared() > 0.001:
		position += _surface_normal * STANDOFF

	if _entity.is_host and not _impact_sounds.is_empty():
		contact_monitor = true
		max_contacts_reported = 1

	var physics_material := PhysicsMaterial.new()
	physics_material.bounce = 0.2
	physics_material.friction = 1.5
	physics_material_override = physics_material

	var aabb := DEFAULT_AABB
	if _model:
		_model.rotation.y = _model_yaw  # the same nose-forward correction the projectile made
		AssetLoader.strip_hitboxes(_model)
		aabb = _visual_aabb(_model, _model.transform)
		if aabb.size.y <= 0.0:
			aabb = DEFAULT_AABB
		# Sit the model's own centre on the body origin, which is what the tumble spins about.
		_model.position.y -= aabb.get_center().y
		add_child(_model)
		var anim_player: AnimationPlayer = _model.find_child("AnimationPlayer")
		if anim_player:
			anim_player.stop()

	var radius := aabb.size.y * 0.5
	var col := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = radius
	col.shape = sphere
	add_child(col)
	# Set after the shape, or Godot derives the tensor from the collision AABB — a box, not a ball.
	inertia = Vector3.ONE * (0.4 * mass * radius * radius)


## A dead player: a ragdoll off the MDL hitboxes, or with `/ragdolls off` a box and a death clip.
func _build_wizard() -> void:
	add_to_group("corpses")
	_model = AssetLoader.load_model(_model_path) if not _model_path.is_empty() else null
	# Pose before building: bodies are placed from the pose, and joint limits centre on it.
	if _model and not _pose.is_empty():
		var anim_player: AnimationPlayer = _model.find_child("AnimationPlayer")
		if anim_player:
			anim_player.stop()  # or an autoplaying clip overwrites the pose we just set
		RagdollBuilder.apply_pose(RagdollBuilder.find_skeleton(_model), _pose)
	if _model and RagdollBuilder.enabled():
		_sim = RagdollBuilder.build(_model, GameConsts.MASK_CORPSE, GameConsts.MASK_WORLD)
	if _model:
		# After the builder: stripping frees the BoneAttachment3D the bone index lives on.
		AssetLoader.strip_hitboxes(_model)
		_strip_collision(_model)
		add_child(_model)

	# Roll regardless, to stay in step with the host's rng.
	var scream: String = DEATH_SOUNDS[_rng.randi() % DEATH_SOUNDS.size()]
	if _age < LATE_AGE:
		SoundSystem.spawn_on(self, scream if _sound.is_empty() else _sound, false, 30.0)

	if _sim:
		_start_ragdoll()
	else:
		_build_posed_wizard()


## The bones are the body; this node just mirrors the pelvis as the network reference.
func _start_ragdoll() -> void:
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC  # we write its transform every frame
	freeze = true
	collision_layer = 0
	_model.top_level = true
	var model_y: float = WIZARD_MODEL_Y if _kind == Kind.WIZARD else 0.0
	var facing := Basis(Vector3.UP, _model_yaw)
	if _head_dir != Vector3.ZERO:
		facing = Basis(Quaternion(Vector3.UP, _head_dir.normalized())) * facing
	_model.global_transform = Transform3D(facing, global_position + facing * Vector3(0.0, model_y, 0.0))

	for child in _sim.get_children():
		var bone := child as PhysicalBone3D
		if bone == null:
			continue
		_bones.append(bone)
		if bone.collision_layer != 0:
			_root_bone = bone
	if _root_bone == null and not _bones.is_empty():
		_root_bone = _bones[0]
	set_physics_process(true)  # the throw waits for the first tick — see _begin_simulation


## Shove this corpse; a baked one refuses. On the host the shove replicates as an event.
func push(velocity: Vector3) -> bool:
	if _baked:
		return false
	if _bones.is_empty():
		# One body; a client's copy is frozen and rides the transform stream.
		if not _entity.is_host:
			return false
		linear_velocity = velocity
		return true
	_throw(velocity)
	if _entity.is_host:
		_entity.publish({"toss": velocity})
	return true


func _throw(velocity: Vector3) -> void:
	for bone in _bones:
		bone.linear_velocity = velocity
	# Or _hear_bone_impacts hears the throw as a landing.
	_bone_velocity.resize(_bones.size())
	_bone_velocity.fill(velocity)
	# A thrown corpse gets a fresh settle budget, still capped by its linger.
	_still_time = 0.0
	_mark_bone_positions()
	_sim_deadline = minf(_sim_time + MAX_SIM_TIME, _linger())


## Run on the first tick, not in _ready, so host and client count the same physics steps.
func _begin_simulation() -> void:
	_sim.physical_bones_start_simulation()
	_push_bones_clear()
	var spin := _initial_spin()
	for bone in _bones:
		bone.angular_velocity = spin
	_throw(_launch_velocity)


## Walk each bone that starts inside the world back out, before the joints can drag on it.
## hop's own ejection moves a body at most its box size per tick (hull_push_out). Pushes go back
## toward the corpse, not the shortest way out, and a step that doesn't come out shallower is
## undone.
func _push_bones_clear() -> void:
	var space := get_world_3d().direct_space_state
	if space == null:
		return
	var query := PhysicsShapeQueryParameters3D.new()
	query.margin = PUSH_SKIN
	for bone in _bones:
		var walked := 0.0
		var escape := bone_overlap(space, query, bone)
		if escape == Vector3.INF:
			continue  # no shape to measure with
		for _pass in PUSH_PASSES:
			var toward := global_position - bone.global_position
			if escape.dot(toward) < 0.0:
				escape = -escape  # back the way it came, not the shortest way out
			var depth := escape.length()
			if depth < 0.001 or walked + depth > MAX_PUSH:
				break
			var before := bone.global_position
			bone.global_position += escape
			var after := bone_overlap(space, query, bone)
			if after.length() >= depth:
				bone.global_position = before
				break
			walked += depth
			escape = after


## The vector that clears one bone out of the world, or Vector3.INF for a bone with no shape.
func bone_overlap(space: PhysicsDirectSpaceState3D, query: PhysicsShapeQueryParameters3D,
		bone: PhysicalBone3D) -> Vector3:
	var shape := bone.get_child(0) as CollisionShape3D if bone.get_child_count() else null
	if shape == null or shape.shape == null:
		return Vector3.INF
	query.shape = shape.shape
	query.collision_mask = bone.collision_mask  # whatever the builder gave the rig
	query.transform = bone.global_transform * shape.transform
	return _deepest_overlap(space, query)


func _deepest_overlap(space: PhysicsDirectSpaceState3D,
		query: PhysicsShapeQueryParameters3D) -> Vector3:
	var contacts := space.collide_shape(query, 4)  # colliders to weigh, not passes
	var best := Vector3.ZERO
	for i in range(0, contacts.size() - 1, 2):
		var step: Vector3 = contacts[i + 1] - contacts[i]
		if step.length_squared() > best.length_squared():
			best = step
	return best


func _build_posed_wizard() -> void:
	var physics_material := PhysicsMaterial.new()
	physics_material.friction = 2.0
	physics_material_override = physics_material

	if _model:
		_model.position.y = WIZARD_MODEL_Y
		_model.rotation.y = _model_yaw
		_anim_player = _model.find_child("AnimationPlayer")
		_entity.set_anim_player(_anim_player)

	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = WIZARD_EXTENTS * 2.0
	col.shape = box
	add_child(col)

	if _anim_player:
		var valid_anims: Array[String] = []
		for anim_name in DEATH_ANIMS:
			if _anim_player.has_animation(anim_name):
				valid_anims.append(anim_name)
		if not valid_anims.is_empty():
			var chosen: String = valid_anims[_rng.randi() % valid_anims.size()]
			var anim := _anim_player.get_animation(chosen)
			anim.loop_mode = Animation.LOOP_NONE
			_anim_player.play(chosen)


func _physics_process(delta: float) -> void:
	if _baked or _root_bone == null:
		return
	if not _sim_started:
		_sim_started = true
		_begin_simulation()
		return
	if _entity.is_host:
		# Before _sim_time advances, so the pelvis and epoch describe the same tick.
		global_position = _root_bone.global_position
		global_rotation = _root_bone.global_rotation
		if net_epoch == 0:
			net_epoch = Time.get_ticks_msec()  # this tick is age 0 — see net_epoch
	else:
		_correct_to_authority()
	if not _impact_sounds.is_empty():
		_hear_bone_impacts()
	# Local on every peer: each simulates the ragdoll, so a broadcast would splash twice.
	_entry.check(self, global_position, _root_bone.linear_velocity.length(), _rng)
	_sim_time += delta
	# Settling is the host's call; a client baking early would be stuck in the wrong place.
	if _entity.is_host or _settle_alone:
		if _all_bones_asleep():
			_bake()
			return
		_still_time += delta
		if _still_time >= SETTLE_WINDOW:
			var moved := _travel_since_mark()
			_still_time = 0.0
			_mark_bone_positions()
			if moved < SETTLE_DISTANCE:
				_bake()
				return
	# A cost cap, on every peer, for a client that never hears the host's bake.
	if _sim_time >= _sim_deadline:
		_bake()


## Ball/box landings and liquid entry, host only; a client's copy is frozen, so these broadcast.
func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if not _entity.is_host:
		return
	if _sim == null:
		_entry.check(self, state.transform.origin, state.get_linear_velocity().length(), _rng, true)
	if _impact_sounds.is_empty():
		return
	var touching := state.get_contact_count() > 0
	if touching and not _was_touching:
		_play_impact(state.get_linear_velocity().length(), true)
	_was_touching = touching


## A ragdoll has no contact monitor, so a landing is a bone's velocity jumping in one tick.
func _hear_bone_impacts() -> void:
	var jolt := 0.0
	for i in _bones.size():
		var v := _bones[i].linear_velocity
		jolt = maxf(jolt, v.distance_to(_bone_velocity[i]))
		_bone_velocity[i] = v
	_play_impact(jolt)


## `broadcast` only for knocks the host alone sees (ball contacts); the rest happen on every peer.
func _play_impact(speed: float, broadcast := false) -> void:
	if speed < IMPACT_MIN_SPEED:
		return
	var now := Time.get_ticks_msec() * 0.001
	if now - _impact_at < IMPACT_COOLDOWN:
		return
	_impact_at = now
	var path: String = _impact_sounds[_rng.randi() % _impact_sounds.size()]
	var volume := linear_to_db(IMPACT_VOLUME * clampf(speed / IMPACT_FULL_SPEED, IMPACT_FLOOR, 1.0))
	var pitch := _rng.randf_range(0.92, 1.08)
	if broadcast:
		SoundSystem.play_3d(path, global_position, pitch, volume)
	else:
		SoundSystem.play_3d_local(path, global_position, pitch, volume)


func _all_bones_asleep() -> bool:
	for b in _bones:
		if not PhysicsServer3D.body_get_state(b.get_rid(), PhysicsServer3D.BODY_STATE_SLEEPING):
			return false
	return not _bones.is_empty()


func _mark_bone_positions() -> void:
	_still_from.resize(_bones.size())
	for i in _bones.size():
		_still_from[i] = _bones[i].global_position


func _travel_since_mark() -> float:
	var worst := 0.0
	for i in mini(_bones.size(), _still_from.size()):
		worst = maxf(worst, _bones[i].global_position.distance_to(_still_from[i]))
	return worst


## A client runs its own ragdoll from the replicated seed, and corrects only gross drift.
## Compared against the host's pelvis at the client's own sim AGE, not against
## global_position — that is interpolated INTERP_DELAY behind and reads time skew as distance.
func _correct_to_authority() -> void:
	if net_epoch == 0:
		return  # the host's tick 0 has not reached us yet; nothing to compare against
	var sample := NetworkManager.sample_entity_at(
		int(get_instance_id()), net_epoch / 1000.0 + _sim_time)
	if not sample.get("valid", false):
		return
	var delta: Vector3 = (sample["position"] as Vector3) - _root_bone.global_position
	var gap := delta.length()
	if _correcting:
		if gap < CORRECTION_SETTLE:
			_correcting = false  # arrived; let the bones sleep and the corpse bake
			return
	elif gap < CORRECTION_THRESHOLD:
		return
	else:
		_correcting = true
	# Every bone by the same offset: the only correction a jointed chain doesn't fight.
	var step := delta * CORRECTION_SLEW
	for bone in _bones:
		bone.global_position += step


## Stop simulating and keep the pose; frozen rigs are far cheaper than simulated ones. Rendering
## only — a client bakes where its own rig stopped, since gameplay reads only the pelvis.
func _bake() -> void:
	if _baked:
		return
	_baked = true
	if _entity.is_host:
		_entity.publish({"bake": true, "age": _sim_time})
	if _sim == null:
		return  # nothing was simulating: a ball corpse, or a client running `/ragdolls off`
	var skeleton := _sim.get_parent() as Skeleton3D
	if skeleton:
		# Read the pose off the bodies: the simulator's output isn't in the skeleton's own pose.
		# A bone with no body rides its parent on its local pose.
		var to_skeleton := skeleton.global_transform.affine_inverse()
		var bodies := {}
		var root_idx := -1
		for bone in _bones:
			var idx := skeleton.find_bone(bone.bone_name)
			if idx >= 0:
				bodies[idx] = bone
				if bone == _root_bone:
					root_idx = idx
		var poses: Array[Transform3D] = []
		poses.resize(skeleton.get_bone_count())
		for i in skeleton.get_bone_count():
			var body: PhysicalBone3D = bodies.get(i)
			var parent := skeleton.get_bone_parent(i)
			if body:
				poses[i] = to_skeleton * (body.global_transform * body.body_offset.affine_inverse())
			elif parent < 0:
				poses[i] = skeleton.get_bone_global_pose(i)
			else:
				poses[i] = poses[parent] * skeleton.get_bone_pose(i)
		_sim.physical_bones_stop_simulation()
		# Rotations only, plus the root's position: writing body positions froze any joint that
		# was open at the bake into a stretched limb.
		for i in skeleton.get_bone_count():
			if not bodies.has(i):
				continue
			var parent := skeleton.get_bone_parent(i)
			var local: Transform3D = poses[i] if parent < 0 else poses[parent].affine_inverse() * poses[i]
			skeleton.set_bone_pose_rotation(i, local.basis.get_rotation_quaternion())
			if i == root_idx:
				skeleton.set_bone_pose_position(i, local.origin)
	else:
		_sim.physical_bones_stop_simulation()
	_sim.queue_free()
	_sim = null
	_bones.clear()
	_root_bone = null
	set_physics_process(false)


## The host's one-shot events: a shove, and the bake.
func _apply_sync_state(state: Dictionary) -> void:
	if state.has("toss"):
		push(state["toss"])
	if state.get("bake", false):
		_accept_bake(float(state.get("age", 0.0)))


## A client behind the host's bake age would freeze mid-fall, so it settles on its own instead.
func _accept_bake(host_age: float) -> void:
	if _bones.is_empty() or _sim_time + BAKE_SLACK >= host_age:
		_bake()
		return
	_settle_alone = true


## Union of the model's mesh boxes, in the model's own frame.
static func _visual_aabb(node: Node, xform: Transform3D, out := AABB()) -> AABB:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh:
		var box := xform * (node as MeshInstance3D).mesh.get_aabb()
		out = box if out.size == Vector3.ZERO else out.merge(box)
	for child in node.get_children():
		if child is Node3D:
			out = _visual_aabb(child, xform * (child as Node3D).transform, out)
	return out


## MDL-baked solid bodies; the corpse carries its own hull.
static func _strip_collision(node: Node) -> void:
	for child in node.get_children():
		if child is StaticBody3D:
			child.queue_free()
		else:
			_strip_collision(child)


## Host-only. A `pose` (RagdollBuilder.capture_pose) asks for a ragdoll rather than a ball.
## `overrides` is merged over the payload (linger, fade, body_radius, topple).
static func spawn(model_path: String, pos: Vector3, velocity: Vector3, model_yaw := 0.0,
		pose := PackedFloat32Array(), normal := Vector3.ZERO, overrides := {}) -> void:
	var payload := {
		"script_path": "res://src/monsters/tumbling_corpse.gd",
		"position": pos,
		"velocity": velocity,
		"model": model_path,
		"model_yaw": model_yaw,
		"kind": Kind.PROP,
		"pose": pose,
		"normal": normal,
		"seed": randi(),
		"sync_state": true,  # shoves and the bake arrive as events (_apply_sync_state)
	}
	payload.merge(overrides, true)
	NetworkManager.spawn_dynamic_entity(payload)


## A dead beast, drawn from the live one's model origin and pose so nothing moves in the handover.
static func spawn_monster(model_path: String, origin: Vector3, velocity: Vector3,
		model_yaw: float, pose: PackedFloat32Array, body_radius: float) -> void:
	spawn(model_path, origin, velocity, model_yaw, pose, Vector3.ZERO, {
		"linger": MONSTER_LINGER,
		"fade": MONSTER_FADE,
		"topple": true,
		"body_radius": body_radius,
	})


## A corpse bounced off `normal`, keeping BOUNCE_SPEED of its flight speed.
static func spawn_deflected(model_path: String, pos: Vector3, direction: Vector3, speed: float,
		normal: Vector3, model_yaw := 0.0, pose := PackedFloat32Array()) -> void:
	var bounce := direction.bounce(normal) if normal.length_squared() > 0.001 else -direction
	spawn(model_path, pos, bounce * speed * BOUNCE_SPEED, model_yaw, pose, normal)


## `pos` is the player's feet; the corpse origin is half a hull above. An empty `pose` starts
## the ragdoll from the model's rest pose.
static func wizard_payload(pos: Vector3, yaw: float, element: int, velocity: Vector3,
		pose := PackedFloat32Array()) -> Dictionary:
	var element_name: String = GameConsts.ELEMENT_NAMES.get(element, "fire")
	return {
		"script_path": "res://src/monsters/tumbling_corpse.gd",
		"position": pos + Vector3(0.0, WIZARD_EXTENTS.y, 0.0),
		"velocity": velocity,
		"model": "models/player/%s.mdl" % element_name,
		"model_yaw": yaw,
		"kind": Kind.WIZARD,
		"pose": pose,
		"seed": randi(),
		"sync_state": true,  # see spawn()
	}


## A body, or gibs if `damage` is over GameConsts.GIB_DAMAGE. Online the host spawns the corpse
## through the dynamic-entity spawner; offline it is built here.
static func spawn_wizard_remains(scene_root: Node, pos: Vector3, yaw: float, elem: int,
		vel := Vector3.ZERO, pose := PackedFloat32Array(), damage := 0.0) -> void:
	if GameConsts.damage_gibs(damage):
		# GibEffect.burst picks broadcast or local itself.
		GibEffect.burst(pos + GameConsts.PLAYER_CENTER, GibEffect.MAT_FLESH, WIZARD_GIB_EXTENT,
			WIZARD_GIB_COUNT, GibEffect.FLESH_BURST_SOUND, scene_root)
		return
	var payload := wizard_payload(pos, yaw, elem, vel, pose)
	if not NetworkManager.is_online():
		if scene_root == null:
			return
		var corpse := TumblingCorpse.new()
		corpse.setup(payload, true)
		scene_root.add_child(corpse)
		return
	if not NetworkManager.is_authority():
		return
	NetworkManager.spawn_dynamic_entity(payload)


func net_sync_properties() -> PackedStringArray:
	return PackedStringArray(["NetInterp:net_anim", ".:net_epoch"])
