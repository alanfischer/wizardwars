extends "res://src/tests/test_base.gd"
## A dead wizard is a ragdoll built out of the model's own MDL hitboxes: what the builder
## makes of a real wizard model, what the corpse does with it, and what `/ragdolls off` falls
## back to.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.

const CorpseScript = preload("res://src/monsters/tumbling_corpse.gd")
const MODEL := "models/player/fire.mdl"
const BIRD_MODEL := "models/npc/bird.mdl"
const ARENA := Vector3(-300.0, 200.0, 300.0)  # clear of map geometry, and of the other suites'
## The velocity a corpse under test was killed carrying — horizontal, so a topple has an axis
## to lay itself across (a body hit from straight above pitches nowhere; see _initial_spin).
const BLOW := Vector3(0.0, 0.0, -4.0)

var _ragdolls_was := "box"
## Impact sounds heard since the test started, by file name (see _note_sound).
var _heard: Array[String] = []
## Splashes heard since the test started, as {clip, pitch, volume, position} — kept apart from
## _heard because what is under test is the voice a splash comes out in, not just that it played.
var _splashes: Array[Dictionary] = []


func _setup_test(_name: String) -> void:
	_ragdolls_was = RagdollBuilder.mode()
	_heard.clear()
	_splashes.clear()
	var scene := (Engine.get_main_loop() as SceneTree).current_scene
	if scene and not scene.child_entered_tree.is_connected(_note_sound):
		scene.child_entered_tree.connect(_note_sound)


func _teardown_test() -> void:
	ServerVars.set_from_string("ragdolls", _ragdolls_was)
	var scene := (Engine.get_main_loop() as SceneTree).current_scene
	if scene and scene.child_entered_tree.is_connected(_note_sound):
		scene.child_entered_tree.disconnect(_note_sound)
	super()


## SoundSystem parents its one-shots to the current scene, so watching that node is the whole
## instrument: every corpse landing arrives here as an AudioStreamPlayer3D holding one of the
## sounds/debris clips.
func _note_sound(node: Node) -> void:
	var player := node as AudioStreamPlayer3D
	if player == null or player.stream == null:
		return
	var path := player.stream.resource_path
	if path.contains("/debris/"):
		_heard.append(path.get_file())
	elif path.contains("/misc/splash"):
		var heard := {"clip": path.get_file(), "pitch": player.pitch_scale,
			"volume": player.volume_db, "position": Vector3.INF}
		_splashes.append(heard)
		# SoundSystem positions the player AFTER adding it, and a one-shot frees itself the
		# moment the clip ends — which for a short splash can be before the test looks. So the
		# position is taken off the node at the end of this frame, not read back later.
		_note_splash_position.call_deferred(heard, player)


func _note_splash_position(heard: Dictionary, player: AudioStreamPlayer3D) -> void:
	if is_instance_valid(player):
		heard["position"] = player.global_position


## A pool whose surface sits `below` metres under `pos` — what a map's water is to a corpse:
## an Area3D on MASK_WATER that nothing collides with and only a point query finds.
func _pool_below(pos: Vector3, below: float, depth := 3.0,
		layer := GameConsts.MASK_WATER) -> Area3D:
	var area := Area3D.new()
	area.collision_layer = layer
	area.collision_mask = 0
	area.monitorable = true
	area.monitoring = false
	var box := BoxShape3D.new()
	box.size = Vector3(40.0, depth, 40.0)
	var col := CollisionShape3D.new()
	col.shape = box
	area.add_child(col)
	_root().add_child(area)
	area.global_position = pos - Vector3(0.0, below + depth * 0.5, 0.0)
	_keep(area)
	return area


func _skull_at(pos: Vector3, seed := 5) -> TumblingCorpse:
	var corpse: TumblingCorpse = CorpseScript.new()
	corpse.setup({
		"position": pos,
		"velocity": Vector3.ZERO,
		"model": "models/flyingskull.mdl",
		"kind": TumblingCorpse.Kind.PROP,
		"seed": seed,
	}, true)
	_root().add_child(corpse)
	_keep(corpse)
	return corpse


## `host` false builds the corpse the way a client replica is built: same payload, same seed,
## its own simulation of it. `age` is how long the host's corpse had already lain there when
## this one was built — what a client reads off the spawn stamp (see TumblingCorpse._age), set
## here directly because a test has no server clock to measure against.
func _corpse_at(pos: Vector3, host := true, age := 0.0) -> TumblingCorpse:
	var corpse: TumblingCorpse = CorpseScript.new()
	corpse.setup(TumblingCorpse.wizard_payload(pos, 0.0, GameConsts.Element.FIRE, Vector3.ZERO), host)
	corpse._age = age
	_root().add_child(corpse)
	_keep(corpse)
	return corpse


## Whether this corpse cried out for the death it came from. A death sound is spawned ON the
## corpse (SoundSystem.spawn_on), so unlike its landings it never passes through the scene the
## sound watcher above listens to.
func _screamed(corpse: TumblingCorpse) -> bool:
	for node in _descendants(corpse):
		var player := node as AudioStreamPlayer3D
		if player != null and player.stream != null \
				and player.stream.resource_path.contains("/player/death"):
			return true
	return false


func _bones(corpse: TumblingCorpse) -> Array[PhysicalBone3D]:
	var out: Array[PhysicalBone3D] = []
	for node in _descendants(corpse):
		if node is PhysicalBone3D:
			out.append(node as PhysicalBone3D)
	return out


func _descendants(node: Node, out: Array[Node] = []) -> Array[Node]:
	for child in node.get_children():
		out.append(child)
		_descendants(child, out)
	return out


## Tick until the corpse has baked, and no longer. A corpse settles well inside MAX_SIM_TIME —
## waiting the whole cap out is seconds of wall clock per test for nothing.
func _tick_until_baked(corpse: TumblingCorpse, frames := 540) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	for i in frames:
		await tree.physics_frame
		if corpse._baked:
			return


func test_the_builder_reads_the_ragdoll_off_the_model() -> void:
	var model := AssetLoader.load_model(MODEL)
	assert_true(model != null, "the wizard model loads")
	_root().add_child(model)
	_keep(model)

	var sim := RagdollBuilder.build(model, GameConsts.MASK_CORPSE, GameConsts.MASK_WORLD)
	assert_true(sim != null, "and it already carries a ragdoll")

	var bones: Array[PhysicalBone3D] = []
	for child in sim.get_children():
		if child is PhysicalBone3D:
			bones.append(child as PhysicalBone3D)
	# 22 Bip01 bones, 21 hitboxes — one per bone except the root.
	assert_eq(bones.size(), 21, "one body per hitbox, and the model ships 21")

	var roots := 0
	var named := {}
	var spanned := 0
	for bone in bones:
		assert_eq(bone.joint_type, PhysicalBone3D.JOINT_TYPE_CONE,
			"cone-twists, so a neck cannot fold to the knees")
		var want: Array = RagdollBuilder.JOINT_LIMITS.get(bone.bone_name, RagdollBuilder.DEFAULT_LIMITS)
		assert_true(is_equal_approx(bone.get("joint_constraints/swing_span"), want[0]),
			"%s swings %.0f degrees" % [bone.bone_name, want[0]])
		assert_true(is_equal_approx(bone.get("joint_constraints/twist_span"), want[1]),
			"%s twists %.0f degrees" % [bone.bone_name, want[1]])
		if RagdollBuilder.JOINT_LIMITS.has(bone.bone_name):
			spanned += 1
		assert_eq(bone.collision_mask, GameConsts.MASK_WORLD, "a bone falls against the world and nothing else")
		assert_true(bone.mass > 0.0, "and weighs something")
		assert_true(bone.get_child(0) is CollisionShape3D, "carrying the hitbox's own box")
		if bone.collision_layer == GameConsts.MASK_CORPSE:
			roots += 1
		else:
			assert_eq(bone.collision_layer, 0, "every other bone is untouchable — limbs pass through each other")
		named[bone.bone_name] = true
	assert_eq(roots, 1, "exactly one free root answers to the rest of the game")
	assert_eq(named.size(), 21, "and no bone was wired twice")
	# The pelvis is the free root and has no joint; every other bone is in the table by name,
	# so nothing fell through to DEFAULT_LIMITS on the rig the game actually ships.
	assert_eq(spanned, 20, "and every jointed bone has spans of its own")


