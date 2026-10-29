extends Node
## Bone lookups on a wizard's rig, and the upper-body animation libraries built off it. One place
## because they have to agree: get_bone_world_pos returns a beam's origin and get_bone_attachment
## parents the effect to that same bone, and both resolve through _resolve_bone. Split out of
## entity_util.gd.

# --- Attack animation library cache ---
# Keyed by element name. Each entry is an AnimationLibrary with leg/spine bones
# stripped, shared across all players of the same element.
var _attack_lib_cache: Dictionary = {}

# Bones stripped from attack animations (legs + spine/pelvis)
const _ATTACK_STRIP_BONES = [
	"Bip01", "Bip01 Pelvis",
	"Bip01 L Leg", "Bip01 L Leg1", "Bip01 L Foot",
	"Bip01 R Leg", "Bip01 R Leg1", "Bip01 R Foot",
	"Bip01 Spine", "Bip01 Spine1", "Bip01 Spine2", "Bip01 Spine3",
]


## Get or create an upper-body-only AnimationLibrary for the given element.
## The library is built once from the source AnimationPlayer and cached.
func get_attack_animation_library(element_name: String, source_player: AnimationPlayer) -> AnimationLibrary:
	if _attack_lib_cache.has(element_name):
		return _attack_lib_cache[element_name]
	var lib := source_player.get_animation_library(&"")
	var attack_lib := AnimationLibrary.new()
	for anim_name in lib.get_animation_list():
		var anim_copy := lib.get_animation(anim_name).duplicate()
		for t_idx in range(anim_copy.get_track_count() - 1, -1, -1):
			var subname: String = anim_copy.track_get_path(t_idx).get_concatenated_subnames()
			if subname in _ATTACK_STRIP_BONES:
				anim_copy.remove_track(t_idx)
		attack_lib.add_animation(anim_name, anim_copy)
	_attack_lib_cache[element_name] = attack_lib
	return attack_lib


## Returns true when bone lookups for `node` should use the right hand.
## Covers both the local VR player (right-handed) and remote puppets whose
## sync_right_hand_world is finite (hand tracking active) and are not left-handed.
func _node_uses_right_hand(node: Node3D) -> bool:
	# RemotePlayer carries its own VR/handedness via sync_* properties; LocalPlayer has none
	# and falls back to local XRManager state.
	var r_hand = node.get("sync_right_hand_world")
	if r_hand == null:
		return XRManager.is_vr and XRManager.hand_tracking and not XRManager.left_handed
	var left_handed = node.get("sync_left_handed")
	return (r_hand as Vector3).is_finite() and not (left_handed as bool)


## Resolve a bone name to the skeleton that has it and its index there. Tries _hand_skeleton
## first, then _skeleton (3P model), with the VR right-hand skeleton ahead of both when hand
## tracking is live; remaps "Bip01 L " → "Bip01 R " for right-handed VR players (local or
## puppet), and falls back to the hand bone on the 3P model.
## get_bone_world_pos and get_bone_attachment MUST agree here — one returns the beam origin,
## the other parents the effect to that same bone.
## Returns [Skeleton3D, bone_idx], or [] when no skeleton has the bone.
func _resolve_bone(node: Node3D, bone_name: String, fallback_bone: String) -> Array:
	var search_bone := bone_name
	var search_fallback := fallback_bone
	var skel_props: Array = ["_hand_skeleton", "_skeleton"]
	if _node_uses_right_hand(node):
		search_bone = bone_name.replace("Bip01 L ", "Bip01 R ")
		search_fallback = fallback_bone.replace("Bip01 L ", "Bip01 R ")
		if XRManager.is_vr and XRManager.hand_tracking:
			skel_props = ["_vr_right_hand_skeleton", "_hand_skeleton", "_skeleton"]
	var hand_fallback := "Bip01 R Hand" if search_bone.contains("Bip01 R ") else "Bip01 L Hand"
	for skel_prop in skel_props:
		var skel: Skeleton3D = node.get(skel_prop)
		if skel and is_instance_valid(skel):
			var bone_idx := skel.find_bone(search_bone)
			if bone_idx < 0 and not search_fallback.is_empty():
				bone_idx = skel.find_bone(search_fallback)
			if bone_idx < 0 and skel_prop == "_skeleton":
				bone_idx = skel.find_bone(hand_fallback)
			if bone_idx >= 0:
				return [skel, bone_idx]
	return []


## Get the world-space position of a named bone on a node's skeleton.
## Returns null if not found. See _resolve_bone for which skeleton and bone is chosen.
func get_bone_world_pos(node: Node3D, bone_name: String, fallback_bone := "") -> Variant:
	var found := _resolve_bone(node, bone_name, fallback_bone)
	if found.is_empty():
		return null
	var skel: Skeleton3D = found[0]
	var bone_pose := skel.get_bone_global_pose(found[1])
	return skel.global_transform * bone_pose.origin


## Find or create a BoneAttachment3D for a named bone on the node's skeleton.
## Useful for parenting effects to bones to eliminate frame lag/jitter.
## Falls back to `node` itself when no skeleton has the bone.
## See _resolve_bone for which skeleton and bone is chosen.
func get_bone_attachment(node: Node3D, bone_name: String, fallback_bone := "") -> Node3D:
	var found := _resolve_bone(node, bone_name, fallback_bone)
	if found.is_empty():
		return node
	var skel: Skeleton3D = found[0]
	var real_bone_name := skel.get_bone_name(found[1])
	for child in skel.get_children():
		if child is BoneAttachment3D and child.bone_name == real_bone_name:
			return child
	var ba := BoneAttachment3D.new()
	ba.bone_name = real_bone_name
	skel.add_child(ba)
	return ba

