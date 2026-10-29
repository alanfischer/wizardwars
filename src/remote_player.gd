## Server-side player puppet — one per remote player on the host.
## Handles snapshot interpolation, animation, and authoritative damage/heal/respawn.
class_name RemotePlayer
extends "res://src/player.gd"
# Movement is inherited from the Player base.

var sync_crouched := false
var sync_pitch := 0.0
var sync_jumping := false
var sync_speed := 0.0  # horizontal speed (m/s) from server velocity — drives walk anim
var sync_move_dir := Vector3.ZERO  # horizontal unit vector of that velocity — drives the gait yaw
var sync_swimming := false  # waist-deep in water — picks the swim/treadwater clips
## True for the view-only copy of your own wizard that third person draws. It runs the model half
## of this class — animation, spine pitch, arm IK, invisibility, combo glow — and none of the
## netcode, physics or damage halves, which _setup_local_avatar turns off wholesale rather than
## guarding case by case.
var local_avatar := false
# sync_firing (HOST puppet authoritative sustained-fire state) lives on the Player base class.
var _sustained_shown := false  # OBSERVER: whether we've started this puppet's held-weapon visual
## Crosshair ID: what this peer was last told it is looking at, so a held target costs nothing
## after the first send. See tick_target_id.
var _target_id_sent: Array = ["", 0, -1]
var _target_id_cooldown := 0.0
var _server_movement: ServerMovement = null
var _godot_body: GodotBody = null
var _model_name = ""
var _staff_path := ""  # staff currently attached, so a re-apply of the same loadout is a no-op

const ServerRequests = preload("res://src/systems/server_requests.gd")

const MOVE_THRESHOLD = 0.01  # minimum distance per frame to count as moving

# --- Gait (GoldSrc StudioProcessGait) ---
# The legs point along the direction of travel while the torso stays on the aim: the model turns
# to the gait yaw and the spine twists back by the difference. Past what the spine can twist,
# GoldSrc spins the legs around and runs the cycle backwards instead — a backpedal.
const GAIT_BONE_NAMES = ["Bip01 Spine", "Bip01 Spine1", "Bip01 Spine2", "Bip01 Spine3"]
const GAIT_MOVE_SPEED := 5.0 * GameConsts.SCALE_FACTOR  # below this the gait drifts back to the aim
const GAIT_RETURN_RATE := 4.0  # how fast that drift converges (HL: flYaw *= dt * 4)
const GAIT_TWIST_PER_BONE := PI / 6.0  # 30 degrees, the range of the model's spine controllers

# Fall damage, from GoldSrc's safe/fatal fall speeds converted to m/s. The damage CURVE is
# deliberately softer than GoldSrc (half a health bar at max instead of a full kill), so a
# long drop hurts without being an instant kill in a game where players fall a lot. Curve
# keeps rising past FALL_REF_SPEED uncapped, so a genuine plunge still punishes.
const FALL_SAFE_SPEED := 1024 #14.5    # m/s — below this, landing is harmless
const FALL_REF_SPEED := 25.6     # m/s — GoldSrc's fatal-fall speed, our curve's reference point
const FALL_DAMAGE_AT_REF := 50.0 # damage at FALL_REF_SPEED — half of GoldSrc's lethal 100
const FALL_DAMAGE_PER_SPEED := FALL_DAMAGE_AT_REF / (FALL_REF_SPEED - FALL_SAFE_SPEED)

var _last_model_offset := Vector3.ZERO  # tracks last applied offset to avoid redundant updates

var sync_right_hand_world := Vector3.INF  # set by _on_sync_vr_hand_states; drives right arm IK
var sync_left_hand_world := Vector3.INF   # set by _on_sync_vr_hand_states; drives left arm IK
var sync_left_handed := false             # true when the remote player casts with their left hand
var _arm_ik: SkeletonIK3D = null
var _left_arm_ik: SkeletonIK3D = null
# Hand positions cached in body-local space so arms track smoothly between 30Hz network updates.
var _right_hand_body_local := Vector3.INF
var _left_hand_body_local := Vector3.INF
var _prev_sync_right_hand_world := Vector3.INF
var _prev_sync_left_hand_world := Vector3.INF

# Snapshot buffer (non-puppet): each entry = [recv_time, pos, rot_y, crouched, pitch, jumping]
var _snapshots: Array = []
var _last_broadcast_seq: int = -1  # out-of-order guard for broadcast_player_state

# Shadow state replicated by a child MultiplayerSynchronizer: the server writes these each net tick
# (set_net_state), the synchronizer ships them to visible peers, and the client's `synchronized`
# signal feeds them into the same push_snapshot interp path the manual broadcast used.
var net_pos := Vector3.ZERO
var net_yaw := 0.0
var net_pitch := 0.0
var net_vel := Vector3.ZERO
var net_flags := 0
var _render_flags := 0  # the net_flags apply_render_flags last showed
var net_seq := -1
var net_weapon_idx := 0
var net_stamp_ms := 0
# Client: element the model was last built for. element/team ride the spawn+sync stream, so a puppet
# rebuilt on visibility re-enter carries its own appearance. -1 forces the first build.
var _applied_element := -1
var _net_sync: MultiplayerSynchronizer = null

# Client-side PVS presence: local-clock ms of the last player-state packet received for this
# puppet (0 = never). The host only streams a player's state to peers who can see it, so
# visibility self-heals from the stream — render while packets arrive, hide once they stop.
# Host puppets ignore this (they're authoritative; see _process).
var _last_state_recv_ms: int = 0
# No packet for this long (ms) ⇒ out of PVS (or dead) ⇒ hide. A few net ticks of slack so
# normal unreliable packet loss doesn't flicker the puppet. Re-entry shows it on the next packet.
const PRESENCE_TIMEOUT_MS := 250

# goldnet backstop: local-clock ms of the last state bundle received while PRESENT (0 = none).
# goldnet presence rides explicit enter/leave events with no timeout, so a missed leave would
# strand a puppet visible+frozen until respawn/despawn — this catches that case instead.
var _last_bundle_ms: int = 0
const GOLDNET_STALE_HIDE_MS := 750

# Cached hitbox Area3D nodes for this player, rebuilt after each model swap.
var _hitbox_areas: Array[Area3D] = []

# class_change_pending_team / class_change_pending_element live on the Player base class.

var grounded: bool:
	get: return _server_movement.state.on_floor if _server_movement else false
var _anim_player: AnimationPlayer
var _attack_player: AnimationPlayer  # upper-body-only attack animations
var _skeleton: Skeleton3D
var _current_anim := &""
var _wizard_model: Node3D
var _staff_model: Node3D
## [glowing, wizard model id, staff model id] last pushed at the materials.
var _glow_signature: Array[int] = []
var _bone_merge: BoneMerge

const SPINE_BONE_NAMES = ["Bip01 Spine1", "Bip01 Spine2"]
var _spine_bone_indices: Array[int] = []
var _gait_bone_indices: Array[int] = []  # the four spine bones the torso twist is spread over
var _pose_bone_indices: Array[int] = []  # union of the two, parent-first — what _apply_spine_pose writes
var _gait_yaw := 0.0  # world yaw the legs are pointing along
var _gait_offset := 0.0  # gait yaw minus aim yaw: the model's extra local yaw, the spine's untwist
var _gait_reversed := false  # legs turned around (backpedal) — the locomotion cycle plays backwards


func _post_ready() -> void:
	# The CapsuleShape3D in remote_player.tscn is a shared sub-resource. Without this
	# duplicate, set_collision_height() mutates the shared shape and changes the
	# capsule height of every other player puppet simultaneously — causing them
	# to float off the floor by half a hull whenever any player crouches.
	var col := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col and col.shape:
		col.shape = col.shape.duplicate()
	add_child(BlobShadow.new())
	if local_avatar:
		_setup_local_avatar()
		return
	if NetworkManager.is_online():
		# Client puppets are positioned by interpolation, not physics: non-colliding with the world,
		# kept on the player layer so local prediction stays solid against them. (Host puppets are
		# authoritative bodies, set up by their creator.)
		if not NetworkManager.is_host():
			collision_mask = 0
			collision_layer = GameConsts.MASK_PLAYER
			physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		_setup_net_synchronizer()


## Build the third-person view copy of a player. The NetSync node has to go before the node
## enters the tree, which is why this is a factory and not something the caller assembles.
static func make_local_avatar(owner_peer_id: int) -> RemotePlayer:
	var avatar: RemotePlayer = load("res://src/remote_player.tscn").instantiate()
	avatar.name = "LocalAvatar"
	avatar.peer_id = owner_peer_id
	avatar.local_avatar = true
	var net_sync := avatar.get_node_or_null(^"NetSync")
	if net_sync:
		avatar.remove_child(net_sync)
		net_sync.free()
	return avatar


## Strip the view copy down to a model. It is not solid (the local player is already standing
## there), not a target, and never streamed — the netcode never learns it exists, because
## make_local_avatar builds it outside the spawner and no one registers it.
func _setup_local_avatar() -> void:
	# has_body_puppet is the base class's word for "this node is a view, the puppet is the real
	# entity", and set_damageable is its single gate — so nothing can put us back in the group.
	has_body_puppet = true
	set_damageable(false)
	collision_layer = 0
	collision_mask = 0
	var col := get_node_or_null(^"CollisionShape3D") as CollisionShape3D
	if col:
		col.disabled = true
	# The detectors exist to feed movement modifiers, which a view copy never asks for. Left in,
	# they would refit the area BVH twice per rendered frame as drive_local_avatar moves us.
	if ladder_detector:
		ladder_detector.queue_free()
	if water_detector:
		water_detector.queue_free()
	# The pose is written in world space every frame and we hang under the local player, who is
	# themselves turned to that same yaw. top_level makes the parent transform structurally
	# unable to reach us, rather than leaving it to every writer to remember.
	top_level = true
	set_process(false)  # _process is the interpolation/PVS half, none of which is ours