## raisedead.mdl hangs three hitboxes off its head bone, and a simulator takes one body per
## bone: a second one on the same bone is refused with an engine error. So the head is one
## body holding all three boxes.
func test_a_bone_with_several_hitboxes_is_one_body() -> void:
	var model := AssetLoader.load_model("models/combo/raisedead.mdl")
	assert_true(model != null, "the raisedead model loads")
	_root().add_child(model)
	_keep(model)
	var skeleton := RagdollBuilder.find_skeleton(model)
	var head := skeleton.find_bone("Bip01 Head")
	var head_boxes := 0
	for entry in RagdollBuilder.collect_hitboxes(skeleton):
		if entry["bone"] == head:
			head_boxes += 1
	assert_eq(head_boxes, 3, "the model ships three boxes on its head")

	var sim := RagdollBuilder.build(model, GameConsts.MASK_CORPSE, GameConsts.MASK_WORLD)
	var heads: Array[PhysicalBone3D] = []
	for child in sim.get_children():
		if child is PhysicalBone3D and child.bone_name == "Bip01 Head":
			heads.append(child as PhysicalBone3D)
	assert_eq(heads.size(), 1, "the head is one body")
	assert_eq(heads[0].get_child_count(), 3, "carrying all three boxes")


## One var, three states, and the raw value is whatever a player typed into chat — so anything
## that is not one of the three has to read as the default rather than as "off", which would
## silently take everyone's corpses away.
func test_a_mistyped_mode_leaves_corpses_alone() -> void:
	for typo in ["capsul", "true", "", "1"]:
		ServerVars.set_from_string("ragdolls", typo)
		assert_eq(RagdollBuilder.mode(), RagdollBuilder.DEFAULT_MODE,
			"'%s' is not a mode, so it reads as %s" % [typo, RagdollBuilder.DEFAULT_MODE])
		assert_true(RagdollBuilder.enabled(), "and corpses still ragdoll")
	ServerVars.set_from_string("ragdolls", "off")
	assert_false(RagdollBuilder.enabled(), "only 'off' turns them off")


## `/ragdolls capsule` is a diagnostic, not a second rig: the same bodies, the same masses,
## each capsule fitted inside the hitbox it stands in for. Only how a bone meets the floor
## changes, which is the whole point of being able to flip between them.
func test_a_capsule_rig_is_the_same_rig_in_another_shape() -> void:
	var boxed := _rig_shapes(MODEL)
	assert_eq(boxed.size(), 21, "the boxed rig is the 21 the model ships")

	ServerVars.set_from_string("ragdolls", "capsule")
	var capped := _rig_shapes(MODEL)
	assert_eq(capped.size(), boxed.size(), "and the capsule rig is the same bodies")

	for bone_name in boxed:
		var box: Dictionary = boxed[bone_name]
		var cap: Dictionary = capped.get(bone_name, {})
		assert_true(not cap.is_empty(), "%s is still a body" % bone_name)
		assert_true(cap["shape"] is CapsuleShape3D, "%s is a capsule" % bone_name)
		assert_true(is_equal_approx(cap["mass"], box["mass"]),
			"%s weighs what its box did, so only the shape changed" % bone_name)
		var fits: Vector3 = box["reach"] - cap["reach"]
		assert_true(fits.x > -0.001 and fits.y > -0.001 and fits.z > -0.001,
			"%s fits inside the hitbox it replaces" % bone_name)


func test_a_capsule_corpse_still_lands_in_one_piece() -> void:
	ServerVars.set_from_string("ragdolls", "capsule")
	_floor_at(ARENA - Vector3(0.0, 1.0, 0.0))
	var corpse := _corpse_at(ARENA + Vector3(0.0, 2.0, 0.0))
	await _tick(2)
	var bones := _bones(corpse)
	assert_eq(bones.size(), 21, "a capsule corpse is the same 21 bodies")
	assert_true((bones[0].get_child(0) as CollisionShape3D).shape is CapsuleShape3D,
		"made of capsules")

	var start := corpse.global_position.y
	await _tick(40)
	assert_true(corpse.global_position.y < start, "it fell")
	assert_true(corpse.global_position.y > ARENA.y - 3.0, "onto the floor, not through it")
	var reach := 0.0
	for bone in bones:
		reach = maxf(reach, bone.global_position.distance_to(corpse.global_position))
	assert_true(reach < 1.5, "and in one piece — furthest bone %.2f m from the pelvis" % reach)


## Each bone of a freshly built rig as {shape, mass, reach}, where reach is the half-extents
## the shape actually occupies in the BODY's frame — a capsule is turned onto the hitbox's
## long axis, so its own half-extents are in the wrong order to compare raw.
func _rig_shapes(model_path: String) -> Dictionary:
	var model := AssetLoader.load_model(model_path)
	_root().add_child(model)
	_keep(model)
	var sim := RagdollBuilder.build(model, GameConsts.MASK_CORPSE, GameConsts.MASK_WORLD)
	var out := {}
	if sim == null:
		return out
	for child in sim.get_children():
		var bone := child as PhysicalBone3D
		if bone == null:
			continue
		var shape := bone.get_child(0) as CollisionShape3D
		out[bone.bone_name] = {
			"shape": shape.shape,
			"mass": bone.mass,
			"reach": (shape.transform * GeomUtil.shape_local_aabb(shape.shape)).size * 0.5,
		}
	return out


func test_a_dead_wizard_falls_apart_and_lands() -> void:
	_floor_at(ARENA - Vector3(0.0, 1.0, 0.0))
	var corpse := _corpse_at(ARENA + Vector3(0.0, 2.0, 0.0))
	await _tick(2)

	var bones := _bones(corpse)
	assert_eq(bones.size(), 21, "the corpse is 21 bodies")
	assert_true(corpse.freeze, "and the node itself simulates nothing — it is only their reference")

	var start := corpse.global_position.y
	await _tick(40)
	assert_true(corpse.global_position.y < start, "it fell")
	assert_true(corpse.global_position.y > ARENA.y - 3.0, "onto the floor, not through it")
	assert_true(corpse.is_in_group("corpses"), "and it is a body a necromancer can find")

	# The pins held. A wizard is 1.8 m standing, so no bone is much over a metre from his
	# pelvis; if the joints were the force springs they used to be, the chain would have
	# stretched under its own weight, and if they had failed outright the bones would simply
	# have fallen apart.
	var reach := 0.0
	for bone in bones:
		reach = maxf(reach, bone.global_position.distance_to(corpse.global_position))
	assert_true(reach < 1.5, "and it landed in one piece — furthest bone %.2f m from the pelvis" % reach)

	# And it landed as a BODY. A pin-only corpse folds its spine in half on the way down,
	# which is what the cone spans exist to stop: the head sits ~0.6 m from the pelvis on a
	# standing wizard, and the four spine segments plus neck plus head cannot lose much of
	# that between them however the corpse comes to rest.
	var skeleton: Skeleton3D = corpse._sim.get_parent()
	var head := skeleton.find_bone("Bip01 Head")
	var pelvis := skeleton.find_bone("Bip01 Pelvis")
	assert_true(head >= 0 and pelvis >= 0, "the rig has a head and a pelvis")
	var spine := skeleton.get_bone_global_pose(head).origin.distance_to(
		skeleton.get_bone_global_pose(pelvis).origin)
	assert_true(spine > 0.35, "and kept its spine — head %.2f m from the pelvis" % spine)


func test_a_settled_corpse_stops_simulating_and_keeps_its_pose() -> void:
	_floor_at(ARENA - Vector3(0.0, 1.0, 0.0))
	var corpse := _corpse_at(ARENA)
	await _tick(2)
	var skeleton: Skeleton3D = corpse._sim.get_parent()
	var rest := skeleton.get_bone_global_pose(1)

	# Past MAX_SIM_TIME nothing is left simulating whatever hop has decided about sleep.
	var ticks := int(TumblingCorpse.MAX_SIM_TIME / 0.016667) + 30
	await _tick(ticks)

	assert_true(corpse._baked, "the corpse baked")
	assert_true(corpse._sim == null, "the simulator is gone")
	assert_true(_bones(corpse).is_empty(), "and so are its 21 bodies")
	var posed := skeleton.get_bone_global_pose(1)
	assert_true(posed.origin.distance_to(rest.origin) > 0.001
			or posed.basis.get_rotation_quaternion().angle_to(rest.basis.get_rotation_quaternion()) > 0.01,
		"the pose it kept is the one it fell into, not the one it started in")


