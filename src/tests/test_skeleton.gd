extends "res://src/tests/test_base.gd"
## Raise dead: what /spawn will answer to, the bodies the cast takes, the two ways it refuses
## without spending the book, and the skeleton that walks out of each one.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.

const SkeletonScript = preload("res://src/monsters/skeleton.gd")
const RaiseDeadWeaponScript = preload("res://src/weapons/raise_dead_weapon.gd")
const ThrowingBoneScript = preload("res://src/projectiles/throwing_bone.gd")

const ARENA := Vector3(300.0, 200.0, -300.0)  # clear of map geometry, and of the other suites'


## A wizard as far as the spell is concerned: damageable, and carrying a peer_id, which is what
## separates a player from a summon.
class DummyWizard extends CharacterBody3D:
	var is_dead := false
	var team := GameConsts.Team.RED
	var peer_id := 3
	var damage_taken := 0.0
	var last_type := -1

	func take_damage(amount: float, type: int, _attacker) -> void:
		damage_taken += amount
		last_type = type
		if damage_taken >= 100.0:
			is_dead = true

	func _active_camera() -> Camera3D:
		return null


## A summon standing in the same field: damageable, but nothing to raise.
class DummySummon extends CharacterBody3D:
	var is_dead := false
	var team := GameConsts.Team.RED
	var damage_taken := 0.0

	func take_damage(amount: float, _type: int, _attacker) -> void:
		damage_taken += amount


func _body(script_class, pos: Vector3, team := GameConsts.Team.RED) -> Node3D:
	var t = script_class.new()
	var col := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.8
	col.shape = cap
	col.position.y = 0.9
	t.add_child(col)
	t.collision_layer = GameConsts.MASK_PLAYER
	t.team = team
	t.add_to_group("damageable")
	_root().add_child(t)
	t.global_position = pos
	_keep(t)
	return t


## Stands in for the corpse a dead wizard leaves — the spell only asks that it be in the group.
func _corpse_at(pos: Vector3) -> Node3D:
	var c := Node3D.new()
	c.add_to_group("corpses")
	_root().add_child(c)
	c.global_position = pos
	_keep(c)
	return c


## Every hit volume under `node`: an Area3D carrying the "hitbox_group" meta, which is what
## marks one both in the MDL importer and in the boxes the skeleton builds for itself.
func _hitboxes(node: Node, out: Array[Area3D] = []) -> Array[Area3D]:
	if node is Area3D and node.has_meta("hitbox_group"):
		out.append(node as Area3D)
	for child in node.get_children():
		_hitboxes(child, out)
	return out


func _caster_at(pos: Vector3, team := GameConsts.Team.BLUE) -> DummyWizard:
	var c := _body(DummyWizard, pos, team) as DummyWizard
	c.peer_id = 1
	return c


func test_the_registry_offers_every_piece_of_the_spell() -> void:
	assert_true(SpawnRegistry.has_object("skeleton"), "a skeleton is a thing in the world")
	assert_true(SpawnRegistry.has_object("throwing_bone"), "and so is what it throws")
	assert_true(SpawnRegistry.has_weapon("raise_dead_weapon"), "the spell that raises them")
	assert_false(SpawnRegistry.has_object("raise_dead_weapon"), "the spell is not itself an object")
	var w := SpawnRegistry.build_weapon("raise_dead_weapon")
	assert_true(w is RaiseDeadWeapon, "right class")
	assert_eq(w.player_attack_prefix, "combo", "cast with the shared combo-spell animation")


func test_the_spell_is_a_pickup_not_a_class_spell() -> void:
	for element in GameConsts.ELEMENT_NAMES:
		var w := SpawnRegistry.build_weapon("raise_dead_weapon", element)
		assert_ne(w, null, "every class can be handed the spell")
		assert_eq(w.hand_model_path, "models/hands/%s.mdl" % GameConsts.ELEMENT_NAMES[element],
			"cast with the %s wizard's own hands" % GameConsts.ELEMENT_NAMES[element])
		for carried in Wizard.create(element).weapons:
			assert_false(carried is RaiseDeadWeapon,
				"no %s wizard spawns holding it" % GameConsts.ELEMENT_NAMES[element])


