extends "res://src/tests/test_base.gd"
## monster_sheep: the grazing cycle, the ledge it won't walk off, the 50 HP anything aimed at it
## can take, and the fact that nothing ever aims at it on purpose.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.

const SheepScript = preload("res://src/monsters/sheep.gd")
const MonsterMakerScript = preload("res://src/entities/monstermaker.gd")
const TriggerCometScript = preload("res://src/entities/trigger_comet.gd")

const ARENA := Vector3(-300.0, 200.0, 300.0)  # clear of map geometry, and of the other suites'


## Something with a health pool for the homing search to find, so "it picked the wizard" is a
## claim about the sheep rather than about an empty field.
class DummyWizard extends CharacterBody3D:
	var is_dead := false
	var team := GameConsts.Team.RED

	func take_damage(_amount: float, _type: int, _attacker) -> void:
		pass


## A spawn guard that records what it would have dropped a comet on instead of launching one —
## the same spy seam test_monstermaker uses on the spawner.
class SpyGuard extends TriggerCometScript:
	var shot: Array[Node] = []

	func _comet(target: Node) -> bool:
		shot.append(target)
		return true


## Records what the burr would have latched onto. The real _attach_to freezes the body, rewrites
## the victim's speed and plays a sound — none of which this is about.
class SpyBurr extends Cockleburr:
	var caught: Array[Node] = []

	func _attach_to(victim: Node3D) -> void:
		caught.append(victim)


func _sheep_at(pos: Vector3) -> Sheep:
	var s: Sheep = SheepScript.new()
	s.setup({"position": pos, "team": GameConsts.Team.NONE}, true)
	_root().add_child(s)
	_keep(s)
	return s


func _wizard_at(pos: Vector3) -> DummyWizard:
	var w := DummyWizard.new()
	var col := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.8
	col.shape = cap
	col.position.y = 0.9
	w.add_child(col)
	w.collision_layer = GameConsts.MASK_PLAYER
	w.add_to_group("damageable")
	_root().add_child(w)
	w.global_position = pos
	_keep(w)
	return w


## Holds the sheep in one clip for the whole of a test, so what moves it can be asked about
## without waiting on its own one-in-four rolls.
func _hold_clip(s: Sheep, clip: String) -> void:
	s._rig.clip = clip
	s._rig.clip_ends = s._rig.age + 100.0


func test_the_maker_and_the_registry_both_know_it() -> void:
	assert_eq(MonsterMakerScript.MONSTER_SCRIPTS.get("monster_sheep", ""),
		"res://src/monsters/sheep.gd", "a map's ww_monstermaker has a sheep to make")
	assert_true(SpawnRegistry.has_object("sheep"), "and /spawn can drop one")


## Names, not indices, tie the code to the model — the original cycled sequence numbers, and a
## rebuilt sheep.mdl has to fail here rather than by silently animating the wrong thing.
func test_the_model_carries_every_clip_we_name() -> void:
	var s := _sheep_at(ARENA)
	await _tick(1)
	assert_ne(s._rig.anim_player, null, "the model brought an AnimationPlayer")
	for clip in [SheepScript.CLIP_TROT, SheepScript.CLIP_DOWN, SheepScript.CLIP_EAT,
			SheepScript.CLIP_UP, SheepScript.CLIP_DEAD]:
		assert_true(s._rig.anim_player.has_animation(clip), "sheep.mdl has '%s'" % clip)
	assert_true(s._rig.anim_player.get_animation(SheepScript.CLIP_TROT).loop_mode != Animation.LOOP_NONE,
		"the trot loops, so a sheep that keeps walking never restarts it")


