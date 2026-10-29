class_name Skeleton
extends CharacterBody3D

## A raised skeleton — monster_skeleton from the WW 1.2 source, dragged out of a body by the
## raise-dead spell and fighting for whoever raised it.
##
## Unlike every other combo summon it has no clock. It is not a spell effect that runs out; it
## is a soldier, and it stands until something kills it or the round ends. 200 HP, walks at a
## man's pace, and throws bones at whatever it can see.
##
## The original was a full Half-Life talk monster — schedules, cover, following orders, the lot.
## None of that machinery exists here, so what is ported is what it looked like from the outside:
## it walks at the nearest enemy it can see, and once it has a clear line it stands and throws.

const SCALE := GameConsts.SCALE_FACTOR
const MAX_HEALTH := 200.0               # SKELETON_HEALTH
const MOVE_SPEED := 150.0 * SCALE       # 3.75 m/s, a man's run
const SIGHT_RANGE := 1024.0 * SCALE     # 25.6 m
const THROW_RANGE := 800.0 * SCALE      # 20 m — it stops closing once it can reach you
const THROW_INTERVAL := 1.0             # the original's rate came out of HL's schedules, not a number
const RETARGET_INTERVAL := 0.5
## How long it keeps chasing a target it can no longer see. The original was a full HL talk
## monster with a memory; find_homing_target only returns what it can draw a clear ray to.
const PURSUE_TIME := 4.0
const RADIUS := 16.0 * SCALE            # VEC_HUMAN_HULL, as the original sized it
const HEIGHT := 72.0 * SCALE
const HEAD_HEIGHT := 16.0 * SCALE       # top of the hull — what a headshot has to find
const EYE_HEIGHT := 50.0 * SCALE        # pev->view_ofs — where it looks and throws from
const STEP_HEIGHT := 18.0 * SCALE       # GoldSrc monster step
const IDLE_CHATTER := 12.0              # it mutters to itself between fights
const MODEL := "models/combo/raisedead.mdl"
const THROW_SOUND := "monster/skeleton/bonethrow.wav"
const DEATH_SOUND := "monster/skeleton/skgibs.wav"
const GIB_MATERIAL := 9                 # matBones — bonegibs.mdl
const GIB_EXTENT := Vector3(0.6, 1.2, 0.6)
const GIB_COUNT := 5
## Spoken through the sentence system rather than by path: these two are what SK_WAIT and
## SK_FOLLOW exist for, and routing them that way is what keeps the lines honest.
const IDLE_SENTENCES := ["SK_WAIT", "SK_FOLLOW"]
const IDLE_ANIMS := ["idle1", "idle2", "idle3"]
## Both of the model's ACT_RANGE_ATTACK1 clips, listed at the actweight the model itself gives
## them (shootgun 1, shootgun2 2) — which is how GoldSrc picks between two clips of one activity.
const THROW_ANIMS := ["shootgun", "shootgun2", "shootgun2"]

var owner_node: Node3D
var owner_peer_id := 0  # 0 = nobody's (a /spawn'd skeleton); bots own theirs with negative ids
var team: int = GameConsts.Team.NONE
## Somewhere to be when there is nobody to fight. A summoned skeleton has none and holds its
## ground, which is what a summon should do; a siege sets it to the altar, and the skeleton walks
## the map to reach it. INF = no objective.
var objective := Vector3.INF
var is_dead: bool:
	get: return _summon.is_dead
var health: float:
	get: return _summon.health
var max_health: float:
	get: return _summon.max_health

var _summon := SummonBehavior.new()
## "run" is the only clip allowed to loop: the idles have to end for a fresh one to be drawn,
## and raisedead.mdl marks idle1 as looping, which would strand the skeleton in it forever.
var _rig := ModelRig.new()
var _nav := MonsterNav.new()
var _walk := MonsterBody.new()
var _model: Node3D
var _target: Node3D
var _seen := false               # the last retarget drew a clear ray to _target
var _pursue_t := 0.0             # chase left on a target it has lost sight of
var _retarget_timer := 0.0
var _throw_timer := 0.0
var _chatter_timer := 0.0


