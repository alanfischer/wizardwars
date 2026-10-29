class_name RagdollBuilder

## Turns a GoldSrc player model into a jointed ragdoll out of the hitboxes it already ships.
##
## models/player/*.mdl is 22 `Bip01` bones carrying 21 hitboxes — one per bone except the
## root — each an axis-aligned box in bone-local space, and the importer has already built
## every one of them as a BoneAttachment3D + Area3D + BoxShape3D with the GoldSrc→Godot
## swizzle done (goldsrc_mdl.cpp, build_hitboxes). So there is no per-model table here and
## none is wanted: the rig IS the ragdoll, and all six element models share it.
##
## Nothing is wired by hand either. A PhysicalBone3D finds its parent by walking BONE
## parents to the nearest bone that has one, and because every bone below the root has a
## hitbox that resolves to the exact skeleton hierarchy — the pelvis as the free root, with
## twenty cone-twist joints hanging off it. The one thing the rig does not get to decide is
## how far down it goes: a hitboxed twig with nothing hanging off it is left out of the
## simulation and rides its parent instead (LEAF_VOLUME_RATIO).
##
## The one thing that IS a table is the joint limits, below, because a body's spans are not
## derivable from its hitboxes.

## kg/m³. Flesh, near enough; what it really sets is the bones' masses relative to one
## another, which is what decides whether an arm can drag a torso around.
const DENSITY := 900.0
const MIN_MASS := 0.05
## The heaviest bone may outweigh the lightest by this much and no more. A mass floor derived
## from the rig rather than an absolute one, because what an impulse solver cannot do is
## reconcile a featherweight body pinned to a heavy one: the light bone gets flung every tick
## and never converges. The wizard rig never notices — its bones span 22:1 on their own — but
## bird.mdl hitboxes every toe and tail feather, and at true density those came out 282:1 with
## MIN_MASS alone. The bird then landed and kept twitching until it faded out, because
## TumblingCorpse calls a corpse settled when its BUSIEST bone has stopped and a handful of
## flung featherweights are always busy.
const MAX_MASS_RATIO := 25.0
## Twigs get no body of their own, and this is deliberately the SAME number: a bone the clamp
## above would have to lie about is a bone the rig can do without, so if it has nothing
## hanging off it, it is left out and its mass folds into the bone that would have held it
## up. The wizard rig, whose lightest leaf is a whole hand, loses nothing; the bird loses
## eight toes and the tip of its beak, which takes its true spread from 321:1 to 32:1 and
## leaves the clamp with almost nothing left to fake. Retune one and the other follows, which
## is the point of writing it this way. ONE pass, deliberately: prune the toes and the feet
## become leaves, prune those and the legs walk off a bone at a time.
const LEAF_VOLUME_RATIO := MAX_MASS_RATIO
## A capsule fitted into a flat hitbox — a wing, a blade of a tail — would otherwise come out
## with no thickness at all.
const MIN_CAPSULE_RADIUS := 0.01
## A corpse does not skid and does not bounce.
const FRICTION := 1.0
const BOUNCE := 0.0
## Spin damping per bone. A limb hanging on its joints touches nothing, so contact friction —
## the only other thing that takes energy out of this rig — never gets a hold of it, and it
## swings for as long as the corpse exists. Measured over eight drops: this takes the settled
## rig from 0.54 rad/s a bone to 0.31 and from 9.6 of 21 bones asleep to 12.4, and it does it
## without flattening the landing, which is why it is not higher — the tumble through the
## first second is unchanged at 4 and visibly deadened by 8.
const ANGULAR_DAMP := 4.0

