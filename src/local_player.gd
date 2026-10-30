## Local first-person player — input, camera, client-side prediction, HUD.
class_name LocalPlayer
extends "res://src/player.gd"
# Movement is inherited from the Player base.


@onready var camera: Camera3D = $Camera3D
@onready var collision_shape: CollisionShape3D = $CollisionShape3D

signal vr_menu_requested(class_only: bool)

## Set by main.gd before add_child — the single XRRig camera used for all VR rendering.
var xr_camera: Camera3D = null
var xr_rig: Node3D = null
var xr_left: XRController3D = null
var xr_right: XRController3D = null

const InputCommand = preload("res://addons/pmove/input_command.gd")
const InputSettings = preload("res://src/systems/input_settings.gd")
const KeyBindings = preload("res://src/systems/key_bindings.gd")
const SCALE := GameConsts.SCALE_FACTOR
## The stock feel, which the [input] sensitivity setting multiplies.
const MOUSE_SENSITIVITY := 0.002

# Mouse look, read from settings.cfg once per spawn rather than per event — _unhandled_input runs
# on every motion the OS reports, which at a high polling rate is hundreds of times a second.
var _invert_mouse := InputSettings.DEFAULT_INVERT
var _mouse_sensitivity := MOUSE_SENSITIVITY

var _hand_anim_player: AnimationPlayer
var _hand_skeleton: Skeleton3D
var _hand_model: Node3D
var _vr_right_hand_model: Node3D = null
var _vr_left_hand_model: Node3D = null
## [glowing, hand model id, VR right id, VR left id] last pushed at the materials.
var _glow_signature: Array[int] = []
var _vr_right_hand_skeleton: Skeleton3D = null
var _vr_left_hand_skeleton: Skeleton3D = null
var _vr_right_hand_offset := Vector3.ZERO  # model-local offset from origin to R Hand bone
var _vr_left_hand_offset := Vector3.ZERO   # model-local offset from origin to L Hand bone
# Built at setup time from bone name lookups — works regardless of skeleton layout.
var _vr_right_bone_map: Array = []
var _vr_left_bone_map: Array = []
var _vr_hand_sync_timer := 0.0

# BASE matrices map hand bone local axes to controller-space axes:
# - WIZARD convention: hand bone X is along-bone (forearm→hand direction).
#   BASE_R sends hand X → ctrl -Z (forward), hand Y → ctrl +Y (up), hand Z → ctrl +X.
#   BASE_L mirrors for left hand.
# - BEAR convention: hand bone Y is along-bone (forearm→hand direction).
#   BASE_BEAR sends hand Y → ctrl -Z (forward), hand Z → ctrl -Y (claws down),
#   hand X → ctrl -X. Same matrix works for both R and L since the L hand's
#   bone basis is naturally mirrored.
# Detection picks BASE_BEAR if hand bone Y is most aligned with forearm→hand,
# otherwise BASE_R/L.
const _VR_WRIST_CALIB_BASE_R := Basis(Vector3(0.0, 0.0, -1.0), Vector3(0.0, 1.0, 0.0), Vector3(1.0, 0.0, 0.0))
const _VR_WRIST_CALIB_BASE_L := Basis(Vector3(0.0, 0.0, -1.0), Vector3(0.0, -1.0, 0.0), Vector3(-1.0, 0.0, 0.0))
const _VR_WRIST_CALIB_BASE_BEAR := Basis(Vector3(-1.0, 0.0, 0.0), Vector3(0.0, 0.0, -1.0), Vector3(0.0, -1.0, 0.0))
# Anchor offset along the arm direction (root→hand). Positive pulls the model
# toward the user (anchor past the wrist toward fingertips); negative pushes
# it forward. Tuned empirically against the OpenXR grip pose.
const _VR_WRIST_TO_PALM := -0.1
var _vr_right_hand_calib := Basis.IDENTITY
var _vr_left_hand_calib := Basis.IDENTITY

# Bone name → OpenXR joint index for each hand side.
const _VR_R_BONE_JOINT_NAMES: Array = [
	["Bip01 R Hand",     1],  # WRIST
	["Bip01 R Finger0",  2],  ["Bip01 R Finger01", 3],  ["Bip01 R Finger02", 4],
	["Bip01 R Finger1",  7],  ["Bip01 R Finger11", 8],  ["Bip01 R Finger12", 9],
	["Bip01 R Finger2",  12], ["Bip01 R Finger21", 13], ["Bip01 R Finger22", 14],
	["Bip01 R Finger3",  17], ["Bip01 R Finger31", 18], ["Bip01 R Finger32", 19],
	["Bip01 R Finger4",  22], ["Bip01 R Finger41", 23], ["Bip01 R Finger42", 24],
]
const _VR_L_BONE_JOINT_NAMES: Array = [
	["Bip01 L Hand",     1],  # WRIST
	["Bip01 L Finger0",  2],  ["Bip01 L Finger01", 3],  ["Bip01 L Finger02", 4],
	["Bip01 L Finger1",  7],  ["Bip01 L Finger11", 8],  ["Bip01 L Finger12", 9],
	["Bip01 L Finger2",  12], ["Bip01 L Finger21", 13], ["Bip01 L Finger22", 14],
	["Bip01 L Finger3",  17], ["Bip01 L Finger31", 18], ["Bip01 L Finger32", 19],
	["Bip01 L Finger4",  22], ["Bip01 L Finger41", 23], ["Bip01 L Finger42", 24],
]

var _hud: CanvasLayer  # cached HUD reference (set by main.gd after HUD is created)
var spectating := false
var noclip := false  # set by server via /noclip; used for client-side prediction
var _debug_render_root: Node3D = null  # F3 debug render meshes container (occluders, hitboxes)
var _respawn_timer: SceneTreeTimer
# A rare race can drop the body puppet's assign_spawn, stranding the view in spectator cam
# forever. The watchdog re-checks a grace past the normal respawn and force-respawns if
# still stuck. _death_seq disambiguates a later death's watchdog.
const RESPAWN_WATCHDOG_GRACE := 2.0
var _death_seq := 0
var _sustained_started := false  # true after first fire of a sustained weapon (paid initial mana_cost)
## FireControl buttons as the input left them, plus those pressed since the last command, so a click
## that comes and goes inside one frame still reaches a command.
var _attack_down := 0
var _attack_tapped := 0
var _weapon_select := -1  # slot switched to since the last command: its weaponselect
var _pending_dragon_mount_id := -1  # mount confirmed before the dragon replica existed
var _satchel_cooldown := 0.0
var _deny_sound: AudioStream
var _pre_bear_speed_multiplier := 1.0
# Network ring buffer — always recording, flush with _flush_net_dump() when needed
var _net_ring: Array[String] = []
const NET_RING_SIZE := 600  # 10 seconds at 60Hz
# Network problem detection
var _last_correction_seq := -1   # for consecutive-correction detection
var _consecutive_corrections := 0
const ALERT_COOLDOWN := 15.0
var _prev_yaw := 0.0
var _prev_pitch := 0.0
# VR controller input state
const VR_SNAP_ANGLE := PI / 4.0      # 45° snap turn
const VR_SNAP_THRESHOLD := 0.7
const VR_TRIGGER_THRESHOLD := 0.7
const VR_CROUCH_TRIGGER := 0.4       # metres below neutral head height to trigger crouch
var _vr_snap_cooldown := 0.0
var _vr_weapon_scroll_cooldown := 0.0
var _vr_trigger_was_pressed := false
var _vr_grip_was_pressed := false
var _vr_ax_was_pressed := false
var _vr_left_ax_was_pressed := false  # left X button
var _vr_left_by_was_pressed := false  # left Y button
var _vr_charge_hand: XRController3D = null  # cast hand locked at charge-begin; cleared on release
var _vr_neutral_eye_y := -1.0        # calibrated on first advanced-tracking frame; -1 = uncalibrated
# Roomscale head tracking: feed physical head movement into the capsule.
var _vr_prev_head_play := Vector3.ZERO  # last tick's HMD XZ in play (rig-local) space
var _vr_head_seeded := false            # false until first sample (avoids a huge first-frame delta)
var _vr_head_residual := Vector3.ZERO   # world-space amount the head has out-run the (blocked) capsule
var _on_ladder := false
var _in_water := false
var _head_liquid := GameConsts.Liquid.NONE  # what the CAMERA is submerged in, for the fog
var _is_crouched := false
var _last_input_cmd: RefCounted = null  # InputCommand; last cmd for server-authoritative send

# Client-side predicted movement (netmove module)
var _movement: ClientMovement = ClientMovement.new()
var _body: GodotBody


# Camera world-space position smoothing — hides tiny prediction corrections visually.
# Physics is unaffected; only the rendered camera position is smoothed.
var _camera_world_pos := Vector3.ZERO
var _prev_camera_world_pos := Vector3.ZERO  # position from previous physics tick, for sub-frame interp
var _camera_snap_pending := true  # snap on next frame (set by teleport/respawn)
const CAMERA_SMOOTH_RATE := 20.0  # lerp speed (higher = snappier)
const CAMERA_SMOOTH_SNAP := 5.0   # snap immediately above this distance (extreme cases only)


# --- Third person ---
# The chase camera sits STRICTLY BEHIND the eye on the view axis, with no shoulder offset. That
# is what lets everything else stay first-person: the shot still leaves the eye along that same
# axis, so screen centre remains the true crosshair and the HUD needs no parallax correction.
# An over-the-shoulder rig would need one, and would have to re-derive the aim from a screen ray.
const CHASE_DISTANCE := 2.2
const CHASE_RADIUS := 0.25        # sphere swept back from the eye — its radius is the wall clearance
const CHASE_MIN_DISTANCE := 0.5   # backed against a wall: closer than this, hide the body instead

## Set together with _chase_camera and _local_avatar — third person is exactly "those exist".
var third_person := false
var _chase_camera: Camera3D = null
var _chase_query: PhysicsShapeQueryParameters3D = null  # reused each frame, never rebuilt
## The wizard everyone else sees, drawn for ourselves — a RemotePlayer in local_avatar mode, so
## it is the same model/animation/IK/glow code rather than a second one that drifts from it.
var _local_avatar: RemotePlayer = null


func get_eye_position() -> Vector3:
	var alpha := Engine.get_physics_interpolation_fraction()
	return _prev_camera_world_pos.lerp(_camera_world_pos, alpha)

func _active_camera() -> Camera3D:
	if XRManager.is_vr and is_instance_valid(xr_camera):
		return xr_camera
	return camera


## Draw-from camera only — zoom and view shake. Aim, the +use ray, the audio listener, the PVS
## observer and the head-liquid check all read _active_camera(); moving any of them here is the bug.
func _render_camera() -> Camera3D:
	return _chase_camera if third_person else _active_camera()


func _cast_hand() -> XRController3D:
	return xr_left if XRManager.left_handed else xr_right


# --- Third person ---

## Switch the view. VR is excluded outright: there the view IS the headset, and a body the
## player's own head is not inside of reads as watching someone else move your hands.
func set_third_person(enabled: bool) -> void:
	if XRManager.is_vr:
		enabled = false
	if enabled == third_person:
		return
	third_person = enabled
	# A shake tween is animating h_offset/v_offset on the camera that WAS drawing; drop it and
	# zero them, or the old camera keeps a permanent offset and the new one never gets the shake.
	if _shake_tween:
		_shake_tween.kill()
		_shake_tween = null
	camera.h_offset = 0.0
	camera.v_offset = 0.0
	if enabled:
		_build_chase_view()
	else:
		_teardown_chase_view()
	_refresh_view_target()


