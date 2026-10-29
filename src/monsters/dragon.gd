class_name Dragon
extends CharacterBody3D

## Mountable dragon. Riders get DragonBreathWeapon and CMF_FLYING flight.
## Entity keyvalues: team_no (int) — which team can mount (0 = any).

const MAX_HEALTH := 500.0
const MAX_FLAME := 50
const FLAME_REGEN_INTERVAL := 2.0
const FLAME_REGEN_AMOUNT := 6

var ent: Dictionary
var entity_id: int:
	get: return _entity.entity_id
## Breath charges. Authority-owned; every change is pushed to the rider's HUD.
var flame := MAX_FLAME:
	set(value):
		value = clampi(value, 0, MAX_FLAME)
		if value == flame:
			return
		flame = value
		sync_flame_to_rider()
## Replicated via net_sync_properties, rides the snapshot alongside spawn (avoids racing
## its own entity like a separate sync RPC would). Setter is the single apply point on both peers.
var is_ridden := false:
	set(value):
		if is_ridden == value:
			return
		is_ridden = value
		_apply_ridden()
var spawn_locked: bool = false  # true for spawn-point dragons; blocks voluntary dismount
var _team: int = 0
# Effective team for friend/foe checks: a ridden dragon fights for its rider's team, an unridden
# one keeps its spawn team_no. Without this, dragons read as teamless and bots target allies too.
var team: int:
	get:
		if is_instance_valid(_rider) and "team" in _rider:
			return _rider.team
		return _team
var _rider: Node = null
var _flame_timer := 0.0
var _model: Node3D = null
var _anim_player: AnimationPlayer = null
var _mouth_marker: Node3D = null
var _entity := EntityBehavior.new()
var _health := HealthBehavior.new()


## Called by _sync_create_entity on clients before add_child/ready.
func setup(data: Dictionary, is_host: bool = true) -> void:
	ent = {"classname": "monster_dragon", "team_no": str(data.get("team_no", 0))}
	if data.has("position"):
		position = data["position"]
	if data.has("yaw"):
		rotation.y = data["yaw"]
	_entity.initialize(self, is_host)
	_health.initialize(self, MAX_HEALTH, is_host, _dragon_die)


func _ready() -> void:
	# Must run after LocalPlayer._process wrote this frame's camera, or a map-spawned dragon
	# (earlier in the scene tree) anchors to last frame's camera and jitters.
	process_priority = 100

	# Map-spawned dragons (EntityRegistry.apply_scripts) never went through the dynamic-entity spawner,
	# so they have no synchronizer and exist only on the authority. Re-create through
	# spawn_dynamic_entity so every peer gets one, then free this unsynced map copy — otherwise
	# map dragons are invisible to non-host clients.
	if ent.is_empty():
		if NetworkManager.is_authority():
			var meta: Dictionary = get_meta("entity", {})
			var xform := global_transform
			NetworkManager.spawn_dynamic_entity({
				"script_path": get_script().resource_path,
				"team_no": int(meta.get("team_no", "0")),
				"position": xform.origin,
				"yaw": xform.basis.get_euler().y,
				"sync_state": true,
			})
		queue_free()
		return

	_model = AssetLoader.load_model("models/dragon.mdl")
	if _model:
		add_child(_model)
		add_child(BlobShadow.new(0.6))
		_anim_player = _model.find_child("AnimationPlayer")
		var skeleton := _model.find_child("Skeleton3D") as Skeleton3D
		if skeleton:
			var bone_idx := skeleton.find_bone("head")
			if bone_idx >= 0:
				var ba := BoneAttachment3D.new()
				ba.bone_idx = bone_idx
				skeleton.add_child(ba)
				_mouth_marker = ba

	_entity.set_anim_player(_anim_player)  # publishes the played animation to NetInterp:net_anim
	_team = int(ent.get("team_no", "0"))

	# Collider lives on both peers: the client replica needs it so the predicted local player
	# collides with it, and so the client-side +use raycast (looks for a trigger() node) can hit it.
	var shape_node := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.6
	cap.height = 1.8
	shape_node.shape = cap
	shape_node.position.y = 0.9
	add_child(shape_node)
	collision_mask = 0  # client replicas don't self-simulate; the host sets its world/clip mask below

	if _entity.is_host:
		add_to_group("dragon")
		# Only the authority simulates the dragon's own physics, so only it needs a world/clip mask.
		collision_mask = GameConsts.MASK_WORLD | GameConsts.MASK_CLIP

	# is_ridden can land before _ready built the model, so re-apply it rather than trust the setter.
	_apply_ridden()

	SoundSystem.precache("monster/dragon/dragon_die1.wav")
	SoundSystem.precache("monster/dragon/dragon_fly1.wav")
	SoundSystem.precache("spells/dragonfire.wav")