## Swing and twist spans in DEGREES, keyed on the CHILD bone — the one the joint holds up,
## which is the `PhysicalBone3D` that owns it. All six element models share the rig, so one
## table covers every wizard. Numbers to start an argument with, not to trust: they are
## tuned by watching, and against the BAKED pose (see TumblingCorpse), because a settled
## corpse's bones shiver for a reason that has nothing to do with its joints.
##
## Anything missing from the table gets DEFAULT_LIMITS, so a model with a bone this list has
## never heard of still gets a corpse and not a squid.
##
## Every span here is DOUBLE what it was first tuned to, and the reason is the paragraph
## below: the cone is centred on the pose the wizard died in, standing, and a corpse on the
## ground is nowhere near that pose. At the old numbers twelve of the twenty joints settled
## OUTSIDE their cone — the spine at 42 degrees of swing against a span of 15 — so the limits
## spent the corpse's whole life shoving at a floor that was never going to move, and the rig
## shivered instead of sleeping (a mean 1.0 rad/s per bone, three to six of the twenty-one
## bones asleep). Doubling them makes the pose a corpse actually lands in nearly legal: 0.1 to
## 0.35 rad/s, and fifteen to twenty-one bones asleep. It costs about 15 cm of extra sprawl.
##
## **The cone is centred on the pose the ragdoll is BUILT in, and that is not a choice.**
## PhysicalBone3D derives both halves of the joint from ONE world transform —
## `joint_transf = global * joint_offset`, then `local_a = parent.global⁻¹ * joint_transf`,
## `local_b = joint_offset` (physical_bone_3d.cpp, _reload_joint) — so the two rest frames
## coincide by construction and no rotation of `joint_offset.basis` can prise them apart.
## Every cone is therefore symmetric about the pose the skeleton is holding when the joint is
## made, and that is why the elbow and knee spans below are smaller than a real joint's
## travel: they buy their range in both directions, so a knee gets 45 degrees of bend and 45
## of hyperextension rather than 60 of bend and none. A one-sided hinge would need a joint
## hop does not have and Godot would not hand it the frames for.
##
## Which pose that is: the one the wizard died in. TumblingCorpse poses its freshly loaded
## skeleton from the rotations that rode the spawn payload BEFORE calling this, so the cones
## centre themselves on the death pose and a corpse killed mid-stride is limited around the
## stride. That falls out of the ordering and costs nothing — but it is why the ordering is
## not free to change. A corpse built with no pose (offline, first person, no body skeleton
## to read) centres on the model's rest pose instead, which is only the old behaviour.
const JOINT_LIMITS := {
	"Bip01 Spine": [30.0, 40.0],   # four segments, so a little each is a lot together
	"Bip01 Spine1": [30.0, 40.0],
	"Bip01 Spine2": [30.0, 40.0],
	"Bip01 Spine3": [30.0, 40.0],
	"Bip01 Neck": [60.0, 60.0],
	"Bip01 Head": [90.0, 80.0],
	"Bip01 L Arm": [40.0, 30.0],   # clavicle
	"Bip01 R Arm": [40.0, 30.0],
	"Bip01 L Arm1": [160.0, 120.0],  # shoulder, the loosest joint in a body
	"Bip01 R Arm1": [160.0, 120.0],
	"Bip01 L Arm2": [90.0, 20.0],  # elbow
	"Bip01 R Arm2": [90.0, 20.0],
	"Bip01 L Hand": [90.0, 60.0],
	"Bip01 R Hand": [90.0, 60.0],
	"Bip01 L Leg": [120.0, 60.0],  # hip
	"Bip01 R Leg": [120.0, 60.0],
	"Bip01 L Leg1": [90.0, 10.0],  # knee
	"Bip01 R Leg1": [90.0, 10.0],
	"Bip01 L Foot": [70.0, 30.0],
	"Bip01 R Foot": [70.0, 30.0],
}
const DEFAULT_LIMITS := [90.0, 60.0]


## What `ragdolls` is asking for, as one of MODES — the raw var is a string a player typed, so
## anything unrecognised reads as the default and a typo leaves corpses alone rather than
## turning them off.
const MODES := ["off", "box", "capsule"]
const DEFAULT_MODE := "box"


static func mode() -> String:
	var value := str(ServerVars.get_value("ragdolls", DEFAULT_MODE))
	return value if value in MODES else DEFAULT_MODE


static func enabled() -> bool:
	return mode() != "off"