## A corpse builds its own fresh model, so without a pose it starts from the model's REST
## pose and a wizard killed mid-stride pops upright before he falls. The dying body's bone
## rotations ride the spawn payload; this is the round trip, capture to corpse.
func test_a_corpse_starts_in_the_pose_its_owner_died_in() -> void:
	var model := AssetLoader.load_model(MODEL)
	assert_true(model != null, "the wizard model loads")
	_root().add_child(model)
	_keep(model)
	var skeleton := RagdollBuilder.find_skeleton(model)
	assert_true(skeleton != null, "and it has a skeleton")

	# Bend one bone somewhere the rest pose certainly is not, and read the pose back out.
	var bone := skeleton.find_bone("Bip01 L Arm1")
	assert_true(bone >= 0, "the rig has a left shoulder")
	var bent := Quaternion(Vector3.UP, 0.9)
	skeleton.set_bone_pose_rotation(bone, bent)
	var pose := RagdollBuilder.capture_pose(skeleton)
	assert_eq(pose.size(), skeleton.get_bone_count() * 4, "a quaternion per bone, and no more")

	_floor_at(ARENA - Vector3(0.0, 1.0, 0.0))
	var corpse: TumblingCorpse = CorpseScript.new()
	corpse.setup(TumblingCorpse.wizard_payload(
		ARENA, 0.0, GameConsts.Element.FIRE, Vector3.ZERO, pose), true)
	_root().add_child(corpse)
	_keep(corpse)
	await _tick(1)

	var corpse_skeleton: Skeleton3D = corpse._sim.get_parent()
	var landed := corpse_skeleton.get_bone_pose_rotation(bone)
	assert_true(landed.angle_to(bent) < 0.05,
		"the corpse woke up holding the pose it was handed (%.2f rad off)" % landed.angle_to(bent))

	# And the refusal: a pose that does not fit the rig is dropped, not smeared onto whatever
	# bones happen to line up. A bear leaves a wizard corpse, so this path is reachable.
	var wrong := PackedFloat32Array()
	wrong.resize(8)
	assert_false(RagdollBuilder.apply_pose(corpse_skeleton, wrong),
		"a pose from the wrong rig is refused")


## A settled corpse does not hold still, it CREEPS — a couple of centimetres a second, for as
## long as you watch, because every bone balances on a box corner that is handed fresh spin
## every tick and friction turns the rocking into a crawl. The settle test measures travel per
## WINDOW for exactly that reason. Measured from a fixed point, as it once was, the creep
## crosses any threshold eventually, resets the timer, and does it again — so a corpse could
## only ever bake on a lucky quiet stretch, or at MAX_SIM_TIME. This asserts it bakes because
## it stopped, not because it ran out of time.
func test_a_corpse_that_only_creeps_counts_as_stopped() -> void:
	_floor_at(ARENA - Vector3(0.0, 1.0, 0.0))
	var corpse := _corpse_at(ARENA + Vector3(0.0, 0.5, 0.0))
	await _tick(int(6.0 / 0.016667))
	assert_true(corpse._baked, "the corpse baked")
	assert_true(corpse._sim_time < TumblingCorpse.MAX_SIM_TIME - 1.0,
		"and it baked because it stopped, not because it ran out of time (%.2f s of %.1f s)"
			% [corpse._sim_time, TumblingCorpse.MAX_SIM_TIME])


## A corpse is something a force can still move, and the verb is the corpse's own rather than
## the funnel's — a tornado is the first caller, an explosion could be the next. Every bone takes
## it, because a rigid throw is the one operator a jointed chain satisfies exactly.
func test_a_corpse_takes_a_shove_while_it_is_still_a_simulation() -> void:
	_floor_at(ARENA - Vector3(0.0, 1.0, 0.0))
	var corpse := _corpse_at(ARENA)
	await _tick(2)

	assert_true(corpse.is_in_group("pushable"), "a corpse is something a force can move")
	var shove := Vector3(0.0, 9.0, 3.0)
	assert_true(corpse.push(shove), "a corpse still simulating takes the shove")
	var bones := _bones(corpse)
	assert_eq(bones.size(), 21, "all 21 bodies are still there")
	var worst := 0.0
	for bone in bones:
		worst = maxf(worst, bone.linear_velocity.distance_to(shove))
	assert_true(worst < 0.001, "and every one of them is carrying it (worst %.4f m/s off)" % worst)


## ...and the other half of the same rule, which is the whole answer for a corpse that has
## stopped: it is furniture. Said once, in the corpse, rather than by everything that pushes.
func test_a_settled_corpse_is_furniture() -> void:
	_floor_at(ARENA - Vector3(0.0, 1.0, 0.0))
	var corpse := _corpse_at(ARENA)
	await _tick(2)
	var skeleton: Skeleton3D = corpse._sim.get_parent()
	await _tick_until_baked(corpse)
	assert_true(corpse._baked, "the corpse baked")

	var settled := skeleton.get_bone_global_pose(1)
	assert_false(corpse.push(Vector3(0.0, 20.0, 0.0)), "a baked corpse refuses the shove")
	await _tick(30)
	assert_true(skeleton.get_bone_global_pose(1).origin.distance_to(settled.origin) < 0.001,
		"and does not move for it")


## The deadline is a cap on what we are willing to PAY for, not a claim that the corpse has
## stopped — so it is measured from the last thing that happened to the corpse. Measured from
## birth, as it was, anything still being thrown around at MAX_SIM_TIME froze in mid-air.
func test_a_shove_gives_the_corpse_its_settling_time_over_again() -> void:
	_floor_at(ARENA - Vector3(0.0, 1.0, 0.0))
	var corpse := _corpse_at(ARENA)
	await _tick(20)
	assert_false(corpse._baked, "still falling")
	var before := corpse._sim_deadline

	corpse.push(Vector3(0.0, 9.0, 0.0))
	assert_true(corpse._sim_deadline > before, "a shove bought it more time")
	assert_true(absf(corpse._sim_deadline - (corpse._sim_time + TumblingCorpse.MAX_SIM_TIME)) < 0.001,
		"as much again as a fresh corpse gets, counted from the shove")


## A client cannot see the thing that did the shoving, so the shove itself is replicated: a
## one-shot event applied to the client's own rig, which then carries on simulating. No
## timestamp — the client's simulation is one one-way trip behind the host's and the event
## takes exactly that long to arrive.
func test_a_client_corpse_is_thrown_by_the_host_not_by_itself() -> void:
	_floor_at(ARENA - Vector3(0.0, 1.0, 0.0))
	var corpse := _corpse_at(ARENA, false)
	await _tick(2)

	var shove := Vector3(1.0, 9.0, 0.0)
	corpse._apply_sync_state({"toss": shove})
	var worst := 0.0
	for bone in _bones(corpse):
		worst = maxf(worst, bone.linear_velocity.distance_to(shove))
	assert_true(worst < 0.001, "the client threw its own rig the way the host threw its (%.4f)" % worst)


## Whether a corpse has STOPPED is the authority's call. Both of the tests for it are thresholds
## on noise the two simulations do not share — left to itself a client could bake early and lie
## there as furniture while the host's corpse was still being thrown around, with the correction
## switched off to boot.
func test_a_client_corpse_stops_when_the_authority_stopped() -> void:
	_floor_at(ARENA - Vector3(0.0, 1.0, 0.0))
	var corpse := _corpse_at(ARENA, false)
	corpse._entity.entity_id = 1  # as main._spawn_dyn_entity wires it for a state-sync entity

	# Long enough that a host's corpse has settled and baked twice over, and still inside the
	# budget below, so what is being measured is the settle tests and not the cap.
	await _tick(int(6.0 / 0.016667))
	assert_false(corpse._baked, "settled, and still simulating: nobody has said to stop")

	# The age the host baked at, which a client in step with it has reached (the word travels one
	# one-way trip, and the client's own simulation started one trip late).
	corpse._apply_sync_state({"bake": true, "age": corpse._sim_time})
	assert_true(corpse._baked, "it stops when the host says its own corpse stopped")
	assert_true(corpse._sim == null, "and gives up the 21 bodies then")


## ...but only a client the host's word can speak for. A corpse arrives the first time it is
## visible (the spawn honors PVS) while the word to stop does not (sync_entity_state is an
## unfiltered broadcast, parked until the entity lands), so a client can be told to stop a rig
## that has not fallen yet — and freezing it there is a body left standing in mid-air at the
## spot the wizard died, for the rest of the corpse's minute. That one finishes the fall itself.
func test_a_client_told_to_stop_before_it_has_fallen_lands_the_body_first() -> void:
	_floor_at(ARENA - Vector3(0.0, 1.0, 0.0))
	var corpse := _corpse_at(ARENA, false)
	corpse._entity.entity_id = 1
	await _tick(2)
	var born_at := corpse._root_bone.global_position

	# The host settled this corpse seconds ago; this client has had it for two ticks.
	corpse._apply_sync_state({"bake": true, "age": 4.0})
	assert_false(corpse._baked, "a rig that has not fallen is not furniture")
	assert_true(corpse._sim != null, "so it keeps its bodies and carries on falling")

	# Read off the rig on the last tick it still had one: a client's corpse NODE is written by the
	# interp stream, not by its own bones, so it says nothing about where the body was drawn.
	var tree := Engine.get_main_loop() as SceneTree
	var rested_at := born_at
	for i in 540:
		await tree.physics_frame
		if corpse._root_bone != null:
			rested_at = corpse._root_bone.global_position
		if corpse._baked:
			break

	assert_true(corpse._baked, "and it stops on its own settle, which the host has vouched for")
	assert_true(corpse._sim_time < TumblingCorpse.MAX_SIM_TIME - 0.5,
		"it settled rather than running out the budget (%.2f s)" % corpse._sim_time)
	assert_true(rested_at.y < born_at.y - 0.2,
		"the body is on the floor, not floating where it died (%.2f -> %.2f)"
		% [born_at.y, rested_at.y])