## Unlike the meteor, an empty cast is refused rather than wasted — the book stays put.
func test_it_refuses_with_nothing_to_raise() -> void:
	var caster := _caster_at(ARENA)
	_body(DummySummon, ARENA + Vector3(2.0, 0.0, 0.0))  # damageable, but no body to raise
	var weapon: RaiseDeadWeapon = RaiseDeadWeaponScript.new()
	await _tick(1)

	assert_false(weapon.can_fire(caster), "an empty room refuses the cast")
	assert_false(weapon.fire(caster), "and firing it anyway does nothing")
	assert_true((weapon._harvest(caster).bodies as Array).is_empty(), "there was nothing to raise")


## A corpse someone is standing over cannot be taken, and it stops the whole cast rather than
## just being skipped — which is what keeps the spell out of a scrum around a fresh kill.
func test_a_watched_body_stops_the_whole_cast() -> void:
	var caster := _caster_at(ARENA)
	var corpse := _corpse_at(ARENA + Vector3(4.0, 0.0, 0.0))
	var weapon: RaiseDeadWeapon = RaiseDeadWeaponScript.new()
	await _tick(1)
	assert_true(weapon.can_fire(caster), "an unwatched body is fair game")

	_body(DummyWizard, corpse.global_position + Vector3(0.5, 0.0, 0.0))  # standing over it
	await _tick(1)
	assert_false(weapon.can_fire(caster), "someone standing over it stops the cast")
	assert_false(weapon.fire(caster), "and the cast does nothing if pushed")
	assert_true(weapon._harvest(caster).blocked, "the whole harvest is refused, not just that body")


## The heart of it: an enemy wizard in the open is killed outright and comes back up fighting
## for whoever cast it.
func test_it_takes_enemy_wizards_it_can_see() -> void:
	var caster := _caster_at(ARENA)
	var victim := _body(DummyWizard, ARENA + Vector3(5.0, 0.0, 0.0)) as DummyWizard
	var weapon: RaiseDeadWeapon = RaiseDeadWeaponScript.new()
	await _tick(1)

	assert_true(weapon.can_fire(caster), "there is a body to take")
	var harvest := weapon._harvest(caster)
	assert_eq((harvest.victims as Array).size(), 1, "one wizard to take")
	assert_lt((harvest.bodies as Array)[0].distance_to(victim.global_position), 0.01,
		"and a skeleton is raised where they are standing")

	assert_true(weapon.fire(caster), "the cast goes off")
	await _tick(2)
	assert_almost_eq(victim.damage_taken, RaiseDeadWeapon.KILL_DAMAGE, 0.01,
		"the wizard is killed outright, not fought")
	assert_eq(victim.last_type, GameConsts.DamageType.RAISING,
		"marked as the raise-dead cast, which is what leaves no corpse behind")


func test_a_wall_hides_a_wizard_from_it() -> void:
	var caster := _caster_at(ARENA)
	_body(DummyWizard, ARENA + Vector3(6.0, 0.0, 0.0))
	_floor_at(ARENA + Vector3(3.0, 0.9, 0.0), Vector3(0.5, 6.0, 8.0))  # wall between them
	var weapon: RaiseDeadWeapon = RaiseDeadWeaponScript.new()
	await _tick(1)

	assert_false(weapon.can_fire(caster), "it has to be able to see the body to take it")


func test_it_leaves_its_own_side_alone() -> void:
	var caster := _caster_at(ARENA)
	var friend := _body(DummyWizard, ARENA + Vector3(4.0, 0.0, 0.0), GameConsts.Team.BLUE)
	var weapon: RaiseDeadWeapon = RaiseDeadWeaponScript.new()
	await _tick(1)

	assert_false(weapon.can_fire(caster), "a teammate is not a body")
	assert_eq(friend.damage_taken, 0.0, "and is left standing")


func test_a_corpse_on_the_floor_is_a_body() -> void:
	var caster := _caster_at(ARENA)
	var corpse := _corpse_at(ARENA + Vector3(3.0, 0.0, 0.0))
	var weapon: RaiseDeadWeapon = RaiseDeadWeaponScript.new()
	await _tick(1)

	var harvest := weapon._harvest(caster)
	assert_eq((harvest.bodies as Array).size(), 1, "the corpse is a body all on its own")
	assert_true(weapon.fire(caster), "and the cast goes off on it alone")
	await _tick(2)
	assert_false(is_instance_valid(corpse), "the body is used up by the raising")