func setup_server_movement() -> void:
	_server_movement = ServerMovement.new()
	_godot_body = GodotBody.new(self, PackedStringArray(["LadderDetector/CollisionShape3D"]))
	_server_movement.bind_body(_godot_body)
	_server_movement.state.on_floor = is_on_floor()
	fire.secondary_waits = true
	# Match player collision properties so simulate_tick works correctly
	collision_mask = GameConsts.MASK_WORLD_AND_CLIP | GameConsts.MASK_ENTITY | GameConsts.MASK_PLAYER  # world + clip + solid entities + other players
	collision_layer = GameConsts.MASK_PLAYER  # host puppets simulate movement and are solid to other players
	floor_block_on_wall = false
	safe_margin = 0.01
	# Mover carry is explicit (netmove carry_motion via PlayerMovementContext);
	# disable Godot's built-in platform velocity so it can never double-apply.
	platform_floor_layers = 0
	platform_wall_layers = 0

	_move_ctx = PlayerMovementContext.new(self, ladder_detector, water_detector)


func has_server_movement() -> bool:
	return _server_movement != null


func get_server_movement() -> ServerMovement:
	return _server_movement


func get_godot_body() -> GodotBody:
	return _godot_body


func get_movement_modifiers(cmd) -> Movement.MovementModifiers:
	## Build movement modifiers for one tick. Called by the server modifier callback.
	return _move_ctx.get_modifiers(_server_movement.cfg, _server_movement.state, weapons, speed_multiplier, cmd)


## Server: one command's weapon switch, charge clock and trigger, ahead of its move, which is
## where the shooter's view fires it too.
func fire_frame(cmd) -> void:
	var input := FireControl.input_of(cmd)
	if input.weapon_select >= 0 and input.weapon_select != current_weapon_idx:
		ServerRequests.switch_weapon(self, input.weapon_select)
	charge.tick(cmd.delta)
	fire.step(cmd, self, weapon_at(current_weapon_idx))


func shoot(cmd, secondary: bool, charge_percent: float) -> int:
	var input := FireControl.input_of(cmd)
	var hand := (input.buttons & FireControl.HAND_AIM) != 0
	return ServerRequests.attack(self, input.aim_from if hand else Vector3.INF,
			input.aim_dir if hand else FireControl.view_dir(cmd), charge_percent, secondary,
			input.shot_ms)


func begin_charge() -> bool:
	return charge.begin(current_weapon_idx)


## Held duration on the server's charge clock sets the strength, not the client's own charge.
func release_charge() -> float:
	var charging_weapon := weapon_at(charge.weapon_idx)
	if charge.weapon_idx != current_weapon_idx or charging_weapon == null:
		return -1.0
	var charge_percent := charging_weapon.charge_percent_at(charge.time)
	charge.clear()
	return charge_percent


func stop_fire() -> void:
	ServerRequests.stop_attack(self)


func get_broadcast_flags() -> int:
	if not _server_movement:
		return 0
	var f := 0
	if _server_movement.state.is_crouched: f |= NetworkManager.PLAYER_FLAG_CROUCHED
	if _server_movement.state.is_jumping: f |= NetworkManager.PLAYER_FLAG_JUMPING
	if sync_firing: f |= NetworkManager.PLAYER_FLAG_FIRING
	if is_in_water(): f |= NetworkManager.PLAYER_FLAG_SWIMMING
	if is_invisible: f |= NetworkManager.PLAYER_FLAG_INVISIBLE
	for st: int in NetworkManager.PLAYER_STATUS_FLAGS:
		if StatusSystem.has_status(self, st):
			f |= NetworkManager.PLAYER_STATUS_FLAGS[st]
	return f


## Show what the snapshot flags say about how this puppet looks: invisibility and the status
## sprites. Level-triggered off the flags, on the host (set_net_state) and clients alike.
func apply_render_flags(flags: int) -> void:
	var changed := flags ^ _render_flags
	_render_flags = flags
	if changed & NetworkManager.PLAYER_FLAG_INVISIBLE:
		apply_invis_visual((flags & NetworkManager.PLAYER_FLAG_INVISIBLE) != 0)
	for st: int in NetworkManager.PLAYER_STATUS_FLAGS:
		var bit: int = NetworkManager.PLAYER_STATUS_FLAGS[st]
		if changed & bit:
			NetworkManager.show_status_visual(peer_id, st, (flags & bit) != 0)


## Teleport to a position and yaw. Zeroes velocity and drops lag-comp history.
func teleport_to(pos: Vector3, yaw: float) -> void:
	super(pos, yaw)
	# The sim's position follows the body transform on its own (state.position is a view over it),
	# so the move above is already visible to everything downstream. Still zero the sim velocity and
	# discard queued pre-teleport commands — those were predicted against the old position.
	if _server_movement:
		_server_movement.state.velocity = Vector3.ZERO
		_server_movement.clear_queue()
	_gait_yaw = yaw  # no drift back from wherever we were running before the teleport
	_gait_offset = 0.0
	LagCompensation.forget(peer_id)


func set_element(new_element: int) -> void:
	set_damageable(true)  # the gate, not add_to_group — a view (has_body_puppet) must stay out
	element = new_element
	var element_name: String = GameConsts.ELEMENT_NAMES[element]
	# Store weapon data and speed from wizard class (host uses for fire() and movement)
	var wizard := Wizard.create(element)
	_stop_all_attacks()
	weapons = with_granted(wizard.weapons)
	speed_multiplier = wizard.speed_multiplier
	max_health = wizard.max_health
	Log.info("[Player] set_element(%d) peer=%d speed_multiplier=%.3f" % [element, peer_id, speed_multiplier])
	current_weapon_idx = 0
	_load_player_model(element_name)
	if weapons.size() > 0 and weapons[0] is Staff:
		_load_staff_model(weapons[0].staff_model_path)


## Client: rebuild the model if the replicated element differs from what's shown. Idempotent and cheap
## when unchanged, so a re-spawned puppet restores its own appearance without a side-channel RPC.
func _ensure_appearance() -> void:
	if is_host_puppet:
		return
	if element == _applied_element:
		return
	if element < 0 or element >= GameConsts.ELEMENT_NAMES.size():
		return  # not a valid replicated element yet — wait for a real value
	_applied_element = element
	set_element(element)


func _apply_spawn_loadout(wizard: Wizard) -> void:
	_stop_all_attacks()
	weapons = with_granted(wizard.weapons)
	var element_name: String = GameConsts.ELEMENT_NAMES[element]
	_load_player_model(element_name)
	if weapons.size() > 0 and weapons[0] is Staff:
		_load_staff_model(weapons[0].staff_model_path)


func apply_remote_spawn_state(new_element: int = -1, reload_loadout: bool = true, dismount: bool = true) -> void:
	reset_for_spawn(new_element, reload_loadout, dismount)
	_on_spawn_state_reset()


func _on_spawn_state_reset() -> void:
	_snapshots.clear()
	_render_flags = 0  # the respawn handler cleared the sprites and reset_for_spawn the invisibility
	LagCompensation.forget(peer_id)
	# Client relevance-driven puppets: don't force-show on respawn, or a puppet respawning
	# outside the viewer's PVS would strand visible. Let the PVS stream reveal it instead.
	if NetworkManager.transport.relevance_events and not is_host_puppet:
		set_present_from_server(false)
	else:
		visible = true
	if _wizard_model:
		AssetLoader.set_model_alpha(_wizard_model, 1.0)
	if _staff_model:
		AssetLoader.set_model_alpha(_staff_model, 1.0)


func _on_spawn_transform_applied() -> void:
	move_and_slide()
	if _server_movement:
		_server_movement.state.velocity = Vector3.ZERO
		_server_movement.state.on_floor = is_on_floor()
		# Mirror local_player.gd reset_movement(): force standing so a crouched-death
		# doesn't leave is_crouched=true on the server while the client resets to false,
		# which would trigger a reconciliation toggle loop (eye_y snapping 0.75↔1.6).
		_server_movement.state.is_crouched = false
		_server_movement.state.eye_y = _server_movement.cfg.stand_eye
		_godot_body.set_collision_height(_server_movement.cfg.stand_height, _server_movement.cfg.stand_height * 0.5)
		_server_movement.clear()
	if NetworkManager.is_authority():
		PhysicsServer3D.body_set_state(get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, global_transform)


func get_model_offset(crouched: bool) -> Vector3:
	if _server_movement == null:
		return Vector3(0, (0.9 if crouched else 1.8) * 0.5, 0)
	var h := _server_movement.cfg.crouch_height if crouched else _server_movement.cfg.stand_height
	return Vector3(0, h * 0.5, 0)


## The model hangs off the body at a baked +90 degrees (AssetLoader.load_model); the gait rides
## on top of that as extra LOCAL yaw, so the body itself — the aim, the hull, the yaw we
## broadcast — never turns with the legs.
func _model_local_yaw() -> float:
	return deg_to_rad(90.0) + _gait_offset


func _apply_gait_rotation() -> void:
	# Smoothed puppets have their model yaw written in world space each frame instead
	# (see _write_visual_transform).
	if _needs_visual_smoothing():
		return
	if _wizard_model:
		_wizard_model.rotation.y = _model_local_yaw()
	if _staff_model:
		_staff_model.rotation.y = _model_local_yaw()


func _update_model_offset() -> void:
	var offset := get_model_offset(sync_crouched)
	if offset == _last_model_offset:
		return
	_last_model_offset = offset
	if _wizard_model:
		_wizard_model.position = offset
	if _staff_model:
		_staff_model.position = offset