func _physics_process(delta: float) -> void:
	if not NetworkManager.is_authority():
		return

	if is_instance_valid(_rider):
		velocity = Vector3.ZERO
		# Skip when the local client is riding: _process() anchors to the rendered camera
		# instead, avoiding jitter from both systems writing the transform at different rates.
		if not _local_player_is_riding():
			global_transform = _rider.global_transform
			var pitch := clampf(_get_rider_pitch() * 0.55, -0.45, 0.45)
			rotation.x = pitch
			# Pivot around rider eye level so the dragon rotates under the camera, not its own feet
			# (else looking down swings the tail into the rider's face).
			const EYE_Y := 0.75
			var pivot := Vector3(0.0, EYE_Y, 0.0)
			global_position += pivot - global_transform.basis * pivot
	else:
		# A parked dragon is immovable. Knockback, tornadoes and push triggers all shove it by
		# writing velocity, so drop everything they wrote and leave only gravity.
		velocity.x = 0.0
		velocity.z = 0.0
		if not is_on_floor():
			velocity.y = maxf(minf(velocity.y, 0.0) - 20.0 * delta, -20.0)
		else:
			velocity.y = 0.0
		move_and_slide()

	# Catch-all for every path that mutates _rider; setter no-ops when unchanged. Playing the
	# clip here is what publishes it to clients via NetInterp:net_anim.
	is_ridden = (_rider != null)
	_play_anim("flying_cycler" if is_ridden else ("idle_1" if is_on_floor() else "fall_cycler"))

	if flame < MAX_FLAME:
		_flame_timer += delta
		if _flame_timer >= FLAME_REGEN_INTERVAL:
			_flame_timer -= FLAME_REGEN_INTERVAL
			flame += FLAME_REGEN_AMOUNT


func _process(_delta: float) -> void:
	var main := get_tree().current_scene
	if not main:
		return
	var client = Game.local_player
	if not is_instance_valid(client) or client.get("_mounted_dragon") != self:
		return
	var cam: Camera3D = client.call("_active_camera") if client.has_method("_active_camera") else client.get("camera")
	if not cam:
		return
	const EYE_Y := 0.75
	# Anchor directly to the rendered camera so the dragon never lags behind it.
	rotation.y = client.rotation.y
	global_position = cam.global_position - Vector3(0.0, EYE_Y, 0.0)
	var pitch := clampf(cam.global_rotation.x * 0.55, -0.45, 0.45)
	rotation.x = pitch
	var pivot := Vector3(0.0, EYE_Y, 0.0)
	global_position += pivot - global_transform.basis * pivot


## Mount/dismount is a +use (not an EntityBase, so it declares the cap itself).
func is_player_usable() -> bool:
	return true


func trigger(activator: Node, _type: TriggerSystem.Type = TriggerSystem.Type.TOGGLE) -> void:
	if not NetworkManager.is_authority():
		return
	if not is_instance_valid(activator):
		return
	if _team != 0:
		var activator_team: int = activator.get("team") if activator.get("team") != null else 0
		if activator_team != _team:
			return
	if _rider == null:
		_rider = activator
		is_ridden = true  # immediately: un-solidify before the rider's next collision tick
		var p := NetworkManager.get_player(activator.peer_id)
		if p:
			p.mount_dragon(self)
		sync_flame_to_rider(true)
	elif _rider == activator:
		if spawn_locked:
			return
		_rider = null
		_reset_pitch()
		is_ridden = false
		var p := NetworkManager.get_player(activator.peer_id)
		if p:
			p.dismount_dragon()


## Sent to the rider's owner only (not the broadcast entity state). Mid-range values ride
## unreliable (~10/s while breathing); empty/full and the mount push go reliable.
func sync_flame_to_rider(reliable := false) -> void:
	if not NetworkManager.is_authority() or not is_instance_valid(_rider):
		return
	if _rider.peer_id < 0:
		return  # bot rider: no HUD, and offline send_to_owner would hit the local player's bar
	reliable = reliable or flame == 0 or flame == MAX_FLAME
	NetworkManager.send_to_owner(_rider.peer_id,
		&"sync_dragon_flame" if reliable else &"sync_dragon_flame_drain", [flame])


func _reset_pitch() -> void:
	const EYE_Y := 0.75
	var pivot := Vector3(0.0, EYE_Y, 0.0)
	global_position += global_transform.basis * pivot - pivot
	rotation.x = 0.0


## State this entity puts on the snapshot. ":x" is a property on the entity itself;
## net_anim is the shared animation slot every animating dyn entity opts into.
func net_sync_properties() -> PackedStringArray:
	return PackedStringArray([":is_ridden", "NetInterp:net_anim"])


func _apply_ridden() -> void:
	collision_layer = 0 if is_ridden else GameConsts.MASK_ENTITY
	if _model:
		_model.position.y = -1.0 if is_ridden else 0.0


func _play_anim(anim: String) -> void:
	if _anim_player and _anim_player.has_animation(anim) and _anim_player.current_animation != anim:
		_anim_player.play(anim)