func _build_chase_view() -> void:
	var cam := Camera3D.new()
	cam.name = "ChaseCamera"
	cam.fov = camera.fov
	cam.near = camera.near
	cam.far = camera.far
	cam.cull_mask = camera.cull_mask  # _post_ready has already added VISUAL_LAYER_BSP
	# A sibling of the eye, not a child: _update_chase_camera writes its world pose outright from
	# the eye's own transform each frame, so nothing it inherits can nudge it off the aim axis.
	add_child(cam)
	_chase_camera = cam

	var sphere := SphereShape3D.new()
	sphere.radius = CHASE_RADIUS
	_chase_query = PhysicsShapeQueryParameters3D.new()
	_chase_query.shape = sphere
	# The mask the player themselves collide against, GoldSrc clip hulls included — those hulls
	# are all some brushwork has, so a world-only mask would let the camera into it.
	_chase_query.collision_mask = GameConsts.MASK_WORLD_AND_CLIP
	_chase_query.collide_with_areas = false
	_chase_query.collide_with_bodies = true

	_local_avatar = RemotePlayer.make_local_avatar(peer_id)
	# Parented to us so it dies with us and inherits `visible` — set_spectating already hides this
	# whole subtree. It is top_level, so our own (unsmoothed) transform never reaches it.
	add_child(_local_avatar)
	_refresh_avatar_appearance()


func _teardown_chase_view() -> void:
	if is_instance_valid(_chase_camera):
		_chase_camera.queue_free()
	_chase_camera = null
	_chase_query = null
	if is_instance_valid(_local_avatar):
		_local_avatar.queue_free()
	_local_avatar = null


## Point rendering at the eye or at the chase camera, and hide the 1P hands when they are not
## the body being drawn. The avatar's own visibility is _update_chase_camera's (it also has to
## drop the body when the camera is pushed into it), so this deliberately does not touch it.
func _refresh_view_target() -> void:
	if camera == null:
		return  # called before _ready (set_spectating from the spawn path); _post_ready re-runs it
	var chase := third_person and not spectating
	if not XRManager.is_vr:
		camera.current = not chase
		if _chase_camera:
			_chase_camera.current = chase
	if is_instance_valid(_hand_model):
		_hand_model.visible = not chase


## Sweep back from the eye and stop short of whatever is behind us. Shortening the arm is the
## only thing the trace may do — the camera stays on the aim axis whatever it returns. Pushed
## closer than CHASE_MIN_DISTANCE, the body goes rather than being drawn from inside.
func _update_chase_camera() -> void:
	var eye := camera.global_transform
	var back := eye.basis.z.normalized()  # camera forward is -Z, so +Z is directly behind
	_chase_query.transform = Transform3D(Basis.IDENTITY, eye.origin)
	_chase_query.motion = back * CHASE_DISTANCE
	var motion: PackedFloat32Array = get_world_3d().direct_space_state.cast_motion(_chase_query)
	# cast_motion returns [safe_fraction, unsafe_fraction]; safe places the sphere CENTRE just
	# before contact, so the camera already clears the wall by CHASE_RADIUS.
	var dist := CHASE_DISTANCE * motion[0] if motion.size() > 0 else CHASE_DISTANCE
	_chase_camera.global_transform = Transform3D(eye.basis, eye.origin + back * dist)
	_local_avatar.visible = dist >= CHASE_MIN_DISTANCE


## Re-apply what the copy wears. Cheap and idempotent when nothing changed, so callers on the
## loadout path can call it unconditionally.
func _refresh_avatar_appearance() -> void:
	if _local_avatar:
		_local_avatar.dress_local_avatar(element, team, is_bear, weapons, current_weapon_idx)


func _drive_local_avatar() -> void:
	# Feet come off the SMOOTHED eye the camera is drawn from, not global_position: the two
	# differ by the prediction-smoothing residual, and taking the body from the other one makes
	# it slide under the view every time a correction lands.
	var feet := camera.global_position - Vector3(0.0, _movement.state.eye_y, 0.0)
	_local_avatar.granted_weapons = granted_weapons  # combo glow reads this; shared, read-only
	_local_avatar.drive_local_avatar(feet, global_rotation.y, camera.rotation.x, _is_crouched,
		velocity, _movement.state.is_jumping, is_invisible, is_dragon_mounted, _in_water)


# get_broadcast_flags is not overridden here: the view is never broadcast — the
# host's snapshot state comes from its body puppet (player-unification Phase 2b).

func set_spectating(enabled: bool) -> void:
	spectating = enabled
	# Deferred: set_spectating() can be called from a physics callback (e.g. _on_died()
	# via trigger_hurt._on_body_entered), and toggling shape state mid-query-flush errors.
	collision_shape.set_deferred("disabled", enabled)
	visible = not enabled
	set_damageable(not enabled)
	_refresh_view_target()  # the spectator cam is always first person


func _post_ready() -> void:
	ClientCommandSystem.register("render", _cmd_render, "/render [wireframe|debug|normal]", "Toggle render debug mode.")
	ClientCommandSystem.register("pos", _cmd_pos, "/pos [on|off]", "Toggle a live position readout (Godot + GoldSrc units).")
	ClientCommandSystem.register("invertmouse", _cmd_invert_mouse, "/invertmouse [on|off]",
			"Invert vertical mouse look. No argument toggles it.")
	ClientCommandSystem.register("sensitivity", _cmd_sensitivity, "/sensitivity [%.2f-%.2f]" % [
			InputSettings.SENSITIVITY_MIN, InputSettings.SENSITIVITY_MAX],
			"Mouse look speed, as a multiplier of the stock feel. No argument reports it.")
	ClientCommandSystem.register("thirdperson", _cmd_third_person, "/thirdperson [on|off]",
			"Watch your own wizard from behind. No argument toggles it.")
	_reload_input_settings()
	# Match server puppet (remote_player.gd) physics properties exactly so client-side
	# prediction produces the same move_and_slide results as the server.
	collision_mask = GameConsts.MASK_WORLD_AND_CLIP | GameConsts.MASK_ENTITY | GameConsts.MASK_PLAYER
	collision_layer = GameConsts.MASK_PLAYER
	floor_block_on_wall = false
	safe_margin = 0.01
	# Mover carry is explicit (netmove carry_motion via PlayerMovementContext);
	# disable Godot's built-in platform velocity so it can never double-apply.
	platform_floor_layers = 0
	platform_wall_layers = 0
	# Disable Godot physics interpolation on the local player subtree.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_body = GodotBody.new(self, PackedStringArray(["LadderDetector/CollisionShape3D"]))
	_movement.bind_body(_body)
	var active_cam := _active_camera()
	camera.current = not XRManager.is_vr
	active_cam.current = true
	active_cam.cull_mask |= GameConsts.VISUAL_LAYER_BSP
	_base_fov = active_cam.fov
	var listener := AudioListener3D.new()
	listener.name = "AudioListener"
	active_cam.add_child(listener)
	listener.make_current()
	_deny_sound = _create_deny_sound()
	# After the eye camera is fully set up: the chase camera is cloned from it, and a map change
	# rebuilds this node, so without the saved value third person would drop out every map.
	set_third_person(InputSettings.load_third_person())
	if XRManager.is_vr:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _on_healed(_amount: float, _allow_overheal: bool) -> void:
	_clear_all_statuses()
	if _hud:
		_hud.update_health(health, max_health)


func _on_damage_applied(_amount: float) -> void:
	Log.debug("Player took %.1f damage (HP: %.0f/%.0f)" % [_amount, health, max_health])
	if _hud:
		_hud.update_health(health, max_health)
		_hud.flash_damage()


func _on_died(_attacker: Node3D, type: int = GameConsts.DamageType.PHYSICAL,
		damage: float = 0.0) -> void:
	if _hud:
		_hud.update_health(health, max_health)
	_clear_all_statuses()
	if weapon:
		weapon.stop_firing(self, true)  # reset secondary state (e.g. zoom)
	var death_velocity := corpse_velocity(velocity)
	_movement.clear()
	_pending_server_states.clear()
	_last_input_cmd = null
	set_spectating(true)
	# Spawn corpse at death position — offline only. Online (host included) the
	# body puppet's death path spawns the corpse and broadcasts sync_player_death;
	# this local die() is the view-side presentation triggered by that broadcast.
	# Offline the view is the authority, so the raising's no-corpse rule is applied here too
	# (online it is the host puppet's death that spawns the body — see RemotePlayer._on_died).
	if not NetworkManager.is_online() and Player.death_type_leaves_corpse(type):
		# Only third person has a body skeleton to read a pose off — in first person the
		# only models we own are the hands. Empty means the corpse starts from rest, which
		# is what it always did, and a death that bursts has no body to pose at all.
		var pose := _local_avatar.capture_bone_pose() \
			if is_instance_valid(_local_avatar) and not GameConsts.damage_gibs(damage) \
			else PackedFloat32Array()
		TumblingCorpse.spawn_wizard_remains(get_tree().current_scene, global_position,
			rotation.y, element, death_velocity, pose, damage)
	_respawn_timer = get_tree().create_timer(RESPAWN_DELAY)
	_respawn_timer.timeout.connect(_respawn)
	# Safety net for a dropped respawn (see RESPAWN_WATCHDOG_GRACE). Online only — offline _respawn
	# spawns us directly and can't be dropped.
	if NetworkManager.is_online():
		_death_seq += 1
		var seq := _death_seq
		get_tree().create_timer(RESPAWN_DELAY + RESPAWN_WATCHDOG_GRACE).timeout.connect(
			func(): _respawn_watchdog(seq))
	Log.info("Player died")


## Recover a stranded spectator whose assign_spawn never arrived. As host, re-run our own
## body puppet's respawn (force=true bypasses its is_dead guard); as a client, re-request our
## current role. `seq` guards against acting on a death a later respawn/death superseded.
func _respawn_watchdog(seq: int) -> void:
	if seq != _death_seq or not spectating or not is_dead:
		return
	var puppet := NetworkManager.get_player(peer_id)
	# Diagnostic: puppet.is_dead tells us which path stranded us — still true means its
	# respawn never delivered; false means assign_spawn was skipped (see _host_respawn).
	var puppet_dead: Variant = puppet.get("is_dead") if puppet and puppet != self else "n/a"
	Log.warn("[Respawn] watchdog: still spectator-dead %.0fs after death (puppet.is_dead=%s) — forcing respawn"
		% [RESPAWN_DELAY + RESPAWN_WATCHDOG_GRACE, puppet_dead])
	if NetworkManager.is_host():
		if puppet and puppet != self and puppet.has_method("_host_respawn"):
			puppet._host_respawn(true)
	elif team != GameConsts.Team.NONE:
		NetworkManager.send_request_join_team(team, element)


## Set camera zoom to the given FOV. Pass 0.0 to restore the default FOV.
func set_zoom(fov: float) -> void:
	if XRManager.is_vr:
		return
	var f := fov if fov > 0.0 else _base_fov
	camera.fov = f
	if is_instance_valid(_chase_camera):
		_chase_camera.fov = f  # both, so toggling the view mid-zoom doesn't lose it


