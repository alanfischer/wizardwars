class_name Sheep
extends CharacterBody3D

## monster_sheep — the livestock grazing on ww_countryside, ww_feudal and ww_pushed.
##
## It hunts nothing and nothing hunts it: CSheep::IRelationship answered R_NM for everything it
## was ever asked about, so a sheep is scenery that happens to carry 50 HP. What it does is trot
## a little way, put its head down, eat, lift its head and trot somewhere else — the four clips
## sheep.mdl ships, cycled the way CSheep::MonsterThink cycled them, with a one-in-four chance of
## a baa every time a clip comes round.
##
## Every map that has sheep places a ww_monstermaker rather than the animal, so the flock is
## however many the maker keeps alive: four on ww_countryside, four on ww_pushed, ten on ww_feudal.

const SCALE := GameConsts.SCALE_FACTOR
const MAX_HEALTH := 50.0                # pev->health
const RADIUS := 12.0 * SCALE            # the original's hull: 24 units across...
const HEIGHT := 30.0 * SCALE            # ...and 30 tall (mins -6, maxs 24)
## trot's own ground speed, taken off the clip: 40.6 units of root motion over 39 frames at 40fps.
const WALK_SPEED := 42.0 * SCALE
## pev->yaw_speed 90, which ChangeYaw spends as 90 degrees per 0.1s think — fast enough that
## nobody sees it turn, but not the single-frame snap that reads as teleporting.
const TURN_RATE := deg_to_rad(900.0)
const WANDER_RADIUS := 50.0 * SCALE     # RANDOM_FLOAT(-50,50) on each axis, off wherever it stands
const ARRIVE_DIST := RADIUS             # close enough to call the goal reached
const GRAZE_CHANCE := 0.25              # RANDOM_LONG(0,3)==1 to put the head down, and to lift it
const BAA_CHANCE := 0.25                # ...and the same roll again for the baa
const BAA_VOLUME := 0.6                 # EMIT_SOUND volume
const STEP_HEIGHT := 18.0 * SCALE       # GoldSrc monster step
const GRAVITY := 20.0                   # 800 sv_units, as MovementConfig.gravity
## PM_Friction and PM_Accelerate, which a sheep walks on rather than on an outright velocity
## assignment — so a shove it is carrying (a forceblast, a blast wave, a trigger_push) bleeds off
## instead of being swallowed whole on the next tick.
##
## The stop speed is the one number that cannot be sv_stopspeed's 100 units: that is more than
## twice this animal's whole walk, so the floor it puts under friction zeroes a trot before it
## gets going. Half the sheep's own pace is the same bargain for a sheep that 100 units is for a
## player, and leaves it trotting within a few percent of its clip.
const FRICTION := 4.0
const ACCELERATE := 10.0
const STOP_SPEED := WALK_SPEED * 0.5
const MODEL := "models/npc/sheep.mdl"
const BAA_SOUND := "monster/sheep/baa.wav"

const CLIP_TROT := "trot"
const CLIP_DOWN := "down"   # head to the grass
const CLIP_EAT := "eat"
const CLIP_UP := "up"       # ...and back out of it
const CLIP_DEAD := "idle"   # the pose Killed() leaves it in, and the only place idle is used
## SUB_StartFadeOut: 255 of alpha at 7 a tenth of a second.
const DEATH_FADE := 3.6
const DEATH_RISE := 25.0 * SCALE        # RANDOM_LONG(20,30), added to velocity.z once and kept

## sheep.mdl's own hitbox is a flat slab on a bone that covers almost none of the animal. One box
## the shape a sheep is — half again as long as it is tall, and longer still than it is wide —
## is what makes it something you can actually shoot — and what lets the rig sleep.
const HITBOX_SIZE := Vector3(0.55, 0.7, 1.25)
const HITBOX_CENTER := Vector3(0.0, 0.42, -0.13)

var team: int = GameConsts.Team.NONE
var is_dead: bool:
	get: return _health.is_dead
var health: float:
	get: return _health.health
var max_health: float:
	get: return _health.max_health

var _entity := EntityBehavior.new()
var _health := HealthBehavior.new()
## sheep.mdl's own loop flags are right — trot and eat go round, the rest are one-shots — so the
## rig takes the model's word for it rather than naming clips of its own.
var _rig := ModelRig.new()
var _model: Node3D
var _goal := Vector3.ZERO


func setup(data: Dictionary, is_host := true) -> void:
	team = data.get("team", GameConsts.Team.NONE)
	position = data.get("position", Vector3.ZERO)
	if data.has("yaw"):
		rotation.y = data["yaw"]
	_entity.initialize(self, is_host)
	_health.initialize(self, MAX_HEALTH, is_host, _die)