## trot -> down -> eat -> up -> trot, with the two loops held on a one-in-four roll, exactly as
## CSheep::MonsterThink cycled its sequences.
func test_it_grazes_in_the_order_the_original_did() -> void:
	var s := _sheep_at(ARENA)
	await _tick(1)

	_hold_clip(s, SheepScript.CLIP_DOWN)
	s._next_clip()
	assert_eq(s._rig.clip, SheepScript.CLIP_EAT, "head down is always followed by eating")

	_hold_clip(s, SheepScript.CLIP_UP)
	s._next_clip()
	assert_eq(s._rig.clip, SheepScript.CLIP_TROT, "head up is always followed by walking on")

	# The two looping clips hold themselves until a roll breaks them, so both outcomes have to
	# show up over enough tries.
	for pair in [[SheepScript.CLIP_EAT, SheepScript.CLIP_UP],
			[SheepScript.CLIP_TROT, SheepScript.CLIP_DOWN]]:
		var seen := {}
		for i in 200:
			_hold_clip(s, pair[0])
			s._next_clip()
			seen[s._rig.clip] = true
		assert_true(seen.has(pair[0]), "'%s' sometimes repeats" % pair[0])
		assert_true(seen.has(pair[1]), "'%s' sometimes gives way to '%s'" % [pair[0], pair[1]])
		assert_eq(seen.size(), 2, "'%s' leads nowhere else" % pair[0])


func test_only_the_trot_moves_it() -> void:
	_floor_at(ARENA - Vector3(0.0, 0.5, 0.0), Vector3(20.0, 1.0, 20.0))
	var s := _sheep_at(ARENA)
	await _tick(5)

	_hold_clip(s, SheepScript.CLIP_EAT)
	await _tick(30)  # it coasts a few centimetres to a stop on friction rather than stopping dead
	var grazing_from := s.global_position
	await _tick(20)
	assert_lt(_flat(s.global_position - grazing_from).length(), 0.01,
		"a sheep with its head in the grass stands still")

	_hold_clip(s, SheepScript.CLIP_TROT)
	s._goal = s.global_position - s.global_transform.basis.z * 1.0
	var walking_from := s.global_position
	await _tick(20)
	assert_gt(_flat(s.global_position - walking_from).length(), 0.1, "the trot walks it somewhere")


func _flat(v: Vector3) -> Vector3:
	return Vector3(v.x, 0.0, v.z)


## The trot used to be assigned straight into `velocity` every tick, which swallowed whatever the
## world had done to the animal — a forceblast, a blast wave, a trigger_push. Friction and
## acceleration spend a shove down instead, so a sheep slides and then goes back to grazing.
func test_a_shove_moves_it() -> void:
	_floor_at(ARENA - Vector3(0.0, 0.5, 0.0), Vector3(60.0, 1.0, 60.0))
	var s := _sheep_at(ARENA)
	_hold_clip(s, SheepScript.CLIP_EAT)  # head down, so what moves it is the shove
	await _tick(5)

	var from := s.global_position
	s.velocity += Vector3(20.0, 0.0, 0.0)
	await _tick(10)

	var moved := _flat(s.global_position - from)
	assert_gt(moved.x, 1.0, "it slides along the push")
	assert_lt(absf(moved.z), 0.5, "and along nothing else")

	_hold_clip(s, SheepScript.CLIP_TROT)
	s._goal = s.global_position + Vector3(0.0, 0.0, -10.0)
	await _tick(90)
	assert_almost_eq(_flat(s.velocity).length(), SheepScript.WALK_SPEED, 0.05,
		"and once the shove is gone it is back to exactly its own pace")


## A blast with any lift in it has to leave the ground, which the clamp that holds a sheep on its
## floor used to undo on the same tick it was written.
func test_a_shove_with_lift_takes_it_off_the_ground() -> void:
	_floor_at(ARENA - Vector3(0.0, 0.5, 0.0), Vector3(60.0, 1.0, 60.0))
	var s := _sheep_at(ARENA)
	_hold_clip(s, SheepScript.CLIP_EAT)
	await _tick(5)
	assert_true(s.is_on_floor(), "standing on it to begin with")

	s.velocity += Vector3(0.0, 8.0, 0.0)
	await _tick(4)
	assert_gt(s.global_position.y - ARENA.y, 0.3, "the lift carries it up")

	await _tick(90)
	assert_lt(absf(s.global_position.y - ARENA.y), 0.2, "and gravity puts it back down")


