extends CharacterBody3D
## Miniature wizard hitbox rig for LagCompensation tests: mirrors how GoldSrcMDL::build_hitboxes
## wires real models, and implements the lag_comp_* trio so rewind's full-fidelity path can be
## exercised without loading an MDL.

const CLIP := &"walk"
const BONE := &"root"
## Bone travel over the clip, so a rewind to the wrong frame is unmistakable in the assertions.
const BONE_TRAVEL := Vector3(4, 0, 0)
const CROUCH_DROP := Vector3(0, -0.5, 0)

var peer_id := 0
var lag_comp_shot_time_ms := 0

var sync_crouched := false
var sync_pitch := 0.0

var _model_root: Node3D
var _skeleton: Skeleton3D
var _anim: AnimationPlayer
var _areas: Array[Area3D] = []


func build_rig(box_offset := Vector3.ZERO, size := Vector3.ONE) -> void:
	_model_root = Node3D.new()
	_model_root.name = "ModelRoot"
	add_child(_model_root)

	_skeleton = Skeleton3D.new()
	_skeleton.name = "Skeleton3D"
	_model_root.add_child(_skeleton)
	_skeleton.add_bone(BONE)
	_skeleton.set_bone_rest(0, Transform3D.IDENTITY)

	var attach := BoneAttachment3D.new()
	_skeleton.add_child(attach)
	attach.bone_idx = 0

	var area := Area3D.new()
	area.collision_layer = GameConsts.MASK_HITBOX
	area.collision_mask = 0
	area.monitoring = false
	area.monitorable = true
	area.set_meta("hitbox_group", 0)
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	area.add_child(cs)
	attach.add_child(area)
	area.position = box_offset
	_areas.append(area)

	var anim := Animation.new()
	anim.length = 1.0
	var track := anim.add_track(Animation.TYPE_POSITION_3D)
	anim.track_set_path(track, NodePath("ModelRoot/Skeleton3D:%s" % BONE))
	anim.position_track_insert_key(track, 0.0, Vector3.ZERO)
	anim.position_track_insert_key(track, 1.0, BONE_TRAVEL)
	var lib := AnimationLibrary.new()
	lib.add_animation(CLIP, anim)
	_anim = AnimationPlayer.new()
	add_child(_anim)
	_anim.add_animation_library(&"", lib)
	# Playing but frozen (speed_scale 0): real puppets' players are always playing, rewind's seek must match.
	_anim.play(CLIP)
	_anim.speed_scale = 0.0


func seek_clip(time: float) -> void:
	_anim.seek(time, true)


func set_crouched(crouched: bool) -> void:
	sync_crouched = crouched
	_model_root.position = CROUCH_DROP if crouched else Vector3.ZERO


func get_hitbox_areas() -> Array[Area3D]:
	return _areas


func lag_comp_capture_pose() -> Array:
	return [sync_crouched, _anim.current_animation, _anim.current_animation_position, sync_pitch]


func lag_comp_apply_pose(pose: Array) -> void:
	sync_crouched = pose[0]
	sync_pitch = pose[3]
	_model_root.position = CROUCH_DROP if sync_crouched else Vector3.ZERO
	var clip: StringName = pose[1]
	if clip != &"":
		if _anim.current_animation != clip:
			_anim.play(clip)
		_anim.seek(pose[2], true)


func lag_comp_hitbox_world_transforms() -> Array:
	var out: Array = []
	_skeleton.force_update_all_bone_transforms()
	var skel_xform := _skeleton.global_transform
	for area in _areas:
		var attach := area.get_parent() as BoneAttachment3D
		out.append(skel_xform * _skeleton.get_bone_global_pose(attach.bone_idx) * area.transform)
	return out
