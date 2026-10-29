extends "res://src/tests/test_base.gd"
## func_breakable material gibs: a breakable sheds debris keyed to its "material" when
## destroyed (an absent key is matGlass, not "inert"), and a redundant TurnOff on an
## already-broken breakable must not refire gibs. Drives routing via a spy since GibEffect.spawn
## is headless-guarded.

const FuncBreakableScript = preload("res://src/entities/func_breakable.gd")


## Spy: skips the autoload-heavy _ready/super side effects, records routing.
class SpyBreakable:
	extends FuncBreakableScript
	var broke := false
	var visible_calls: Array = []
	func _break() -> void:
		broke = true
	func set_entity_visible(on: bool) -> void:
		visible_calls.append(on)
	func _sync_notify() -> void:
		pass


func _make(material: int, game_visible: bool) -> SpyBreakable:
	var b := SpyBreakable.new()
	b._material = material
	b._game_visible = game_visible
	return b


## A damageable breakable as _ready would wire it: health pool armed, break on death.
func _make_damageable(material: int, hp: float) -> SpyBreakable:
	var b := _make(material, true)
	b._arm_damage(hp)
	return b


func test_material_breakable_gibs_on_destroy() -> void:
	var b := _make(1, true)  # wood
	b.trigger(null, TriggerSystem.Type.OFF)
	assert_true(b.broke, "material breakable sheds debris when destroyed")
	assert_true(b.visible_calls.is_empty(), "break path hides via _break, not super")
	b.free()


func test_missing_material_key_is_glass() -> void:
	# CBreakable zero-inits m_Material, so no "material" key means matGlass — that is
	# what makes ww_december's and ww_library's windows shatter instead of standing.
	var b := FuncBreakableScript.new()
	assert_eq(b._material, GibEffect.MAT_GLASS, "absent material key defaults to glass")
	assert_eq(GibEffect.model_for_material(GibEffect.MAT_GLASS), "models/glassgibs.mdl", "glass gibs")
	b.free()


func test_unbreakable_glass_ignores_damage_and_use() -> void:
	# CBreakable::IsBreakable() is false only for matUnbreakableGlass: TakeDamage bails
	# and Use is a no-op, so it neither shatters nor even hides.
	var b := _make(GibEffect.MAT_UNBREAKABLE_GLASS, true)
	b.trigger(null, TriggerSystem.Type.OFF)
	assert_false(b.broke, "unbreakable glass ignores a Use")
	assert_true(b.visible_calls.is_empty(), "and does not hide either")
	b.free()


func test_turn_on_never_gibs() -> void:
	var b := _make(1, false)
	b.trigger(null, TriggerSystem.Type.ON)
	assert_false(b.broke, "restoring a breakable never sheds debris")
	assert_eq(b.visible_calls, [true], "it becomes visible again")
	b.free()


func test_already_broken_does_not_refire_gibs() -> void:
	var b := _make(1, false)  # already hidden/broken
	b.trigger(null, TriggerSystem.Type.OFF)
	assert_false(b.broke, "a redundant TurnOff on a broken breakable emits no gibs")
	b.free()


func test_damage_breaks_at_zero_health() -> void:
	var b := _make_damageable(1, 100.0)  # wood door
	b.take_damage(100.0, GameConsts.DamageType.PHYSICAL, null)
	assert_true(b.broke, "a breakable shot to 0 HP shatters")
	b.free()


func test_partial_damage_does_not_break() -> void:
	var b := _make_damageable(1, 100.0)
	b.take_damage(60.0, GameConsts.DamageType.PHYSICAL, null)
	assert_false(b.broke, "still-standing breakable does not gib on partial damage")
	assert_false(b._health.is_dead, "health survives above 0")
	b.free()


func test_non_damageable_ignores_damage() -> void:
	var b := _make(1, true)  # never armed (trigger-only / no health)
	b.take_damage(9999.0, GameConsts.DamageType.PHYSICAL, null)
	assert_false(b.broke, "a non-damageable breakable can't be shot apart")
	b.free()


func test_exposes_team_none_so_bots_skip_it() -> void:
	# Breakables sit in the "damageable" group for AoE, but must read as team NONE so
	# bot target-selection (which skips team==NONE) doesn't fixate on the wall.
	var b := _make(1, true)
	assert_eq(b.team, GameConsts.Team.NONE, "breakable is teamless")
	b.free()