## Load (or swap to) the player body model by name (e.g. "earth", "bear").
## Frees existing models first. Does not load a staff.
func _load_player_model(model_name: String) -> void:
	# Respawns and loadout resets re-apply the same class, so the model is usually already
	# the right one. Rebuilding it anyway tears down and recreates ~90 nodes (incl. the 21
	# bone hitboxes) for no visible change. Team can still have changed, so re-skin.
	if model_name == _model_name and is_instance_valid(_wizard_model):
		AssetLoader.set_model_skin(_wizard_model, team)
		return
	if _arm_ik:
		_arm_ik.queue_free()
		_arm_ik = null
	if _left_arm_ik:
		_left_arm_ik.queue_free()
		_left_arm_ik = null
	sync_right_hand_world = Vector3.INF
	sync_left_hand_world = Vector3.INF
	_right_hand_body_local = Vector3.INF
	_left_hand_body_local = Vector3.INF
	_prev_sync_right_hand_world = Vector3.INF
	_prev_sync_left_hand_world = Vector3.INF
	if _bone_merge:
		_bone_merge.queue_free()
		_bone_merge = null
	if _staff_model:
		_staff_model.queue_free()
		_staff_model = null
	_staff_path = ""
	if _wizard_model:
		_wizard_model.queue_free()
		_wizard_model = null
	if _attack_player:
		_attack_player.queue_free()
	_anim_player = null
	_attack_player = null
	_skeleton = null
	_spine_bone_indices = []
	_gait_bone_indices = []
	_pose_bone_indices = []
	_current_anim = &""

	_model_name = model_name
	_last_model_offset = Vector3.ZERO  # force refresh on next _update_model_offset
	_hitbox_areas.clear()
	var wizard_model = AssetLoader.load_model("models/player/%s.mdl" % model_name)
	if not wizard_model:
		return
	wizard_model.position = get_model_offset(sync_crouched)
	_last_model_offset = wizard_model.position
	add_child(wizard_model)
	_wizard_model = wizard_model
	AssetLoader.set_model_skin(wizard_model, team)
	_collect_hitbox_areas_into(wizard_model, _hitbox_areas)

	_anim_player = wizard_model.find_child("AnimationPlayer")
	_skeleton = wizard_model.find_child("Skeleton3D")
	if _skeleton:
		for bone_name in SPINE_BONE_NAMES:
			var idx := _skeleton.find_bone(bone_name)
			if idx >= 0:
				_spine_bone_indices.append(idx)
		for bone_name in GAIT_BONE_NAMES:
			var idx := _skeleton.find_bone(bone_name)
			if idx >= 0:
				_gait_bone_indices.append(idx)
		# Overrides on a parent feed the child's global pose, so both passes have to walk the
		# chain root-first; bone indices already run parent before child in a GoldSrc skeleton.
		for idx in _spine_bone_indices + _gait_bone_indices:
			if not _pose_bone_indices.has(idx):
				_pose_bone_indices.append(idx)
		_pose_bone_indices.sort()
	if _anim_player and _skeleton:
		_attack_player = AnimationPlayer.new()
		_attack_player.name = "AttackPlayer"
		var attack_lib := BoneUtil.get_attack_animation_library(model_name, _anim_player)
		_attack_player.add_animation_library(&"", attack_lib)
		_anim_player.get_parent().add_child(_attack_player)
		_attack_player.root_node = _anim_player.root_node
	_setup_arm_ik()
	_setup_left_arm_ik()


## Load the staff model from the given resource path and attach via bone merge.
## Requires _wizard_model to already be loaded.
func _load_staff_model(staff_path: String) -> void:
	if not _wizard_model:
		return
	if staff_path.is_empty():
		return
	if staff_path == _staff_path and is_instance_valid(_staff_model):
		return
	# Callers no longer always come through a model rebuild (which cleared these), so the
	# previous staff has to be dropped here or it stays parented alongside the new one.
	if _bone_merge:
		_bone_merge.queue_free()
		_bone_merge = null
	if _staff_model:
		_staff_model.queue_free()
		_staff_model = null
	var staff_model = AssetLoader.load_model(staff_path)
	if not staff_model:
		return
	_staff_path = staff_path
	staff_model.position.y = 0.9
	add_child(staff_model)
	_staff_model = staff_model

	var player_skel: Skeleton3D = _wizard_model.find_child("Skeleton3D")
	var staff_skel: Skeleton3D = staff_model.find_child("Skeleton3D")
	if player_skel and staff_skel:
		_bone_merge = BoneMerge.attach(staff_skel, player_skel)


func toggle_bear_form() -> void:
	if not NetworkManager.is_authority():
		return
	if is_bear:
		become_wizard()
	else:
		become_bear()


func become_bear() -> void:
	is_bear = true
	_bear_mana_drain_timer = 0.0
	var health_frac := health / max_health
	max_health = EarthWizard.BEAR_MAX_HEALTH
	health = health_frac * max_health
	speed_multiplier = EarthWizard.BEAR_SPEED
	_load_player_model("bear")
	var ew := EarthWizard.new()
	_stop_all_attacks()
	weapons = ew.make_bear_loadout()
	current_weapon_idx = 0
	SoundSystem.spawn_on(self, "spells/bearmorph.wav")
	NetworkManager.broadcast_and_dispatch(&"sync_bear_morph",
		[peer_id, true, health, max_health])


func become_wizard() -> void:
	is_bear = false
	_bear_mana_drain_timer = 0.0
	var health_frac := health / max_health
	# set_element reloads model, weapons, speed, and max_health for earth wizard
	set_element(element)
	health = health_frac * max_health
	NetworkManager.broadcast_and_dispatch(&"sync_bear_morph",
		[peer_id, false, health, max_health])


func _on_bear_drain_tick() -> void:
	NetworkManager.sync_mana_to_owner(self)


func _on_bear_mana_empty() -> void:
	become_wizard()


func _on_dragon_mount_authority(dragon: Node) -> void:
	_stop_all_attacks()
	weapons = [DragonBreathWeapon.new(dragon)]
	current_weapon_idx = 0


func _on_dragon_dismount_authority(_dragon: Node) -> void:
	set_element(element)


## Client-side puppet: revert model on dismount.
func apply_dragon_mount_visual(entity_id: int, mounted: bool) -> void:
	if mounted == false:
		dismount_dragon()
	_dragon_entity_id = entity_id if mounted else -1

	_last_model_offset = Vector3.ZERO  # force offset refresh on next _update_model_offset
	if not mounted:
		var element_name: String = GameConsts.ELEMENT_NAMES[element]
		_load_player_model(element_name)
		var wizard := Wizard.create(element)
		weapons = with_granted(wizard.weapons)
		current_weapon_idx = 0
		if weapons.size() > 0 and weapons[0] is Staff:
			_load_staff_model(weapons[0].staff_model_path)


## Called on client-side puppets via _on_sync_bear_morph to swap the visible model
## and weapon list so play_attack() picks the right animation.
func apply_bear_morph_visual(new_is_bear: bool) -> void:
	is_bear = new_is_bear
	var element_name: String = GameConsts.ELEMENT_NAMES[element]
	if new_is_bear:
		_load_player_model("bear")
		var ew := EarthWizard.new()
		_stop_all_attacks()
		weapons = ew.make_bear_loadout()
		current_weapon_idx = 0
	else:
		_load_player_model(element_name)
		var wizard := Wizard.create(element)
		_stop_all_attacks()
		weapons = with_granted(wizard.weapons)
		current_weapon_idx = 0
		if weapons.size() > 0 and weapons[0] is Staff:
			_load_staff_model(weapons[0].staff_model_path)


func push_snapshot(server_time_ms: int, seq: int, pos: Vector3, rot_y: float, crouched: bool, pitch: float, jumping: bool, vel: Vector3 = Vector3.ZERO, firing: bool = false) -> void:
	if not _record_snapshot(server_time_ms, seq, pos, rot_y, crouched, pitch, jumping, vel):
		return
	# Reconcile the sustained-beam visual to the freshest authoritative firing state. This
	# self-heals a dropped sync_attack/sync_stop_attack: even if the on/off edge event never
	# arrives, the next snapshot's PLAYER_FLAG_FIRING corrects the beam within a tick or two.
	_reconcile_firing(firing)


## Host-only: feed this puppet's own just-simulated state into the same interpolation buffer
## every other observer uses, so the host's screen smooths it too instead of rendering
## process_queue's raw per-tick output. Skips _reconcile_firing — the authoritative input
## path already ran fire()/stop_firing(), so reconciling here too would fire it twice.
func push_visual_snapshot(server_time_ms: int, seq: int, pos: Vector3, rot_y: float,
		crouched: bool, pitch: float, jumping: bool, vel: Vector3) -> void:
	_record_snapshot(server_time_ms, seq, pos, rot_y, crouched, pitch, jumping, vel)


func _record_snapshot(server_time_ms: int, seq: int, pos: Vector3, rot_y: float, crouched: bool,
		pitch: float, jumping: bool, vel: Vector3) -> bool:
	# Discard out-of-order packets. On WiFi, UDP can deliver an older broadcast
	# after a newer one. Without this check the buffer gets positions in the wrong
	# order and the interpolation lerps backward — the "snap back" artifact.
	if seq <= _last_broadcast_seq:
		return false
	_last_broadcast_seq = seq
	# Re-entering this peer's PVS after a gap: drop stale snapshots so we snap to the fresh
	# position instead of interpolating across the hole (a long slide / teleport artifact).
	var now_local := Time.get_ticks_msec()
	if _last_state_recv_ms != 0 and now_local - _last_state_recv_ms > PRESENCE_TIMEOUT_MS:
		_snapshots.clear()
	_last_state_recv_ms = now_local
	# Stamp snapshots in server-time space (matches get_estimated_server_time()) so the slewed clock
	# keeps render_time monotonic; local receipt time made brackets inflate/compress with jitter.
	_snapshots.append([server_time_ms / 1000.0, pos, rot_y, crouched, pitch, jumping, vel])
	if _snapshots.size() > NetworkManager.SNAPSHOT_BUFFER_SIZE:
		_snapshots.pop_front()
	return true