## A corpse is replicated as a seed and replayed by whoever receives it, so a peer the spawner
## held back until the body entered its PVS replays a death that is long over. The body itself
## is the point of that replay; the death CRY is not — it belongs to a death that happened out
## of sight a minute ago. The roll still happens, so a corpse of the same age elsewhere rolls
## the death the host rolled.
func test_a_corpse_handed_over_late_arrives_as_a_body_not_a_death() -> void:
	_floor_at(ARENA - Vector3(0.0, 1.0, 0.0))
	var fresh := _corpse_at(ARENA, false)
	var late := _corpse_at(ARENA + Vector3(3.0, 0.0, 0.0), false, 30.0)
	await _tick(2)

	assert_true(_screamed(fresh), "a corpse that arrives with its death cries out")
	assert_false(_screamed(late), "one handed over half a minute later does not")


## ...and the age it is measured against has to be real. A client with no server clock yet — the
## first corpses after a join — cannot date one, and must read it as fresh rather than silently
## treating every corpse on the map as old.
func test_a_corpse_cannot_be_dated_without_a_clock() -> void:
	var corpse: TumblingCorpse = CorpseScript.new()
	var payload := TumblingCorpse.wizard_payload(ARENA, 0.0, GameConsts.Element.FIRE, Vector3.ZERO)
	payload["born_ms"] = 1  # the host's clock at its first millisecond, an age ago
	corpse.setup(payload, false)
	assert_false(NetworkManager.is_clock_synced(), "no clock, as on a client that just joined")
	assert_eq(corpse._age, 0.0, "so the corpse is taken as fresh")
	corpse.free()


## A late corpse gets the life the host's has LEFT, not its minute over again: the fade picks up
## where the host has it, and one whose minute is already up goes out here too. (The simulation
## budget is not docked the same way — a corpse on its way out still has to land.)
func test_a_late_corpse_gets_only_the_life_it_has_left() -> void:
	_floor_at(ARENA - Vector3(0.0, 1.0, 0.0))
	var spent := _corpse_at(ARENA, false,
		TumblingCorpse.WIZARD_LINGER + TumblingCorpse.WIZARD_FADE + 1.0)
	var fresh := _corpse_at(ARENA + Vector3(3.0, 0.0, 0.0), false)
	await _tick(4)

	assert_false(is_instance_valid(spent), "a corpse whose minute is up on the host goes out here")
	assert_true(is_instance_valid(fresh), "while a fresh one still has its minute")


## A corpse told to stop before it had a rig to stop — a client running `/ragdolls off` — takes
## the word without reaching for a simulator that was never built.
func test_a_rigless_corpse_takes_the_word_to_stop() -> void:
	ServerVars.set_from_string("ragdolls", "off")
	_floor_at(ARENA - Vector3(0.0, 1.0, 0.0))
	var corpse := _corpse_at(ARENA, false)
	await _tick(2)

	corpse._apply_sync_state({"bake": true, "age": 4.0})
	assert_true(corpse._baked, "stopped, with nothing to stop")
	assert_true(_bones(corpse).is_empty(), "and no rig was involved")


## ...but the deadline is a budget, not a threshold, so it runs everywhere. It is what catches a
## client that never hears the word — one whose bake was evicted from the pending-state cache,
## or who first saw the corpse after the host had already stopped it. Without it that client
## runs 21 bodies for the corpse's whole minute.
func test_a_client_that_is_never_told_still_stops_on_its_own_budget() -> void:
	_floor_at(ARENA - Vector3(0.0, 1.0, 0.0))
	var corpse := _corpse_at(ARENA, false)
	corpse._entity.entity_id = 1

	await _tick_until_baked(corpse, int(TumblingCorpse.MAX_SIM_TIME / 0.016667) + 60)

	assert_true(corpse._baked, "it stopped without being told")
	assert_true(corpse._sim_time >= TumblingCorpse.MAX_SIM_TIME - 0.5,
		"and it was the cap that stopped it, not a settle test (%.2f s)" % corpse._sim_time)


## The affordability argument, since hop will not sleep these for us: eight dead wizards is
## 168 bodies, and every one of them has to stop on its own before the corpses' minute is up.
func test_eight_dead_wizards_all_stop_on_their_own() -> void:
	_floor_at(ARENA - Vector3(0.0, 1.0, 0.0))
	var corpses: Array[TumblingCorpse] = []
	for i in 8:
		corpses.append(_corpse_at(ARENA + Vector3(i * 2.0 - 8.0, 0.0, 0.0)))
	await _tick(2)
	var bodies := 0
	for corpse in corpses:
		bodies += _bones(corpse).size()
	assert_eq(bodies, 168, "eight corpses is 168 bodies while they are falling")

	await _tick(int(TumblingCorpse.MAX_SIM_TIME / 0.016667) + 30)
	var still_simulating := 0
	for corpse in corpses:
		if not corpse._baked:
			still_simulating += 1
	assert_eq(still_simulating, 0, "and none of them is still simulating a minute before it fades")


## Put the authority's pelvis at `where` for the age this corpse has reached, the way the stream
## would have: a snapshot pair in the interp buffer, and the (net_stamp, net_age) the client
## reads the epoch off. Two samples, because one is a degenerate buffer that never interpolates.
func _authority_pelvis_at(corpse: TumblingCorpse, where: Vector3) -> void:
	var bridge := NetInterpBridge.new()
	bridge.name = "NetInterp"
	corpse.add_child(bridge)
	# On an offline/authority tree the bridge publishes itself every tick, which would overwrite
	# the stamp below. Nothing here is testing the publish side.
	bridge.set_physics_process(false)
	var stamp := 100000
	bridge.net_stamp = stamp
	# net_epoch is the host's clock at ITS tick 0, so the corpse's own age samples exactly at
	# `stamp`. One snapshot either side of it so the sample interpolates rather than extrapolates.
	corpse.net_epoch = stamp - int(round(corpse._sim_time * 1000.0))
	var id := int(corpse.get_instance_id())
	NetworkManager.push_mover_snapshot(id, stamp - 50, where, Vector3.ZERO, Vector3.ZERO)
	NetworkManager.push_mover_snapshot(id, stamp + 50, where, Vector3.ZERO, Vector3.ZERO)


## A client runs its own ragdoll and is pulled back to the authority's pelvis when the two
## drift. The correction has to be RIGID — every bone by the same delta — because that is the
## one operator a jointed chain satisfies exactly; nudging a single bone fights the solver.
##
## The reference is the host's pelvis at the client's OWN simulation age, not at render time:
## see TumblingCorpse._correct_to_authority for why comparing across the two clocks read a
## difference in time as a difference in position.
func test_a_client_corpse_is_pulled_back_in_one_piece() -> void:
	_floor_at(ARENA - Vector3(0.0, 1.0, 0.0))
	var corpse := _corpse_at(ARENA, false)
	await _tick(2)

	var bones := _bones(corpse)
	assert_eq(bones.size(), 21, "a client builds the same 21 bodies")
	var root: PhysicalBone3D = corpse._root_bone
	var before: Array[Vector3] = []
	for bone in bones:
		before.append(bone.global_position - root.global_position)

	# Put the authority's reference well past the threshold and let the slew answer it.
	var shove := Vector3(TumblingCorpse.CORRECTION_THRESHOLD * 4.0, 0.0, 0.0)
	var predicted := root.global_position
	_authority_pelvis_at(corpse, predicted + shove)
	var gap_before := root.global_position.distance_to(predicted + shove)
	await _tick(1)

	var gap_after := root.global_position.distance_to(predicted + shove)
	assert_true(gap_after < gap_before, "the corpse moved toward where the host says it is")
	var worst := 0.0
	for i in bones.size():
		worst = maxf(worst, (bones[i].global_position - root.global_position).distance_to(before[i]))
	assert_true(worst < 0.05, "and arrived in one piece — every bone took the same offset")


## ...and it takes several ticks to get there rather than teleporting, because the one frame a
## whole-rig jump lands on is the one frame it is visible.
func test_a_client_corpse_is_slewed_not_teleported() -> void:
	_floor_at(ARENA - Vector3(0.0, 1.0, 0.0))
	var corpse := _corpse_at(ARENA, false)
	await _tick(2)

	var root: PhysicalBone3D = corpse._root_bone
	var shove := Vector3(TumblingCorpse.CORRECTION_THRESHOLD * 4.0, 0.0, 0.0)
	var target := root.global_position + shove
	_authority_pelvis_at(corpse, target)
	var gap_before := root.global_position.distance_to(target)
	await _tick(1)

	var closed := gap_before - root.global_position.distance_to(target)
	assert_true(closed > gap_before * 0.05,
		"one tick closes part of the gap (closed %.2f of %.2f)" % [closed, gap_before])
	assert_true(closed < gap_before * 0.75,
		"...and only part of it — a whole-rig jump is visible on the frame it lands on")