## A ww_monstermaker has no spell in front of it to warm the model, so a sheep asks on its own
## way in — the same reason Skeleton.precache() exists.
static func precache() -> void:
	AssetLoader.precache_model(MODEL)
	SoundSystem.precache(BAA_SOUND)


func _ready() -> void:
	precache()
	# No yaw correction: the imported scene already carries the turn from the MDL's authoring
	# axis onto -Z, so the sheep faces the node's own forward and the aim below is a plain look-at.
	_model = AssetLoader.load_model(MODEL)
	_rig.initialize(self, _model.find_child("AnimationPlayer") if _model else null)
	if _model:
		AssetLoader.strip_hitboxes(_model)  # replaced by the one box below
		add_child(_model)
		add_child(BlobShadow.new(RADIUS))
		_entity.set_anim_player(_rig.anim_player)  # publishes the played clip via NetInterp:net_anim
	_rig.play(CLIP_TROT)

	# Solid on both peers so a client's predicted player walks into it too; only the authority
	# moves it, so only the authority needs a world mask (mirrors Skeleton).
	var col := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = RADIUS
	cyl.height = HEIGHT
	col.shape = cyl
	col.position.y = HEIGHT * 0.5
	add_child(col)
	collision_layer = GameConsts.MASK_ENTITY
	collision_mask = (GameConsts.MASK_WORLD | GameConsts.MASK_CLIP) if _entity.is_host else 0
	floor_snap_length = STEP_HEIGHT

	# Killable by anything aimed at it, and a target for nothing: see Combat.find_homing_target,
	# which is where R_NM lives now.
	add_to_group("unhunted")
	_rig.add_hitbox(HITBOX_SIZE, HITBOX_CENTER)
	# Presentation and nothing else: the hull and the hitbox above are the sheep's own, and
	# ww_feudal keeps ten of these in one field. See [ModelRig].
	_rig.sleep_offscreen(AABB(HITBOX_CENTER - HITBOX_SIZE * 0.5, HITBOX_SIZE))
	_pick_goal()


func _physics_process(delta: float) -> void:
	_health.tick(delta)
	_rig.tick(delta)
	if not _entity.is_host:
		return

	if _rig.clip_cycled():
		_next_clip()
	# Only the trot moves it. A sheep with its head in the grass stands where it is.
	var horizontal := _walk(delta) if _rig.clip == CLIP_TROT else Vector3.ZERO

	# Upward motion survives the ground clamp, or a shove with any lift in it is gone before the
	# sheep has left the floor it is standing on.
	if is_on_floor() and velocity.y <= 0.0:
		velocity.y = 0.0
	elif not is_on_floor():
		velocity.y = maxf(velocity.y - GRAVITY * delta, -GRAVITY)
	_accelerate(horizontal, delta)
	var motion := Vector3(velocity.x, 0.0, velocity.z)
	if motion != Vector3.ZERO:
		SpatialQuery.step_up(self, motion * delta, STEP_HEIGHT)
	move_and_slide()


## Friction on whatever the sheep is carrying, then acceleration toward its own trot — GoldSrc's
## two ground rules, which between them let a shove move it and then wear off. `velocity` is the
## source of truth between ticks, so an external write is still in it when this runs.
##
## Off the floor it keeps what threw it: a sheep has no air control, and a blast that lifts one
## should carry it rather than be spent against its own walk.
func _accelerate(wish: Vector3, delta: float) -> void:
	if not is_on_floor():
		return
	var horizontal := Vector3(velocity.x, 0.0, velocity.z)
	var speed := horizontal.length()
	if speed > 0.0:
		var drop := maxf(speed, STOP_SPEED) * FRICTION * delta
		horizontal *= maxf(speed - drop, 0.0) / speed
	if wish != Vector3.ZERO:
		var wish_speed := wish.length()
		var wish_dir := wish / wish_speed
		var add := wish_speed - horizontal.dot(wish_dir)
		if add > 0.0:
			horizontal += wish_dir * minf(ACCELERATE * wish_speed * delta, add)
	velocity.x = horizontal.x
	velocity.z = horizontal.z