## Server: write this puppet's authoritative state into the shadow props the MultiplayerSynchronizer
## replicates, once per net tick. now_ms is the server send-time stamp for the client interp bracket.
func set_net_state(seq: int, pos: Vector3, yaw: float, pitch: float, vel: Vector3,
		flags: int, weapon_idx: int, now_ms: int) -> void:
	net_seq = seq
	net_pos = pos
	net_yaw = yaw
	net_pitch = pitch
	net_vel = vel
	net_flags = flags
	net_weapon_idx = weapon_idx
	net_stamp_ms = now_ms
	apply_render_flags(flags)
	# Every replicated slot on this puppet is written right here, so this is the one place that
	# has to tell goldnet to read it (see NetworkManager.mark_entity_dirty). Unconditional: a
	# puppet is written once per net tick and is one of the few entities that genuinely changes.
	NetworkManager.mark_entity_dirty(self)


## Every slot of the BAKED NetSync. The config itself lives in remote_player.tscn (under stock a
## runtime-added sync never pairs), so this table carries the hints only — but it lists every slot,
## which is what lets apply() catch the two drifting apart. yaw/pitch pack to a byte at GoldSrc
## angle precision, pos/vel to half-floats, net_stamp_ms to a delta off the header time. push is
## exactly what set_net_state writes; peer_id/element/team are spawn props nothing marks.
const PLAYER_SPEC := {
	".:peer_id": {},
	".:net_seq": {"push": true},
	".:net_pos": {"quant": "vec3_half", "push": true},
	".:net_yaw": {"quant": "angle8", "push": true},
	".:net_pitch": {"quant": "angle8", "push": true},
	".:net_vel": {"quant": "vec3_half", "push": true},
	".:net_flags": {"push": true},
	".:net_weapon_idx": {"push": true},
	".:net_stamp_ms": {"quant": "time_delta", "push": true},
	".:element": {},
	".:team": {},
}


## Wire the child MultiplayerSynchronizer that replaces the manual per-tick player broadcast. The
## synchronizer and its replication config are BAKED into remote_player.tscn (under stock a
## runtime-added one gets no replication-ID handshake and never pairs); here we only wire what
## can't live in a scene — the per-slot hints, the per-peer PVS filter (a Callable) and the
## client receive hook.
func _setup_net_synchronizer() -> void:
	if _net_sync != null:
		return
	_net_sync = get_node_or_null(^"NetSync") as MultiplayerSynchronizer
	if _net_sync == null:
		return
	# Per-peer PVS gating via _net_visible_to; NetworkManager pushes its result into peer_visibility
	# each net tick — the single gate both stock and goldnet read (see NetworkManager._pvs_syncs).
	NetworkManager.register_pvs_sync(_net_sync, _net_visible_to, _net_pvs_epoch)
	# apply(), not build(): the scene owns the config, so this stamps the hints and reports drift
	# from it — a hint naming a slot the config lost is otherwise ignored in silence.
	SyncSpec.apply(_net_sync, PLAYER_SPEC)
	_net_sync.synchronized.connect(_on_net_synchronized)


## Server-side per-peer gate: never send a peer its own body (it reconciles from its OwnerState),
## and only send to peers who can see this player via BSP PVS. Near-range relies on the player hull
## linking into every leaf it touches (GoldSrc SV_FindTouchedLeafs), not a distance override.
func _net_visible_to(observer_peer: int) -> bool:
	if observer_peer == peer_id:
		return false
	# Withhold until the peer has loaded the map, the same guard the movers use (see
	# MoverNetPublisher._visible_to). A spawn streamed into a client's reload window arrives with no
	# scene to receive it and is dropped — and because this pair's answer never changes again, it is
	# never re-sent, so that player stays a ghost for the rest of the map. Peer map-readiness is
	# folded into the column epoch (NetworkManager._peer_pvs_epoch), so the false -> true flip on
	# ready re-evaluates this row and goldnet ships a fresh spawn and baseline then.
	if not NetworkManager.is_peer_map_ready(observer_peer):
		return false
	# Dead / unjoined puppets drop out of the stream; the client hides them by packet absence.
	if is_dead or team == GameConsts.Team.NONE:
		return false
	return VisibilitySystem.is_player_visible_to_peer(peer_id, observer_peer)


## Change epoch for the gate above (see NetworkManager.register_pvs_sync). Everything _net_visible_to
## reads that is not the observing peer has to be represented here, or the send filter will skip a
## row whose answer has in fact changed.
##
## is_dead and team are folded into the VALUE rather than signalled from wherever they are assigned:
## death and team changes happen on several paths, and a missed signal would strand a corpse in
## everyone's stream. Deriving the epoch from the state itself cannot be forgotten.
func _net_pvs_epoch() -> int:
	var flags := (2 if is_dead else 0) | (1 if team == GameConsts.Team.NONE else 0)
	return VisibilitySystem.player_epoch(peer_id) * 4 + flags


## Client: a replicated bundle arrived — feed it through the same interp path the manual broadcast
## used. Host puppets are authoritative (driven directly), so they ignore this.
func _on_net_synchronized() -> void:
	if is_host_puppet:
		return
	_ensure_appearance()
	# A bundle arrived: refresh the goldnet staleness backstop (see _update_pvs_presence). Stamp it
	# here, not in push_snapshot, so an idle puppet whose seq hasn't advanced still counts as present.
	_last_bundle_ms = Time.get_ticks_msec()
	# goldnet: a state bundle arriving IS this puppet's PVS-enter event, so reveal it here (the leave
	# comes through NetworkManager._on_entity_relevance_lost). A late bundle can't resurrect a hidden
	# dead puppet — set_present_from_server gates the reveal on is_dead. No-op on stock.
	if NetworkManager.transport.relevance_events:
		set_present_from_server(true)
	# Feed the server-time stamp into the slewed clock; interp brackets need it.
	NetworkManager._update_server_clock(net_stamp_ms)
	current_weapon_idx = net_weapon_idx
	# Not in the snapshot tuple: swimming changes far more slowly than the interp delay, so
	# there is nothing to interpolate and nothing to gain from spending a slot on it.
	sync_swimming = (net_flags & NetworkManager.PLAYER_FLAG_SWIMMING) != 0
	apply_render_flags(net_flags)
	push_snapshot(net_stamp_ms, net_seq, net_pos, net_yaw,
		(net_flags & NetworkManager.PLAYER_FLAG_CROUCHED) != 0, net_pitch,
		(net_flags & NetworkManager.PLAYER_FLAG_JUMPING) != 0, net_vel,
		(net_flags & NetworkManager.PLAYER_FLAG_FIRING) != 0)


## Observer: drive a held weapon's visual from the authoritative firing state. Level-triggered and
## idempotent, so a dropped sync_attack/sync_stop_attack edge event self-heals on the next snapshot.
## Only sustained weapons use this — discrete shots come through _on_sync_attack events. "Sustained"
## means the weapon holds something while the trigger is down (a ray's beam, levitate's loop), not
## that it is literally a beam.
func _reconcile_firing(firing: bool) -> void:
	var wpn: Weapon = weapon_at(current_weapon_idx)
	if wpn == null or not wpn.sustained:
		_stop_sustained_if_shown()  # not a held weapon (e.g. switched away) → clear anything stale
		return
	if firing and not _sustained_shown:
		play_attack()
		wpn.fire(self, Vector3.INF, _aim_dir_from_sync(), 0.0, false)
		last_fired_weapon_idx = current_weapon_idx
		_sustained_shown = true
	elif not firing and _sustained_shown:
		wpn.stop_firing(self)
		_sustained_shown = false


## Observer: stop whatever a held weapon was showing for this puppet. Call on hide/death/despawn/
## PVS-exit so it can't be stranded when packets (carrying firing=false) stop arriving.
func _stop_sustained_if_shown() -> void:
	if not _sustained_shown:
		return
	_sustained_shown = false
	var wpn := last_fired_weapon()
	if wpn:
		wpn.stop_firing(self)


## Aim direction reconstructed from the puppet's synced yaw + pitch (forward = -Z at 0,0).
func _aim_dir_from_sync() -> Vector3:
	var cp := cos(sync_pitch)
	return Vector3(-sin(rotation.y) * cp, sin(sync_pitch), -cos(rotation.y) * cp)


## Return cached hitbox Area3Ds for lag-comp rewinding.
func get_hitbox_areas() -> Array[Area3D]:
	return _hitbox_areas


func _collect_hitbox_areas_into(node: Node, out: Array[Area3D]) -> void:
	for child in node.get_children():
		if child is Area3D and child.has_meta("hitbox_group"):
			out.append(child)
		else:
			_collect_hitbox_areas_into(child, out)


# --- Lag-compensation rig pose ---
# The hitboxes ride BoneAttachment3Ds, so where they sit is a function of the animation frame,
# the crouch model offset, the spine pitch and the gait yaw the legs are turned to — none of
# which a position/yaw rewind restores. LagCompensation records these each sim tick and feeds
# them back before a hitscan query.
# The upper-body attack player is deliberately left alone: it only moves arm boxes, which
# carry no damage multiplier of their own.