## A correction must RUN OUT, not stop the instant it is back inside the deadband. Stopping there
## parked the rig ~0.2m off forever, and every nudge re-woke the bones, pushed them into the floor
## for hop to eject, and earned the next nudge: the corpse shook for its whole life instead of
## settling. Guards the shipped-and-reverted version of exactly that.
func test_a_corrected_client_corpse_comes_to_rest() -> void:
	_floor_at(ARENA - Vector3(0.0, 1.0, 0.0))
	var corpse := _corpse_at(ARENA, false)
	await _tick(90)  # land and settle first — a resting corpse is where the shake showed up

	var root: PhysicalBone3D = corpse._root_bone
	# An authority that has come to rest somewhere else, well past the deadband.
	var target := root.global_position + Vector3(TumblingCorpse.CORRECTION_THRESHOLD * 3.0, 0.0, 0.0)
	_authority_pelvis_at(corpse, target)
	await _tick(120)

	assert_false(corpse._correcting, "the correction finished rather than latching on forever")
	# Came to rest: either it baked — which needs every bone asleep, and the shake re-woke them
	# each tick so it never could — or its pelvis has simply stopped moving.
	var settled := corpse._baked
	if not settled:
		var was: Vector3 = corpse._root_bone.global_position
		await _tick(30)
		settled = corpse._baked or corpse._root_bone.global_position.distance_to(was) < 0.05
	assert_true(settled, "and it came to rest instead of twitching on forever")


## The reference is read at the corpse's own age, so a stream that says nothing about that age
## leaves the rig alone rather than yanking it at whatever the newest packet happened to hold.
func test_a_client_corpse_with_no_reference_is_left_alone() -> void:
	_floor_at(ARENA - Vector3(0.0, 1.0, 0.0))
	var corpse := _corpse_at(ARENA, false)
	await _tick(2)

	var root: PhysicalBone3D = corpse._root_bone
	# The old reference: the node transform interp_entities writes. Moving it must do nothing.
	corpse.global_position = root.global_position + Vector3(10.0, 0.0, 0.0)
	var was := root.global_position
	await _tick(1)

	assert_true(root.global_position.distance_to(was) < 0.2,
		"the interpolated node transform is not the reference any more")


func test_ragdolls_off_falls_back_to_the_death_clips() -> void:
	ServerVars.set_from_string("ragdolls", "off")
	_floor_at(ARENA - Vector3(0.0, 1.0, 0.0))
	var corpse := _corpse_at(ARENA)
	await _tick(2)

	assert_true(_bones(corpse).is_empty(), "no ragdoll")
	assert_false(corpse.freeze, "the corpse is the body again")
	var has_box := false
	for child in corpse.get_children():
		if child is CollisionShape3D and (child as CollisionShape3D).shape is BoxShape3D:
			has_box = true
	assert_true(has_box, "in a body-sized box — not a capsule, which spins from nothing on a floor")
	assert_true(corpse._anim_player != null and not corpse._anim_player.current_animation.is_empty(),
		"holding one of the six death poses")


func test_a_prop_corpse_is_untouched_by_any_of_this() -> void:
	var corpse: TumblingCorpse = CorpseScript.new()
	corpse.setup({
		"position": ARENA,
		"velocity": Vector3(0.0, 0.0, -4.0),
		"model": "models/flyingskull.mdl",
		"kind": TumblingCorpse.Kind.PROP,
		"seed": 7,
	}, true)
	_root().add_child(corpse)
	_keep(corpse)
	await _tick(2)

	assert_true(_bones(corpse).is_empty(), "a spent skull is not a ragdoll")
	assert_false(corpse.is_in_group("corpses"), "and not a body anyone can raise")
	assert_eq(corpse.collision_layer, GameConsts.MASK_CORPSE,
		"but a descending platform can still find it")


## Every real caller names a model, so the fallback is only ever what /spawn gets — and it is
## the raise-dead skeleton rather than an invisible body with nothing to measure. It is also the
## one corpse that rigs itself: with no pose on the payload it takes the model's own rest pose,
## which fits the rig by construction, so it collapses in a heap rather than tumbling stiff.
func test_a_corpse_with_no_model_named_is_a_skeleton_ragdoll() -> void:
	var corpse: TumblingCorpse = CorpseScript.new()
	corpse.setup({"position": ARENA, "seed": 3}, true)
	_root().add_child(corpse)
	_keep(corpse)
	await _tick(2)

	assert_eq(corpse._model_path, Skeleton.MODEL, "a corpse out of nothing is a skeleton")
	assert_true(corpse._model != null, "and it has a body to draw, not an invisible one")
	assert_false(_bones(corpse).is_empty(), "built on its own rest pose, not rolled up in a ball")
	assert_true(corpse._sim_deadline <= TumblingCorpse.RAGDOLL_PROP_LINGER,
		"and it is a rigged prop, so it stops simulating by the time it starts to fade")
	assert_false(corpse._impact_sounds.is_empty(), "and it clatters on the way down")


func test_a_named_model_still_wins_over_the_fallback() -> void:
	var corpse: TumblingCorpse = CorpseScript.new()
	corpse.setup({"position": ARENA, "model": BIRD_MODEL, "seed": 3}, true)
	_root().add_child(corpse)
	_keep(corpse)
	await _tick(2)

	assert_eq(corpse._model_path, BIRD_MODEL, "the payload is not overridden")
	assert_true(_bones(corpse).is_empty(),
		"and a named model with no pose is still a ball — only the conjured one rigs itself")


## A rigged prop — the bird a wall stopped — is the same ragdoll off a different rig, asked
## for by handing the corpse the pose the model was in when it stopped.
func test_a_prop_with_a_pose_falls_as_a_ragdoll() -> void:
	var pose := _bird_pose()
	assert_true(pose.size() > 0, "the bird model has a rig to capture")
	_floor_at(ARENA - Vector3(0.0, 3.0, 0.0))
	var corpse: TumblingCorpse = CorpseScript.new()
	corpse.setup({
		"position": ARENA,
		"velocity": Vector3(0.0, 0.0, -4.0),
		"model": BIRD_MODEL,
		"kind": TumblingCorpse.Kind.PROP,
		"pose": pose,
		"seed": 11,
	}, true)
	_root().add_child(corpse)
	_keep(corpse)
	await _tick(2)

	var bones := _bones(corpse)
	assert_true(bones.size() > 1, "the bird's own hitboxes became jointed bodies")
	assert_false(corpse.is_in_group("corpses"), "but a dead bird is not a body anyone can raise")
	var start := corpse.global_position
	await _tick(30)
	assert_true(corpse.global_position.y < start.y, "and it falls")


## A dead beast — a shot-down dragon, a raised skeleton put back down — is that same rigged prop
## with its clock, width and topple named on the payload. It used to be a third Kind, and these
## four tests are the whole of what the Kind was worth: nothing about how the body is BUILT.
func test_a_beast_is_a_rigged_prop_that_stays() -> void:
	var beast := _beast_corpse(Dragon.CORPSE_RADIUS)
	await _tick(2)

	assert_true(_bones(beast).size() > 1, "a beast falls as a ragdoll, same as any rigged prop")
	assert_false(beast.is_in_group("corpses"),
		"and is no more raisable than a dead bird — being a prop is what says so")
	assert_eq(beast._linger(), TumblingCorpse.MONSTER_LINGER, "it lies there as furniture")
	assert_eq(beast._fade(), TumblingCorpse.MONSTER_FADE)


## The linger is also the simulation budget (_sim_deadline caps against it), so the beast's own
## clock is what buys a long faller the time to land. On a spent projectile's five seconds a
## dragon shot down from height bakes in mid-air, hardening where it was still falling.
func test_a_beast_gets_the_whole_simulation_budget() -> void:
	var beast := _beast_corpse(Dragon.CORPSE_RADIUS)
	await _tick(2)

	assert_gt(beast._sim_deadline, TumblingCorpse.RAGDOLL_PROP_LINGER,
		"a beast is still simulating when a spent projectile would already have faded out")
	assert_almost_eq(beast._sim_deadline, beast._sim_time + TumblingCorpse.MAX_SIM_TIME, 0.2,
		"...and gets the whole cap, not a linger shorter than it")


## The splash is measured off the named width rather than bucketed by kind. This is the one the
## old enum got wrong: MONSTER carried a dragon's 0.8 as its default, so a beast that did not
## remember to object punched a dragon's hole in the water whatever size it really was.
func test_a_beast_splashes_in_proportion_to_its_width() -> void:
	var dragon := _beast_corpse(Dragon.CORPSE_RADIUS)
	var raised := _beast_corpse(Skeleton.RADIUS)
	await _tick(2)

	assert_almost_eq(dragon._entry.size, 2.0, 0.001, "a dragon thuds")
	assert_almost_eq(raised._entry.size, TumblingCorpse.SPLASH_PER_RADIUS * Skeleton.RADIUS, 0.001,
		"and a man-sized beast splashes like the man it was")
	assert_lt(raised._entry.size, dragon._entry.size * 0.6,
		"...which is nothing like a dragon, and is what the old kind's default could not say")