func set_weapon(new_weapon: Weapon) -> void:
	_end_trigger()
	if weapon:
		weapon.stop_firing(self, true)  # reset any secondary state (e.g. zoom)

	if _hand_model and is_instance_valid(_hand_model):
		_hand_model.queue_free()
	_hand_anim_player = null
	_hand_skeleton = null
	_hand_model = null

	weapon = new_weapon
	if not weapon:
		return

	# VR hand-tracking uses full hand models managed by set_loadout(); nothing to do per weapon.
	if XRManager.is_vr and XRManager.hand_tracking:
		return

	var hand_model = AssetLoader.load_model(weapon.hand_model_path)
	if hand_model:
		AssetLoader.strip_hitboxes(hand_model)  # a viewmodel is not a target; on a listen host it ate our own hitscans
		hand_model.visible = not third_person  # the chase view's body is the avatar, not these
		_active_camera().add_child(hand_model)
		AssetLoader.set_model_skin(hand_model, team)
		_hand_model = hand_model
		_hand_anim_player = hand_model.find_child("AnimationPlayer")
		_hand_skeleton = hand_model.find_child("Skeleton3D")
		if _invis_alpha < 1.0:
			AssetLoader.set_model_alpha(_hand_model, _invis_alpha)
		if _hand_anim_player:
			_play_hand_idle()
			_hand_anim_player.animation_finished.connect(_on_hand_anim_finished)
	_refresh_avatar_appearance()  # the staff and element the copy wears come from the loadout


## Return the 1P hands to their idle pose. Guards has_animation like
## Weapon.play_attack_anim: hand models vary per element, and a name none of them
## carries would otherwise error on every call.
func _play_hand_idle() -> void:
	if not _hand_anim_player or not weapon:
		return
	if _hand_anim_player.has_animation(weapon.hand_idle_anim):
		_hand_anim_player.play(weapon.hand_idle_anim)


func _on_charge_backfire() -> void:
	fire.charging = false
	if weapon:
		fire.start_cooldown(weapon)


func set_loadout(loadout: Array[Weapon]) -> void:
	if _vr_right_hand_model and is_instance_valid(_vr_right_hand_model):
		_vr_right_hand_model.queue_free()
	_vr_right_hand_model = null
	_vr_right_hand_skeleton = null
	if _vr_left_hand_model and is_instance_valid(_vr_left_hand_model):
		_vr_left_hand_model.queue_free()
	_vr_left_hand_model = null
	_vr_left_hand_skeleton = null
	for w in weapons:
		w.stop_firing(self)
		w.cleanup(self)
	weapons = loadout
	current_weapon_idx = 0
	if weapons.size() > 0:
		set_weapon(weapons[0])
	if _hud:
		_hud.update_weapon_row(weapons, current_weapon_idx)
	if XRManager.is_vr and XRManager.hand_tracking:
		_setup_vr_hand_models()


func _apply_spawn_loadout(wizard: Wizard) -> void:
	set_loadout(with_granted(wizard.weapons))


## The puppet's append plus the HUD row, so a picked-up spell shows in the weapon wheel
## right away instead of at the next loadout rebuild.
func add_granted_weapon(key: String) -> bool:
	if not super(key):
		return false
	if _hud:
		_hud.update_weapon_row(weapons, current_weapon_idx)
	return true


## The mirror, for a spell that spends itself. set_weapon() too, not just the row: the slot the
## view was holding is gone, so the hand model and cooldown have to follow what replaced it.
func remove_granted_weapon(key: String) -> bool:
	if not super(key):
		return false
	var replacement := weapon_at(current_weapon_idx)
	if replacement:
		set_weapon(replacement)
	if _hud:
		_hud.update_weapon_row(weapons, current_weapon_idx)
	return true


func _get_vr_hand_model_path() -> String:
	for w in weapons:
		if not w.hand_model_path.is_empty():
			return w.hand_model_path
	return ""


# Build VR wrist calibration by detecting which hand bone axis runs along the
# bone (forearm → hand), then applying the matching BASE matrix. Wizards use
# the X-along-bone convention; bear uses Y-along-bone.
static func _vr_calib_from_rest(skel: Skeleton3D, hand_idx: int, base_wizard: Basis) -> Basis:
	var rest := skel.get_bone_global_rest(hand_idx)
	var parent := skel.get_bone_parent(hand_idx)
	if parent < 0:
		return base_wizard * rest.basis.inverse()
	var bone_dir := (rest.origin - skel.get_bone_global_rest(parent).origin).normalized()
	if bone_dir.length_squared() < 1e-4:
		return base_wizard * rest.basis.inverse()
	var ax := absf(rest.basis.x.dot(bone_dir))
	var ay := absf(rest.basis.y.dot(bone_dir))
	var az := absf(rest.basis.z.dot(bone_dir))
	if ay > ax and ay > az:
		return _VR_WRIST_CALIB_BASE_BEAR * rest.basis.inverse()
	return base_wizard * rest.basis.inverse()


func _setup_vr_hand_models() -> void:
	var path := _get_vr_hand_model_path()
	Log.info("VRHands: setup path=%s registered_trackers=%s" % [path, XRServer.get_trackers(0xFF).keys()])
	if path.is_empty():
		return
	_vr_right_hand_model = _setup_one_vr_hand(path, true)
	_vr_left_hand_model  = _setup_one_vr_hand(path, false)


func _setup_one_vr_hand(path: String, is_right: bool) -> Node3D:
	var model := AssetLoader.load_model(path)
	if not model:
		return null
	AssetLoader.strip_hitboxes(model)
	AssetLoader.set_model_skin(model, team)
	add_child(model)
	var anim := model.find_child("AnimationPlayer") as AnimationPlayer
	if anim:
		anim.active = false
	var skel := model.find_child("Skeleton3D") as Skeleton3D
	if skel:
		var name_map: Dictionary = {}
		for i in skel.get_bone_count():
			name_map[skel.get_bone_name(i)] = i
		var l_arm := (name_map.get("Bip01 L Arm", name_map.get("Hands biped L UpperArm", -1))) as int
		var r_arm := (name_map.get("Bip01 R Arm", name_map.get("Hands biped R UpperArm", -1))) as int
		var hand_l := (name_map.get("Bip01 L Hand", name_map.get("Hands biped L Hand", -1))) as int
		var hand_r := (name_map.get("Bip01 R Hand", name_map.get("Hands biped R Hand", -1))) as int
		if is_right:
			if l_arm >= 0:
				skel.set_bone_pose_position(l_arm, Vector3(0.0, -1000.0, 0.0))
			_vr_right_hand_skeleton = skel
			if hand_r >= 0:
				var rest_r := skel.get_bone_global_rest(hand_r)
				_vr_right_hand_offset = skel.transform * (rest_r.origin + rest_r.origin.normalized() * _VR_WRIST_TO_PALM)
				_vr_right_hand_calib = _vr_calib_from_rest(skel, hand_r, _VR_WRIST_CALIB_BASE_R)
			_vr_right_bone_map = []
			for pair in _VR_R_BONE_JOINT_NAMES:
				var idx: int = name_map.get(pair[0], -1)
				if idx >= 0:
					_vr_right_bone_map.append([idx, pair[1]])
		else:
			if r_arm >= 0:
				skel.set_bone_pose_position(r_arm, Vector3(0.0, -1000.0, 0.0))
			_vr_left_hand_skeleton = skel
			if hand_l >= 0:
				var rest_l := skel.get_bone_global_rest(hand_l)
				_vr_left_hand_offset = skel.transform * (rest_l.origin + rest_l.origin.normalized() * _VR_WRIST_TO_PALM)
				_vr_left_hand_calib = _vr_calib_from_rest(skel, hand_l, _VR_WRIST_CALIB_BASE_L)
			_vr_left_bone_map = []
			for pair in _VR_L_BONE_JOINT_NAMES:
				var idx: int = name_map.get(pair[0], -1)
				if idx >= 0:
					_vr_left_bone_map.append([idx, pair[1]])
		# Bake idle animation onto finger bones once; arm bones reset to rest afterward
		# so global_transform calibration is unaffected.
		var idle_anim_name := ""
		for w in weapons:
			if not w.hand_idle_anim.is_empty():
				idle_anim_name = w.hand_idle_anim
				break
		var bone_map_ref: Array = _vr_right_bone_map if is_right else _vr_left_bone_map
		if anim and not idle_anim_name.is_empty() and anim.has_animation(idle_anim_name):
			anim.active = true
			anim.play(idle_anim_name)
			anim.seek(0.0, true)
			anim.active = false
			var finger_poses: Dictionary = {}
			for i in range(1, bone_map_ref.size()):
				var target_bone_idx: int = bone_map_ref[i][0]
				if is_right:
					# Animation has R finger tracks — read directly.
					finger_poses[target_bone_idx] = skel.get_bone_pose_rotation(target_bone_idx)
				else:
					# Animation only has R finger tracks; mirror to L by reading the
					# corresponding R bone — biped local frames are already mirrored so
					# the same quaternion produces symmetric curl on the left side.
					if i <= 3:
						continue  # left thumb has different local frame; rest pose is fine
					var r_bone_idx: int = name_map.get(_VR_R_BONE_JOINT_NAMES[i][0], -1)
					if r_bone_idx >= 0:
						finger_poses[target_bone_idx] = skel.get_bone_pose_rotation(r_bone_idx)
			for bi in skel.get_bone_count():
				skel.reset_bone_pose(bi)
			if is_right:
				if l_arm >= 0:
					skel.set_bone_pose_position(l_arm, Vector3(0.0, -1000.0, 0.0))
			else:
				if r_arm >= 0:
					skel.set_bone_pose_position(r_arm, Vector3(0.0, -1000.0, 0.0))
			for bidx in finger_poses:
				skel.set_bone_pose_rotation(bidx, finger_poses[bidx])
	return model


func _update_vr_hand_models() -> void:
	_update_one_vr_hand(true)
	_update_one_vr_hand(false)


func _update_one_vr_hand(is_right: bool) -> void:
	var model: Node3D = _vr_right_hand_model if is_right else _vr_left_hand_model
	var skel: Skeleton3D = _vr_right_hand_skeleton if is_right else _vr_left_hand_skeleton
	var hand_offset: Vector3 = _vr_right_hand_offset if is_right else _vr_left_hand_offset
	var hand_ctrl: XRController3D = xr_right if is_right else xr_left

	if not is_instance_valid(model) or not is_instance_valid(skel):
		return
	if not is_instance_valid(hand_ctrl) or not hand_ctrl.get_is_active():
		if Engine.get_process_frames() % 300 == 0:
			Log.info("VRHands %s: ctrl inactive" % ["R" if is_right else "L"])
		model.visible = false
		return
	model.visible = true
	var wrist_xform := hand_ctrl.global_transform
	var calib := _vr_right_hand_calib if is_right else _vr_left_hand_calib
	var model_basis := wrist_xform.basis * calib
	model.global_transform = Transform3D(model_basis,
		wrist_xform.origin - model_basis * hand_offset)


func apply_local_spawn_state(new_element: int = -1, reload_loadout: bool = true, dismount: bool = true) -> void:
	reset_for_spawn(new_element, reload_loadout, dismount)
	_on_spawn_state_reset()


func _on_spawn_state_reset() -> void:
	_clear_all_statuses()
	_pending_dragon_mount_id = -1  # reset_for_spawn dismounts; don't replay a parked mount
	var dragon_loop := get_node_or_null("DragonFlyLoop")
	if dragon_loop:
		dragon_loop.queue_free()
	if _hand_model:
		AssetLoader.set_model_alpha(_hand_model, 1.0)
	if _hud:
		# reset_for_spawn always dismounts, so the bar goes back to mana even if
		# the server's dismount confirmation hasn't landed yet.
		_hud.set_flame_mode(false)
		_hud.update_health(health, max_health)
		_hud.update_mana(mana, max_mana)
		_hud.update_satchels(satchel_pack.count, element)
		_hud.update_weapon_row(weapons, current_weapon_idx)


func _on_spawn_transform_applied() -> void:
	if camera and not XRManager.is_vr:
		camera.rotation = Vector3.ZERO
		_view_punch = 0.0  # or the decay writes the old roll straight back onto the fresh camera
	set_spectating(false)
	move_and_slide()
	reset_movement()