## The one rule that keeps a flock on the hilltop it was put on: GoldSrc refuses a step that
## finds no ground, and so does this.
func test_it_will_not_walk_off_a_ledge() -> void:
	var slab := _floor_at(ARENA - Vector3(0.0, 0.5, 0.0), Vector3(4.0, 1.0, 4.0))
	var s := _sheep_at(ARENA + Vector3(0.0, 0.0, 1.6))  # a step from the near edge
	_hold_clip(s, SheepScript.CLIP_EAT)  # standing still, so the edge stays where it was put
	await _tick(10)

	assert_true(s._ground_ahead(Vector3.FORWARD),
		"back toward the middle of the slab there is floor to land on")
	assert_false(s._ground_ahead(Vector3.BACK), "over the edge there is not")
	assert_lt(absf(s.global_position.y - (slab.global_position.y + 0.5)), 0.2, "and it is standing on it")


func test_it_stays_on_the_ground_it_was_put_on() -> void:
	var slab := _floor_at(ARENA - Vector3(0.0, 0.5, 0.0), Vector3(4.0, 1.0, 4.0))
	var s := _sheep_at(ARENA)
	await _tick(180)  # three seconds of wandering on a two-metre reach

	var offset := _flat(s.global_position - ARENA)
	assert_lt(offset.length(), 2.2, "it never left the slab")
	assert_lt(absf(s.global_position.y - (slab.global_position.y + 0.5)), 0.2, "nor fell off it")


## The MDL's own hit volume is a slab on a bone that covers almost none of the animal, so the
## sheep carries one box of its own — without which it could not be shot at all.
func test_it_carries_one_hitbox_of_its_own() -> void:
	var s := _sheep_at(ARENA)
	await _tick(1)
	assert_eq(_count_hitboxes(s), 1, "one box, not the model's own")
	assert_eq(_count_hitboxes(s._model), 0, "and none of them hangs off a bone")


func test_fifty_points_of_anything_kills_it() -> void:
	_floor_at(ARENA - Vector3(0.0, 0.5, 0.0), Vector3(20.0, 1.0, 20.0))
	var s := _sheep_at(ARENA)
	await _tick(2)

	var from := s.global_position + Vector3(0.0, SheepScript.HITBOX_CENTER.y, 4.0)
	var ray := Combat.raycast_world(s, from, Vector3(0.0, 0.0, -1.0), 8.0, RID(),
		GameConsts.MASK_HITSCAN, true)
	assert_true(Combat.apply_hitscan_damage(ray, 20.0, GameConsts.DamageType.PHYSICAL, null),
		"a ray at body height lands on it")
	assert_almost_eq(s.health, SheepScript.MAX_HEALTH - 20.0, 0.01, "and costs it what it hit for")

	s.take_damage(SheepScript.MAX_HEALTH, GameConsts.DamageType.PHYSICAL, null)
	assert_true(s.is_dead, "fifty is the whole animal")
	await _tick(2)
	assert_false(is_instance_valid(s), "and it leaves no body behind — it fades out of the world")