## The one difference in how a bird corpse and a dragon corpse MOVE: a bird was swatted into a
## wall and scrambles off it, a dragon keeled over and pitches along the blow it took.
func test_a_beast_keels_over_where_a_spent_projectile_scrambles() -> void:
	var beast := _beast_corpse(Dragon.CORPSE_RADIUS)
	await _tick(2)
	var spin := beast._initial_spin()

	assert_almost_eq(spin.y, 0.0, 0.001, "a beast topples about a horizontal axis")
	assert_almost_eq(spin.normalized().dot(BLOW.normalized()), 0.0, 0.001, "...laid across the blow")
	assert_almost_eq(spin.length(), TumblingCorpse.WIZARD_TOPPLE_SPEED, 0.001,
		"at the same rate a dead wizard pitches over, because it is the same fall")

	var bird: TumblingCorpse = CorpseScript.new()
	bird.setup({
		"position": ARENA, "velocity": BLOW, "model": BIRD_MODEL,
		"pose": _bird_pose(), "seed": 11,
	}, true)
	_root().add_child(bird)
	_keep(bird)
	await _tick(2)
	assert_almost_eq(bird._initial_spin().length(), TumblingCorpse.RAGDOLL_TUMBLE_SPEED, 0.001,
		"where the same rig with no topple named scrambles on a random axis instead")


## The prune leaves the rig the game actually ships completely alone. A wizard's lightest
## leaf is a whole hand, nowhere near LEAF_VOLUME_RATIO of his pelvis, so every one of the
## model's 21 hitboxes still becomes a body — which is what makes the prune safe to run on
## every model rather than a flag someone has to remember to pass.
func test_the_prune_takes_nothing_off_the_wizard_rig() -> void:
	var model := AssetLoader.load_model(MODEL)
	assert_true(model != null, "the wizard model loads")
	_root().add_child(model)
	_keep(model)
	var skeleton := RagdollBuilder.find_skeleton(model)
	var boxes := RagdollBuilder.collect_hitboxes(skeleton)
	assert_eq(boxes.size(), 21, "the model ships 21 hitboxes")

	var folded := RagdollBuilder.prune_leaves(skeleton, boxes)
	assert_eq(boxes.size(), 21, "and the prune keeps all of them")
	assert_true(folded.is_empty(), "so no bone inherits anything")


## ...and on the bird it takes the toes and the beak tip, which are leaves, and nothing else.
## The two tests that matter are the same one twice over: what comes off is a bone with
## nothing hanging off it, and it is light enough that the solver was never going to settle
## it — the featherweights MAX_MASS_RATIO was invented to paper over.
func test_the_prune_takes_only_leaves_off_the_bird() -> void:
	var model := AssetLoader.load_model(BIRD_MODEL)
	assert_true(model != null, "the bird model loads")
	_root().add_child(model)
	_keep(model)
	var skeleton := RagdollBuilder.find_skeleton(model)
	var boxes := RagdollBuilder.collect_hitboxes(skeleton)

	var before := {}
	var heaviest := 0.0
	for entry in boxes:
		before[entry["bone"]] = RagdollBuilder._volume(entry)
		heaviest = maxf(heaviest, before[entry["bone"]])

	var folded := RagdollBuilder.prune_leaves(skeleton, boxes)
	var kept := {}
	for entry in boxes:
		kept[entry["bone"]] = true
	assert_true(kept.size() < before.size(), "the bird loses bones — it hitboxes every toe")
	assert_true(kept.size() > before.size() / 2, "but it is still a bird, not a stump")

	for bone in before:
		if kept.has(bone):
			continue
		assert_true(before[bone] < heaviest / RagdollBuilder.LEAF_VOLUME_RATIO,
			"%s was dropped, so it was a featherweight" % skeleton.get_bone_name(bone))
		# A leaf in the RAGDOLL tree: no kept bone hangs off it, however many skeleton bones
		# sit between them.
		for other in kept:
			var parent := skeleton.get_bone_parent(other)
			while parent >= 0:
				assert_true(parent != bone, "%s was dropped, so nothing hangs off it"
					% skeleton.get_bone_name(bone))
				parent = skeleton.get_bone_parent(parent)

	# Nothing weighs less for having been pruned: what came off a toe went onto the foot.
	var inherited := 0.0
	for bone in folded:
		assert_true(kept.has(bone), "and what it left behind went to a bone that stayed")
		inherited += folded[bone]
	var lost := 0.0
	for bone in before:
		if not kept.has(bone):
			lost += before[bone]
	assert_true(is_equal_approx(inherited, lost), "all of it, not some of it")


## No bone is a featherweight next to its neighbours. bird.mdl hitboxes every toe and tail
## feather, and at true density that is a 282:1 spread an impulse solver cannot reconcile —
## the light bones get flung every tick, and a corpse whose busiest bone never stops never
## bakes, so the bird faded out still twitching.
func test_a_rig_never_spans_more_mass_than_the_solver_can_hold() -> void:
	for path in [MODEL, BIRD_MODEL]:
		var model := AssetLoader.load_model(path)
		assert_true(model != null, "%s loads" % path)
		_root().add_child(model)
		_keep(model)
		var sim := RagdollBuilder.build(model, GameConsts.MASK_CORPSE, GameConsts.MASK_WORLD)
		assert_true(sim != null, "and carries a ragdoll")
		var light := INF
		var heavy := 0.0
		for child in sim.get_children():
			var bone := child as PhysicalBone3D
			if bone == null:
				continue
			light = minf(light, bone.mass)
			heavy = maxf(heavy, bone.mass)
		assert_true(light > 0.0, "%s: every bone weighs something" % path)
		assert_true(heavy / light <= RagdollBuilder.MAX_MASS_RATIO + 0.01,
			"%s: %.0f:1 is within the %.0f:1 the solver can hold"
				% [path, heavy / light, RagdollBuilder.MAX_MASS_RATIO])


## A corpse always bakes while it is still there to see. The cap used to be a flat eight
## seconds, which a rigged prop — destroyed six seconds in — could never reach.
func test_a_corpse_stops_simulating_before_it_fades_away() -> void:
	_floor_at(ARENA - Vector3(0.0, 1.0, 0.0))
	var corpse: TumblingCorpse = CorpseScript.new()
	corpse.setup({
		"position": ARENA,
		"velocity": Vector3.ZERO,
		"model": BIRD_MODEL,
		"kind": TumblingCorpse.Kind.PROP,
		"pose": _bird_pose(),
		"seed": 9,
	}, true)
	_root().add_child(corpse)
	_keep(corpse)
	await _tick(2)

	assert_true(_bones(corpse).size() > 1, "the bird is a ragdoll")
	assert_true(corpse._sim_deadline <= TumblingCorpse.RAGDOLL_PROP_LINGER,
		"and stops simulating by the time it starts to fade, not after it is gone")

	var wizard := _corpse_at(ARENA + Vector3(4.0, 0.0, 0.0))
	await _tick(2)
	assert_eq(wizard._sim_deadline, TumblingCorpse.MAX_SIM_TIME,
		"a wizard lingers a minute, so the flat cap is still the one that bites")


## A rigged prop starts clear of the surface it stopped against, not inside it. hop ejects a
## body that starts in a brush, but only by its own box size per tick, and the joints do not
## wait that long: the free bones stretch the joints of the ones still coming out into something
## with very long legs. A bird is far wider than the standoff a ball needs, so it is the wings
## that end up in the wall.
##
## And only those bones move. Standing the whole rig off by the reach of its deepest bone used
## to clear the wall too, but it took the body with it and the corpse read as a teleport.
func test_a_rigged_prop_starts_clear_of_the_surface_it_hit() -> void:
	var pose := _bird_pose()
	assert_true(pose.size() > 0, "the bird model has a rig to capture")
	var ceiling := ARENA.y
	_floor_at(Vector3(ARENA.x, ceiling + 0.5, ARENA.z))  # a slab whose underside is the ceiling
	_floor_at(Vector3(ARENA.x, ceiling - 6.5, ARENA.z))
	# The push measures the world, so the slabs have to be in the space before the corpse is.
	await _tick(1)
	var corpse: TumblingCorpse = CorpseScript.new()
	# What spawn_deflected hands a ceiling hit: the impact point, and a normal pointing down.
	var normal := Vector3.DOWN
	corpse.setup({
		"position": Vector3(ARENA.x, ceiling, ARENA.z),
		"velocity": Vector3(0.0, -4.0, 0.0),
		"model": BIRD_MODEL,
		"model_yaw": 0.4,
		"kind": TumblingCorpse.Kind.PROP,
		"pose": pose,
		"normal": normal,
		"seed": 21,
	}, true)
	_root().add_child(corpse)
	_keep(corpse)

	# Tick 0 throws the rig (TumblingCorpse._begin_simulation) — driven by hand so that the push
	# has run and the solver has NOT stepped, which is the whole measurement: where the corpse
	# PUT its bones, not where hop has since ejected them.
	corpse._physics_process(0.0)

	assert_true(_bones(corpse).size() > 1, "the bird is a ragdoll")
	var bounds := _rig_bounds(corpse)
	assert_true(bounds.position.y + bounds.size.y <= ceiling,
		"not one box starts inside the ceiling")
	assert_true(absf(corpse._model.global_position.y - ceiling) < 0.001,
		"and the rest of the bird stayed where it struck — only the buried bones moved")

	var start := corpse.global_position.y
	await _tick(90)
	assert_true(corpse.global_position.y < start - 1.0, "so it falls away instead of sticking")


