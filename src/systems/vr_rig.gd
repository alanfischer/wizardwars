class_name VRRig
extends XROrigin3D
## The XR rig in main.tscn: the headset camera and the two controllers under it, the lobby panel
## hung in front of the camera with a laser pointer on each controller, and the rig following the
## local player's eye with the head clamped out of walls. Inert off VR.

const PANEL_OFFSET := Vector3(0.0, 0.0, -2.0)

@onready var camera: XRCamera3D = $XRCamera3D
@onready var left: XRController3D = $LeftController
@onready var right: XRController3D = $RightController
## The lobby, and the team/class menu while one is open. Null off VR.
var lobby_panel: VRLobbyPanel

var _head_probe := PhysicsShapeQueryParameters3D.new()


func _ready() -> void:
	set_process(XRManager.is_vr)
	if not XRManager.is_vr:
		return
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	var sphere := SphereShape3D.new()
	sphere.radius = 0.12
	_head_probe.shape = sphere
	_head_probe.collision_mask = GameConsts.MASK_WORLD_AND_CLIP


## Hangs the lobby in front of the camera, with a pointer on each controller. False off VR: the
## caller shows it as a plain CanvasLayer instead.
func host_lobby(lobby: LobbyUI) -> bool:
	if not XRManager.is_vr:
		return false
	lobby_panel = VRLobbyPanel.new()
	lobby_panel.name = "VRLobbyPanel"
	camera.add_child(lobby_panel)
	lobby_panel.position = PANEL_OFFSET
	lobby_panel.add_ui(lobby)
	right.add_child(_laser())
	left.add_child(_laser())
	return true


## Back in front of the camera, wherever the player had left it.
func attach_panel() -> void:
	if lobby_panel == null:
		return
	if lobby_panel.get_parent() != camera:
		lobby_panel.reparent(camera, false)
	lobby_panel.position = PANEL_OFFSET
	lobby_panel.rotation = Vector3.ZERO


func _process(_delta: float) -> void:
	var player := Game.local_player
	if Game.game_active and player:
		_follow(player)
	if lobby_panel and lobby_panel.visible:  # none if main returned before hosting the lobby
		if right.get_is_active():
			lobby_panel.update_pointer(right)
		elif left.get_is_active():
			lobby_panel.update_pointer(left)


func _follow(player: LocalPlayer) -> void:
	var nominal_eye: Vector3 = player.get_eye_position()
	var allowed_eye: Vector3 = nominal_eye
	if XRManager.advanced_head_tracking:
		# Roomscale: the capsule already tracks the head horizontally, so the camera's remaining XZ
		# lean is only the residual — how far the head has out-run a blocked capsule. Sphere-cast
		# the full 3D offset so walls AND ceilings both clamp the result.
		var head_local := camera.position
		var residual: Vector3 = player.get_vr_head_residual()
		var desired_eye := Vector3(
			nominal_eye.x + residual.x,
			player.global_position.y + head_local.y,
			nominal_eye.z + residual.z
		)
		if desired_eye.distance_squared_to(nominal_eye) > 0.0001:
			_head_probe.transform = Transform3D(Basis.IDENTITY, nominal_eye)
			_head_probe.motion = desired_eye - nominal_eye
			var motion: PackedFloat32Array = get_world_3d().direct_space_state.cast_motion(_head_probe)
			var safe_frac := 1.0 if motion.is_empty() else motion[0]
			allowed_eye = nominal_eye.lerp(desired_eye, safe_frac)
	global_position = allowed_eye - global_basis * camera.position


static func _laser() -> MeshInstance3D:
	var laser := MeshInstance3D.new()
	laser.name = "LaserPointer"
	var laser_mesh := BoxMesh.new()
	laser_mesh.size = Vector3(0.003, 0.003, 4.0)
	laser.mesh = laser_mesh
	var laser_mat := StandardMaterial3D.new()
	laser_mat.albedo_color = Color(1.0, 0.2, 0.2, 0.6)
	laser_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	laser_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	laser.material_override = laser_mat
	laser.position = PANEL_OFFSET
	return laser
