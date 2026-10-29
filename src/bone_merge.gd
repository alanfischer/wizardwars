class_name BoneMerge
extends Node3D
## Replicates GoldSrc "bone merge": copies named bones from a source skeleton
## onto this one. Use attach(), or add as a child of the TARGET skeleton and call setup(source).
## Runs in _process() so it reads IK-modified source bone data.

var _source: Skeleton3D
var _target: Skeleton3D
var _bone_map: Dictionary = {}  # target bone idx -> source bone idx


static func attach(target_skel: Skeleton3D, source_skel: Skeleton3D) -> BoneMerge:
	var merge := BoneMerge.new()
	target_skel.add_child(merge)
	merge.setup(source_skel)
	return merge


func setup(source: Skeleton3D) -> void:
	_source = source
	_bone_map.clear()

	_target = get_parent() as Skeleton3D
	if not _target:
		return

	var source_names := {}  # String -> int
	for i in source.get_bone_count():
		source_names[source.get_bone_name(i)] = i

	for i in _target.get_bone_count():
		var bone_name := _target.get_bone_name(i)
		if bone_name in source_names:
			_bone_map[i] = source_names[bone_name]

	set_process(not _bone_map.is_empty())


func _process(_delta: float) -> void:
	if not is_instance_valid(_source) or not is_instance_valid(_target):
		return
	# Sorted so parents are processed before children.
	var sorted_keys: Array = _bone_map.keys()
	sorted_keys.sort()
	var src_gtf := _source.global_transform
	var tgt_gtf_inv := _target.global_transform.affine_inverse()
	# Caches overridden target world transforms so children can compute pose relative to them.
	var world_poses: Dictionary = {}  # int -> Transform3D
	for target_idx in sorted_keys:
		var source_idx: int = _bone_map[target_idx]
		var w_pose := src_gtf * _source.get_bone_global_pose(source_idx)
		world_poses[target_idx] = w_pose
		var parent_idx: int = _target.get_bone_parent(target_idx)
		var local_pose: Transform3D
		if parent_idx >= 0 and world_poses.has(parent_idx):
			local_pose = world_poses[parent_idx].affine_inverse() * w_pose
		elif parent_idx >= 0:
			var p_world := _target.global_transform * _target.get_bone_global_pose(parent_idx)
			local_pose = p_world.affine_inverse() * w_pose
		else:
			local_pose = tgt_gtf_inv * w_pose
		_target.set_bone_pose(target_idx, local_pose)