## A corpse draws its model from the origin it was spawned at, full stop. It used to centre its
## whole rig on that point instead, which for a GoldSrc model — bird.mdl draws the bird a good
## third of a metre off its own origin — dropped the visible bird that far in the frame the
## projectile handed over, and read as a teleport whether a wall was involved or not.
func test_a_rigged_prop_draws_where_it_was_spawned() -> void:
	var corpse: TumblingCorpse = CorpseScript.new()
	corpse.setup({
		"position": ARENA,
		"velocity": Vector3.ZERO,
		"model": BIRD_MODEL,
		"kind": TumblingCorpse.Kind.PROP,
		"pose": _bird_pose(),
		"seed": 4,
	}, true)
	_root().add_child(corpse)
	_keep(corpse)

	assert_true(_bones(corpse).size() > 1, "the bird is a ragdoll")
	assert_true(corpse._model.global_position.distance_to(ARENA) < 0.001,
		"the model hangs off the spawn point")
	assert_true(_rig_bounds(corpse).get_center().distance_to(ARENA) > 0.05,
		"and the rig sits where the model puts it, rather than being dragged onto that point")


## World bounds of a ragdoll's bodies — a turned shape reaches by its basis' columns, scaled
## by its half-extents and taken absolute.
func _rig_bounds(corpse: TumblingCorpse) -> AABB:
	var low := Vector3.INF
	var high := -Vector3.INF
	for bone in _bones(corpse):
		var shape := bone.get_child(0) as CollisionShape3D
		if shape == null or shape.shape == null:
			continue
		var world: AABB = (bone.global_transform * shape.transform) * GeomUtil.shape_local_aabb(shape.shape)
		low = low.min(world.position)
		high = high.max(world.end)
	return AABB(low, high - low)


## Every bone lands with the body, including the ones the ragdoll never simulated. bird.mdl
## hitboxes the wing tips and skips the forearm they hang off, and a bone with no body has no
## physics pose to bake — read the wrong way it stays in the frame the corpse was BUILT in,
## which is a wing stretched back to wherever the bird hit the wall.
func test_a_baked_ragdoll_leaves_no_bone_behind() -> void:
	var pose := _bird_pose()
	assert_true(pose.size() > 0, "the bird model has a rig to capture")
	_floor_at(ARENA - Vector3(0.0, 6.0, 0.0))
	var corpse: TumblingCorpse = CorpseScript.new()
	corpse.setup({
		"position": ARENA,
		"velocity": Vector3(1.0, 0.0, 0.0),
		"model": BIRD_MODEL,
		"kind": TumblingCorpse.Kind.PROP,
		"pose": pose,
		"seed": 5,
	}, true)
	_root().add_child(corpse)
	_keep(corpse)
	await _tick(2)

	var skeleton := RagdollBuilder.find_skeleton(corpse)
	assert_true(skeleton != null, "the corpse carries the bird's rig")
	var bodies := _bones(corpse).size()
	assert_true(bodies > 0 and bodies < skeleton.get_bone_count(),
		"and the rig has bones the ragdoll does not simulate — that is what this is about")

	await _tick(120)  # falls the five-odd metres to the floor
	corpse._bake()
	await _tick(1)

	var landed := corpse.global_position
	var worst := 0.0
	var worst_bone := ""
	for i in skeleton.get_bone_count():
		var at: Vector3 = (skeleton.global_transform * skeleton.get_bone_global_pose(i)).origin
		if at.distance_to(landed) > worst:
			worst = at.distance_to(landed)
			worst_bone = skeleton.get_bone_name(i)
	assert_true(landed.y < ARENA.y - 2.0, "the bird fell a good way before it baked")
	assert_true(worst < 1.0, "and every bone baked with it — furthest was %s at %.2fm"
		% [worst_bone, worst])


## A pose from some other rig is refused, and the prop falls as the ball it always was.
func test_a_prop_with_a_foreign_pose_stays_a_ball() -> void:
	var corpse: TumblingCorpse = CorpseScript.new()
	corpse.setup({
		"position": ARENA,
		"velocity": Vector3.ZERO,
		"model": BIRD_MODEL,
		"kind": TumblingCorpse.Kind.PROP,
		"pose": PackedFloat32Array([0.0, 0.0, 0.0, 1.0]),  # one bone: not this model's rig
		"seed": 3,
	}, true)
	_root().add_child(corpse)
	_keep(corpse)
	await _tick(2)

	assert_true(_bones(corpse).is_empty(), "no ragdoll built on a pose that doesn't fit")
	var has_sphere := false
	for child in corpse.get_children():
		if child is CollisionShape3D and (child as CollisionShape3D).shape is SphereShape3D:
			has_sphere = true
	assert_true(has_sphere, "the ball instead")


## A spent skull is a ball, and a ball knows what it hits: contact monitoring turns each
## landing into one bone knock, as loud as the landing was hard.
func test_a_spent_skull_clatters_where_it_lands() -> void:
	_floor_at(ARENA - Vector3(0.0, 3.0, 0.0))
	var corpse: TumblingCorpse = CorpseScript.new()
	corpse.setup({
		"position": ARENA,
		"velocity": Vector3(2.0, 0.0, -5.0),
		"model": "models/flyingskull.mdl",
		"kind": TumblingCorpse.Kind.PROP,
		"seed": 7,
	}, true)
	_root().add_child(corpse)
	_keep(corpse)
	await _tick(90)

	assert_true(_heard.size() >= 1, "the skull knocked against the floor")
	for clip in _heard:
		assert_true(clip.begins_with("bone_clink"), "and it is bone it knocks with, not %s" % clip)


## The smack that ended the skull is the corpse's own first sound. It happened to the
## projectile, so the body has to sound it at birth or the hit anyone was watching is the one
## landing they never hear.
func test_a_skull_sounds_the_wall_it_died_against() -> void:
	var corpse: TumblingCorpse = CorpseScript.new()
	corpse.setup({
		"position": ARENA,
		"velocity": Vector3.RIGHT * 3.5,     # what spawn_deflected keeps off the surface
		"normal": Vector3.RIGHT,
		"model": "models/flyingskull.mdl",
		"kind": TumblingCorpse.Kind.PROP,
		"seed": 3,
	}, true)
	_root().add_child(corpse)
	_keep(corpse)

	assert_eq(_heard.size(), 1, "the strike sounds on the frame the corpse is built")
	assert_true(_heard[0].begins_with("bone_clink"), "and it is a bone knock (%s)" % _heard)


## ...and one that stopped against nothing does not: a skull that simply ran out of life
## drifts on and falls, and there was no surface for it to have hit.
func test_a_skull_that_hit_nothing_starts_quiet() -> void:
	var corpse: TumblingCorpse = CorpseScript.new()
	corpse.setup({
		"position": ARENA,
		"velocity": Vector3.RIGHT * 5.0,
		"model": "models/flyingskull.mdl",
		"kind": TumblingCorpse.Kind.PROP,
		"seed": 3,
	}, true)
	_root().add_child(corpse)
	_keep(corpse)

	assert_true(_heard.is_empty(), "nothing was struck, so nothing knocked (%s)" % [_heard])


## A ragdoll has no contacts to monitor, so it listens to its own bones instead — and the
## cooldown is what keeps a tumbling bird from reading as a rattle.
func test_a_dead_bird_flops_when_it_lands() -> void:
	_floor_at(ARENA - Vector3(0.0, 3.0, 0.0))
	var corpse: TumblingCorpse = CorpseScript.new()
	corpse.setup({
		"position": ARENA,
		"velocity": Vector3(6.0, 2.0, -6.0),
		"model": BIRD_MODEL,
		"kind": TumblingCorpse.Kind.PROP,
		"pose": _bird_pose(),
		"seed": 12,
	}, true)
	_root().add_child(corpse)
	_keep(corpse)
	assert_true(_bones(corpse).size() > 1, "the bird is a ragdoll")
	await _tick(180)

	assert_true(_heard.size() >= 1, "the bird flopped where it landed")
	assert_true(_heard.size() <= 8, "a few times over the fall, not once a frame (%d)" % _heard.size())
	for clip in _heard:
		assert_true(clip.begins_with("flesh_flop"), "and it flops rather than clinks (%s)" % clip)