func start_invisibility() -> void:
	is_invisible = true


func stop_invisibility() -> void:
	is_invisible = false


func _update_invis_alpha(delta: float) -> void:
	_update_invis_alpha_common(delta, Vector2(velocity.x, velocity.z).length(),
		[_hand_model, _vr_right_hand_model, _vr_left_hand_model])


## The carrier's half of the combo-spell glow: everyone else sees it on the wizard and the staff
## (RemotePlayer._update_combo_glow), and the wizard holding it sees it on their own hands, which
## is the only part of themselves they can see. Same signature check, and the hand models are in
## it because set_weapon rebuilds them on every switch — a fresh model wears no glow until this
## puts one back on it. An invisible wizard doesn't glow, in either view.
func _update_combo_glow() -> void:
	var sig: Array[int] = [
		1 if has_combo_weapon() and not is_invisible else 0,
		_hand_model.get_instance_id() if _hand_model else 0,
		_vr_right_hand_model.get_instance_id() if _vr_right_hand_model else 0,
		_vr_left_hand_model.get_instance_id() if _vr_left_hand_model else 0,
	]
	if sig == _glow_signature:
		return
	_glow_signature = sig
	var strength := COMBO_GLOW_STRENGTH if sig[0] == 1 else 0.0
	for model in [_hand_model, _vr_right_hand_model, _vr_left_hand_model]:
		if model:
			AssetLoader.set_model_glow(model, COMBO_GLOW_COLOR, strength)


## Called from BearSpellWeapon.fire() on the local client node.
func client_bear_morph() -> void:
	# Offline only: online (host included) the fire request reaches the body
	# puppet, whose toggle_bear_form broadcasts sync_bear_morph — the view then
	# applies it via on_bear_morph_confirmed. No local state change here avoids
	# prediction desync.
	if not NetworkManager.is_online():
		_toggle_bear_form()


# has_server_movement()/get_server_movement() are inherited from the Player base
# (false/null): this node is only the predicted first-person view — the host's
# server-side simulation runs on its body puppet (main._register_host_player).


## Toggle bear/wizard form locally (used by host/offline and auto-revert).
func _toggle_bear_form() -> void:
	is_bear = not is_bear
	_bear_mana_drain_timer = 0.0
	if is_bear:
		SoundSystem.spawn_on(self, "spells/bearmorph.wav")
	var ew := EarthWizard.new()
	if is_bear:
		var health_frac := health / max_health
		max_health = EarthWizard.BEAR_MAX_HEALTH
		health = health_frac * max_health
		_pre_bear_speed_multiplier = speed_multiplier
		speed_multiplier = EarthWizard.BEAR_SPEED
		set_loadout(ew.make_bear_loadout())
	else:
		var health_frac := health / max_health
		max_health = ew.max_health
		health = health_frac * max_health
		speed_multiplier = _pre_bear_speed_multiplier
		set_loadout(with_granted(ew.weapons))
	if _hud:
		_hud.update_health(health, max_health)


func _on_bear_drain_tick() -> void:
	if _hud:
		_hud.update_mana(mana, max_mana)


func _on_bear_mana_empty() -> void:
	# Offline only — online the body puppet owns bear drain and its auto-revert.
	_toggle_bear_form()


## Called from main.gd when sync_bear_morph arrives for this peer.
## Applies the server's authoritative bear state to the local client.
func on_bear_morph_confirmed(new_is_bear: bool, new_health: float, new_max_health: float) -> void:
	is_bear = new_is_bear
	_bear_mana_drain_timer = 0.0
	max_health = new_max_health
	health = new_health
	var ew := EarthWizard.new()
	if new_is_bear:
		_pre_bear_speed_multiplier = Wizard.create(element).speed_multiplier
		speed_multiplier = EarthWizard.BEAR_SPEED
		set_loadout(ew.make_bear_loadout())
	else:
		speed_multiplier = _pre_bear_speed_multiplier
		set_loadout(with_granted(ew.weapons))
	if new_is_bear:
		SoundSystem.spawn_on(self, "spells/bearmorph.wav")
	if _hud:
		_hud.update_health(health, max_health)


func _on_dragon_mount_authority(dragon: Node) -> void:
	# Update loadout and HUD for the host player
	on_dragon_mount_confirmed(dragon.entity_id, true)


func _on_dragon_dismount_authority(_dragon: Node) -> void:
	# Revert loadout and HUD for the host player
	on_dragon_mount_confirmed(-1, false)


## Called from main.gd when sync_dragon_mount arrives for this peer.
func on_dragon_mount_confirmed(entity_id: int, mounted: bool) -> void:
	_pending_dragon_mount_id = -1
	if mounted:
		var dragon = NetworkManager.get_synced_entity(entity_id)
		if not is_instance_valid(dragon):
			# Spawner and RPC streams aren't ordered, so the mount can beat its dragon.
			_pending_dragon_mount_id = entity_id
			Log.info("Dragon mount %d parked: replica not here yet" % entity_id)
			return
		mount_dragon(dragon)
		_mounted_dragon.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		set_loadout([DragonBreathWeapon.new(dragon, element)])
		SoundSystem.spawn_on(self, "monster/dragon/dragon_fly1.wav", true, 20.0, "DragonFlyLoop")
		if _hud:
			# Assume full until the dragon's own count lands. The mount push follows
			# immediately; a late-join resync (sync_state_to_peer) sends no flame, so
			# this prime is the only value there until the next shot or regen tick.
			_hud.set_flame_mode(true)
			_hud.update_flame(Dragon.MAX_FLAME, Dragon.MAX_FLAME)
	else:
		if is_dragon_mounted:
			if is_instance_valid(_mounted_dragon):
				_mounted_dragon.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_INHERIT
			dismount_dragon()
		var snd := get_node_or_null("DragonFlyLoop")
		if snd:
			snd.queue_free()
		var wizard := Wizard.create(element)
		set_loadout(with_granted(wizard.weapons))
		if _hud:
			_hud.set_flame_mode(false)
			_hud.update_mana(mana, max_mana)


## A replicated entity just landed — retry a mount that arrived before its dragon.
func retry_pending_dragon_mount() -> void:
	if _pending_dragon_mount_id >= 0:
		on_dragon_mount_confirmed(_pending_dragon_mount_id, true)


func _switch_weapon(direction: int) -> void:
	if weapons.size() <= 1:
		return
	var new_idx := (current_weapon_idx + direction) % weapons.size()
	if new_idx < 0:
		new_idx += weapons.size()
	_switch_weapon_to(new_idx)


func _switch_weapon_to(new_idx: int) -> void:
	if new_idx == current_weapon_idx:
		return
	var old_idx := current_weapon_idx
	if old_idx >= 0 and old_idx < weapons.size():
		weapons[old_idx].stop_firing(self)
	_last_weapon_idx = old_idx
	current_weapon_idx = new_idx
	set_weapon(weapons[current_weapon_idx])  # ends the old weapon's hold or charge
	Log.debug("Switched to weapon %d/%d" % [current_weapon_idx + 1, weapons.size()])
	if _hud:
		_hud.update_weapon_row(weapons, current_weapon_idx)
	_weapon_select = current_weapon_idx


func on_hit_confirmed(lethal := false) -> void:
	if _hud:
		_hud.flash_hit(lethal)


func _on_sync_mana(new_mana: float, new_satchels: int) -> void:
	mana = new_mana
	satchel_pack.count = new_satchels
	if _hud:
		_hud.update_mana(mana, max_mana)
		_hud.update_satchels(satchel_pack.count, element)
	# Server is the authority on mana; if it hits zero while we're sustaining a
	# drain weapon, stop firing locally (mirrors what authority does in process()).
	if mana <= 0.0 and weapon and weapon.mana_drain > 0.0:
		fire.end_hold(self)


func _on_sync_dragon_flame(flame: int) -> void:
	if _hud:
		_hud.update_flame(flame, Dragon.MAX_FLAME)


# add_mana/add_satchels are inherited from the Player base, which syncs the new
# values to the owner — for this view that lands in _on_sync_mana (HUD update).


## env_shake: rattle the view, decaying to nothing across `duration` the way GoldSrc's own shake
## settles. Who shakes is decided before this (NetworkManager.send_screen_shake). SHAKE_UNIT
## converts GoldSrc amplitude units to metres: h_offset/v_offset *translate* the camera, so a big
## amplitude (120 for a meteor or ball lightning) has to land in centimetres — SHAKE_MAX caps it
## there whatever the caller asks for.
## Skipped in VR: the head-driven XR camera shoving around is nauseating.
const SHAKE_UNIT := 0.0004
const SHAKE_MAX := 0.06

func shake_view(amplitude: float, duration: float, frequency: float) -> void:
	if XRManager.is_vr:
		return
	var cam := _render_camera()  # h_offset/v_offset only move the camera that draws
	if not cam:
		return
	var peak := minf(amplitude * SHAKE_UNIT, SHAKE_MAX)
	var steps := maxi(int(duration * maxf(frequency, 1.0)), 1)
	if _shake_tween:
		_shake_tween.kill()
	var home_h := cam.h_offset
	var home_v := cam.v_offset
	_shake_tween = create_tween()
	for i in steps:
		var offset := peak * (1.0 - float(i) / float(steps))
		_shake_tween.tween_property(cam, "h_offset",
			home_h + randf_range(-offset, offset), duration / steps)
		_shake_tween.parallel().tween_property(cam, "v_offset",
			home_v + randf_range(-offset, offset), duration / steps)
	_shake_tween.tween_property(cam, "h_offset", home_h, 0.05)
	_shake_tween.parallel().tween_property(cam, "v_offset", home_v, 0.05)

var _shake_tween: Tween


## GoldSrc pev->punchangle: a mind missile rocks the view of whoever it hits, without moving
## where their next shot goes — punchangle was only ever added to the rendered view angles, never
## to v_angle. Only the roll of it is applied here, because the camera's pitch IS the aim the shot
## is taken along (cmd.pitch, and the camera's own -Z), so a jolt there would knock the shot as
## well as the view. Rolling about that same -Z leaves both alone. Decays away like the original's.
const PUNCH_DECAY := 6.0    # e-folds per second
const PUNCH_MIN := 0.001    # radians below which it is over

var _view_punch := 0.0


func punch_view(roll_degrees: float) -> void:
	if XRManager.is_vr or not camera:
		return  # a jolt applied to a head-tracked camera is nausea, not feedback
	_view_punch = deg_to_rad(roll_degrees)


func _decay_view_punch(delta: float) -> void:
	if _view_punch == 0.0 or not camera:
		return
	_view_punch *= exp(-PUNCH_DECAY * delta)
	if absf(_view_punch) < PUNCH_MIN:
		_view_punch = 0.0
	camera.rotation.z = _view_punch


## Status effect display (client-side, driven by server RPCs).
var _active_statuses: Dictionary = {}  # StatusType -> true

func show_status(status_type: int) -> void:
	_active_statuses[status_type] = true
	if _hud:
		_hud.show_status(status_type)

func hide_status(status_type: int) -> void:
	_active_statuses.erase(status_type)
	if _hud:
		_hud.hide_status(status_type)

## Our own call for help, echoed into the status strip for the seconds it's live over our head.
## Not tracked in _active_statuses: it expires on its own and isn't a condition to be cured.
func show_help_call(sprite_path: String, duration: float) -> void:
	if _hud:
		_hud.show_help_call(sprite_path, duration)

## Toggle/fill a persistent-plant HUD health bar ("beanstalk"/"thornplant").
## Driven by the owning body via NetworkManager.send_to_owner (see
## PlantBehavior.set_beanstalk and PlantBehavior.tick_indicators).
func set_plant_indicator(kind: String, active: bool, hp: float = 0.0, max_hp: float = 0.0) -> void:
	if _hud:
		_hud.set_plant_indicator(kind, active, hp, max_hp)