## CSheep::IRelationship answered R_NM to everything, which is what keeps a homing missile on the
## wizard behind the flock. It stays damageable, though: a comet that lands among them still does.
func test_nothing_hunts_it_but_anything_can_hurt_it() -> void:
	# Off the line between the two wizards: a sheep is a solid body on the entity layer, so one
	# standing in the way would block the search's line of sight rather than be passed over.
	var s := _sheep_at(ARENA + Vector3(2.5, 0.0, 2.0))
	var seeker := _wizard_at(ARENA + Vector3(0.0, 0.0, 6.0))
	await _tick(2)

	assert_true(s.is_in_group("damageable"), "splash damage walks the damageable group")
	assert_true(s.is_in_group("unhunted"), "and this is what takes it back out of a search")
	assert_eq(Combat.find_homing_target(seeker, null, GameConsts.Team.BLUE, 30.0), null,
		"a field with nothing but sheep in it offers no target")

	var wizard := _wizard_at(ARENA + Vector3(0.0, 0.0, -6.0))
	await _tick(2)
	assert_eq(Combat.find_homing_target(seeker, null, GameConsts.Team.BLUE, 30.0), wizard,
		"it looks straight past the nearer sheep to the wizard beyond")


## The other place the codebase picks something to attack. A guard given team_no "0" is active
## with no team to filter on, so without the same rule it comets the flock in front of it.
func test_a_spawn_guard_does_not_shoot_the_flock() -> void:
	var guard := SpyGuard.new()
	guard.set_meta("entity", {"classname": "trigger_comet", "team_no": "0"})
	_root().add_child(guard)
	_keep(guard)
	guard.global_position = ARENA - Vector3(0.0, 0.5, 0.0)
	var s := _sheep_at(ARENA)
	await _tick(2)

	guard._scan_for_enemies()
	assert_true(guard.shot.is_empty(), "a field of sheep gives an active guard nothing to shoot")

	var wizard := _wizard_at(ARENA + Vector3(2.0, 0.0, 0.0))
	await _tick(2)
	guard._scan_for_enemies()
	assert_eq(guard.shot, [wizard] as Array[Node], "it drops one on the wizard who walks in instead")
	assert_false(s.is_dead, "and the sheep is still standing")


## The comet spell picks its own target out of the same group, and it is the one place that walks
## it with no rule at all — so a flock between caster and wizard ate the comet.
func test_the_comet_spell_looks_past_the_flock() -> void:
	var caster := _wizard_at(ARENA + Vector3(0.0, 0.0, 6.0))
	var s := _sheep_at(ARENA + Vector3(0.0, 0.0, 2.0))
	await _tick(2)

	# An empty answer, not "the wizard won on points": _find_target scores by how centred a
	# candidate is, and anything behind the flock is MORE centred, so a two-body test would
	# pass with the rule deleted.
	var spell := CometWeapon.new()
	var from: Vector3 = caster.global_position + Vector3(0.0, 1.5, 0.0)
	var aim := Vector3(0.0, 0.0, -1.0)
	assert_eq(spell._find_target(caster, from, aim), null,
		"a flock dead ahead offers the comet nothing to lock")

	var wizard := _wizard_at(ARENA + Vector3(0.0, 0.0, -2.0))
	wizard.team = GameConsts.Team.BLUE  # or the caster spares it as a teammate
	await _tick(2)
	assert_eq(spell._find_target(caster, from, aim), wizard,
		"it locks the wizard beyond them instead")
	assert_false(s.is_dead, "and the flock is untouched either way")


## A cocklebur latches onto whatever enemy comes within TRAP_RADIUS, which is the last place the
## codebase picks something to attack. A sheep wandering over one is not a catch.
func test_a_cocklebur_does_not_trip_on_the_flock() -> void:
	var burr := SpyBurr.new()
	burr.setup({"position": ARENA, "team": GameConsts.Team.BLUE}, true)
	_root().add_child(burr)
	_keep(burr)
	_sheep_at(ARENA + Vector3(0.5, 0.0, 0.0))
	await _tick(2)

	burr._check_for_victim()
	assert_true(burr.caught.is_empty(), "a sheep underfoot gives the burr nothing to grab")

	var wizard := _wizard_at(ARENA + Vector3(0.5, 0.0, 0.0))
	await _tick(2)
	burr._check_for_victim()
	assert_eq(burr.caught, [wizard] as Array[Node], "the wizard who walks in is another matter")