func setup(data: Dictionary, is_host := true) -> void:
	owner_peer_id = data.get("owner_peer_id", 0)
	team = data.get("team", GameConsts.Team.NONE)
	_summon.setup(self, data, is_host, MAX_HEALTH, _die)
	_nav.setup(self)
	_walk.setup(self, MOVE_SPEED, HEIGHT)
	_chatter_timer = randf_range(2.0, IDLE_CHATTER)


## Everything one needs to stand up and fight. Raise-dead warms it at class-select time; a
## map's ww_monstermaker has no spell in front of it, so a skeleton also asks on its own way in.
static func precache() -> void:
	AssetLoader.precache_model(MODEL)
	AssetLoader.precache_model(ThrowingBone.MODEL)
	for sound_path in [THROW_SOUND, DEATH_SOUND, ThrowingBone.HIT_SOUND, "misc/talk.wav"]:
		SoundSystem.precache(sound_path)
	# The heap it leaves clatters bone by bone as it lands.
	for sound_path in TumblingCorpse.IMPACT_SOUNDS.get(MODEL, []):
		SoundSystem.precache(sound_path)
	for sentence in IDLE_SENTENCES:
		SentenceSystem.precache(sentence)


func _ready() -> void:
	precache()
	# No yaw correction on the model: every clip animates the root back to -Z and one is always
	# playing, so the skeleton faces the node's own forward and each yaw below is a plain look-at.
	_model = AssetLoader.load_model(MODEL)
	_rig.initialize(self, _model.find_child("AnimationPlayer") if _model else null,
			ModelRig.Loop.LISTED, PackedStringArray(["run"]))
	if _model:
		AssetLoader.strip_hitboxes(_model)  # replaced by _add_hitboxes below — see why there
		add_child(_model)
		add_child(BlobShadow.new(RADIUS))
		_summon.set_anim_player(_rig.anim_player)  # publishes the played clip via NetInterp:net_anim
		_rig.play(IDLE_ANIMS[0])

	# Solid on both peers so the client's predicted player collides with it too; only the
	# authority walks it, so only the authority needs a world mask (mirrors GiantPlant).
	var col := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = RADIUS
	cyl.height = HEIGHT
	col.shape = cyl
	col.position.y = HEIGHT * 0.5
	add_child(col)
	collision_layer = GameConsts.MASK_ENTITY
	collision_mask = (GameConsts.MASK_WORLD | GameConsts.MASK_CLIP) if _summon.is_host else 0
	floor_snap_length = STEP_HEIGHT

	_add_hitboxes()
	# The rig is what a crowd of skeletons costs — an animating one measured at ~2ms a frame here,
	# so thirty of them held 16fps — and it is pure presentation: the hitboxes above are the body's
	# own, and a thrown bone leaves from _eye(), not from a bone. That is what makes it eligible
	# to sleep at all; see [ModelRig].
	_rig.sleep_offscreen(AABB(Vector3(-RADIUS, 0.0, -RADIUS),
			Vector3(RADIUS * 2.0, HEIGHT, RADIUS * 2.0)))


## Hitscan reads MASK_HITBOX and nothing else, so without volumes on that layer a skeleton
## could not be shot at all. The model ships 21, one per bone, and each is a physics-server
## transform write on every frame the rig animates. Two boxes on the hull it already collides
## with cost nothing to animate and keep the headshot the per-bone set was worth.
func _add_hitboxes() -> void:
	var body_height := HEIGHT - HEAD_HEIGHT
	_rig.add_hitbox(Vector3(RADIUS * 2.0, body_height, RADIUS * 2.0),
			Vector3(0.0, body_height * 0.5, 0.0))
	_rig.add_hitbox(Vector3(RADIUS * 1.5, HEAD_HEIGHT, RADIUS * 1.5),
			Vector3(0.0, HEIGHT - HEAD_HEIGHT * 0.5, 0.0), GameConsts.HITBOX_GROUP_HEAD)