func _clear_all_statuses() -> void:
	for st in _active_statuses.keys():
		if _hud:
			_hud.hide_status(st)
	_active_statuses.clear()
	if _hud:
		_hud.hide_help_call()  # times out on its own, but must not outlive a death or respawn
	if NetworkManager.is_authority():
		StatusSystem.clear_all(self)


## The buttons count as up until pressed again; the server hears the release in the next command.
func _stop_all_attacks() -> void:
	_end_trigger()
	_attack_down = 0
	_attack_tapped = 0


## Ends the current weapon's charge or hold, here alone: no command carries it.
func _end_trigger() -> void:
	if fire.charging and weapon:
		weapon.cancel_charge(self)
	if fire.auto_firing and weapon:
		weapon.stop_firing(self)
		_sustained_started = false
	fire.reset()


func _respawn() -> void:
	# Online (host included), the view waits for the body puppet's respawn to
	# arrive via assign_spawn — the server owns spawn timing and placement.
	if NetworkManager.is_online():
		_movement.clear()
		_last_input_cmd = null
		return
	# Apply a role queued via die_for_class_change (mirrors remote_player._host_respawn).
	var applied_change := class_change_pending_team >= 0
	if applied_change:
		team = class_change_pending_team
		set_element(class_change_pending_element)
		class_change_pending_team = -1
		class_change_pending_element = -1
	var sp := SpawnSystem.get_spawn_for_team(team)
	spawn_at(sp, element, false)
	# Network: broadcast host player respawn so clients re-show the puppet
	if NetworkManager.is_online() and NetworkManager.is_host():
		sync_spawn_to_network(sp, false, false, true)
		if applied_change:
			NetworkManager.sync_team_for_peer.rpc(peer_id, team, element, global_position, rotation.y)
	Log.info("Player respawned")


## Called by TFC goal system (GR_FORCE_RESPAWN_NO_DIE) to respawn the host
## player without a death animation. Mirrors remote_player.gd._host_respawn(true).
func _host_respawn(_force: bool = false) -> void:
	if team == GameConsts.Team.NONE:
		return
	# Beanstalks and thornplants persist across death and forced-respawn —
	# only class/team change destroys them (see ClientJoin.select_team_class).
	var sp := SpawnSystem.get_spawn_for_team(team)
	spawn_at(sp, element, true)
	# Broadcast respawn so other clients re-show the puppet
	if NetworkManager.is_online():
		sync_spawn_to_network(sp, false, false, true)


# --- Trigger (FireControl's shooter) ---

## This command's trigger: its buttons and weapon switch and, while firing, the lag-comp stamp and a
## tracked hand's aim. Stepped here as the server will step it, to predict the shots.
func _step_fire(cmd) -> void:
	var input := FireControl.TriggerInput.new()
	if not is_dead and not LobbyUI.pause_open:
		input.buttons = _attack_down | _attack_tapped
	_attack_tapped = 0
	input.weapon_select = _weapon_select
	_weapon_select = -1
	if (input.buttons | fire.buttons) != 0:
		input.shot_ms = NetworkManager.shot_time_ms() if NetworkManager.is_online() else 0
		var hand := _fire_hand()
		if hand:
			input.buttons |= FireControl.HAND_AIM
			input.aim_from = hand.global_position
			input.aim_dir = -hand.global_transform.basis.z
	cmd.set_meta(&"fire", input)
	fire.step(cmd, self, weapon)


func _set_attack(button: int, down: bool) -> void:
	if down and (_attack_down & button) == 0:
		_attack_tapped |= button
	_attack_down = _attack_down | button if down else _attack_down & ~button


## The hand a VR hand-tracked shot leaves from: the one a charge began in, else the cast hand.
## Null without hand tracking, where shots leave the eye.
func _fire_hand() -> XRController3D:
	if not (XRManager.is_vr and XRManager.hand_tracking):
		return null
	if is_instance_valid(_vr_charge_hand):
		return _vr_charge_hand
	var hand := _cast_hand()
	return hand if is_instance_valid(hand) else null


## One shot FireControl decided on. Online it is the cosmetics alone, since the body puppet's step of
## the same command fires the real one; offline it is the shot.
func shoot(_cmd, secondary: bool, charge_percent: float) -> int:
	if is_dead or not weapon:
		return FireControl.Shot.REFUSED
	# Mana gate: sustained weapons already firing only need mana > 0 (drain handles cost).
	# Discrete weapons and first-fire of sustained weapons need full mana_cost.
	# _sustained_started tracks whether we've already paid the initial cost this hold.
	var already_sustaining := _sustained_started and weapon.mana_drain > 0.0
	if not already_sustaining and weapon.mana_cost > 0.0 and mana < weapon.min_mana_to_fire(self):
		_play_deny_sound()
		return FireControl.Shot.DENIED
	if not weapon.can_fire(self):
		return FireControl.Shot.WARNED  # e.g. confirm-before-destroy: a re-press confirms at once
	var hand := _fire_hand()
	_vr_charge_hand = null
	if not _dispatch_fire(hand, charge_percent, secondary, not already_sustaining):
		return FireControl.Shot.REFUSED
	return FireControl.Shot.FIRED


func begin_charge() -> bool:
	if weapon.mana_cost > 0.0 and mana < weapon.mana_cost:
		_play_deny_sound()
		return false
	weapon.begin_charge(self)
	if XRManager.is_vr:
		_vr_charge_hand = _cast_hand()
	return true


func release_charge() -> float:
	return weapon.release_charge(self)


func stop_fire() -> void:
	_sustained_started = false
	if weapon:
		weapon.stop_firing(self)
	_play_hand_idle()


## Fire the current weapon: every LocalPlayer fires locally first for prediction cosmetics
## (hand anim, sound, beams, local weapon state). Real effects gate on
## NetworkManager.is_authoritative_fire(), false for an online view — the body puppet's fire is
## the only real one. Offline, the local fire IS the real one. Returns false when the fire refused.
func _dispatch_fire(cast_hand: XRController3D, charge_percent: float, secondary: bool,
		deduct_mana: bool) -> bool:
	var hand_valid: bool = XRManager.is_vr and XRManager.hand_tracking and is_instance_valid(cast_hand)
	var local_aim_from: Vector3 = cast_hand.global_position if hand_valid else Vector3.INF
	if not weapon.fire(self, local_aim_from, Vector3.ZERO, charge_percent, secondary):
		return false
	if is_instance_valid(_local_avatar):
		_local_avatar.play_attack()  # what every other peer plays for us on sync_attack
	# Track sustained state for the local mana gate; mana itself is server-owned online.
	if weapon.mana_drain > 0.0:
		_sustained_started = true
	# Offline we are the mana authority; online the server handler deducts and
	# syncs it back via sync_mana (locally dispatched for the host).
	if not NetworkManager.is_online() and deduct_mana and weapon.mana_cost > 0.0:
		mana = maxf(mana - weapon.actual_mana_cost(self), 0.0)
		if _hud:
			_hud.update_mana(mana, max_mana)
	return true


## The server found a fire a warning-only press (e.g. confirm-before-destroy) that this view didn't
## predict. Resets attack cooldown and stops auto-fire so the player must deliberately re-press to
## confirm, preventing auto_repeat weapons (beanstalk) from immediately self-confirming.
func on_fire_warning() -> void:
	fire.cooldown_ms = 0
	fire.end_hold(self)


func _on_hand_anim_finished(anim_name: StringName) -> void:
	if not _hand_anim_player:
		return
	if weapon and weapon.is_attack_anim(String(anim_name)):
		if fire.auto_firing:
			return  # hold last frame while sustaining fire
		_play_hand_idle()


var _pending_server_states: Array = []  # queued for processing in _physics_process


func _on_server_state(seq: int, pos: Vector3, vel: Vector3,
		crouched: bool, on_floor: bool, jumping: bool, jump_held: bool) -> void:
	ProjectileStandIn.note_played(seq)
	if is_dead or spectating:
		return
	# Queue for processing in _physics_process so move_and_slide uses the
	# fixed physics delta during replay, not the variable process delta.
	_pending_server_states.append(
		ClientMovement.ServerState.new(seq, pos, vel, crouched, on_floor, jumping, jump_held))


func _process_pending_server_states() -> void:
	for server_state in _pending_server_states:
		_reconcile_server_state(server_state)
	_pending_server_states.clear()


func _reconcile_server_state(server_state: ClientMovement.ServerState) -> void:
	if is_dead or spectating:
		return

	var corrected := _movement.reconcile(_body, server_state)
	if corrected:
		_sync_local_from_movement()
		NetworkManager.record_correction()
		var c := _movement.last_correction
		var dist: float = c["dist"]
		var now := Time.get_ticks_msec() / 1000.0
		# Consecutive-correction detection: corrections on every seq indicate
		# systematic physics divergence (client and server disagree on every tick),
		# not just occasional resync after a spike.
		if server_state.seq == _last_correction_seq + 1:
			_consecutive_corrections += 1
		else:
			_consecutive_corrections = 1
		_last_correction_seq = server_state.seq
		var consec_str := ""
		if _consecutive_corrections >= 3:
			consec_str = " CONSECUTIVE=%d" % _consecutive_corrections
		var replay_pos: Vector3 = c["replay_pos"]
		var server_pos: Vector3 = c["server_pos"]
		var replay_lateral: float = Vector2(replay_pos.x - server_pos.x, replay_pos.z - server_pos.z).length()
		var msg := "[NetDebug] CORRECTION dist=%.3f lat=%.3f dy=%.3f replay_lat=%.3f replay_dy=%.3f unacked=%d queue=%d ping=%d seq=%d%s" % [
			dist, c["dist_lateral"], c["dist_y"],
			replay_lateral, replay_pos.y - server_pos.y,
			c["unacked"], NetworkManager.net_input_queue_depth, NetworkManager.net_ping_ms,
			server_state.seq, consec_str]
		msg += " pred_floor=%s srv_floor=%s pred_jump=%s srv_jump=%s" % [
			c["predicted_on_floor"], c["server_on_floor"],
			c["predicted_is_jumping"], c["server_is_jumping"]]
		msg += " pred_vy=%.2f srv_vy=%.2f pred_vxz=%.2f srv_vxz=%.2f" % [
			c["predicted_vel_y"], c["server_vel_y"],
			c["predicted_vxz"], c["server_vxz"]]
		msg += " near=%.2f" % _nearest_player_distance()
		_net_ring.append("  !! %s" % msg)
		if NetworkManager.view_diag != null:
			Log.info(msg)
		_check_net_alert(now)
	# Track unacked commands (prediction buffer depth)
	NetworkManager.net_unacked_cmds = _movement.buffer_size()
	if NetworkManager.view_diag != null:
		NetworkManager.view_diag.note_reconcile(_movement.buffer_size(), corrected,
				_movement.last_correction["dist"] if corrected else 0.0)


## Horizontal distance to the closest other player, as this client draws them: player contact is a
## misprediction the client can't avoid, since it collides against bodies drawn in the past.
func _nearest_player_distance() -> float:
	var best := INF
	var players := NetworkManager.player_table()
	for id in players:
		var p: Node3D = players[id]
		if p == self or not is_instance_valid(p) or not p.visible:
			continue
		var d := Vector2(p.global_position.x - global_position.x, p.global_position.z - global_position.z).length()
		best = minf(best, d)
	return best


func get_movement_modifiers(cmd) -> Movement.MovementModifiers:
	return _move_ctx.get_modifiers(_movement.cfg, _movement.state, weapons, speed_multiplier, cmd)