## Toward the goal, turning onto it as it goes. A goal it has arrived at, or would have to step
## off something to reach, is thrown away for a fresh one — which is the whole of the original's
## route handling: MoveToLocation failing and ShouldAdvanceRoute both re-roll the same vector.
func _walk(delta: float) -> Vector3:
	var to_goal := _goal - global_position
	to_goal.y = 0.0
	if to_goal.length() < ARRIVE_DIST:
		_pick_goal()
		return Vector3.ZERO
	var dir := to_goal.normalized()
	rotation.y = _turn_toward(atan2(-dir.x, -dir.z), delta)
	if is_on_floor() and not _ground_ahead(dir):
		_pick_goal()
		return Vector3.ZERO
	return dir * WALK_SPEED


func _pick_goal() -> void:
	_goal = global_position + Vector3(randf_range(-WANDER_RADIUS, WANDER_RADIUS), 0.0,
			randf_range(-WANDER_RADIUS, WANDER_RADIUS))


func _turn_toward(target_yaw: float, delta: float) -> float:
	var step := TURN_RATE * delta
	return rotation.y + clampf(wrapf(target_yaw - rotation.y, -PI, PI), -step, step)


## Is there floor to land on a body-width ahead? GoldSrc's SV_movestep refuses a step that finds
## no ground within a step height of the one it left, and that refusal is the only reason a sheep
## put on a hilltop is still on it ten minutes later.
func _ground_ahead(dir: Vector3) -> bool:
	var from := global_position + dir * (RADIUS * 2.0) + Vector3.UP * STEP_HEIGHT
	var params := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * (STEP_HEIGHT * 3.0))
	params.collision_mask = GameConsts.MASK_WORLD | GameConsts.MASK_CLIP
	params.exclude = [get_rid()]
	return not get_world_3d().direct_space_state.intersect_ray(params).is_empty()


## The grazing loop, as CSheep::MonsterThink cycled it at the end of every sequence: trot until a
## one-in-four roll puts the head down, eat until the same roll lifts it, then trot again.
func _next_clip() -> void:
	match _rig.clip:
		CLIP_DOWN: _rig.play(CLIP_EAT)
		CLIP_UP: _rig.play(CLIP_TROT)
		CLIP_EAT: _rig.play(CLIP_UP if randf() < GRAZE_CHANCE else CLIP_EAT)
		_: _rig.play(CLIP_DOWN if randf() < GRAZE_CHANCE else CLIP_TROT)
	if randf() < BAA_CHANCE:
		SoundSystem.play_3d(BAA_SOUND, global_position, 1.0, linear_to_db(BAA_VOLUME))


func take_damage(amount: float, type: int = GameConsts.DamageType.PHYSICAL, attacker: Node3D = null) -> void:
	_health.take_damage(amount, type, attacker)


func _die() -> void:
	_ascend(global_position, rotation.y)
	_entity.die_at(global_position, {"yaw": rotation.y}, true)


## Death is a one-shot event, not a property that converges.
func _apply_sync_state(state: Dictionary) -> void:
	if "death_pos" in state:
		_ascend(state.death_pos, float(state.get("yaw", 0.0)))


## What a dead sheep leaves: no gibs, no blood and no body — CSheep bled nothing and refused to
## come apart at any damage. Killed() drops it into its idle pose, takes away its collision, hands
## it a little upward velocity under MOVETYPE_NOCLIP and fades it out, so it drifts up out of the
## world. Built locally on each peer from the one death it was told about, since a visual with a
## duration cannot ride the despawn.
func _ascend(pos: Vector3, yaw: float) -> void:
	var scene_root := get_tree().current_scene
	if scene_root == null or DisplayServer.get_name() == "headless":
		return  # a dedicated server draws nobody, so it has no use for the body
	var body := AssetLoader.load_model(MODEL)
	if body == null:
		return
	AssetLoader.strip_hitboxes(body)
	# Held by a node of its own: the imported model root carries the turn onto -Z, and writing a
	# yaw straight onto it would throw that away.
	var holder := Node3D.new()
	holder.add_child(body)
	scene_root.add_child(holder)
	holder.global_position = pos
	holder.rotation.y = yaw
	var ap := body.find_child("AnimationPlayer") as AnimationPlayer
	if ap:
		ap.play(CLIP_DEAD)
	var tween := holder.create_tween()
	tween.set_parallel(true)
	tween.tween_property(holder, "global_position", pos + Vector3.UP * DEATH_RISE * DEATH_FADE,
			DEATH_FADE)
	tween.tween_method(func(alpha: float) -> void:
		AssetLoader.set_model_alpha(body, alpha)
	, 1.0, 0.0, DEATH_FADE)
	tween.chain().tween_callback(holder.queue_free)


## Animation rides the shared NetInterp slot (see EntityBehavior.set_anim_player).
func net_sync_properties() -> PackedStringArray:
	return PackedStringArray(["NetInterp:net_anim"])