func test_material_model_mapping() -> void:
	# Faithful to WizardWars func_break.cpp material -> gib model.
	assert_eq(GibEffect.model_for_material(0), "models/glassgibs.mdl", "glass")
	assert_eq(GibEffect.model_for_material(1), "models/woodgibs.mdl", "wood")
	assert_eq(GibEffect.model_for_material(2), "models/metalplategibs.mdl", "metal")
	assert_eq(GibEffect.model_for_material(4), "models/cindergibs.mdl", "cinderblock")
	assert_eq(GibEffect.model_for_material(8), "models/rockgibs.mdl", "rocks")
	# Unmapped/unshipped materials fall back to wood so it never no-ops.
	assert_eq(GibEffect.model_for_material(99), "models/woodgibs.mdl", "unknown -> wood fallback")


## GoldSrc lets a brush name its own "gibmodel", which wins over whatever its material implies.
## Only one map in the set uses it, so without this the key would go on being ignored unnoticed.
func test_a_brush_can_name_its_own_gib_model() -> void:
	var named := "models/flyingskull.mdl"
	assert_eq(GibEffect.model_for_break(GibEffect.MAT_GLASS, named), named,
		"a brush that names a model throws that model, not its material's")
	assert_eq(GibEffect.model_for_break(1, ""), GibEffect.model_for_material(1),
		"and one that names nothing falls back to its material")
	assert_eq(GibEffect.model_for_break(1, "models/not_shipped_anywhere.mdl"),
		GibEffect.model_for_material(1),
		"as does one that names something that isn't there")


## The map this exists for. ww_feudal has a func_breakable that showers flying skulls; the model
## it names is hardcoded in the .bsp, so the file has to keep that exact path.
func test_ww_feudal_still_asks_for_its_flying_skulls() -> void:
	var bsp := FileAccess.open("res://maps/ww_feudal.bsp", FileAccess.READ)
	assert_ne(bsp, null, "ww_feudal is in the map set")
	# Entity keyvalues are lump 0; the rest of a .bsp is binary, so reading the whole file as
	# text stops dead at the first null byte.
	bsp.seek(4)
	var ents_offset := bsp.get_32()
	var ents_length := bsp.get_32()
	bsp.seek(ents_offset)
	var text := bsp.get_buffer(ents_length).get_string_from_ascii()
	assert_true(text.contains("\"gibmodel\" \"models/flyingskull.mdl\""),
		"the map still names this gib model")
	assert_ne(AssetLoader.load_model("models/flyingskull.mdl"), null,
		"and the model is on disk at the path the map hardcodes")


## The collider is the gib's own bounding box — no invented extents.
func test_gib_collider_is_the_gibs_bounding_box() -> void:
	var body_size := Vector3(0.6, 0.024, 0.12)
	var box := (GibEffect._collision_box(body_size).shape as BoxShape3D).size
	assert_almost_eq(box.x, 0.6, 0.001, "the mesh's own length")
	assert_almost_eq(box.y, 0.024, 0.001, "its own thickness")
	assert_almost_eq(box.z, 0.12, 0.001, "its own width")


## The trace reads the collider unrotated, so the box's vertical extent alone sets the
## resting height. The thin axis has to land on Y or the gib hovers by half its length —
## which is what the old disc did to a glass shard, holding it 14.9 cm up.
func test_the_thin_axis_is_turned_onto_y() -> void:
	var cases := {
		"thin y (most gibs)": Vector3(0.577, 0.102, 0.122),
		"thin x (cinder chunk)": Vector3(0.238, 0.524, 0.357),
		"thin z (metal plate)": Vector3(0.104, 0.176, 0.093),
	}
	for name in cases:
		var size: Vector3 = cases[name]
		var body_size: Vector3 = (GibEffect._flat_basis(size) * size).abs()
		var thinnest: float = minf(size.x, minf(size.y, size.z))
		assert_almost_eq(body_size.y, thinnest, 0.001, "%s rests on its flat side" % name)
		# The box is the same box, only reordered — no extent invented or dropped.
		var before := [size.x, size.y, size.z]
		var after := [body_size.x, body_size.y, body_size.z]
		before.sort()
		after.sort()
		for i in 3:
			assert_almost_eq(after[i], before[i], 0.001, "%s keeps its own extents" % name)