## Build the ragdoll under `model`'s skeleton and return its simulator, or null if the model
## has no skeleton or no hitboxes to build from. Nothing is simulating yet — the caller
## starts it. `root_layer` goes on the one free-root bone (the pelvis), which is the body
## the rest of the game finds; every other bone stays on layer 0, so limbs pass through each
## other and nothing in the game can be hit by a corpse's arm.
static func build(model: Node3D, root_layer: int, world_mask: int) -> PhysicalBoneSimulator3D:
	var skeleton := find_skeleton(model)
	if skeleton == null:
		return null
	var boxes := collect_hitboxes(skeleton)
	if boxes.is_empty():
		return null

	var folded := prune_leaves(skeleton, boxes)

	var hitboxed := {}
	for entry in boxes:
		hitboxed[entry["bone"]] = true

	var sim := PhysicalBoneSimulator3D.new()
	sim.name = "Ragdoll"
	skeleton.add_child(sim)

	# Read once: a rig is all one shape, and a var changed mid-build must not split it.
	var want_capsule := mode() == "capsule"
	# A bone can carry several hitboxes (raisedead.mdl has three on its head), but a simulator
	# takes one PhysicalBone3D per bone, so each bone is one body with a shape per box.
	var by_bone := {}
	for entry in boxes:
		if not by_bone.has(entry["bone"]):
			by_bone[entry["bone"]] = []
		by_bone[entry["bone"]].append(entry)

	var heaviest := 0.0
	for bone_idx in by_bone:
		heaviest = maxf(heaviest, _mass_of(bone_idx, by_bone[bone_idx], folded))
	var floor_mass := maxf(MIN_MASS, heaviest / MAX_MASS_RATIO)

	for bone_idx: int in by_bone:
		var bone_boxes: Array = by_bone[bone_idx]

		var phys := PhysicalBone3D.new()
		phys.name = "Bone_%d" % bone_idx
		sim.add_child(phys)
		phys.bone_name = skeleton.get_bone_name(bone_idx)

		# The body sits on its boxes' centre of volume, not on the bone; setting the offset also
		# places the joint back at the bone's own origin, which is where a limb actually pivots.
		var center := Vector3.ZERO
		var total := 0.0
		for entry in bone_boxes:
			center += entry["center"] * _volume(entry)
			total += _volume(entry)
		center = center / total if total > 0.0 else bone_boxes[0]["center"]
		for entry in bone_boxes:
			var shape := _shape_for(entry["size"], want_capsule)
			shape.position = entry["center"] - center
			phys.add_child(shape)

		var offset := Transform3D(Basis(), center)
		phys.body_offset = offset
		phys.joint_offset = offset.affine_inverse()
		# A cone-twist, which is the same ball-socket pin plus the spans in JOINT_LIMITS. Pins alone
		# constrain POSITION and say nothing about orientation, so every joint was a free
		# 360-degree swivel and the corpse landed as a heap with its neck folded to its
		# knees — see plans/ragdoll_joint_limits.md. The spans are set through the node's
		# properties, which take DEGREES and hand the server radians.
		phys.joint_type = PhysicalBone3D.JOINT_TYPE_CONE
		var limits: Array = JOINT_LIMITS.get(phys.bone_name, DEFAULT_LIMITS)
		phys.set("joint_constraints/swing_span", limits[0])
		phys.set("joint_constraints/twist_span", limits[1])

		phys.mass = maxf(floor_mass, _mass_of(bone_idx, bone_boxes, folded))
		phys.friction = FRICTION
		phys.bounce = BOUNCE
		phys.angular_damp = ANGULAR_DAMP
		# Only the free root answers to the rest of the game: a descending platform finds a
		# body through EntityBase._wake_touching_props, and that wants one hit, not 21.
		phys.collision_layer = root_layer if _is_free_root(skeleton, bone_idx, hitboxed) else 0
		phys.collision_mask = world_mask

	return sim


## One bone's body, from the hitbox it was read off. A box IS the hitbox and is the default;
## `/ragdolls capsule` fits a capsule inside that same box — the longest axis is the limb's
## length, the THINNER of the other two is the radius, so the capsule never reaches further
## than the box did and the two differ only in how a limb meets the floor. Mass stays on the box's volume either way, which
## keeps the comparison to the shape alone.
static func _shape_for(size: Vector3, want_capsule: bool) -> CollisionShape3D:
	var node := CollisionShape3D.new()
	if not want_capsule:
		var box := BoxShape3D.new()
		box.size = size
		node.shape = box
		return node
	var axis := size.max_axis_index()
	var cap := CapsuleShape3D.new()
	cap.radius = maxf(minf(size[(axis + 1) % 3], size[(axis + 2) % 3]) * 0.5, MIN_CAPSULE_RADIUS)
	cap.height = maxf(size[axis], cap.radius * 2.0)  # Godot's height counts both caps
	node.shape = cap
	# Godot stands a capsule along Y; stand this one along the hitbox's longest axis instead.
	if axis == 0:
		node.basis = Basis(Vector3.BACK, -PI * 0.5)
	elif axis == 2:
		node.basis = Basis(Vector3.RIGHT, PI * 0.5)
	return node


## The skeleton's current pose as one flat array of bone rotations, for handing a corpse the
## pose its owner died in. Rotations only: a GoldSrc rig poses by rotating bones, and their
## positions are the rest offsets the model already ships, so sending them would be 22 more
## vectors saying nothing. Quaternion per bone, in bone-index order, 4 floats each.
static func capture_pose(skeleton: Skeleton3D) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if skeleton == null:
		return out
	out.resize(skeleton.get_bone_count() * 4)
	for i in skeleton.get_bone_count():
		var q := skeleton.get_bone_pose_rotation(i)
		out[i * 4] = q.x
		out[i * 4 + 1] = q.y
		out[i * 4 + 2] = q.z
		out[i * 4 + 3] = q.w
	return out