## Snapshot the rig state a rewind has to reproduce.
func lag_comp_capture_pose() -> Array:
	var clip := &""
	var clip_pos := 0.0
	if _anim_player and _anim_player.is_playing():
		clip = _anim_player.current_animation
		clip_pos = _anim_player.current_animation_position
	return [sync_crouched, clip, clip_pos, sync_pitch, _gait_offset]


## Put the rig back into a captured pose. Also used to undo a rewind, so it must fully
## determine the rig from `pose` alone — no reliance on what the puppet was doing before.
func lag_comp_apply_pose(pose: Array) -> void:
	sync_crouched = pose[0]
	sync_pitch = pose[3]
	_gait_offset = pose[4]
	_reset_model_local_transform(sync_crouched)
	var clip: StringName = pose[1]
	if _anim_player and clip != &"":
		if _anim_player.current_animation != clip:
			_anim_player.play(clip)
			_current_anim = clip
		_anim_player.seek(pose[2], true)
	_apply_spine_pose()


## Force _wizard_model/_staff_model's LOCAL transform back to the crouch offset and the rig's own
## yaw (the baked 90 degrees plus the rewound gait, and nothing else), unconditionally (bypassing
## _update_model_offset's _last_model_offset memoization, which exists to skip redundant writes on
## the normal render path and must NOT skip this one).
## LagCompensation._repose reads hitboxes via _skeleton.global_transform, composed through this
## local offset on top of the ROOT transform it rewinds — a puppet with active visual smoothing
## (_needs_visual_smoothing) carries an extra world-space correction here the rest of the time
## (see _write_visual_transform), which must never leak into that composition or a rewound hit
## query would land off by however much smoothing was in effect. Safe to call unconditionally:
## the next _process() frame recomputes and reapplies real smoothing regardless.
func _reset_model_local_transform(crouched: bool) -> void:
	var offset := get_model_offset(crouched)
	_last_model_offset = offset
	if _wizard_model:
		_wizard_model.position = offset
		_wizard_model.rotation.y = _model_local_yaw()
	if _staff_model:
		_staff_model.position = offset
		_staff_model.rotation.y = _model_local_yaw()


## Hitbox transforms in world space for the pose the rig is in right now, ordered to match
## get_hitbox_areas(). Composed from the skeleton's bone poses rather than read off each
## Area3D, because BoneAttachment3D only catches up on the skeleton's next update — a rewind
## needs the boxes for a pose applied microseconds ago.
func lag_comp_hitbox_world_transforms() -> Array:
	var out: Array = []
	if not _skeleton:
		return out
	_skeleton.force_update_all_bone_transforms()
	var skel_xform := _skeleton.global_transform
	for area in _hitbox_areas:
		var attach := area.get_parent() as BoneAttachment3D
		if attach == null:
			return []  # unexpected rig shape — let the caller fall back rather than half-rewind
		# BoneAttachment3D's own transform IS the bone's global pose, so composing the pose
		# here replaces it rather than stacking on top of it.
		out.append(skel_xform * _skeleton.get_bone_global_pose(attach.bone_idx) * area.transform)
	return out


func _process(_delta: float) -> void:
	# Run interpolation in _process for smooth visuals at display framerate.
	# Host puppets are authoritative (server sim + spawn/death events drive their visibility),
	# so packet-presence/PVS-by-packet-timing is always skipped for them — the host's own camera
	# PVS (_update_host_local_visibility) drives that instead. Position/rotation is a different
	# question: every OTHER connected player's (and bot's) puppet still needs local visual
	# smoothing here even though it's server-authoritative — see _needs_visual_smoothing.
	if not is_host_puppet:
		_interpolate_from_buffer()
		_update_pvs_presence()
	else:
		_update_host_local_visibility()
		if _needs_visual_smoothing():
			_interpolate_from_buffer()


## Host (listen server): cull this puppet against the host's own camera PVS (the same AABB query the
## send filter uses) so the host doesn't see opponents through walls. Dead/unjoined puppets hide.
func _update_host_local_visibility() -> void:
	# The host's own body puppet never renders on this machine — the first-person
	# LocalPlayer view is its local presentation (player-unification Phase 2b).
	if peer_id == multiplayer.get_unique_id():
		if visible:
			visible = false
		return
	var should_render := not is_dead and team != GameConsts.Team.NONE
	if should_render:
		should_render = VisibilitySystem.is_player_locally_visible(peer_id)
	if visible != should_render:
		visible = should_render


## Client (stock path): show this puppet exactly while player-state packets keep arriving — the host
## streams a player only to peers who can see them, so packet presence is the visibility signal.
## Skipped on goldnet, where explicit PVS enter/leave (set_present_from_server) drives presence instead.
func _update_pvs_presence() -> void:
	if NetworkManager.transport.relevance_events:
		# goldnet drives presence via enter/leave events, not packet timing — but a MISSED leave
		# (dropped, capped, or never generated when a puppet's sync goes silent) would strand this
		# puppet visible and frozen with no timeout to recover. Backstop: a still-visible puppet that
		# has received no bundle in GOLDNET_STALE_HIDE_MS is a missed leave (a present puppet streams
		# every ~33ms), so hide it. A later bundle re-shows it via _on_net_synchronized. This can't
		# fight a real leave (that clears `visible` first) or a correctly-streamed puppet.
		if visible and _last_bundle_ms != 0 \
				and Time.get_ticks_msec() - _last_bundle_ms > GOLDNET_STALE_HIDE_MS:
			set_present_from_server(false)
		return
	var present := _last_state_recv_ms != 0 \
		and Time.get_ticks_msec() - _last_state_recv_ms < PRESENCE_TIMEOUT_MS
	set_present_from_server(present)


## Presence contract: the transport tells us when this puppet enters our PVS (state bundle →
## _on_net_synchronized) or leaves it (relevance_lost → NetworkManager routes here). The same contract
## entities use, so the puppet unifies onto the relevance system. Idempotent; clears the beam on hide.
func set_present_from_server(on: bool) -> void:
	if is_host_puppet:
		return  # host puppets are driven by the host's own camera PVS (_update_host_local_visibility)
	if on and is_dead:
		return  # never reveal a puppet the authority confirmed dead (cleared on respawn, then re-shown)
	if visible == on:
		return
	visible = on
	# Collision tracks presence: an out-of-PVS (or dead) puppet must be INERT, not just invisible.
	# Gating it here makes hide + collision-off atomic — the reliable death RPC is a separate channel
	# that, on a lossy link, could otherwise leave an invisible-but-still-colliding body.
	_set_puppet_collision(on)
	if not on:
		_stop_sustained_if_shown()  # left our PVS: no more firing=false will arrive


## Deferred collider update: re-derive `disabled` from liveness at flush time instead of latching
## a fixed value. The death path disables the collider deferred (set_deferred / call_deferred), but a
## same-frame revive — the ww_hunt target-killed notepad returns and cascades into a GR_FORCE_RESPAWN
## force-respawn in the SAME frame — re-enables it immediately via _enable_after_spawn. A plain deferred
## `disabled = true` would then flush at end-of-frame and clobber that enable, stranding a live-but-
## non-solid puppet that falls through the floor. Re-reading is_dead here lets the revive win.
func sync_collider_to_liveness() -> void:
	var shape := get_node_or_null(^"CollisionShape3D") as CollisionShape3D
	if shape:
		shape.disabled = is_dead


## Toggle the puppet's body collider with its presence. No-op on host puppets (their collision is
## authority-driven via the death/respawn flow, not the client PVS stream).
func _set_puppet_collision(enabled: bool) -> void:
	if is_host_puppet:
		return
	var shape := get_node_or_null(^"CollisionShape3D") as CollisionShape3D
	if shape:
		shape.set_deferred("disabled", not enabled)


## Client: force this puppet out of the "present" state immediately (used on death so the body
## hides at once and the corpse takes over, rather than lingering until the presence timeout).
## Re-shown automatically when the next player-state packet arrives (e.g. on respawn).
func mark_pvs_absent() -> void:
	_last_state_recv_ms = 0
	_last_bundle_ms = 0  # clear the goldnet staleness stamp so a re-show starts fresh
	visible = false
	_set_puppet_collision(false)  # hide + collision-off atomically (see set_present_from_server)
	_stop_sustained_if_shown()  # death/despawn: clear it so the corpse doesn't inherit one


# --- Third-person view copy (see LocalPlayer.set_third_person) ---

## Build (or re-skin) the view copy to match the wizard the local player is currently wearing.
## Deliberately NOT set_element(): that also rewrites weapons, speed_multiplier and max_health,
## and puts us back in the "damageable" group the avatar was taken out of. `weapons` is shared
## by reference with the LocalPlayer purely so play_attack() can name the right animation — the
## avatar never fires, charges or cleans them up.
## This body's current bone rotations, for the corpse it is about to leave. The corpse builds
## its own model from rest, so without this a wizard killed mid-stride pops upright before he
## falls; with it the ragdoll starts on the frame he died on, gait lean and arm IK included,
## because this reads the posed skeleton rather than the clip that drove it.
func capture_bone_pose() -> PackedFloat32Array:
	return RagdollBuilder.capture_pose(_skeleton)


func dress_local_avatar(new_element: int, new_team: int, bear: bool,
		loadout: Array[Weapon], weapon_idx: int) -> void:
	element = new_element
	team = new_team
	is_bear = bear
	weapons = loadout
	current_weapon_idx = weapon_idx
	var model_name: String = "bear" if is_bear else GameConsts.ELEMENT_NAMES.get(element, "")
	if model_name.is_empty():
		return  # no class picked yet (spectating) — nothing to dress
	var previous := _wizard_model
	_load_player_model(model_name)
	if _wizard_model != previous and _wizard_model:
		# The wizard MDL ships 21 per-bone hitboxes on MASK_HITBOX. On a copy of ourselves they
		# sit right on our own aim ray — the viewmodel-hands bug over again. Only on a fresh
		# model: a weapon switch re-enters here and would otherwise re-walk the tree for nothing.
		AssetLoader.strip_hitboxes(_wizard_model)
		_hitbox_areas.clear()
	var staff: Weapon = weapon_at(0)
	if staff is Staff:
		_load_staff_model(staff.staff_model_path)