## The skeleton itself: it closes on what it can see and throws bones once it has the range.
func test_the_skeleton_walks_at_an_enemy_and_throws_bones() -> void:
	_floor_at(ARENA - Vector3(0.0, 0.5, 0.0))
	var skel: Skeleton = SkeletonScript.new()
	skel.setup({"position": ARENA, "team": GameConsts.Team.BLUE}, true)
	_root().add_child(skel)
	_keep(skel)
	var foe := _body(DummyWizard, ARENA + Vector3(0.0, 0.0, -10.0))

	await _tick(30)

	assert_eq(skel._target, foe, "it picked them up")
	var facing := -skel.global_transform.basis.z
	var to_foe := (foe.global_position - skel.global_position).normalized()
	assert_gt(facing.dot(to_foe), 0.99, "and turned to face them")
	# The bone itself rides the entity spawner, which no test scene has — that its clock is
	# running is what says it threw.
	assert_gt(skel._throw_timer, 0.0, "and started throwing")


## Knockback reaches a monster the way it reaches a player — by writing the body's velocity, which
## is what ForceBlastWeapon, apply_aoe_knockback and trigger_push all do. MonsterBody carried its
## own velocity across the tick and overwrote that, so a forceblast cost a skeleton 5 points of
## health and moved it not at all.
func test_a_shove_moves_it() -> void:
	_floor_at(ARENA - Vector3(0.0, 0.5, 0.0))
	var skel: Skeleton = SkeletonScript.new()
	skel.setup({"position": ARENA, "team": GameConsts.Team.BLUE}, true)
	_root().add_child(skel)
	_keep(skel)
	await _tick(5)  # nothing to fight and no objective: it is standing still

	var from := skel.global_position
	skel.velocity += Vector3(20.0, 0.0, 0.0)
	await _tick(10)

	var moved := skel.global_position - from
	assert_gt(moved.x, 1.0, "it slides along the push")
	assert_lt(absf(moved.z), 0.5, "and along nothing else")

	# And it is spent against friction rather than kept — a shoved skeleton walks again.
	await _tick(90)
	assert_lt(Vector3(skel.velocity.x, 0.0, skel.velocity.z).length(), 0.1,
		"the shove wears off")


## Names, not indices, tie the code to the model — so a swapped or rebuilt raisedead.mdl has to
## fail here rather than by silently animating the wrong thing.
func test_the_model_carries_every_clip_we_name() -> void:
	var skel: Skeleton = SkeletonScript.new()
	skel.setup({"position": ARENA, "team": GameConsts.Team.BLUE}, true)
	_root().add_child(skel)
	_keep(skel)
	var ap: AnimationPlayer = skel._rig.anim_player
	assert_true(ap != null, "the model brought an AnimationPlayer")
	for clip in SkeletonScript.THROW_ANIMS + SkeletonScript.IDLE_ANIMS + ["run"]:
		assert_true(ap.has_animation(clip), "raisedead.mdl has '%s'" % clip)


## shootgun/shootgun2 are the model's only blended sequences: GoldSrc holds the two extremes of
## the aim (50 degrees down, 50 up) and poses in between from the monster's SetBlending. Keeping
## one extreme is what had the skeleton throwing its bones into the floor, so this asks the
## imported clip where the throwing arm actually points.
func test_the_throw_aims_level_and_not_at_the_floor() -> void:
	var skel: Skeleton = SkeletonScript.new()
	skel.setup({"position": ARENA, "team": GameConsts.Team.BLUE}, true)
	_root().add_child(skel)
	_keep(skel)
	skel._rig.wake()  # the suite runs headless, where a skeleton's rig sleeps and holds its pose
	var bones: Skeleton3D = skel._model.find_child("Skeleton3D")
	var upper := bones.find_bone("Bip01 R Arm")
	var hand := bones.find_bone("Bip01 R Hand")
	assert_gt(upper, -1, "the model has the throwing arm")

	for clip in SkeletonScript.THROW_ANIMS:
		# Sampled at a fraction of the clip, not at a fixed 0.4s: shootgun2 is exactly 0.40 long,
		# and seeking to its end leaves the player with no clip and the arm wherever it stopped.
		var length: float = skel._rig.anim_player.get_animation(clip).length
		var p0 := _hand_at(skel, bones, hand, clip, 0.0)
		var p1 := _hand_at(skel, bones, hand, clip, length * 0.6)
		assert_gt(p0.distance_to(p1), 0.01, "%s moves the throwing hand during the clip" % clip)