func take_damage(amount: float, type: int = GameConsts.DamageType.PHYSICAL,
		attacker: Node3D = null) -> void:
	if attacker and Teams.nodes_friendly(attacker, self):
		return  # no friendly fire — matches player.take_damage (self reports the rider's team)
	_health.take_damage(amount, type, attacker)


const GIB_EXTENT := Vector3(1.2, 1.2, 2.4)    # dragon-sized burst, not a skeleton's
const GIB_COUNT := 12
## Half-width of the carcass, for its shadow and its splash. Wider than the flight capsule's
## 0.6 because a dragon in the air is a tube and a dead one is sprawled across the floor.
const CORPSE_RADIUS := 0.8
const GIB_CENTER_Y := 0.9                     # mid-body, matching the collider

## A dragon dies the way a wizard does: it falls where it was shot down and lies there, unless
## the blow that finished it was big enough to take it apart (GameConsts.GIB_DAMAGE). `/ragdolls
## off` has no body to leave either, so it bursts — a model-sized ball rolling down the street
## is not the fallback anyone wants for something this size.
func _dragon_die() -> void:
	if is_instance_valid(_rider):
		var p := NetworkManager.get_player(_rider.peer_id)
		if p:
			p.dismount_dragon()
	_rider = null
	var pos := global_position + Vector3(0.0, GIB_CENTER_Y, 0.0)
	var gibbed: bool = GameConsts.damage_gibs(_health.last_damage) \
		or not RagdollBuilder.enabled()
	# The model's own origin, not the mid-body point the burst uses — see _spawn_corpse.
	if not gibbed and not _spawn_corpse(_model.global_position if _model else global_position):
		gibbed = true  # no model, so no rig and no body: it bursts after all
	_death_effect(pos, gibbed)
	SoundSystem.play_3d("monster/dragon/dragon_die1.wav", pos)  # to every peer, event or not
	# The corpse is replicated as its own entity, but the burst is a one-shot the clients have to
	# be told about — so which of the two deaths it was rides with death_pos.
	_entity.die_at(pos, {"gibbed": gibbed})


## The body it leaves: a ragdoll of the dragon's own MDL hitboxes, replicated the same way a
## dead wizard's is. It carries the pose it died in — whatever frame of flying_cycler or idle_1
## it was on — so a dragon shot out of the air folds up mid-beat instead of snapping to rest.
## False when there was no model to read a rig off, which is the caller's cue to burst rather
## than leave nothing at all.
##
## `origin` is the model's own, not the mid-body point the burst uses: a corpse draws its model
## from the origin it is given, so handing over anything else moves the dragon in the frame it
## dies. The caller reads it off the model rather than the node because a ridden dragon carries
## an offset of its own (_model.position.y).
func _spawn_corpse(origin: Vector3) -> bool:
	if _model == null:
		return false
	TumblingCorpse.spawn_monster("models/dragon.mdl", origin, velocity, rotation.y,
		RagdollBuilder.capture_pose(RagdollBuilder.find_skeleton(_model)), CORPSE_RADIUS)
	return true


## Death is a one-shot event, not a property that converges — same as the skeleton's. The gibs
## are their own nodes in the scene, and so is the corpse, so both outlive the dragon and the
## despawn can take it the same frame; a fade would have had to keep the dying node alive and
## replicate that state.
func _apply_sync_state(state: Dictionary) -> void:
	if "death_pos" in state:
		_death_effect(state.death_pos, bool(state.get("gibbed", false)))


## It comes apart, or it just stops. The cry isn't here: _dragon_die broadcasts it, so it reaches
## every peer whether or not the death event does.
func _death_effect(pos: Vector3, gibbed: bool) -> void:
	var scene_root := get_tree().current_scene
	if scene_root == null:
		return
	if gibbed:
		GibEffect.spawn(GibEffect.MAT_FLESH, pos, GIB_EXTENT, scene_root, "", GIB_COUNT)


func get_mouth_position() -> Vector3:
	if is_instance_valid(_mouth_marker):
		return _mouth_marker.global_position + global_transform.basis * _MOUTH_OFFSET
	return global_position + global_transform.basis * Vector3(0.0, 0.2, -1.5)

# Offset from the head bone toward the snout, in dragon-local space (Y=up, -Z=forward).
const _MOUTH_OFFSET := Vector3(0.0, 0.0, -0.5)


func _local_player_is_riding() -> bool:
	var main := get_tree().current_scene
	if not main:
		return false
	var client = Game.local_player
	return is_instance_valid(client) and client.get("_mounted_dragon") == self


func _get_rider_pitch() -> float:
	if not is_instance_valid(_rider):
		return 0.0
	if "sync_pitch" in _rider:
		return float(_rider.sync_pitch)
	var cam = _rider.get("camera")
	if cam is Camera3D:
		return cam.rotation.x
	return 0.0