## Place and pose the view copy from the local player's predicted state. Called every rendered
## frame, off the same smoothed eye the camera is drawn from — anything else and the body would
## swim under the view by the smoothing residual.
func drive_local_avatar(feet: Vector3, yaw: float, pitch: float, crouched: bool, vel: Vector3,
		jumping: bool, invisible: bool, riding: bool, swimming: bool) -> void:
	global_transform = Transform3D(Basis(Vector3.UP, yaw), feet)  # world pose; see top_level above
	sync_pitch = pitch
	sync_crouched = crouched
	set_sync_velocity(vel)
	sync_jumping = jumping
	sync_swimming = swimming
	is_invisible = invisible
	# is_dragon_mounted is a getter over this id; the avatar has no dragon of its own and reads
	# it for one thing only — picking the riding animation in _update_animation.
	_dragon_entity_id = 0 if riding else -1


## The one place the animation-facing view of a velocity is derived: horizontal speed picks the
## clip, horizontal direction points the legs (see _update_gait).
func set_sync_velocity(vel: Vector3) -> void:
	var flat := Vector3(vel.x, 0.0, vel.z)
	sync_speed = flat.length()
	sync_move_dir = flat / sync_speed if sync_speed > 0.0 else Vector3.ZERO


## Everything that turns this puppet's state into the thing you look at. Split out of
## _physics_process because the third-person view copy runs this half and none of the rest.
func _update_visuals(delta: float) -> void:
	# Use server-authoritative horizontal speed for animation selection.
	# Position delta was unreliable: frost reduces velocity to ~0.5–2 m/s,
	# making interpolated position deltas hover near the threshold and
	# rapidly flip between walk and idle every frame for ~20s.
	var is_moving := sync_speed > MOVE_THRESHOLD

	# GoldSrc crouch anims don't lower the root bone — model Y offset compensates.
	# Bear model origin differs from wizard models; get_model_offset() handles both.
	_update_model_offset()
	_update_gait(delta)
	_apply_gait_rotation()
	_update_animation(is_moving)
	_apply_spine_pose()
	_apply_arm_ik()
	_update_invis_alpha(delta)
	_update_combo_glow()


func _physics_process(delta: float) -> void:
	_update_visuals(delta)
	if local_avatar:
		return  # the view copy is a model and nothing else — no sim, no damage, no authority

	# Out-of-world kill is handled centrally for all players in main._kill_players_out_of_world().

	# Lava/slime damage (server only — host owns the puppet sim)
	if NetworkManager.is_authority() and is_alive and _move_ctx:
		_move_ctx.tick_liquid_damage(delta)

	# Overheal drain (server only — client drains via its own _physics_process)
	if NetworkManager.is_authority() and health > max_health:
		health = maxf(health - GameConsts.OVERHEAL_DRAIN * delta, max_health)

	_tick_bear_mana_drain(delta)

	# Primed-satchel fuse + sustained-beam mana drain (server only — host owns the puppet sim).
	# The charge clock runs on commands, in fire_frame.
	if NetworkManager.is_authority():
		satchel_pack.tick_fuse(delta)
		tick_mana_drain(delta)
		plants.tick_indicators(delta)
		tick_target_id(delta)


## GoldSrc MAX_ID_RANGE: how far the crosshair will name something.
const TARGET_ID_RANGE := 2048.0 * GameConsts.SCALE_FACTOR
## The original re-traced twice a second; this is quicker off the mark and costs the same,
## since a line that hasn't changed is never sent.
const TARGET_ID_INTERVAL := 0.1


## Host-only: trace from this puppet's eye and tell its owner who is under the crosshair.
## Server-side because that is where health lives — a client only knows its own.
## Bots (negative peer ids) have no HUD to send it to.
func tick_target_id(delta: float) -> void:
	if peer_id <= 0:
		return
	_target_id_cooldown -= delta
	if _target_id_cooldown > 0.0:
		return
	_target_id_cooldown = TARGET_ID_INTERVAL
	var line := _look_target_line()
	if line == _target_id_sent:
		return
	_target_id_sent = line
	NetworkManager.send_target_id_to(peer_id, line[0], line[1], line[2])


## [label, relation, health_pct] for whatever this puppet's crosshair is on — see
## Teams.target_id_line. Empty label when the trace finds nothing worth naming.
func _look_target_line() -> Array:
	# "damageable" is the gate for a puppet that has actually spawned: a peer still loading the
	# map is parked on a spawn point outside the group, and must not be reading names off it.
	if not is_alive or not is_in_group("damageable"):
		return ["", 0, -1]
	var aim := Combat.get_aim(self, Vector3.INF, _aim_dir_from_sync())
	var ray := Combat.raycast_world(self, aim.from, aim.aim_dir, TARGET_ID_RANGE, RID(),
			GameConsts.MASK_HITSCAN, true, Combat.collect_hitscan_excludes(self))
	var result: Dictionary = ray.result
	if result.is_empty():
		return ["", 0, -1]
	return Teams.target_id_line(self, Combat.find_damageable(result.collider))


## Host-only: turn a landing impact speed (m/s) into GoldSrc-style fall damage.
## Fired per landing tick by ServerMovement.process_queue (see main._process_player_movements).
func apply_fall_damage(impact_speed: float) -> void:
	if is_dead or impact_speed <= FALL_SAFE_SPEED:
		return
	take_damage((impact_speed - FALL_SAFE_SPEED) * FALL_DAMAGE_PER_SPEED, GameConsts.DamageType.PHYSICAL)


## Player snapshot format: [time, pos, rot_y, crouched, pitch, jumping, vel]
const _PL_POS := 1
const _PL_ROT_Y := 2
const _PL_CROUCHED := 3
const _PL_PITCH := 4
const _PL_JUMPING := 5
const _PL_VEL := 6

## True when this MACHINE needs to render this puppet's position/rotation through the
## interpolation buffer even though it's an is_host_puppet body: the host's own view of every
## OTHER connected player (and bots). Those bodies are driven directly by server simulation
## every physics tick (setup_server_movement) — global_position IS the live collision transform
## (MovementState.position is a view over it — see pmove/movement.gd), so this must never be
## used to justify writing global_position itself; see _write_visual_transform.
func _needs_visual_smoothing() -> bool:
	return is_host_puppet and peer_id != multiplayer.get_unique_id()


## Write an interpolated pose. Client puppets have no real physics body locally, so the root
## transform is free to use — write it directly. is_host_puppet bodies are live collision
## bodies (see _needs_visual_smoothing): the root must stay exactly where the server simulation
## put it, so the visual mesh (a child, along with the staff) tracks the smoothed pose instead,
## with the crouch/eye height offset folded in since this replaces _update_model_offset's write
## for as long as smoothing is active.
func _write_visual_transform(pos: Vector3, yaw: float, crouched: bool) -> void:
	if not _needs_visual_smoothing():
		global_position = pos
		rotation.y = yaw
		return
	var visual_pos := pos + get_model_offset(crouched)
	if _wizard_model:
		_wizard_model.global_position = visual_pos
		_wizard_model.global_rotation.y = yaw + _model_local_yaw()
	if _staff_model:
		_staff_model.global_position = visual_pos
		_staff_model.global_rotation.y = yaw + _model_local_yaw()


func _apply_snapshot(s: Array) -> void:
	_write_visual_transform(s[_PL_POS], s[_PL_ROT_Y], s[_PL_CROUCHED])
	sync_crouched = s[_PL_CROUCHED]
	sync_pitch = s[_PL_PITCH]
	sync_jumping = s[_PL_JUMPING]
	set_sync_velocity(s[_PL_VEL])

func _interpolate_from_buffer() -> void:
	if _snapshots.is_empty():
		return

	var last_snap: Array = _snapshots[_snapshots.size() - 1]

	if _snapshots.size() == 1:
		_apply_snapshot(last_snap)
		return

	var render_time := NetworkManager.get_estimated_server_time() - NetworkManager.INTERP_DELAY
	var bracket := SnapshotInterp.find_bracket(_snapshots, render_time)
	var s0_idx: int = bracket.s0_idx

	if s0_idx == -1:
		_apply_snapshot(_snapshots[0])
		return

	if s0_idx >= _snapshots.size() - 1:
		# Extrapolate using server velocity for accuracy during direction changes
		var overshoot := minf(render_time - last_snap[0], NetworkManager.EXTRAP_MAX)
		var extrap_pos: Vector3 = (last_snap[_PL_POS] as Vector3) + (last_snap[_PL_VEL] as Vector3) * overshoot
		_write_visual_transform(extrap_pos, last_snap[_PL_ROT_Y], last_snap[_PL_CROUCHED])
		sync_crouched = last_snap[_PL_CROUCHED]
		sync_pitch = last_snap[_PL_PITCH]
		sync_jumping = last_snap[_PL_JUMPING]
		set_sync_velocity(last_snap[_PL_VEL])
		return

	var s0: Array = _snapshots[s0_idx]
	var s1: Array = _snapshots[s0_idx + 1]
	var t: float = bracket.t

	var pos := SnapshotInterp.lerp_vec3(s0, s1, t, _PL_POS)
	var yaw := SnapshotInterp.lerp_rot(s0, s1, t, _PL_ROT_Y)
	_write_visual_transform(pos, yaw, s1[_PL_CROUCHED])
	sync_crouched = s1[_PL_CROUCHED]
	sync_pitch = SnapshotInterp.lerp_rot(s0, s1, t, _PL_PITCH)
	sync_jumping = s1[_PL_JUMPING]
	set_sync_velocity(s1[_PL_VEL])

	SnapshotInterp.prune(_snapshots, s0_idx)