func _physics_process(delta: float) -> void:
	_summon.tick(delta)
	_rig.tick(delta)
	if not _summon.is_host:
		return

	# It outlives whoever raised it, so a freed owner must not reach target filtering or
	# damage credit — both read properties off it.
	if not is_instance_valid(owner_node):
		owner_node = null

	_throw_timer -= delta
	_retarget_timer -= delta
	if _retarget_timer <= 0.0 or not _has_live_target():
		_retarget_timer = RETARGET_INTERVAL
		var found := Combat.find_homing_target(self, owner_node, team, SIGHT_RANGE,
				get_rid(), _eye(), Vector3.ZERO, 0.0, _spares_skeleton)
		# Losing sight is not losing the target: find_homing_target returns only what it can draw
		# a clear ray to, so without the pursuit window a skeleton forgot anyone who stepped behind
		# a pillar — and a monster that forgets you at the first corner never walks a route at all.
		if found != null:
			_target = found
			_seen = true
			_pursue_t = PURSUE_TIME
		elif _has_live_target():
			_seen = false
			_pursue_t -= RETARGET_INTERVAL
			if _pursue_t <= 0.0:
				_target = null
		else:
			_target = null

	var horizontal := Vector3.ZERO
	# The route point behind `horizontal`, so the body can swim at it in three dimensions.
	var heading := Vector3.INF
	if _has_live_target():
		var aim := SpatialQuery.collision_center(_target)
		var flat := aim - global_position
		flat.y = 0.0
		# Not while swimming: planting its feet is what a throw is, and a skeleton treading the
		# moat with a wizard in range would stand there throwing until the round ended. It gets
		# itself out of the water first (see [MonsterBody]).
		if _seen and flat.length() <= THROW_RANGE and not _walk.in_water:
			if flat.length_squared() > 0.0001:
				rotation.y = atan2(-flat.x, -flat.z)
			_throw()          # in reach and in sight: it plants its feet and throws
		else:
			# Round the corner instead of into it. ZERO is the nav saying it has nothing better
			# than the straight line this always walked.
			var dir := _nav.desired_dir(delta, aim, _walk.in_water)
			if dir == Vector3.ZERO and flat.length_squared() > 0.0001:
				dir = flat.normalized()
			if dir != Vector3.ZERO:
				rotation.y = atan2(-dir.x, -dir.z)
				horizontal = dir
				heading = _nav.waypoint()
	elif objective != Vector3.INF:
		var dir := _nav.desired_dir(delta, objective, _walk.in_water)
		if dir == Vector3.ZERO:
			var flat := objective - global_position
			flat.y = 0.0
			dir = flat.normalized() if flat.length_squared() > 0.0001 else Vector3.ZERO
		if dir != Vector3.ZERO:
			rotation.y = atan2(-dir.x, -dir.z)
			horizontal = dir
			heading = _nav.waypoint()
	else:
		_idle_chatter(delta)

	# Gravity, friction, stepping and sliding all belong to the kernel now — see [MonsterBody].
	_walk.walk(delta, horizontal, heading)

	_update_anim(horizontal != Vector3.ZERO)


func _throw() -> void:
	if _throw_timer > 0.0:
		return
	_throw_timer = THROW_INTERVAL
	_rig.play(THROW_ANIMS.pick_random())
	var from := _eye()
	var to := SpatialQuery.collision_center(_target)
	SoundSystem.play_3d(THROW_SOUND, from)
	var bone := NetworkManager.spawn_projectile("res://src/projectiles/throwing_bone.gd", {
		"position": from,
		"direction": (to - from).normalized(),
		"team": team,
	}, owner_node if owner_node else self, get_rid())
	# The eye sits inside the skeleton's own contact radius, so without this the bone strikes
	# the thrower on tick one — vanishing at the hand and hurting itself.
	if bone:
		bone.exclude_node = self  # server-only Node ref, not serializable


## Walk and idle loop, with the throw clip left alone until it ends: GoldSrc holds
## ACT_RANGE_ATTACK1 for the whole sequence, and the bone leaves on frame 0, so cutting the
## clip short showed nothing but the wind-up and read as a fidget rather than a throw.
func _update_anim(moving: bool) -> void:
	if _rig.clip in THROW_ANIMS and not _rig.clip_over():
		return
	if moving:
		_rig.play("run")
	elif not (_rig.clip in IDLE_ANIMS and not _rig.clip_over()):
		_rig.play(IDLE_ANIMS[randi() % IDLE_ANIMS.size()])