## The throwing hand's pose `t` seconds into `clip`, read in the same frame it is set.
##
## Nothing may be awaited between the two samples. An AnimationPlayer advances on IDLE frames
## by default, so awaiting a PHYSICS frame lets an unpredictable number of idle frames carry the
## playhead past where it was seeked — by however much the machine was busy. That drift used to
## measure this travel anywhere from 0.035 down to 0.004, and the low end failed the assertion
## below. seek(update=true) applies the pose immediately, so read it before anything moves.
func _hand_at(skel: Skeleton, bones: Skeleton3D, bone: int, clip: String, t: float) -> Vector3:
	skel._rig.anim_player.play(clip)
	skel._rig.anim_player.seek(t, true)
	bones.force_update_all_bone_transforms()
	return bones.get_bone_global_pose(bone).origin


## The bone leaves on frame 0 of the throw clip, so a clip cut short shows the wind-up and
## nothing after it — which is what made the skeleton look like it was fidgeting with a weapon
## instead of throwing. Nothing may paint over the throw until it ends.
func test_the_throw_animation_plays_to_the_end() -> void:
	_floor_at(ARENA - Vector3(0.0, 0.5, 0.0))
	var skel: Skeleton = SkeletonScript.new()
	skel.setup({"position": ARENA, "team": GameConsts.Team.BLUE}, true)
	_root().add_child(skel)
	_keep(skel)
	_body(DummyWizard, ARENA + Vector3(0.0, 0.0, -3.0))  # already inside throwing range

	await _tick(5)

	var ap: AnimationPlayer = skel._rig.anim_player
	var clip := ap.current_animation
	assert_true(clip in SkeletonScript.THROW_ANIMS, "it throws with one of the model's attack clips")
	# Three quarters through the clip: the old guard had already handed over to an idle by here.
	await _tick(int(ap.get_animation(clip).length * Engine.physics_ticks_per_second * 0.75))
	assert_eq(ap.current_animation, clip, "still throwing, not painted over by walk or idle")


func test_a_bone_is_worth_forty_and_is_gone() -> void:
	# Feet on the arena floor, so the body centre a bone is measured against sits at 0.9 —
	# the height the bone is thrown at.
	var victim := _body(DummyWizard, ARENA + Vector3(0.0, 0.0, -3.0)) as DummyWizard
	var bone: ThrowingBone = ThrowingBoneScript.new()
	bone.setup({"position": ARENA + Vector3(0.0, 0.9, 0.0), "direction": Vector3.FORWARD}, true)
	_root().add_child(bone)
	_keep(bone)

	await _tick(20)  # 45 m/s covers 3 m in a heartbeat

	assert_almost_eq(victim.damage_taken, ThrowingBone.DAMAGE, 0.01, "a bone's worth")
	assert_false(is_instance_valid(bone), "and it does not go on to hit anything else")


## The eye a bone leaves from sits inside the skeleton's own contact radius, so a bone thrown
## without the thrower excluded strikes it on tick one — hurting itself and nothing in the air,
## which looks from outside like the throw animation and no bone at all.
func test_a_thrown_bone_clears_the_skeleton_that_threw_it() -> void:
	_floor_at(ARENA - Vector3(0.0, 0.5, 0.0))
	var skel: Skeleton = SkeletonScript.new()
	skel.setup({"position": ARENA, "team": GameConsts.Team.BLUE}, true)
	_root().add_child(skel)
	_keep(skel)
	var foe := _body(DummyWizard, ARENA + Vector3(0.0, 0.0, -8.0)) as DummyWizard
	await _tick(2)
	assert_lt(SpatialQuery.collision_center(skel).distance_to(skel._eye()), 0.6,
		"its own centre is inside the radius a bone contacts at — hence the exclusion")

	var bone: ThrowingBone = ThrowingBoneScript.new()
	bone.setup({"position": skel._eye(), "direction": Vector3.FORWARD}, true)
	bone.exclude_rid = skel.get_rid()
	bone.exclude_node = skel  # what Skeleton._throw sets on the spawned bone
	_root().add_child(bone)
	_keep(bone)

	await _tick(20)

	assert_almost_eq(skel.health, Skeleton.MAX_HEALTH, 0.01, "the thrower is untouched by its own bone")
	assert_almost_eq(foe.damage_taken, ThrowingBone.DAMAGE, 0.01, "and it reached the enemy instead")