func _update_animation(is_moving: bool) -> void:
	if not _anim_player:
		return
	var anim: StringName
	var cycle := is_moving  # a locomotion cycle, so a backpedal may run it backwards
	if is_dragon_mounted:
		anim = &"crouch_aim_dragonbreath"
		cycle = false
	elif sync_swimming:
		# Water outranks jumping: GoldSrc leaves waterlevel 2 in the air-move state, and a swimmer
		# bobbing over the surface would otherwise flicker between the jump and swim clips.
		anim = &"swim" if is_moving else &"treadwater"
	elif sync_jumping:
		anim = &"jump"
		cycle = false
	elif sync_crouched:
		anim = &"crawl" if is_moving else &"crouch_idle"
	else:
		anim = &"run2" if is_moving else &"idle"
	if anim != _current_anim:
		_current_anim = anim
		_anim_player.play(anim)
	# Only the walk/swim cycles reverse — see _update_gait's flip.
	var rate := -1.0 if (cycle and _gait_reversed) else 1.0
	if _anim_player.speed_scale != rate:
		_anim_player.speed_scale = rate


func _setup_arm_ik() -> void:
	if not _skeleton:
		return
	if _skeleton.find_bone("Bip01 R Arm") < 0 or _skeleton.find_bone("Bip01 R Hand") < 0:
		return
	var ik := SkeletonIK3D.new()
	ik.name = "ArmIK"
	# Use clavicle as root when available: the walk animation swings the clavicle,
	# shifting the shoulder in world space each frame and jittering the IK solution.
	# Making the clavicle the IK root lets the solver own it, preventing that conflict.
	ik.root_bone = "Bip01 R Clavicle" if _skeleton.find_bone("Bip01 R Clavicle") >= 0 else "Bip01 R Arm"
	ik.tip_bone = "Bip01 R Hand"
	ik.min_distance = 0.01
	ik.override_tip_basis = false  # position-only IK; rotation constraint causes FABRIK instability
	_skeleton.add_child(ik)
	_arm_ik = ik


func _setup_left_arm_ik() -> void:
	if not _skeleton:
		return
	if _skeleton.find_bone("Bip01 L Arm") < 0 or _skeleton.find_bone("Bip01 L Hand") < 0:
		return
	var ik := SkeletonIK3D.new()
	ik.name = "LeftArmIK"
	ik.root_bone = "Bip01 L Clavicle" if _skeleton.find_bone("Bip01 L Clavicle") >= 0 else "Bip01 L Arm"
	ik.tip_bone = "Bip01 L Hand"
	ik.min_distance = 0.01
	ik.override_tip_basis = false
	_skeleton.add_child(ik)
	_left_arm_ik = ik


## Basis for the left arm IK target — 180° around Y, the mirror of Basis.IDENTITY
## for a character facing -Z.  The right arm works with IDENTITY; the left arm's
## hand bone is mirrored in X/Z so it needs the corresponding reflected rotation.
const _LEFT_ARM_IK_BASIS := Basis(Vector3(-1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, -1))

# VR controllers sit closer to the body than the avatar's arms can reach at rest.
# Scale the IK target outward from the spine so a natural controller position
# produces a visibly extended arm on the puppet. Tune if arms over/under-extend.
const _IK_REACH_SCALE := 1.5

func _scale_ik_target(hand_world: Vector3) -> Vector3:
	var chest_y: float = global_position.y + get_model_offset(sync_crouched).y + 0.3
	var spine := Vector3(global_position.x, chest_y, global_position.z)
	return spine + (hand_world - spine) * _IK_REACH_SCALE

func _apply_arm_ik() -> void:
	# Convert to body-local space when the network value changes, then reconstruct
	# world position from the current body transform every frame. This makes the arm
	# track body movement smoothly at visual framerate instead of stepping at 30 Hz.
	var inv_tf := global_transform.affine_inverse()
	if sync_right_hand_world != _prev_sync_right_hand_world:
		_prev_sync_right_hand_world = sync_right_hand_world
		_right_hand_body_local = inv_tf * sync_right_hand_world if sync_right_hand_world.is_finite() else Vector3.INF
	if sync_left_hand_world != _prev_sync_left_hand_world:
		_prev_sync_left_hand_world = sync_left_hand_world
		_left_hand_body_local = inv_tf * sync_left_hand_world if sync_left_hand_world.is_finite() else Vector3.INF

	var r_world := global_transform * _right_hand_body_local if _right_hand_body_local.is_finite() else Vector3.INF
	var l_world := global_transform * _left_hand_body_local if _left_hand_body_local.is_finite() else Vector3.INF

	if _arm_ik and is_instance_valid(_arm_ik) and _skeleton:
		if not r_world.is_finite():
			if _arm_ik.is_running():
				_arm_ik.stop()
		else:
			_arm_ik.target = Transform3D(Basis.IDENTITY, _scale_ik_target(r_world))
			if not _arm_ik.is_running():
				_arm_ik.start()
	if _left_arm_ik and is_instance_valid(_left_arm_ik) and _skeleton:
		if not l_world.is_finite():
			if _left_arm_ik.is_running():
				_left_arm_ik.stop()
		else:
			_left_arm_ik.target = Transform3D(_LEFT_ARM_IK_BASIS, _scale_ik_target(l_world))
			if not _left_arm_ik.is_running():
				_left_arm_ik.start()


## GoldSrc StudioEstimateGait/StudioProcessGait: track the yaw the legs run along, and how far
## the torso has to twist back to keep facing the aim. Standing still, the legs come back under
## the view over about a quarter second rather than snapping.
func _update_gait(delta: float) -> void:
	var aim_yaw := rotation.y
	if sync_speed > GAIT_MOVE_SPEED and sync_move_dir != Vector3.ZERO:
		# Forward is -Z at yaw 0, so the yaw that points along a direction is atan2(-x, -z).
		_gait_yaw = atan2(-sync_move_dir.x, -sync_move_dir.z)
	else:
		_gait_yaw += wrapf(aim_yaw - _gait_yaw, -PI, PI) * minf(delta * GAIT_RETURN_RATE, 1.0)
	if _gait_bone_indices.is_empty():
		# No spine to untwist (an unexpected skeleton): turning the model would turn the aim with
		# it, so leave the legs on the aim rather than point the whole wizard the wrong way.
		_gait_offset = 0.0
		_gait_reversed = false
		return
	var offset := wrapf(_gait_yaw - aim_yaw, -PI, PI)
	var twist_limit := GAIT_TWIST_PER_BONE * _gait_bone_indices.size()
	# Past the spine's range the legs spin around and the cycle runs backwards — a backpedal,
	# not a wizard wrung out at the waist. The flip lands mid-range, which is its own hysteresis.
	_gait_reversed = absf(offset) > twist_limit
	if _gait_reversed:
		offset -= signf(offset) * PI
	_gait_offset = offset


## Spine pitch (look up/down) and gait twist (torso back onto the aim while the legs point along
## the run) in one pass: both are global-pose overrides on the same chain, and a second pass would
## clear the first one's work.
func _apply_spine_pose() -> void:
	if not _skeleton or _pose_bone_indices.is_empty():
		return
	for idx in _pose_bone_indices:
		_skeleton.set_bone_global_pose_override(idx, Transform3D.IDENTITY, 0.0, false)
	var pitch_per_bone := sync_pitch / maxf(_spine_bone_indices.size(), 1)
	var twist_per_bone := -_gait_offset / maxf(_gait_bone_indices.size(), 1)
	for idx in _pose_bone_indices:
		var pose := _skeleton.get_bone_global_pose(idx)
		# Rotate in skeleton space (pre-multiply) around +Z (BACK) for pitch and +Y (UP) for the
		# twist — the pitch and yaw axes of a +X-facing model. Pre-multiplying avoids any
		# dependence on bone-local orientation, so this works identically for wizards and the
		# bear's differently-oriented spine. A bone's global pose already carries its parent's
		# override, so the shares add up the chain like GoldSrc's per-bone controllers do.
		var twist := Basis(Vector3.UP, twist_per_bone) if _gait_bone_indices.has(idx) else Basis()
		var pitch := Basis(Vector3.BACK, pitch_per_bone) if _spine_bone_indices.has(idx) else Basis()
		pose.basis = twist * pitch * pose.basis
		_skeleton.set_bone_global_pose_override(idx, pose, 1.0, true)


func _on_healed(amount: float, allow_overheal: bool) -> void:
	# Tell the owning client they were healed (host body: local dispatch)
	NetworkManager.send_to_owner(peer_id, &"sync_player_heal",
		[amount, allow_overheal])


func _on_damage_taken_authority(amount: float, type: int, attacker: Node3D) -> void:
	# Notify the attacker they landed a hit. Runs before apply_damage_raw, so
	# health is still pre-damage — the killing blow is health - amount <= 0.
	NetworkManager.send_hit_confirmed_to(attacker, health - amount <= 0.0)
	# Tell the owning client they took damage (host body: local dispatch)
	NetworkManager.send_to_owner(peer_id, &"sync_player_damage",
		[amount, type])
	# A bot puppet's brain only sees a cone — a hit from outside it is how it learns it's shot at.
	var brain := get_node_or_null(^"BotBrain")
	if brain != null:
		brain.on_damaged(attacker)