func _idle_chatter(delta: float) -> void:
	_chatter_timer -= delta
	if _chatter_timer > 0.0:
		return
	_chatter_timer = randf_range(IDLE_CHATTER * 0.5, IDLE_CHATTER * 1.5)
	SentenceSystem.play_on(self, IDLE_SENTENCES[randi() % IDLE_SENTENCES.size()])


## The original's IRelationship allies a skeleton with every non-player, so two of them never
## fight. It matters for the map-placed ones (ww_matrox's ww_monstermaker waves), which are
## teamless and would otherwise pick the skeleton beside them over the players they were put
## there to stop.
func _spares_skeleton(node: Node) -> bool:
	return node is Skeleton


## Re-checked every tick, not just at acquisition: a target that dies, leaves, or turns friendly
## mid-fight has to release it.
func _has_live_target() -> bool:
	if not is_instance_valid(_target) or not _target.is_inside_tree() or _target.get("is_dead"):
		return false
	return not Teams.summon_spares(team, owner_node, _target)


func take_damage(amount: float, type: int = GameConsts.DamageType.PHYSICAL, attacker: Node3D = null) -> void:
	_summon.take_damage(amount, type, attacker)


## A skeleton that is put down falls apart into a heap of its own bones — a ragdoll of the
## model's hitboxes, the same body a dead wizard leaves, on the frame it was standing in. It
## still bursts into loose gibs under the two conditions every other body in the game bursts
## under: a finishing blow over GameConsts.GIB_DAMAGE, and `/ragdolls off`, which has no body
## to leave at all. The original only ever did the burst (TE_BREAKMODEL of drybones.mdl).
func _die() -> void:
	var pos := global_position + Vector3(0.0, HEIGHT * 0.5, 0.0)
	var gibbed: bool = GameConsts.damage_gibs(_summon.vitals.last_damage) \
		or not RagdollBuilder.enabled()
	if not gibbed and not _spawn_corpse():
		gibbed = true  # no model, so no rig and no body: it comes apart after all
	_death_effect(pos, gibbed)
	SoundSystem.play_3d(DEATH_SOUND, pos)  # from here to every peer, as the original's DeathSound
	# The corpse is its own replicated entity, but the burst is a one-shot the clients have to be
	# told about — so which of the two deaths it was rides with death_pos.
	_summon.die_at(pos, {"gibbed": gibbed})


## The heap it leaves: a ragdoll built from raisedead.mdl's own hitboxes, carrying the pose it
## died in, drawn from the node origin the live model was drawn from so nothing moves in the
## handover frame. False when there is no model to read a rig off — the caller's cue to burst.
##
## Man-sized rather than dragon-sized, which is why spawn_monster asks for a width (body_radius)
## instead of assuming one: a beast is a size, not a category.
func _spawn_corpse() -> bool:
	if _model == null:
		return false
	TumblingCorpse.spawn_monster(MODEL, global_position, velocity, rotation.y,
		RagdollBuilder.capture_pose(RagdollBuilder.find_skeleton(_model)), RADIUS)
	return true


## Death is a one-shot event, not a property that converges.
func _apply_sync_state(state: Dictionary) -> void:
	if "death_pos" in state:
		_death_effect(state.death_pos, bool(state.get("gibbed", false)))


## It comes apart, or it falls in a heap. The sound isn't here: _die broadcasts it, so it reaches
## every peer whether or not the death event does.
func _death_effect(pos: Vector3, gibbed: bool) -> void:
	var scene_root := get_tree().current_scene
	if scene_root == null:
		return
	if gibbed:
		GibEffect.spawn(GIB_MATERIAL, pos, GIB_EXTENT, scene_root, "", GIB_COUNT)


func _eye() -> Vector3:
	return global_position + Vector3(0.0, EYE_HEIGHT, 0.0)


## Animation rides the shared NetInterp slot (see EntityBehavior.set_anim_player).
func net_sync_properties() -> PackedStringArray:
	return PackedStringArray(["NetInterp:net_anim"])