## A skeleton's thrown bone is ordinary damage. Only the raise-dead cast consumes the body it
## takes; kills by the skeleton raised from it still leave corpses.
func test_a_thrown_bone_is_marked_as_the_skeletons_kill() -> void:
	var victim := _body(DummyWizard, ARENA) as DummyWizard
	var bone: ThrowingBone = ThrowingBoneScript.new()
	bone.setup({"position": ARENA, "direction": Vector3.FORWARD}, true)
	_root().add_child(bone)
	_keep(bone)

	bone._strike(victim)

	assert_almost_eq(victim.damage_taken, ThrowingBone.DAMAGE, 0.01, "it hurt them")
	assert_eq(victim.last_type, GameConsts.DamageType.PHYSICAL, "as an ordinary skeleton bone hit")


class _DeathRecorder:
	extends Player
	var died_as := -1
	var died_from := 0.0

	func _on_died(_attacker: Node3D, type: int = GameConsts.DamageType.PHYSICAL,
			damage: float = 0.0) -> void:
		died_as = type
		died_from = damage


func test_the_mark_reaches_the_death_handler() -> void:
	for type in [GameConsts.DamageType.RAISING, GameConsts.DamageType.FIRE]:
		var body := _DeathRecorder.new()
		body.health = 10.0
		body.apply_damage_raw(50.0, null, type)
		assert_true(body.is_dead, "the blow was lethal")
		assert_eq(body.died_as, type, "the death handler is told what killed them")
		assert_almost_eq(body.died_from, 50.0, 0.01, "...and how hard it hit")
		body.free()


func test_only_raise_dead_cast_suppresses_corpses() -> void:
	assert_false(Player.death_type_leaves_corpse(GameConsts.DamageType.RAISING),
		"the skeleton weapon cast consumes the body")
	assert_true(Player.death_type_leaves_corpse(GameConsts.DamageType.PHYSICAL),
		"a skeleton's thrown bone leaves a corpse")
	assert_true(Player.death_type_leaves_corpse(GameConsts.DamageType.FIRE),
		"unrelated death types still leave corpses")


## The other half of the rule: a big enough blow leaves no body either, so a wizard burst by a
## fireball is as unraisable as one taken by the raising itself.
func test_a_big_enough_blow_leaves_no_body() -> void:
	assert_false(GameConsts.damage_gibs(GameConsts.GIB_DAMAGE),
		"a blow on the threshold still leaves a corpse")
	assert_false(GameConsts.damage_gibs(0.0), "a death that wasn't an injury leaves one too")
	assert_true(GameConsts.damage_gibs(GameConsts.GIB_DAMAGE + 0.1), "over it, the body comes apart")


## raisedead.mdl ships 21 per-bone hitboxes, and every one of them is a physics transform write
## on every frame the rig animates. A skeleton drops them for two boxes on the hull it already
## collides with — so what shoots it still has something to hit, at a fixed cost.
func test_it_carries_two_hitboxes_of_its_own() -> void:
	var skel: Skeleton = SkeletonScript.new()
	skel.setup({"position": ARENA, "team": GameConsts.Team.BLUE}, true)
	_root().add_child(skel)
	_keep(skel)
	await _tick(1)

	var boxes := _hitboxes(skel)
	assert_eq(boxes.size(), 2, "a body box and a head box, not the model's per-bone set")
	assert_eq(_hitboxes(skel._model).size(), 0, "none of them hang off a bone")
	assert_eq(skel._model.find_child("Hitbox_0", true, false), null,
		"and the BoneAttachment3Ds that carried them are gone with them")
	var groups: Array[int] = []
	for box in boxes:
		assert_eq(box.collision_layer, GameConsts.MASK_HITBOX, "on the layer hitscan reads")
		groups.append(int(box.get_meta("hitbox_group")))
	assert_true(GameConsts.HITBOX_GROUP_HEAD in groups, "one of them is the head")


