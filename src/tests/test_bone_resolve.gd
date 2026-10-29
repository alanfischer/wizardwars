extends "res://src/tests/test_base.gd"
## BoneUtil._resolve_bone, through its two callers. get_bone_world_pos returns a beam origin
## and get_bone_attachment parents the effect to that same bone, so the two MUST pick the same
## bone on the same skeleton — if they drift apart the effect renders where the beam is not.
## Every test here asserts the pair agrees, not just that each works.

const TOL := 0.0001

## A puppet exposing the properties _resolve_bone probes: the two skeleton slots, plus the
## sync_* pair RemotePlayer carries its handedness in.
class BonePuppet extends Node3D:
	var _skeleton: Skeleton3D = null
	var _hand_skeleton: Skeleton3D = null
	var sync_right_hand_world := Vector3.INF
	var sync_left_handed := false


func _skel(bones: Dictionary) -> Skeleton3D:
	var skel := Skeleton3D.new()
	for name in bones:
		var idx := skel.add_bone(name)
		skel.set_bone_rest(idx, Transform3D(Basis(), bones[name]))
		# The rest alone leaves get_bone_global_pose at the origin, which would make every
		# bone here answer (0,0,0) and the agreement assertions pass on a mismatch.
		skel.set_bone_pose_position(idx, bones[name])
	return skel


func _puppet(hand_bones: Variant, body_bones: Variant) -> BonePuppet:
	var p := BonePuppet.new()
	if hand_bones != null:
		p._hand_skeleton = _skel(hand_bones)
		p.add_child(p._hand_skeleton)
	if body_bones != null:
		p._skeleton = _skel(body_bones)
		p.add_child(p._skeleton)
	_root().add_child(p)
	return p


## The world position _resolve_bone's answer implies, computed independently of the function
## under test: whichever bone the attachment landed on, read off that skeleton directly.
func _pos_of_attachment(ba: Node3D) -> Vector3:
	var skel := ba.get_parent() as Skeleton3D
	var idx := skel.find_bone(ba.bone_name)
	return skel.global_transform * skel.get_bone_global_pose(idx).origin


## Both callers resolved the same bone, and that bone is `expected`.
func _assert_pair_agrees(p: Node3D, bone: String, expected: String, fallback := "") -> void:
	var pos = BoneUtil.get_bone_world_pos(p, bone, fallback)
	var ba := BoneUtil.get_bone_attachment(p, bone, fallback)
	assert_ne(pos, null, "%s: get_bone_world_pos found a bone" % expected)
	assert_true(ba is BoneAttachment3D, "%s: get_bone_attachment made an attachment" % expected)
	assert_eq(ba.bone_name, expected, "attachment parented to the expected bone")
	assert_vec3_almost_eq(pos, _pos_of_attachment(ba), TOL,
		"beam origin is the attachment's bone, not some other bone")


func test_direct_hit_on_hand_skeleton() -> void:
	var p := _puppet({"Bip01 L Hand": Vector3(1, 0, 0)}, {"Bip01 L Hand": Vector3(9, 0, 0)})
	await _settle()
	_assert_pair_agrees(p, "Bip01 L Hand", "Bip01 L Hand")
	# Both must have preferred the 1P hand skeleton over the 3P body one.
	var pos = BoneUtil.get_bone_world_pos(p, "Bip01 L Hand")
	assert_vec3_almost_eq(pos, Vector3(1, 0, 0), TOL, "_hand_skeleton wins over _skeleton")
	p.free()


func test_falls_through_to_body_skeleton() -> void:
	# The bone exists only on the 3P model; the hand skeleton is present but has other bones.
	var p := _puppet({"Bip01 Head": Vector3(0, 2, 0)}, {"Bip01 Spine": Vector3(0, 1, 0)})
	await _settle()
	_assert_pair_agrees(p, "Bip01 Spine", "Bip01 Spine")
	p.free()


func test_fallback_bone_used_when_primary_missing() -> void:
	var p := _puppet(null, {"Bip01 L Finger1": Vector3(3, 0, 0)})
	await _settle()
	_assert_pair_agrees(p, "Bip01 L Finger0", "Bip01 L Finger1", "Bip01 L Finger1")
	p.free()