## Gibs are tumbled by the solver now instead of posed by a script. Re-locking rotation
## zeroes the body's inertia in hop and gates the whole angular path off, so the body
## would stop turning entirely — assert on the BODY's basis, not the mesh's.
## Spawned high and left in free fall, so this reads the integrator, not a contact.
func test_a_launched_gib_is_turned_by_the_solver() -> void:
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.12, 0.024, 0.07)
	mesh.mesh = box
	GibEffect._launch(mesh, Vector3(0.0, 40.0, 0.0), 1.0, _root())
	var body := mesh.get_parent() as RigidBody3D
	assert_ne(body, null, "the gib got a body")
	assert_false(body.lock_rotation, "rotation is not locked")
	assert_gt(body.inertia.length(), 0.0, "and it has an inertia tensor to spin with")
	# The mesh basis carries the spawn scale as well as the flattening rotation; writing
	# a bare rotation to it would silently reset the gib to full size.
	assert_almost_eq(mesh.scale.x, mesh.scale.y, 0.001, "scale survived the flatten")
	var collider := body.get_child(0) as CollisionShape3D
	var collider_size := (collider.shape as BoxShape3D).size
	var visual: Vector3 = (mesh.basis * mesh.get_aabb().size).abs()
	for i in 3:
		assert_almost_eq(collider_size[i], visual[i], 0.005,
			"collider matches the drawn gib on axis %d" % i)

	var tree := Engine.get_main_loop() as SceneTree
	await tree.physics_frame
	var start := body.global_basis.get_rotation_quaternion()
	for i in 30:
		await tree.physics_frame
	var turned: float = start.angle_to(body.global_basis.get_rotation_quaternion())
	assert_gt(turned, 0.1, "the solver turned the body itself (%.3f rad)" % turned)
	body.queue_free()


## Lowest about the long axis is what tumbles a bone end over end. The tensor and the
## collider now describe the same box, so they must agree.
func test_gib_inertia_matches_its_collider() -> void:
	var body_size := Vector3(0.6, 0.1, 0.12)
	var I := GibEffect._box_inertia(body_size, 1.0)
	assert_lt(I.x, I.z, "least resistance about the long axis")
	assert_lt(I.z, I.y, "most about the shortest")
	var box := (GibEffect._collision_box(body_size).shape as BoxShape3D).size
	assert_eq(GibEffect._box_inertia(box, 1.0), I, "same box, same tensor")


func test_gib_tumble_axis_leans_across_the_bone() -> void:
	for i in 20:
		var axis := GibEffect._tumble_axis(Vector3.RIGHT)
		assert_almost_eq(axis.length(), 1.0, 0.001, "unit axis")
		assert_almost_eq(axis.dot(Vector3.RIGHT), 0.0, 0.001, "never along the bone")


func test_gib_long_axis_comes_from_the_mesh() -> void:
	assert_eq(GibEffect._longest_axis(Vector3(0.6, 0.1, 0.12)), Vector3.RIGHT, "long on x")


## A gib model keeps its debris shapes as the submodels of one bodypart, and only the
## first was ever built — so every gib in a burst was the same bone. bonegibs has five.
func test_a_gib_model_offers_all_its_shapes() -> void:
	var proto := AssetLoader.load_model("models/bonegibs.mdl")
	assert_ne(proto, null, "bone gib model is on disk")
	var meshes := GibEffect._all_mesh_instances(proto)
	assert_gt(meshes.size(), 1, "more than one bone shape to throw")
	var sizes := {}
	for m in meshes:
		sizes[str(m.mesh.get_aabb().size.snappedf(0.001))] = true
	assert_gt(sizes.size(), 1, "and they are genuinely different shapes")
	proto.free()


## A window is in "damageable" so a blast breaks it, and in "unhunted" so no homing missile,
## monster or bot picks it over the wizard standing behind it. ww_library has a wall of them.
func test_a_damageable_breakable_is_not_a_target() -> void:
	var b := _make_damageable(GibEffect.MAT_GLASS, 50.0)
	assert_true(b.is_in_group("damageable"), "splash and stray shots walk the damageable group")
	assert_true(b.is_in_group("unhunted"), "and this is what keeps it out of every search")
	b.free()