func test_a_hitscan_finds_them_and_the_head_one_hurts_more() -> void:
	var skel: Skeleton = SkeletonScript.new()
	skel.setup({"position": ARENA, "team": GameConsts.Team.BLUE}, true)
	_root().add_child(skel)
	_keep(skel)
	await _tick(1)

	var chest := _shoot_at(skel, SkeletonScript.HEIGHT * 0.5)
	assert_true(chest > 0.0, "a ray at chest height lands on the body box")
	var head := _shoot_at(skel, SkeletonScript.HEIGHT - SkeletonScript.HEAD_HEIGHT * 0.5)
	assert_eq(head, chest * GameConsts.HEADSHOT_MULT, "and the head box still doubles it")


## Fires 40 at the skeleton from 6 m away at the given height, and reports what it cost it.
func _shoot_at(skel: Skeleton, height: float) -> float:
	var before: float = skel.health
	var from := skel.global_position + Vector3(0.0, height, 6.0)
	var ray := Combat.raycast_world(skel, from, Vector3(0.0, 0.0, -1.0), 12.0, RID(),
		GameConsts.MASK_HITSCAN, true)
	Combat.apply_hitscan_damage(ray, 40.0, GameConsts.DamageType.PHYSICAL, null)
	return before - skel.health


## Animating the rig is most of what a skeleton costs, and nothing but an eye needs it: the
## hitboxes are the body's own and the bone leaves from the eye position. Headless is the case
## where nobody is looking at all, so the rig stands still there — while the AI goes on choosing
## clips, because that is what a client is told to play.
func test_the_rig_sleeps_where_nothing_draws_it() -> void:
	_floor_at(ARENA - Vector3(0.0, 0.5, 0.0))
	var skel: Skeleton = SkeletonScript.new()
	skel.setup({"position": ARENA, "team": GameConsts.Team.BLUE}, true)
	_root().add_child(skel)
	_keep(skel)
	_body(DummyWizard, ARENA + Vector3(0.0, 0.0, -3.0))  # inside throwing range
	await _tick(5)

	assert_false(skel._rig.anim_player.active, "nothing draws it here, so its rig is not animated")
	var bones: Skeleton3D = skel._model.find_child("Skeleton3D")
	var hand := bones.find_bone("Bip01 R Hand")
	var pose := bones.get_bone_global_pose(hand).origin
	var clips := {}
	for i in 120:
		await _tick(1)
		clips[skel._rig.anim_player.current_animation] = true
	assert_lt(bones.get_bone_global_pose(hand).origin.distance_to(pose), 0.0001,
		"the pose never moves")

	# The throw clip is held for its whole length and then released — off the skeleton's own
	# clock, since a sleeping AnimationPlayer reports the clip as playing forever.
	var threw := false
	var idled := false
	for clip in clips:
		threw = threw or clip in SkeletonScript.THROW_ANIMS
		idled = idled or clip in SkeletonScript.IDLE_ANIMS
	assert_true(threw, "it still tells clients when it throws")
	assert_true(idled, "and still comes off the throw clip when it ends")


func test_the_book_holds_one_free_cast() -> void:
	var w := SpawnRegistry.build_weapon("raise_dead_weapon")
	assert_eq(w.mana_cost, 0.0, "the book is the cost, not mana")
	assert_eq(w.min_mana_to_fire(null), 0.0, "so an empty caster can still cast it")

	var p := _wizard()
	var base := p.weapons.size()
	assert_true(p.add_granted_weapon("raise_dead_weapon"), "picked the book up")
	assert_eq(p.weapons.size(), base + 1, "and it joined the loadout")
	assert_true(p.remove_granted_weapon("raise_dead_weapon"), "casting spends it")
	assert_eq(p.weapons.size(), base, "the spell is gone again")
	assert_true(p.granted_weapons.is_empty(), "and not replayed to a late joiner")
	assert_true(p.add_granted_weapon("raise_dead_weapon"), "another book grants it again")
	p.free()