func _on_died(attacker: Node3D, type: int = GameConsts.DamageType.PHYSICAL,
		damage: float = 0.0) -> void:
	sync_firing = false  # clear authoritative beam state so it doesn't persist into respawn
	# Host puppet: disable our body collider so bots/players pass through the dead body.
	# Remote puppets get this from main._on_sync_player_death, but that handler early-returns
	# for our own peer id, so the host body must disable it here (mirrors die_for_class_change).
	# Re-enabled on respawn by _enable_after_spawn (spawn_at, via _host_respawn). Deferred through
	# sync_collider_to_liveness so a same-frame force-respawn revive isn't clobbered (see that method).
	if is_host_puppet:
		call_deferred(&"sync_collider_to_liveness")
	if _server_movement:
		_server_movement.clear_queue()
	# Leave the body on the host before broadcasting — or a burst where the body would have been,
	# if the blow was big enough (TumblingCorpse.spawn_wizard_remains). A raising leaves neither:
	# it takes the wizard's body to make the skeleton, so there is nothing left for the next book
	# to raise.
	if Player.death_type_leaves_corpse(type):
		var death_velocity := _server_movement.state.velocity if _server_movement else Vector3.ZERO
		# Only a body that is going to lie there needs the pose it died in — a burst throws it
		# away, and reading one off the skeleton is 22 bones of work on the busiest machine.
		var pose := PackedFloat32Array() if GameConsts.damage_gibs(damage) else capture_bone_pose()
		TumblingCorpse.spawn_wizard_remains(get_tree().current_scene, global_position,
			rotation.y, element, death_velocity, pose, damage)
	# Broadcast death to all clients (include killer peer_id for K/D tracking) and
	# apply locally — the host body's own death must reach the host's view.
	# A killer that isn't a player (an unowned skeleton's bone) has no peer_id: nobody gets credit.
	var pid: Variant = attacker.get("peer_id") if attacker else null
	var killer_peer: int = int(pid) if pid != null else 0
	GoalSystem.record_kill(killer_peer, peer_id)
	NetworkManager.broadcast_player_death(peer_id, killer_peer)
	# Host respawns this puppet after delay
	get_tree().create_timer(RESPAWN_DELAY).timeout.connect(_host_respawn)


func start_invisibility() -> void:
	is_invisible = true
	if NetworkManager.is_authority():
		NetworkManager.send_to_owner(peer_id, &"sync_player_invis", [peer_id, true])


func stop_invisibility() -> void:
	is_invisible = false
	if NetworkManager.is_authority():
		NetworkManager.send_to_owner(peer_id, &"sync_player_invis", [peer_id, false])


func apply_invis_visual(active: bool) -> void:
	is_invisible = active


func _update_invis_alpha(delta: float) -> void:
	_update_invis_alpha_common(delta, sync_speed, [_wizard_model, _staff_model])


## The glow shell the original put on a wizard carrying a combo spell, so everyone can see who
## has one. Driven off granted_weapons, which every peer already has (sync_grant_weapon reaches
## the replicas, and respawn clears it through reset_for_spawn), so it needs no traffic of its
## own. An invisible wizard doesn't glow — the spell shouldn't cost them the spell they're
## already casting. The signature covers the models too: set_element builds new ones.
func _update_combo_glow() -> void:
	var sig: Array[int] = [
		1 if has_combo_weapon() and not is_invisible else 0,
		_wizard_model.get_instance_id() if _wizard_model else 0,
		_staff_model.get_instance_id() if _staff_model else 0,
	]
	if sig == _glow_signature:
		return
	_glow_signature = sig
	var strength := COMBO_GLOW_STRENGTH if sig[0] == 1 else 0.0
	for model in [_wizard_model, _staff_model]:
		if model:
			AssetLoader.set_model_glow(model, COMBO_GLOW_COLOR, strength)


func _host_respawn(force: bool = false) -> void:
	if not is_dead and not force:
		return  # already respawned (e.g. by respawn_all_players round reset)
	# A siege holds its dead until the wave break, which is what makes a wave worth surviving.
	# The break's own respawn goes through respawn_all_players -> spawn_at and does not come here.
	if not force and SiegeSystem.holds_respawn():
		get_tree().create_timer(1.0).timeout.connect(_host_respawn)
		return
	# Resolve the spawn for the team we'll land on (honoring a queued class/team change) BEFORE
	# touching any state — a null spawn must abort cleanly.
	var next_team: int = class_change_pending_team if class_change_pending_team >= 0 else team
	var sp := SpawnSystem.get_spawn_for_team(next_team)
	if sp == null:
		# No active spawn right now (spawns toggled off on a control map, or a transient gap). Do NOT
		# fall through: spawn_at() clears is_dead unconditionally while sync_spawn_to_network's
		# is_instance_valid(sp) guard skips assign_spawn — which strands the owner's view in the
		# spectator cam (puppet "alive", view never un-spectated). Stay dead, keep any pending change,
		# and retry shortly. The owner-view respawn watchdog (local_player) is the last-resort backstop.
		Log.warn("[Respawn] _host_respawn peer=%d: no active spawn for team %d (is_dead=%s force=%s) — retry in 1s" % [
			peer_id, next_team, is_dead, force])
		get_tree().create_timer(1.0).timeout.connect(_host_respawn.bind(force))
		return
	Log.debug("[Respawn] _host_respawn peer=%d team=%d (is_dead=%s force=%s)" % [peer_id, next_team, is_dead, force])
	# Apply a class/team change queued via die_for_class_change now that the
	# respawn delay has elapsed. Combat deaths and class-change deaths share this
	# timer, so the pending role is honored however the player died.
	var applied_change := class_change_pending_team >= 0
	if applied_change:
		team = class_change_pending_team
		set_element(class_change_pending_element)
		class_change_pending_team = -1
		class_change_pending_element = -1
	# Beanstalks and thornplants persist across death and forced-respawn —
	# only class/team change destroys them (see cleanup_for_class_change).
	# Move to spawn BEFORE re-enabling collision and marking alive,
	# so trigger_hurt at old position can't kill us during teleport.
	# Sync assign_spawn to the client BEFORE mount effects so that
	# assign_spawn (which dismounts) arrives first; sync_dragon_mount follows.
	spawn_at(sp, element, true, false)
	sync_spawn_to_network(sp)
	_apply_spawn_point_effects(sp)
	# Tell every peer about the new team/element so remote puppets re-color and
	# friendly-fire stays correct after a class change. The RPC is call_remote, so the host's own
	# copy of the roster has to be written here or it keeps the pre-change team forever.
	if applied_change:
		NetworkManager.set_player_team(peer_id, team)
		NetworkManager.sync_team_for_peer.rpc(peer_id, team, element, global_position, rotation.y)


func play_attack() -> void:
	if not _attack_player:
		return
	var current_weapon: Weapon = weapons[current_weapon_idx] if current_weapon_idx < weapons.size() else null
	var anim: String
	if current_weapon:
		anim = current_weapon.get_attack_anim(sync_crouched)
	elif sync_crouched:
		anim = "crouch_shoot_staff"
	else:
		anim = "ref_shoot_staff"
	# Player models share one generic third-person shoot pose; most weapons have no bespoke
	# ref_shoot_<prefix> sequence, so fall back to the staff shoot instead of playing nothing.
	if not _attack_player.has_animation(anim):
		anim = "crouch_shoot_staff" if sync_crouched else "ref_shoot_staff"
	if not _attack_player.has_animation(anim):
		Log.warn("Attack anim '%s' not found" % anim)
		return
	var anim_res := _attack_player.get_animation(anim)
	anim_res.loop_mode = Animation.LOOP_NONE
	# play() resumes a clip already running rather than restarting it, so a weapon whose swing
	# outlasts its cooldown (0.54s of ref_shoot_staff against the staffs' 0.5s) finished one
	# swing per TWO shots and read as half speed. Restart, as the first-person hands do.
	_attack_player.stop()
	_attack_player.play(anim)
	if current_weapon:
		# Sound is handled by weapon.fire() called from _on_sync_attack
		if not _attack_player.animation_finished.is_connected(_on_attack_finished):
			_attack_player.animation_finished.connect(_on_attack_finished)


func _on_attack_finished(_anim_name: StringName) -> void:
	if _attack_player.animation_finished.is_connected(_on_attack_finished):
		_attack_player.animation_finished.disconnect(_on_attack_finished)


## Host: called when a player switches team/class. A live player enters the normal
## death state and respawns with the pending team/element after RESPAWN_DELAY; an
## already-dead player just records the pending role so the in-flight respawn timer
## (combat or a prior change) applies it on fire. This makes opening the class menu
## while dead unable to shorten the delay. Safe to call repeatedly while counting
## down — it only updates the pending values.
func die_for_class_change(pending_team: int, pending_element: int) -> void:
	class_change_pending_team = pending_team
	class_change_pending_element = pending_element
	if is_dead:
		return  # respawn timer already running; pending values are used when it fires
	is_dead = true
	sync_firing = false  # clear authoritative beam state across the class change
	visible = false
	is_respawning = true
	# Same deferred, liveness-derived disable as _on_died — never a raw latch that a
	# same-frame revive could clobber (see sync_collider_to_liveness).
	call_deferred(&"sync_collider_to_liveness")
	remove_from_group("damageable")
	StatusSystem.clear_all(self)
	
	if _server_movement:
		_server_movement.clear_queue()
	NetworkManager.broadcast_player_death(peer_id, 0)
	# Reuse the shared respawn path; it consumes the pending class/team and
	# broadcasts it when the timer fires. (Godot auto-disconnects this if the
	# puppet is freed first, so no manual validity guard is needed.)
	get_tree().create_timer(RESPAWN_DELAY).timeout.connect(_host_respawn)