## The table is opt-in: a corpse whose model names no landing sound makes none, which is
## every corpse but the skull and the bird.
func test_a_dead_wizard_lands_without_a_sound_of_his_own() -> void:
	_floor_at(ARENA - Vector3(0.0, 3.0, 0.0))
	_keep(_corpse_at(ARENA))
	await _tick(120)

	assert_true(_heard.is_empty(), "a wizard's corpse has no landing sound (%s)" % [_heard])


## Water is the one surface a corpse falls THROUGH — its mask is the world alone, so nothing
## about the fall changes and the entry has to be found by asking. A body goes in once, however
## long it then bobs there.
func test_a_dead_wizard_splashes_going_into_the_water() -> void:
	var pool := _pool_below(ARENA, 1.0)
	_floor_at(ARENA - Vector3(0.0, 4.5, 0.0))  # the pool floor, under 3m of water
	_corpse_at(ARENA)
	await _tick(240)

	assert_eq(_splashes.size(), 1, "one splash, on the way in (%s)" % [_splashes])
	assert_true(str(_splashes[0]["clip"]).begins_with("splash"),
		"and it is a splash (%s)" % _splashes[0]["clip"])
	assert_true(pool != null, "the pool outlived the corpse")


## The sound comes off the surface, not from wherever the body had sunk to by the time the
## probe caught it — a splash two metres under the water is a splash nobody is looking at.
func test_a_splash_sounds_at_the_surface() -> void:
	var surface_y := ARENA.y - 1.0
	_pool_below(ARENA, 1.0)
	_floor_at(ARENA - Vector3(0.0, 4.5, 0.0))
	_corpse_at(ARENA)
	await _tick(60)

	assert_eq(_splashes.size(), 1, "the corpse went in")
	var at: Vector3 = _splashes[0]["position"]
	assert_true(at.is_finite(), "the splash was placed when it played")
	var dy := at.y - surface_y
	assert_true(dy > -0.05, "the splash is at the surface, not under it (%.2f below)" % -dy)
	assert_true(dy < 0.5, "and not left up where the corpse was a moment ago (%.2f above)" % dy)


## A skull is a quarter of a body and goes in like one: the clip is the same, the voice is not.
func test_a_skull_plops_where_a_wizard_whumps() -> void:
	_pool_below(ARENA, 1.0, 6.0)
	_skull_at(ARENA)
	await _tick(60)
	assert_eq(_splashes.size(), 1, "the skull went in (%s)" % [_splashes])
	var plop: Dictionary = _splashes[0].duplicate()
	_splashes.clear()

	_corpse_at(ARENA + Vector3(6.0, 0.0, 0.0))  # the same pool, clear of the skull
	await _tick(60)
	assert_eq(_splashes.size(), 1, "and so did the wizard (%s)" % [_splashes])
	var whump: Dictionary = _splashes[0]

	assert_true(plop["pitch"] > whump["pitch"],
		"a skull is the higher of the two (%.2f vs %.2f)" % [plop["pitch"], whump["pitch"]])
	assert_true(whump["volume"] > plop["volume"],
		"and a body the louder (%.1f vs %.1f dB)" % [whump["volume"], plop["volume"]])


## A wizard who drowned and died down there did not arrive: he was already in it. Without this
## the first probe of his life would read as an entry and plop at nothing.
func test_a_corpse_born_under_the_surface_arrives_silently() -> void:
	# Deep enough to cover the pelvis, which is what a ragdoll probes with and stands a good
	# way above the feet the corpse is spawned on.
	_pool_below(ARENA, -4.0, 12.0)
	_floor_at(ARENA - Vector3(0.0, 3.0, 0.0))
	_corpse_at(ARENA)
	await _tick(120)

	assert_true(_splashes.is_empty(), "nothing was entered, so nothing splashed (%s)" % [_splashes])


## Lava is the one liquid with no clip: a cheerful plop into magma is worse than silence, and
## the bank is keyed by liquid precisely so it can say nothing.
func test_a_corpse_falls_into_lava_without_a_plop() -> void:
	_pool_below(ARENA, 1.0, 3.0, GameConsts.MASK_WATER | GameConsts.MASK_LAVA)
	_floor_at(ARENA - Vector3(0.0, 4.5, 0.0))
	_corpse_at(ARENA)
	await _tick(120)

	assert_true(_splashes.is_empty(), "lava swallows it quietly (%s)" % [_splashes])


## The bird's rest pose, which is all this needs — what is under test is that a pose fitting
## the rig turns the prop into a ragdoll, not which frame it was captured on.
## A beast corpse off the real payload spawn_monster sends, so these tests measure what the two
## shipping callers actually get rather than a hand-written dict that could drift from them. The
## bird rig stands in for a dragon's — what is under test is the clock and the width, not the model.
func _beast_corpse(body_radius: float) -> TumblingCorpse:
	var corpse: TumblingCorpse = CorpseScript.new()
	corpse.setup({
		"position": ARENA,
		"velocity": BLOW,
		"model": BIRD_MODEL,
		"pose": _bird_pose(),
		"seed": 11,
		"linger": TumblingCorpse.MONSTER_LINGER,
		"fade": TumblingCorpse.MONSTER_FADE,
		"topple": true,
		"body_radius": body_radius,
	}, true)
	_root().add_child(corpse)
	_keep(corpse)
	return corpse


func _bird_pose() -> PackedFloat32Array:
	var model := AssetLoader.load_model(BIRD_MODEL)
	if model == null:
		return PackedFloat32Array()
	var pose := RagdollBuilder.capture_pose(RagdollBuilder.find_skeleton(model))
	model.queue_free()
	return pose


## The bake used to write every bone's POSITION off the bodies, so a limb stretched at the
## moment the corpse stopped stayed stretched for its whole minute — the ww_golem report. Bone
## lengths are the skeleton's, not the simulation's: this drags one bone a metre and a half out
## of the rig and asserts the corpse it bakes is still a body.
func test_a_stretched_rig_bakes_a_body_shaped_corpse() -> void:
	_floor_at(ARENA - Vector3(0.0, 1.0, 0.0))
	var corpse := _corpse_at(ARENA)
	await _tick(2)
	var skeleton: Skeleton3D = corpse._sim.get_parent()
	var hand := skeleton.find_bone("Bip01 R Hand")
	var forearm := skeleton.find_bone("Bip01 R Arm2")
	assert_true(hand >= 0 and forearm >= 0, "the rig has a right hand and a forearm")
	# What the model says a forearm is. get_bone_global_pose answers with the posed skeleton
	# rather than the simulator's output, so this is the rest length however the rig is lying.
	var rest := skeleton.get_bone_global_pose(hand).origin.distance_to(
		skeleton.get_bone_global_pose(forearm).origin)
	assert_gt(rest, 0.05, "and a forearm has a length to keep")

	var body: PhysicalBone3D = null
	for bone in _bones(corpse):
		if bone.bone_name == "Bip01 R Hand":
			body = bone
	assert_true(body != null, "the hand is one of the simulated bones")
	body.global_position += Vector3(0.0, 0.0, 1.5)
	corpse._bake()

	assert_true(corpse._baked, "it stopped")
	var baked := skeleton.get_bone_global_pose(hand).origin.distance_to(
		skeleton.get_bone_global_pose(forearm).origin)
	assert_almost_eq(baked, rest, 0.002,
		"a baked forearm is a forearm long, not however far the bodies drifted apart")


## The push-out may give up on a bone it cannot free; it may not bury it further. The "back the
## way it came" reversal is wrong for a corpse that died INSIDE something thick, and since each
## step is a penetration depth the loop walked the bone in until MAX_PUSH stopped it. The bone
## here sits just under a thick slab's top face with the body's origin well below it, so the
## shortest way out is up and the way it came is down.
func test_a_buried_bone_is_not_pushed_deeper() -> void:
	_static_box_at(ARENA, Vector3(6.0, 4.0, 6.0))
	var corpse := _corpse_at(ARENA)  # dead inside it, like a wizard killed in the golem
	await _tick(2)

	# Stated rather than inherited from two ticks of falling: the rule is about the direction
	# from the BODY to the bone, and a rig dropped inside a slab lands somewhere unpredictable.
	var bone := _bones(corpse)[0]
	corpse.global_position = ARENA                         # the body, deep inside the slab
	bone.global_position = ARENA + Vector3(0.0, 1.5, 0.0)  # 0.5 m under a 2 m-thick ceiling
	var space := corpse.get_world_3d().direct_space_state
	var query := PhysicsShapeQueryParameters3D.new()
	query.margin = TumblingCorpse.PUSH_SKIN
	var before := corpse.bone_overlap(space, query, bone).length()
	assert_gt(before, 0.0, "the bone starts inside the slab")

	corpse._push_bones_clear()

	var after := corpse.bone_overlap(space, query, bone).length()
	assert_lt(after, before + 0.001,
		"%s came out no deeper than it went in (%.3f m -> %.3f m)" % [bone.bone_name, before, after])