## A map's makers (ww_matrox) hand out teamless skeletons, and teamlessness spares nobody — so
## without the IRelationship rule that allies a skeleton with every non-player, three skeletons
## dropped side by side pick each other instead of the wizards walking in.
func test_a_skeleton_never_picks_another_skeleton() -> void:
	_floor_at(ARENA - Vector3(0.0, 0.5, 0.0))
	var skel: Skeleton = SkeletonScript.new()
	skel.setup({"position": ARENA, "team": GameConsts.Team.NONE}, true)
	_root().add_child(skel)
	_keep(skel)

	var mate: Skeleton = SkeletonScript.new()
	mate.setup({"position": ARENA + Vector3(2.0, 0.0, 0.0), "team": GameConsts.Team.NONE}, true)
	_root().add_child(mate)
	_keep(mate)

	var foe := _body(DummyWizard, ARENA + Vector3(0.0, 0.0, -8.0), GameConsts.Team.NONE)

	await _tick(5)

	assert_eq(skel._target, foe, "it walks past the skeleton beside it to the wizard beyond")
	assert_eq(mate._target, foe, "and so does the one it walked past")


## Spy: GibEffect.spawn and the corpse spawner are both guarded (headless, no entity spawner),
## so record the routing instead — the same shape as SpyDragon.
class SpySkeleton:
	extends SkeletonScript
	var effects: Array[Vector3] = []
	var gibbed: Array[bool] = []
	var corpses := 0
	func _death_effect(pos: Vector3, was_gibbed: bool) -> void:
		effects.append(pos)
		gibbed.append(was_gibbed)
	func _spawn_corpse() -> bool:
		corpses += 1
		return true


## A skeleton killed at ARENA by a single blow of `last_blow`. Two hits, because the first has
## to leave it standing for the second to be the one that counts.
func _dying_skeleton(last_blow: float) -> SpySkeleton:
	var skel := SpySkeleton.new()
	skel.setup({"position": ARENA, "team": GameConsts.Team.BLUE}, true)
	_root().add_child(skel)
	_keep(skel)
	skel.take_damage(Skeleton.MAX_HEALTH - last_blow)
	skel.take_damage(last_blow)
	return skel


## What the user asked for: it falls in a heap of its own bones rather than bursting. The
## original only ever burst (TE_BREAKMODEL of drybones.mdl), so this is a deliberate departure.
func test_a_skeleton_put_down_leaves_a_ragdoll() -> void:
	var skel := _dying_skeleton(GameConsts.GIB_DAMAGE)
	assert_eq(skel.corpses, 1, "it leaves a body")
	assert_false(skel.gibbed[0], "and does not come apart")


## The other half, and the rule every other body in the game follows: a finishing blow over
## GIB_DAMAGE takes it apart instead, and there is no body left under it.
func test_a_big_enough_blow_still_scatters_the_bones() -> void:
	var skel := _dying_skeleton(GameConsts.GIB_DAMAGE * 2.0)
	assert_eq(skel.corpses, 0, "nothing is left whole enough to be a body")
	assert_true(skel.gibbed[0], "so it bursts")
	assert_eq(skel.effects[0], ARENA + Vector3(0.0, Skeleton.HEIGHT * 0.5, 0.0),
		"mid-body, not at its feet")


## `/ragdolls off` has no body to leave either, so it falls back to the burst rather than
## vanishing where it stood.
func test_ragdolls_off_falls_back_to_the_burst() -> void:
	var was := RagdollBuilder.mode()
	ServerVars.set_from_string("ragdolls", "off")
	var skel := _dying_skeleton(1.0)
	ServerVars.set_from_string("ragdolls", was)
	assert_eq(skel.corpses, 0, "no rig, so no body")
	assert_true(skel.gibbed[0], "it bursts instead")


## The regression the dragon already fixed: the host's death visual is local, so a client that
## is never told sees only the despawn — the skeleton popped out instead of coming apart.
func test_death_reaches_a_client_replica() -> void:
	var skel := SpySkeleton.new()
	skel.setup({"position": ARENA, "team": GameConsts.Team.BLUE}, false)
	_keep(skel)
	skel._apply_sync_state({"death_pos": Vector3(1.0, 2.0, 3.0), "gibbed": true})
	assert_eq(skel.effects.size(), 1, "the client plays it where the host saw it die")
	assert_eq(skel.effects[0], Vector3(1.0, 2.0, 3.0), "at the host's position, not the replica's")
	assert_true(skel.gibbed[0], "and was told which of the two deaths it was")