## Put a captured pose back on a skeleton. Returns false and changes nothing if it does not
## fit — the bone count is the whole check, and it is enough: the six element models share
## one rig, so a pose that fits is a pose from that rig, and anything else (a bear, a model
## that changed under a stale client) is refused and falls back to the rest pose rather than
## being smeared onto the wrong bones.
static func apply_pose(skeleton: Skeleton3D, pose: PackedFloat32Array) -> bool:
	if skeleton == null or pose.size() != skeleton.get_bone_count() * 4:
		return false
	for i in skeleton.get_bone_count():
		skeleton.set_bone_pose_rotation(i, Quaternion(
			pose[i * 4], pose[i * 4 + 1], pose[i * 4 + 2], pose[i * 4 + 3]).normalized())
	return true


## Every MDL hitbox under `skeleton`, as {bone, size, center} with the box in bone-local
## space. Read this BEFORE AssetLoader.strip_hitboxes: it frees the BoneAttachment3D the
## bone index lives on.
static func collect_hitboxes(skeleton: Skeleton3D) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for child in skeleton.get_children():
		var attach := child as BoneAttachment3D
		if attach == null:
			continue
		for area_node in attach.get_children():
			var area := area_node as Area3D
			if area == null or not area.has_meta("hitbox_group"):
				continue
			for shape_node in area.get_children():
				var shape := shape_node as CollisionShape3D
				var box := shape.shape as BoxShape3D if shape else null
				if box == null:
					continue
				out.append({
					"bone": attach.bone_idx,
					"size": box.size,
					"center": shape.position,
				})
	return out


## Drop the twigs, in place, and return what each surviving bone inherited as
## {bone: volume}. See LEAF_VOLUME_RATIO. A leaf is a bone no other hitboxed bone hangs off,
## which is a question about the RAGDOLL tree rather than the skeleton's — bird.mdl hitboxes
## the wing tips and skips the forearm they hang from, so the bones between do not count.
## The free root is never a candidate: it holds the whole assembly up, and a one-bone rig
## would otherwise prune itself out of existence.
static func prune_leaves(skeleton: Skeleton3D, boxes: Array[Dictionary]) -> Dictionary:
	var volume := {}
	for entry in boxes:
		volume[entry["bone"]] = volume.get(entry["bone"], 0.0) + _volume(entry)
	var parent_of := {}
	var has_child := {}
	var heaviest := 0.0
	for bone in volume:
		heaviest = maxf(heaviest, volume[bone])
		parent_of[bone] = _hitboxed_parent(skeleton, bone, volume)
		if parent_of[bone] >= 0:
			has_child[parent_of[bone]] = true

	# One pass over the tree as it was, and one is all it can take: a pruned bone is never
	# another's parent — having a child is the whole test — so nothing below needs a second
	# look at what it just changed.
	var min_volume := heaviest / LEAF_VOLUME_RATIO
	var folded := {}
	var kept: Array[Dictionary] = []
	for entry in boxes:
		var bone: int = entry["bone"]
		var parent: int = parent_of[bone]
		if parent < 0 or has_child.has(bone) or volume[bone] >= min_volume:
			kept.append(entry)
			continue
		folded[parent] = folded.get(parent, 0.0) + _volume(entry)
	boxes.assign(kept)
	return folded


static func _volume(entry: Dictionary) -> float:
	var size: Vector3 = entry["size"]
	return size.x * size.y * size.z


static func _mass_of(bone_idx: int, bone_boxes: Array, folded: Dictionary) -> float:
	var volume: float = folded.get(bone_idx, 0.0)
	for entry in bone_boxes:
		volume += _volume(entry)
	return volume * DENSITY


## The nearest ancestor bone that carries a hitbox, or -1 for the free root — on a Bip01 rig
## the pelvis, the one bone with nothing above it to pin to.
static func _hitboxed_parent(skeleton: Skeleton3D, bone_idx: int, hitboxed: Dictionary) -> int:
	var parent := skeleton.get_bone_parent(bone_idx)
	while parent >= 0:
		if hitboxed.has(parent):
			return parent
		parent = skeleton.get_bone_parent(parent)
	return -1


static func _is_free_root(skeleton: Skeleton3D, bone_idx: int, hitboxed: Dictionary) -> bool:
	return _hitboxed_parent(skeleton, bone_idx, hitboxed) < 0


## Public because the corpse needs it to pose a freshly loaded model before building on it.
static func find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node as Skeleton3D
	for child in node.get_children():
		var found := find_skeleton(child)
		if found:
			return found
	return null