func test_hand_fallback_on_body_skeleton_only() -> void:
	# Neither the bone nor its fallback exists, but the 3P skeleton has the hand: both callers
	# land on "Bip01 L Hand". The hand skeleton must NOT take that shortcut.
	var p := _puppet({"Bip01 L Hand": Vector3(5, 0, 0)},
			{"Bip01 L Hand": Vector3(0, 0, 7), "Bip01 Spine": Vector3(0, 1, 0)})
	await _settle()
	_assert_pair_agrees(p, "Bip01 L Finger11", "Bip01 L Hand")
	var pos = BoneUtil.get_bone_world_pos(p, "Bip01 L Finger11")
	assert_vec3_almost_eq(pos, Vector3(0, 0, 7), TOL,
		"the hand fallback is the _skeleton's hand; _hand_skeleton gets no such fallback")
	p.free()


func test_right_handed_puppet_remaps_both_callers() -> void:
	# A remote puppet with hand tracking live and right-handed: "Bip01 L " -> "Bip01 R ".
	var p := _puppet(null, {"Bip01 L Hand": Vector3(-2, 0, 0), "Bip01 R Hand": Vector3(2, 0, 0)})
	p.sync_right_hand_world = Vector3(1, 1, 1)
	await _settle()
	_assert_pair_agrees(p, "Bip01 L Hand", "Bip01 R Hand")
	p.free()


func test_left_handed_puppet_does_not_remap() -> void:
	var p := _puppet(null, {"Bip01 L Hand": Vector3(-2, 0, 0), "Bip01 R Hand": Vector3(2, 0, 0)})
	p.sync_right_hand_world = Vector3(1, 1, 1)
	p.sync_left_handed = true
	await _settle()
	_assert_pair_agrees(p, "Bip01 L Hand", "Bip01 L Hand")
	p.free()


func test_remapped_hand_fallback_is_the_right_hand() -> void:
	# The remap drives the hand fallback too: a right-handed puppet missing the finger bone
	# falls back to "Bip01 R Hand", never the left one.
	var p := _puppet(null, {"Bip01 L Hand": Vector3(-2, 0, 0), "Bip01 R Hand": Vector3(2, 0, 0)})
	p.sync_right_hand_world = Vector3(1, 1, 1)
	await _settle()
	_assert_pair_agrees(p, "Bip01 L Finger11", "Bip01 R Hand")
	p.free()


func test_no_match_agrees_on_failure() -> void:
	# The one case the two differ by design, and they must differ exactly this way.
	var p := _puppet(null, {"Bip01 Spine": Vector3(0, 1, 0)})
	await _settle()
	assert_eq(BoneUtil.get_bone_world_pos(p, "Bip01 Pelvis"), null, "no bone -> null position")
	assert_eq(BoneUtil.get_bone_attachment(p, "Bip01 Pelvis"), p, "no bone -> the node itself")
	p.free()


func test_no_skeleton_at_all() -> void:
	var p := _puppet(null, null)
	await _settle()
	assert_eq(BoneUtil.get_bone_world_pos(p, "Bip01 L Hand"), null, "no skeleton -> null")
	assert_eq(BoneUtil.get_bone_attachment(p, "Bip01 L Hand"), p, "no skeleton -> the node")
	p.free()


func test_attachment_is_reused_not_duplicated() -> void:
	var p := _puppet(null, {"Bip01 L Hand": Vector3(1, 0, 0)})
	await _settle()
	var first := BoneUtil.get_bone_attachment(p, "Bip01 L Hand")
	var second := BoneUtil.get_bone_attachment(p, "Bip01 L Hand")
	assert_eq(second, first, "second call reuses the existing BoneAttachment3D")
	p.free()


func test_attachment_reused_across_the_fallback_path() -> void:
	# Two different requests that resolve to the same real bone share one attachment — the
	# reuse keys off the resolved bone name, not the name asked for.
	var p := _puppet(null, {"Bip01 L Hand": Vector3(1, 0, 0)})
	await _settle()
	var direct := BoneUtil.get_bone_attachment(p, "Bip01 L Hand")
	var via_fallback := BoneUtil.get_bone_attachment(p, "Bip01 L Finger11")
	assert_eq(via_fallback, direct, "both resolved to Bip01 L Hand and share its attachment")
	p.free()