## The adapter ClientMovement predicts on — the client-side counterpart of RemotePlayer's.
## [PlayerMovementContext] asks for it to probe poses the hull is not in (its unstick fallback).
func get_godot_body() -> GodotBody:
	return _body


func _sync_local_from_movement() -> void:
	_is_crouched = _movement.state.is_crouched
	# _on_ladder is tracked from _check_ladder() in the physics loop, not from movement state


## World-space amount the headset has out-run the (blocked) capsule. main.gd uses
## this as the camera lean offset: ~zero when the body tracks the head freely,
## growing only when the capsule is stuck against geometry.
func get_vr_head_residual() -> Vector3:
	return _vr_head_residual


## Called on spawn/teleport after the body has been placed — state.position is a view
## over the body transform, so the new placement needs no explicit sync.
func reset_movement() -> void:
	_movement.state.velocity = Vector3.ZERO
	_movement.state.on_floor = is_on_floor()
	# Force standing state so spawning after a crouched death doesn't leave is_crouched=true,
	# which would block VR neutral-eye calibration and cause persistent phys_crouch mismatch.
	_movement.state.is_crouched = false
	_movement.state.eye_y = _movement.cfg.stand_eye
	_body.set_collision_height(_movement.cfg.stand_height, _movement.cfg.stand_height * 0.5)
	_movement.clear()
	_last_input_cmd = null
	_sync_local_from_movement()
	_camera_snap_pending = true
	gravity_scale = 1.0
	_vr_neutral_eye_y = -1.0
	# Re-seed roomscale head tracking so the post-spawn position isn't read as one
	# giant head_delta, and clear any leaned-out residual from before the respawn.
	_vr_head_seeded = false
	_vr_head_residual = Vector3.ZERO
	# Pre-initialize camera world pos so get_eye_position() returns the correct spawn
	# height before the first physics frame, preventing a frame where the VR rig is
	# placed at origin (and a stale nominal_eye causes a bad sphere-cast on the first tick).
	_camera_world_pos = global_position + Vector3(0.0, _movement.cfg.stand_eye, 0.0)
	_prev_camera_world_pos = _camera_world_pos
	if NetworkManager.view_diag != null:
		NetworkManager.view_diag.reset_motion()


func end_sustained_fire(w: Weapon) -> void:
	_sustained_started = false
	super(w)

## Teleport to a position and yaw. Zeroes velocity and resets prediction.
func teleport_to(pos: Vector3, yaw: float) -> void:
	super(pos, yaw)
	reset_movement()


func is_in_water() -> bool:
	return _in_water


func _unhandled_input(event: InputEvent) -> void:
	if XRManager.is_vr:
		# Controller input is polled each physics frame in _apply_vr_input()
		return

	if LobbyUI.pause_open:
		return

	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * _mouse_sensitivity)
		# Yaw is never inverted — "invert mouse" has meant the vertical axis alone since flight
		# sticks, and a game that flipped both would just be reading the mouse backwards.
		var pitch: float = event.relative.y * _mouse_sensitivity
		if _invert_mouse:
			pitch = -pitch
		camera.rotation.x = clampf(camera.rotation.x - pitch, -PI / 2.0, PI / 2.0)

	if event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	# The buttons go into the next command, where FireControl turns them into shots.
	if event.is_action_pressed("attack") and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and not spectating and not is_dead:
		_set_attack(FireControl.ATTACK, true)
	elif event.is_action_released("attack"):
		_set_attack(FireControl.ATTACK, false)
	elif event.is_action_pressed("attack2") and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED \
			and not spectating and not is_dead and weapon:
		_set_attack(FireControl.ATTACK2, true)
	elif event.is_action_released("attack2"):
		_set_attack(FireControl.ATTACK2, false)
	elif event is InputEventMouseButton and event.pressed:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	if event.is_action_pressed("use") and not spectating and not is_dead:
		_use_pressed()

	if not spectating and not is_dead:
		if event.is_action_pressed("weapon_prev"):
			_switch_weapon(-1)
		elif event.is_action_pressed("weapon_next"):
			_switch_weapon(1)

		# One action per slot rather than arithmetic on the keycode, so the spell keys can be
		# moved off the number row like any other control.
		for slot in mini(weapons.size(), KeyBindings.SLOT_COUNT):
			if event.is_action_pressed("slot%d" % (slot + 1)) and slot != current_weapon_idx:
				_switch_weapon_to(slot)
				break
		if event.is_action_pressed("lastweapon") and weapons.size() > 1 \
				and _last_weapon_idx != current_weapon_idx:
			_switch_weapon_to(_last_weapon_idx)

		# The fuse burns between the press and the release, so this control needs both edges.
		if event.is_action_pressed("satchel"):
			_prime_satchel()
		elif event.is_action_released("satchel"):
			_throw_satchel()

		if event.is_action_pressed("callhelp"):
			_call_for_help()

	if event is InputEventKey and event.pressed and event.keycode == KEY_F11:
		if get_window().mode == Window.MODE_EXCLUSIVE_FULLSCREEN:
			get_window().mode = Window.MODE_WINDOWED
		else:
			get_window().mode = Window.MODE_EXCLUSIVE_FULLSCREEN

	if event is InputEventKey and event.pressed and event.keycode == KEY_F4:
		print(VisibilitySystem.get_debug_info())

	if _hud:
		if event.is_action_pressed("chat"):
			_hud.open_chat_input(false)
			get_viewport().set_input_as_handled()
		elif event.is_action_pressed("chat_team"):
			_hud.open_chat_input(true)
			get_viewport().set_input_as_handled()
		elif event.is_action_pressed("console"):
			_hud.open_chat_input(false, "/")
			get_viewport().set_input_as_handled()


const USE_RANGE := 64.0 * SCALE  # 1.6 — HL +use reach


func _use_pressed() -> void:
	if is_dragon_mounted:
		NetworkManager.send_request_use(_mounted_dragon.get_path())
		return

	var space := get_world_3d().direct_space_state
	var aim_cam := _active_camera()
	var from := aim_cam.global_position
	var to := from + -aim_cam.global_transform.basis.z * USE_RANGE
	var params := PhysicsRayQueryParameters3D.create(from, to)
	params.exclude = [get_rid()]
	var result := space.intersect_ray(params)
	if result.is_empty():
		return
	var hit: Node3D = result.collider
	# Walk up parents to the first +usable entity. Non-usable brushwork (a
	# func_breakable, a plain wall) is climbed past, not stopped on.
	var node: Node = hit
	while node:
		if GoldSrcEntity.is_player_usable(node):
			NetworkManager.send_request_use(node.get_path())
			return
		node = node.get_parent()


## Z: ask a teammate for a heal — a sprite over our head and a shout, both drawn by every peer
## in earshot. The server owns the cooldown and picks the line, so this only catches the one
## refusal it can explain: a bear has no voice to call with.
func _call_for_help() -> void:
	if is_bear:
		if _hud:
			_hud.show_center_message("A bear cannot call for help")
		return
	NetworkManager.send_request_help_call()


func _on_chat_submitted(message: String, team_only: bool) -> void:
	if message.begins_with("/") and ClientCommandSystem.dispatch(message):
		return
	if not NetworkManager.is_online():
		return
	if message.begins_with("/"):
		NetworkManager.send_request_command(message)
	else:
		NetworkManager.send_request_chat(message, team_only)


func _exit_tree() -> void:
	ClientCommandSystem.unregister("render")
	ClientCommandSystem.unregister("pos")
	ClientCommandSystem.unregister("invertmouse")
	ClientCommandSystem.unregister("sensitivity")
	ClientCommandSystem.unregister("thirdperson")


func _cmd_render(args: String) -> void:
	var mode := args.to_lower()
	match mode:
		"wireframe":
			get_viewport().debug_draw = Viewport.DEBUG_DRAW_WIREFRAME
			_hide_debug_render()
			ClientCommandSystem.reply_ok("render: wireframe")
		"debug":
			get_viewport().debug_draw = Viewport.DEBUG_DRAW_DISABLED
			_toggle_debug_render()
			ClientCommandSystem.reply_ok("render: debug")
		"", "normal":
			get_viewport().debug_draw = Viewport.DEBUG_DRAW_DISABLED
			_hide_debug_render()
			ClientCommandSystem.reply_ok("render: normal")
		_:
			ClientCommandSystem.reply_err("Usage: /render [wireframe|debug|normal]")


var _pos_readout := false


## Re-read the [input] section. Called on spawn, and by the two commands after they write to it,
## so a change takes hold on the next mouse motion instead of the next map.
func _reload_input_settings() -> void:
	_invert_mouse = InputSettings.load_invert_mouse()
	_mouse_sensitivity = MOUSE_SENSITIVITY * InputSettings.load_sensitivity()


## on/off/blank-toggles argument -> the value asked for, or -1 if it was none of those.
func _parse_toggle(args: String, current: bool) -> int:
	match args.to_lower():
		"on", "1", "true": return 1
		"off", "0", "false": return 0
		"": return 0 if current else 1
	return -1


func _cmd_invert_mouse(args: String) -> void:
	var asked := _parse_toggle(args, _invert_mouse)
	if asked < 0:
		ClientCommandSystem.reply_err("Usage: /invertmouse [on|off]")
		return
	var invert := asked == 1
	InputSettings.save_invert_mouse(invert)
	_reload_input_settings()
	ClientCommandSystem.reply_ok("invertmouse: %s" % ("on" if invert else "off"))


func _cmd_sensitivity(args: String) -> void:
	if args.is_empty():
		ClientCommandSystem.reply_ok("sensitivity: %.2f" % InputSettings.load_sensitivity())
		return
	if not args.is_valid_float():
		ClientCommandSystem.reply_err("Usage: /sensitivity [%.2f-%.2f]" % [
			InputSettings.SENSITIVITY_MIN, InputSettings.SENSITIVITY_MAX])
		return
	var asked := args.to_float()
	var applied := InputSettings.clamp_sensitivity(asked)
	InputSettings.save_sensitivity(applied)
	_reload_input_settings()
	if applied != asked:
		ClientCommandSystem.reply_ok("sensitivity: %.2f (clamped from %.2f)" % [applied, asked])
	else:
		ClientCommandSystem.reply_ok("sensitivity: %.2f" % applied)


func _cmd_third_person(args: String) -> void:
	if XRManager.is_vr:
		ClientCommandSystem.reply_err("thirdperson: not in VR")
		return
	var asked := _parse_toggle(args, third_person)
	if asked < 0:
		ClientCommandSystem.reply_err("Usage: /thirdperson [on|off]")
		return
	var enabled := asked == 1
	InputSettings.save_third_person(enabled)
	set_third_person(enabled)
	ClientCommandSystem.reply_ok("thirdperson: %s" % ("on" if enabled else "off"))


func _cmd_pos(args: String) -> void:
	if not _hud:
		ClientCommandSystem.reply_err("No HUD")
		return
	match args.to_lower():
		"on": _pos_readout = true
		"off": _pos_readout = false
		"": _pos_readout = not _pos_readout
		_:
			ClientCommandSystem.reply_err("Usage: /pos [on|off]")
			return
	_hud.set_pos_visible(_pos_readout)
	ClientCommandSystem.reply_ok("pos: %s" % ("on" if _pos_readout else "off"))


func _hide_debug_render() -> void:
	if _debug_render_root:
		_debug_render_root.visible = false
	for mi in get_tree().get_nodes_in_group("debug_hitbox_mesh"):
		mi.queue_free()
	if _hud:
		_hud.set_render_debug_visible(false)


## Generate a short low-pitched buzz for "out of mana/satchels" denial.
static func _create_deny_sound() -> AudioStream:
	var sample_rate := 22050
	var duration := 0.15
	var freq := 220.0
	var num_samples := int(sample_rate * duration)
	var audio := AudioStreamWAV.new()
	audio.format = AudioStreamWAV.FORMAT_16_BITS
	audio.mix_rate = sample_rate
	var data := PackedByteArray()
	data.resize(num_samples * 2)
	for i in num_samples:
		var t := float(i) / sample_rate
		var envelope := 1.0 - (t / duration)
		var sample := sin(t * freq * TAU) * envelope * 0.3
		var s16 := int(clampf(sample, -1.0, 1.0) * 32767)
		data[i * 2] = s16 & 0xFF
		data[i * 2 + 1] = (s16 >> 8) & 0xFF
	audio.data = data
	return audio


func _play_deny_sound() -> void:
	if not _deny_sound:
		return
	var player := AudioStreamPlayer.new()
	player.stream = _deny_sound
	player.bus = SoundSystem.EFFECTS_BUS
	player.volume_db = -6.0
	add_child(player)
	player.play()
	player.finished.connect(player.queue_free)


func _prime_satchel() -> void:
	if _satchel_cooldown > 0.0:
		return
	if satchel_pack.count <= 0:
		_play_deny_sound()
		return
	_satchel_cooldown = 0.5
	# Deduct locally (server confirms via sync_mana)
	satchel_pack.count -= 1
	if _hud:
		_hud.update_satchels(satchel_pack.count, element)
	SoundSystem._play_local_global("items/gunpickup3.wav")
	if NetworkManager.is_online():
		# The server puppet owns the fuse; send_request_* dispatches directly to
		# the server-side handler on the listen-server host (RPC-to-self drops).
		NetworkManager.send_request_prime_satchel()
	# Offline: nothing to track; _throw_satchel below spawns immediately.


func _throw_satchel() -> void:
	var aim_dir := -_active_camera().global_transform.basis.z
	if NetworkManager.is_online():
		NetworkManager.send_request_throw_satchel(aim_dir)
	else:
		# Offline: spawn directly with default fuse.
		satchel_pack.spawn(aim_dir.normalized(), Satchel.FUSE_TIME)


## Overrides InputCommand fields with Meta Quest controller state.
## Cast hand (right by default, left if XRManager.left_handed):
##   trigger = attack, grip = attack2, A/X = use, B/Y = jump,
##   thumbstick = snap turn + weapon cycle.
## Move hand (the other one):
##   thumbstick = move, click = crouch, X/A = class menu, Y/B = team menu.
func _apply_vr_input(cmd: RefCounted, delta: float, chat_open: bool) -> void:
	if not is_instance_valid(xr_right) or not is_instance_valid(xr_left):
		return

	var cast_hand := xr_left if XRManager.left_handed else xr_right
	var move_hand := xr_right if XRManager.left_handed else xr_left

	# Keep body yaw in sync with HMD world yaw so other players and the server
	# always see you facing where you're actually looking, not just snap-turn steps.
	if is_instance_valid(xr_camera):
		rotation.y = xr_camera.global_rotation.y
	cmd.yaw = rotation.y

	# Movement: move-hand thumbstick, direction relative to HMD horizontal facing
	var move_stick := move_hand.get_vector2("primary")
	var active_cam := _active_camera()
	if not chat_open and move_stick.length() > 0.2:
		var hmd_fwd := -active_cam.global_transform.basis.z
		hmd_fwd.y = 0.0
		hmd_fwd = hmd_fwd.normalized() if hmd_fwd.length() > 0.001 else Vector3.FORWARD
		var hmd_rgt := active_cam.global_transform.basis.x
		hmd_rgt.y = 0.0
		hmd_rgt = hmd_rgt.normalized() if hmd_rgt.length() > 0.001 else Vector3.RIGHT
		var world_move := hmd_fwd * move_stick.y + hmd_rgt * move_stick.x
		var body_inv := Basis(Vector3.UP, -rotation.y)
		var local_move := body_inv * world_move
		cmd.move_input = Vector2(local_move.x, local_move.z)
	else:
		cmd.move_input = Vector2.ZERO

	cmd.pitch = active_cam.global_rotation.x

	# Snap turn: cast-hand thumbstick left/right; weapon cycle: cast-hand thumbstick up/down
	_vr_snap_cooldown -= delta
	_vr_weapon_scroll_cooldown -= delta
	var cast_stick := cast_hand.get_vector2("primary")
	if _vr_snap_cooldown <= 0.0 and absf(cast_stick.x) > VR_SNAP_THRESHOLD:
		var snap := -signf(cast_stick.x) * VR_SNAP_ANGLE
		rotation.y += snap
		if xr_rig:
			xr_rig.rotation.y += snap
		# The whole player frame rotates about the body, so the stored head-vs-body
		# residual (a world vector) must rotate with it to stay pointing at the head.
		_vr_head_residual = Basis(Vector3.UP, snap) * _vr_head_residual
		cmd.yaw = rotation.y
		_vr_snap_cooldown = 0.4
	if _vr_weapon_scroll_cooldown <= 0.0 and absf(cast_stick.y) > VR_SNAP_THRESHOLD:
		_switch_weapon(1 if cast_stick.y < 0.0 else -1)
		_vr_weapon_scroll_cooldown = 0.4

	var trigger_pressed := cast_hand.get_float("trigger") > VR_TRIGGER_THRESHOLD
	var grip_pressed := cast_hand.get_float("grip") > VR_TRIGGER_THRESHOLD
	var ax_pressed := cast_hand.is_button_pressed("ax_button")
	var by_pressed := cast_hand.is_button_pressed("by_button")

	cmd.jump = by_pressed
	var btn_crouch := move_hand.is_button_pressed("primary_click")
	var phys_crouch := false
	if XRManager.advanced_head_tracking and is_instance_valid(xr_camera):
		# Auto-calibrate: ratchet neutral upward whenever the game character is
		# standing. If the player spawned while physically crouching, the neutral
		# starts low but corrects itself the moment they stand fully upright.
		if not _is_crouched:
			_vr_neutral_eye_y = maxf(_vr_neutral_eye_y, xr_camera.position.y)
		if _vr_neutral_eye_y > 0.0:
			phys_crouch = xr_camera.position.y < _vr_neutral_eye_y - VR_CROUCH_TRIGGER
	# Mounted forces a ducked hull, but under noclip the kernel reads crouch as
	# "descend" — forcing it would sink the rider fast. Let real input through.
	cmd.crouch = true if (is_dragon_mounted and not noclip) else (btn_crouch or phys_crouch)

	# Edges like the mouse's events, so a trigger held through a respawn needs a fresh pull.
	if not trigger_pressed:
		_set_attack(FireControl.ATTACK, false)
	if not grip_pressed:
		_set_attack(FireControl.ATTACK2, false)
	if not spectating and not is_dead:
		if trigger_pressed and not _vr_trigger_was_pressed:
			_set_attack(FireControl.ATTACK, true)
		if grip_pressed and not _vr_grip_was_pressed and weapon:
			_set_attack(FireControl.ATTACK2, true)
		if ax_pressed and not _vr_ax_was_pressed:
			_use_pressed()

	# Move-hand Y = show team + class menu; move-hand X = show class-only menu
	var left_ax_pressed := move_hand.is_button_pressed("ax_button")
	var left_by_pressed := move_hand.is_button_pressed("by_button")
	if not spectating:
		if left_by_pressed and not _vr_left_by_was_pressed:
			vr_menu_requested.emit(false)
		if left_ax_pressed and not _vr_left_ax_was_pressed:
			vr_menu_requested.emit(true)

	_vr_trigger_was_pressed = trigger_pressed
	_vr_grip_was_pressed = grip_pressed
	_vr_ax_was_pressed = ax_pressed
	_vr_left_ax_was_pressed = left_ax_pressed
	_vr_left_by_was_pressed = left_by_pressed

	# Roomscale: feed the headset's physical horizontal movement into the command so the
	# server-authoritative capsule tracks the head (see movement.gd apply_head_delta).
	# xr_camera.position is the raw HMD pose in rig-local play space, untouched by our
	# own rig repositioning.
	if XRManager.advanced_head_tracking and is_instance_valid(xr_camera) and is_instance_valid(xr_rig):
		var head_play := Vector3(xr_camera.position.x, 0.0, xr_camera.position.z)
		if not _vr_head_seeded:
			_vr_prev_head_play = head_play
			_vr_head_seeded = true
		var world_delta := xr_rig.global_basis * (head_play - _vr_prev_head_play)
		_vr_prev_head_play = head_play
		var local_delta := Basis(Vector3.UP, -cmd.yaw) * world_delta
		cmd.head_delta = Vector2(local_delta.x, local_delta.z)


func _process(delta: float) -> void:
	_decay_view_punch(delta)
	if spectating:
		return
	if XRManager.is_vr:
		if XRManager.hand_tracking:
			_update_vr_hand_models()
		return  # XRCamera3D position is managed by the XR subsystem
	var alpha := Engine.get_physics_interpolation_fraction()
	camera.global_position = _prev_camera_world_pos.lerp(_camera_world_pos, alpha)
	if NetworkManager.view_diag != null and not is_dead:
		NetworkManager.view_diag.note_frame(delta, camera.global_position,
				_camera_world_pos.distance_to(_prev_camera_world_pos))
	if third_person:
		# Both read the eye camera, so both have to follow the write above in the same frame.
		_update_chase_camera()
		_drive_local_avatar()


func _physics_process(delta: float) -> void:
	if spectating:
		return

	# Process any queued server states (reconciliation) inside the physics frame
	# so that move_and_slide replay uses the fixed physics delta, not process delta.
	_process_pending_server_states()


	if _satchel_cooldown > 0.0:
		_satchel_cooldown -= delta

	_update_invis_alpha(delta)
	_update_combo_glow()

	# A held fire button does not survive the pause panel: its release is swallowed while it is up.
	if LobbyUI.pause_open:
		_stop_all_attacks()
	if fire.charging and weapon:
		weapon.update_charge(self, delta)

	# Offline only — online (host included) the body puppet owns bear mana drain
	# and the plant HUD bars.
	if not NetworkManager.is_online():
		_tick_bear_mana_drain(delta)
		plants.tick_indicators(delta)

	# --- Build InputCommand from current input state ---
	var keys_held : bool = (_hud != null and _hud.is_chat_open()) or LobbyUI.pause_open
	var cmd := InputCommand.new()
	cmd.seq = _movement.get_next_seq()
	cmd.move_input = Vector2.ZERO if keys_held else Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	_apply_rotating_ground_yaw()
	cmd.yaw = rotation.y
	cmd.pitch = camera.rotation.x
	var keys_free := not keys_held
	cmd.jump = keys_free and Input.is_action_pressed("jump")
	cmd.crouch = (is_dragon_mounted and not noclip) or (keys_free and Input.is_action_pressed("crouch"))
	cmd.walk = keys_free and Input.is_action_pressed("walk")
	cmd.noclip = noclip
	cmd.delta = _movement.command_delta(delta)
	if XRManager.is_vr:
		_apply_vr_input(cmd, delta, keys_held)
		if XRManager.hand_tracking and NetworkManager.is_online() and not NetworkManager.is_host() and not is_dead:
			_vr_hand_sync_timer += delta
			if _vr_hand_sync_timer >= NetworkManager.NET_TICK_INTERVAL:
				_vr_hand_sync_timer -= NetworkManager.NET_TICK_INTERVAL
				var r_pos := xr_right.global_position if is_instance_valid(xr_right) else Vector3.INF
				var l_pos := xr_left.global_position if is_instance_valid(xr_left) else Vector3.INF
				if r_pos.is_finite() or l_pos.is_finite():
					NetworkManager.report_vr_hands.rpc_id(1, r_pos, l_pos, 1 if XRManager.left_handed else 0)
	_step_fire(cmd)
	if weapon:
		weapon.contribute_input_flags(cmd)  # after the trigger, so a levitate it starts lifts this command

	# --- Environment detection (side effects that must happen before predict) ---

	# Ladder detection — zero velocity on first contact
	var on_ladder := _check_ladder()
	if on_ladder and not _on_ladder:
		_movement.state.velocity = Vector3.ZERO
		velocity = Vector3.ZERO
	_on_ladder = on_ladder

	# Water detection — fog toggle
	_in_water = _check_water()
	var head_liquid := _check_head_liquid()
	if head_liquid != _head_liquid:
		_head_liquid = head_liquid
		_set_underwater_fog(head_liquid)

	# Lava/slime damage — offline only. Online (host included) the body puppet's
	# _physics_process owns it; damage arrives back via sync_player_damage.
	if not NetworkManager.is_online() and not is_dead:
		_move_ctx.tick_liquid_damage(delta)

	# --- Run predicted movement ---
	cmd.quantize()  # predict with exactly what the server will decode
	_movement.predict(_body, cmd, get_movement_modifiers)
	_push_base_vel = Vector3.ZERO  # consumed for this frame; trigger_push re-sets next frame if still in zone
	# Roomscale: track how far the head out-ran the capsule. When the body moved
	# freely, requested == consumed and the residual is unchanged; when the capsule
	# was blocked (wall/doorframe), the residual grows so main.gd can lean the view
	# past the stuck body. Unwinds automatically as the player steps back.
	if XRManager.is_vr and XRManager.advanced_head_tracking and cmd.head_delta != Vector2.ZERO:
		var requested_world := Basis(Vector3.UP, cmd.yaw) * Vector3(cmd.head_delta.x, 0.0, cmd.head_delta.y)
		_vr_head_residual += requested_world - _movement.state.head_consumed
	_sync_local_from_movement()
	_last_input_cmd = cmd

	_prev_camera_world_pos = _camera_world_pos
	var desired_world_pos := global_position + Vector3(0.0, _movement.state.eye_y, 0.0)
	if _camera_snap_pending or _camera_world_pos.distance_squared_to(desired_world_pos) > CAMERA_SMOOTH_SNAP * CAMERA_SMOOTH_SNAP:
		_camera_world_pos = desired_world_pos
		_prev_camera_world_pos = desired_world_pos
		_camera_snap_pending = false
	else:
		_camera_world_pos = _camera_world_pos.lerp(desired_world_pos, 1.0 - exp(-CAMERA_SMOOTH_RATE * delta))

	# Overheal drain
	if health > max_health:
		health = maxf(health - GameConsts.OVERHEAL_DRAIN * delta, max_health)
		if _hud:
			_hud.update_health(health, max_health)

	# Sustained mana drain (rays, levitate, etc.) — offline only. Online the server
	# puppet's tick_mana_drain owns the drain for every player including the listen-
	# server host (the puppet's trigger fires through ServerRequests.attack, which sets
	# mana_drain_active), and mana arrives back via sync_mana / sync_mana_drain.
	if fire.auto_firing and weapon and weapon.mana_drain > 0.0 and not NetworkManager.is_online():
		mana = maxf(mana - weapon.mana_drain * delta, 0.0)
		if _hud:
			_hud.update_mana(mana, max_mana)
		if mana <= 0.0:
			fire.end_hold(self)

	# Always record into ring buffer
	_net_ring_record()


# Ride the spin of a rotating brush underfoot (func_platrot, func_door_rotating), mirroring
# GoldSrc PM_Move's groundentity avelocity. Flatscreen only — involuntary view rotation is a
# VR nausea trigger, so a VR rider revolves in position but keeps head control.
func _apply_rotating_ground_yaw() -> void:
	# CharacterBody3D's own is_on_floor is unreliable after the step path (see movement.gd),
	# so use the movement system's floor flag instead.
	if XRManager.is_vr or not _movement.state.on_floor:
		return
	rotation.y += _move_ctx.get_carry_yaw_delta()


# --- Network ring buffer (10s rolling window, flushed on demand) ---

func _net_ring_record() -> void:
	var nm := NetworkManager
	if not nm.is_online():
		return
	var pos := global_position
	var vel_len := velocity.length()
	var seq := _movement.last_seq()
	var yaw := rad_to_deg(rotation.y)
	var pitch := rad_to_deg(camera.rotation.x)
	var dyaw := yaw - _prev_yaw
	var dpitch := pitch - _prev_pitch
	# Normalize yaw delta to [-180, 180]
	if dyaw > 180.0: dyaw -= 360.0
	elif dyaw < -180.0: dyaw += 360.0
	_prev_yaw = yaw
	_prev_pitch = pitch
	var flag := " <<<" if absf(dyaw) > 5.0 or absf(dpitch) > 5.0 else ""
	var floor_str := " floor=%s jump=%s vy=%.1f" % [
		is_on_floor(), _movement.state.is_jumping, velocity.y]
	var line := "%.3f | %d | %d | %d | %d | %.1f | (%.1f,%.1f,%.1f) | %.1f | %.1f | %.1f | dy=%.1f dp=%.1f | %d %s %s" % [
		Time.get_ticks_msec() / 1000.0, nm.net_ping_ms, nm.net_ping_avg_ms,
		nm.net_input_queue_depth, nm.net_unacked_cmds,
		nm.net_corrections_per_sec,
		pos.x, pos.y, pos.z, vel_len, yaw, pitch, dyaw, dpitch, seq, flag,
		floor_str]
	_net_ring.append(line)
	if _net_ring.size() > NET_RING_SIZE:
		_net_ring.pop_front()


func _flush_net_dump() -> void:
	if _net_ring.is_empty():
		return
	Log.info("[NetDump] === DUMP (%d samples) ===" % _net_ring.size())
	Log.info("[NetDump] time | ping | pavg | queue | unack | corr/s | pos | vel | yaw | pitch | seq | floor/jump/vy [voff]")
	for line in _net_ring:
		Log.info("[NetDump] %s" % line)
	Log.info("[NetDump] === END DUMP ===")
	if _hud:
		_hud.show_center_message("Net dump written to log (%d samples)" % _net_ring.size(),
			Color.GREEN, 2.0, false)


func _check_net_alert(_now: float) -> void:
	# Removed automatic alert — too noisy for normal multiplayer.
	# Call _flush_net_dump() manually when a player reports rubber-banding.
	# Server logs frame time/fps/queue data for diagnosis.
	pass


# --- Ladder / Water ---

func _check_ladder() -> bool:
	return _move_ctx.check_ladder()

func _check_water() -> bool:
	return _move_ctx.check_water()


func _check_head_liquid() -> GameConsts.Liquid:
	return SpatialQuery.liquid_at_point(self, _active_camera().global_position)


# --- Underwater fog ---

## Colour and density of being submerged, per liquid. One green for all three read as a
## swimming pool no matter what you had jumped into — ww_volcano and ww_keep are lava.
const _LIQUID_FOG := {
	GameConsts.Liquid.WATER: [Color(0.06, 0.15, 0.1), 0.4, 0.25],
	GameConsts.Liquid.SLIME: [Color(0.10, 0.16, 0.04), 0.35, 0.45],
	GameConsts.Liquid.LAVA: [Color(0.45, 0.10, 0.02), 0.7, 0.9],
}


func _set_underwater_fog(liquid: GameConsts.Liquid) -> void:
	var world_env := get_tree().root.find_child("WorldEnvironment", true, false) as WorldEnvironment
	if not world_env or not world_env.environment:
		return
	var env := world_env.environment
	env.fog_enabled = liquid != GameConsts.Liquid.NONE
	if not env.fog_enabled:
		return
	var preset: Array = _LIQUID_FOG.get(liquid, _LIQUID_FOG[GameConsts.Liquid.WATER])
	env.fog_light_color = preset[0]
	env.fog_light_energy = preset[1]
	env.fog_density = preset[2]
	env.fog_sky_affect = 0.0


# --- Debug rendering ---


func _toggle_debug_render() -> void:
	var was_showing := _debug_render_root != null and _debug_render_root.visible
	if _debug_render_root == null:
		_debug_render_root = Node3D.new()
		_debug_render_root.name = "DebugRenderRoot"
		get_tree().get_root().add_child(_debug_render_root)
		var occluder_count := _build_occluder_debug_meshes(_debug_render_root)
		print("debug render: built %d occluder meshes" % occluder_count)
	if not was_showing:
		_debug_render_root.visible = true
		# Rebuild hitbox meshes each time we turn on — players/monsters may have
		# spawned since the last toggle.
		var hitbox_count := _build_hitbox_debug_meshes()
		print("debug render: built %d hitbox meshes" % hitbox_count)
		if _hud:
			_hud.set_render_debug_visible(true)
	else:
		_hide_debug_render()


func _build_occluder_debug_meshes(parent: Node3D) -> int:
	var instances := get_tree().get_root().find_children("*", "OccluderInstance3D", true, false)
	if instances.is_empty():
		return 0

	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.0, 1.0, 0.5, 0.35)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.no_depth_test = true

	for inst in instances:
		var occ = inst.occluder
		if not occ is PolygonOccluder3D:
			continue
		var poly: PackedVector2Array = (occ as PolygonOccluder3D).polygon
		if poly.size() < 3:
			continue

		# Use the same triangulation as the C++ (handles non-convex polygons)
		var tris: PackedInt32Array = Geometry2D.triangulate_polygon(poly)
		if tris.is_empty():
			continue

		var verts := PackedVector3Array()
		for i in range(0, tris.size(), 3):
			verts.append(Vector3(poly[tris[i]].x,     poly[tris[i]].y,     0.0))
			verts.append(Vector3(poly[tris[i + 1]].x, poly[tris[i + 1]].y, 0.0))
			verts.append(Vector3(poly[tris[i + 2]].x, poly[tris[i + 2]].y, 0.0))

		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts

		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.material_override = mat
		parent.add_child(mi)
		mi.global_transform = inst.global_transform

	return instances.size()


## Hitbox debug meshes live under the BoneAttachment3D that owns the hitbox Area3D
## so they follow animated bones automatically. They're tagged in the
## "debug_hitbox_mesh" group for group-based visibility toggling.
func _build_hitbox_debug_meshes() -> int:
	var areas := get_tree().get_root().find_children("*", "Area3D", true, false)
	var count := 0
	for area in areas:
		if not area.has_meta("hitbox_group"):
			continue
		var shape: CollisionShape3D = null
		for child in area.get_children():
			if child is CollisionShape3D:
				shape = child
				break
		if shape == null:
			continue
		var box := shape.shape
		if not box is BoxShape3D:
			continue
		var parent := area.get_parent()
		if parent == null:
			continue
		var group := int(area.get_meta("hitbox_group"))
		var mat := StandardMaterial3D.new()
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.no_depth_test = true
		mat.albedo_color = Color(1.0, 0.2, 0.2, 0.4) if group == GameConsts.HITBOX_GROUP_HEAD else Color(0.3, 0.7, 1.0, 0.3)

		var mi := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = (box as BoxShape3D).size
		mi.mesh = mesh
		mi.material_override = mat
		mi.transform = shape.transform
		mi.add_to_group("debug_hitbox_mesh")
		parent.add_child(mi)
		count += 1
	return count


func free_debug_render() -> void:
	if _debug_render_root and is_instance_valid(_debug_render_root):
		_debug_render_root.queue_free()
	_debug_render_root = null
