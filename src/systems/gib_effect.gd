class_name GibEffect
extends RefCounted
# Debris burst for destroyed func_breakable brushes: scatter N rigid gib bodies keyed
# by GoldSrc's "material" value, with random impulse + spin, then fade out. Cosmetic
# only; never runs on a headless server.

# GoldSrc Materials enum (func_break.h) -> stock HL gib model.
# Flesh isn't shipped and falls back to wood, as does any material with no entry here.
const MAT_GLASS := 0  # CBreakable's zero-init default when a brush has no "material" key
const MAT_UNBREAKABLE_GLASS := 7  # CBreakable::IsBreakable() is false for this one alone
const MAT_FLESH := 3  # what a body bursts into — a wizard, a dragon, a bird
## The noise a body makes coming apart. One path, because there is one of these sounds in the
## assets and everything that bursts uses it.
const FLESH_BURST_SOUND := "player/gib.wav"
const MATERIAL_GIBS := {
	0: "models/glassgibs.mdl",       # matGlass
	1: "models/woodgibs.mdl",        # matWood
	2: "models/metalplategibs.mdl",  # matMetal
	3: "models/fleshgibs.mdl",       # matFlesh
	4: "models/cindergibs.mdl",      # matCinderBlock
	8: "models/rockgibs.mdl",        # matRocks
	9: "models/bonegibs.mdl",        # matBones
}
const FALLBACK_GIB := "models/woodgibs.mdl"  # matWood default; always present
## How fast a gib sheds its tumble. hop-godot applies BODY angular damp only — no area
## or project-default override — so this is the whole of it, and at 0 a gib keeps its
## launch spin until it fades. At 3.0 it still lands turning at 1-3 rev/s, scatters
## under a metre, and settles at ~2.9 s.
const ANGULAR_DAMP := 3.0
## The hole one chunk of debris punches in a pool, against LiquidSounds' 1.0 = a person.
const SPLASH_SIZE := 0.25
## ...and how many of a burst are allowed to notice the water. A plop and a spray per chunk
## would be a machine gun, so only the first few of the shower carry one — the rest go in
## unmarked, which at gib scale nobody reads as missing.
const MAX_SPLASHERS := 6


## A gib that hears itself go into the water. Only splashers_for() of a burst are built as
## one; the rest are plain bodies that cost nothing per tick.
class SplashingGib extends RigidBody3D:
	var _entry := LiquidEntry.new()
	var _rng := RandomNumberGenerator.new()

	func _init() -> void:
		_entry.size = GibEffect.SPLASH_SIZE

	## Local on every peer: gibs are client-side cosmetics — the host has none to broadcast.
	func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
		_entry.check(self, state.transform.origin, state.get_linear_velocity().length(), _rng)


## How many of a `count`-chunk burst splash. Enough that a small break still marks the water,
## bounded so a collapsing house does not.
static func splashers_for(count: int) -> int:
	@warning_ignore("integer_division")
	return clampi(count / 6, 2, MAX_SPLASHERS)


## A burst every peer that can see it sees: the host sends it to the PVS around it, offline it
## simply happens, and a client never starts one of its own. One-shot and cosmetic, so it rides
## its own unreliable RPC rather than a replicated entity — nothing survives it for a replica to
## be. An empty `sound` bursts silently; a zero `count` sizes the debris to `extent`.
static func burst(pos: Vector3, material: int, extent: Vector3, count: int, sound: String,
		scene_root: Node, gibmodel := "") -> void:
	if not NetworkManager.is_online():
		play_burst(pos, material, extent, count, sound, scene_root, gibmodel)
		return
	if not NetworkManager.is_authority():
		return
	NetworkManager.send_to_pvs_and_dispatch(AABB(pos - extent * 0.5, extent), &"sync_gib_burst",
		[pos, material, extent, count, sound, gibmodel])


## The burst itself, on this peer alone: the debris and the noise that goes with it. Every peer
## runs exactly this — the host through send_to_pvs_and_dispatch, a client off the RPC — which is
## why the sound is local-only. A broadcast one would land a second copy on each client.
static func play_burst(pos: Vector3, material: int, extent: Vector3, count: int, sound: String,
		scene_root: Node, gibmodel := "") -> void:
	spawn(material, pos, extent, scene_root, gibmodel, count)
	if not sound.is_empty():
		SoundSystem.play_3d_local(sound, pos)


## Resolve a GoldSrc "material" value to a gib model path (wood fallback).
static func model_for_material(material: int) -> String:
	return MATERIAL_GIBS.get(material, FALLBACK_GIB)


## What a breakable actually throws. GoldSrc lets a brush name its own "gibmodel" and use that
## instead of whatever its material implies — ww_feudal has one that showers flying skulls. An
## empty or missing model falls back to the material, so a brush that names nothing, or names
## something that isn't shipped, still breaks the way its material says.
static func model_for_break(material: int, gibmodel: String) -> String:
	if not gibmodel.is_empty() and AssetLoader.load_model(gibmodel) != null:
		return gibmodel
	return model_for_material(material)


## Spawn a debris burst at `center` sized to `extent` (the brush's world AABB size).
## `scene_root` receives the transient gib bodies. No-op on headless / bad model.
## `gibmodel` overrides the material's model when the brush named one — see model_for_break.
static func spawn(material: int, center: Vector3, extent: Vector3, scene_root: Node,
		gibmodel: String = "", count: int = 0) -> void:
	if DisplayServer.get_name() == "headless" or scene_root == null:
		return
	var proto := AssetLoader.load_model(model_for_break(material, gibmodel))
	if proto == null:
		proto = AssetLoader.load_model(FALLBACK_GIB)
		if proto == null:
			return
	# build_model bakes verts at rest pose, so the skinned .mdl mesh renders fine
	# skeleton-free — and must be: a skeleton with fewer bones than referenced trips
	# "bs > sbs" in mesh_get_aabb and fails to render.
	# Every shape in the model, not just the first. A gib .mdl keeps its debris as the
	# submodels of one bodypart — bonegibs has five, metalplategibs thirteen — and they
	# are alternatives, so the importer builds them all with only the first visible.
	var gib_meshes: Array[Mesh] = []
	for src in _all_mesh_instances(proto):
		var m: Mesh = src.mesh
		# Bake the resolved material onto the shared mesh so set_model_alpha can
		# duplicate it per-instance when fading (see _launch) without an override.
		var resolved := src.get_active_material(0)
		if resolved and m.get_surface_count() > 0:
			m.surface_set_material(0, resolved)
		gib_meshes.append(m)
	proto.free()
	if gib_meshes.is_empty():
		return

	# More debris for bigger structures; keep it bounded so a house isn't a swarm.
	var span := extent.x * extent.y * extent.z
	if count == 0:
		count = clampi(int(round(span * 1.5)), 5, 48)
	# Throw strength scales with size so a house flings debris further than a crate.
	var reach := clampf(span * 0.5, 1.5, 6.0)

	var splashers := splashers_for(count)
	for i in count:
		var node := MeshInstance3D.new()
		node.mesh = gib_meshes[randi() % gib_meshes.size()]
		# Spawn from a random point inside the brush volume, not all from one spot.
		var jitter := Vector3(
			randf_range(-0.5, 0.5) * extent.x,
			randf_range(-0.5, 0.5) * extent.y,
			randf_range(-0.5, 0.5) * extent.z)
		_launch(node, center + jitter, reach, scene_root, i < splashers)


## First MeshInstance3D in a loaded model (depth-first), or null.
static func _first_mesh_instance(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh:
		return node
	for child in node.get_children():
		var found := _first_mesh_instance(child)
		if found:
			return found
	return null


## Every MeshInstance3D in a loaded model, visible or not — a gib model's shapes past the
## first are built hidden, being alternatives rather than parts shown together.
static func _all_mesh_instances(node: Node, out: Array[MeshInstance3D] = []) -> Array[MeshInstance3D]:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh:
		out.append(node)
	for child in node.get_children():
		_all_mesh_instances(child, out)
	return out

static func _launch(node: Node3D, at: Vector3, reach: float, scene_root: Node,
		hears_water := false) -> void:
	var lifetime := randf_range(2.0, 3.0)
	var fade_time := 0.6

	node.scale *= randf_range(0.7, 1.2)
	# Held separately: the basis written below carries scale as well as rotation, so
	# assigning a bare rotation to it would throw this away.
	var scl := node.scale
	var aabb := _local_visual_aabb(node)
	if aabb.size == Vector3.ZERO:
		aabb = AABB(Vector3(-0.05, -0.05, -0.05), Vector3(0.1, 0.1, 0.1))
	var size := aabb.size * scl
	# Lay the gib's thinnest axis along body Y — see _flat_basis. Everything below is in
	# that frame: the collider, the inertia tensor and the tumble axis.
	var flat := _flat_basis(size)
	var body_size := (flat * size).abs()

	var body: RigidBody3D = SplashingGib.new() if hears_water else RigidBody3D.new()
	body.collision_layer = 0
	body.collision_mask = GameConsts.MASK_WORLD
	body.angular_damp = ANGULAR_DAMP
	# The mesh turns with the body now, so it is placed once rather than every frame.
	node.basis = flat * Basis.from_scale(scl)
	node.position = -(flat * (aabb.get_center() * scl))

	body.add_child(_collision_box(body_size))
	body.add_child(node)
	# After the shape: Godot would otherwise recompute it, and the auto tensor is derived
	# from the collision AABB against the mass rather than the box's own extents.
	body.inertia = _box_inertia(body_size, body.mass)
	scene_root.add_child(body)
	body.global_transform = Transform3D(
		Basis.from_euler(Vector3(randf() * TAU, randf() * TAU, randf() * TAU)), at)
	body.angular_velocity = (body.global_basis * _tumble_axis(_longest_axis(body_size))) \
		* randf_range(6.0, 14.0)

	var angle := randf() * TAU
	body.apply_impulse(Vector3(
		cos(angle) * randf_range(0.5, 1.0) * reach,
		randf_range(1.0, 2.0) * reach * 0.5,
		sin(angle) * randf_range(0.5, 1.0) * reach))

	var tween := body.create_tween()
	tween.tween_interval(lifetime - fade_time)
	tween.tween_method(func(alpha: float) -> void:
		AssetLoader.set_model_alpha(node, alpha)
	, 1.0, 0.0, fade_time)
	tween.tween_callback(body.queue_free)


## The gib's own bounding box. Nothing is invented: the extents are the mesh's, already
## turned into the body frame by _flat_basis.
static func _collision_box(body_size: Vector3) -> CollisionShape3D:
	var box := BoxShape3D.new()
	box.size = body_size.max(Vector3(0.02, 0.02, 0.02))
	var col := CollisionShape3D.new()
	col.shape = box
	return col


## Turn the mesh so its THINNEST extent lies along body Y — a fixed axis swap baked in
## once at spawn, not an animation. hop's BSP trace reads the collider unrotated whatever
## the body is doing, so the box's vertical extent alone sets how high the gib rests
## (plans/rotating_gibs.md, finding 1). Putting the thin axis there is what makes a gib
## lying flat touch the floor: a glass shard 1.3 cm thick rests 0.7 cm up, where the old
## disc held it 14.9 cm off the ground. Which axis is thin varies by shape — most gib
## meshes are flat in Y already and get the identity, but cinder and ice chunks are tall
## in Y and would otherwise hover by half their length.
static func _flat_basis(size: Vector3) -> Basis:
	if size.x <= size.y and size.x <= size.z:
		return Basis(Vector3.BACK, PI * 0.5)   # x -> y
	if size.z <= size.y:
		return Basis(Vector3.RIGHT, -PI * 0.5)  # z -> y
	return Basis.IDENTITY


## Principal-axis inertia of the gib's box, so it tumbles like the shape it is.
static func _box_inertia(size: Vector3, mass: float) -> Vector3:
	var s := size.max(Vector3(0.02, 0.02, 0.02))
	return Vector3(
		mass * (s.y * s.y + s.z * s.z) / 12.0,
		mass * (s.x * s.x + s.z * s.z) / 12.0,
		mass * (s.x * s.x + s.y * s.y) / 12.0)


## A thrown stick turns end over end, so the spin axis leans across the bone, never
## along it. Mesh-local; the caller rotates it into the body's frame.
static func _tumble_axis(long_axis: Vector3) -> Vector3:
	var perp := Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5)
	perp -= long_axis * perp.dot(long_axis)
	if perp.length_squared() < 0.001:
		perp = long_axis.cross(Vector3.UP)
	return perp.normalized()


## Unit vector along the gib's longest extent, in mesh-local space.
static func _longest_axis(size: Vector3) -> Vector3:
	if size.x >= size.y and size.x >= size.z:
		return Vector3.RIGHT
	return Vector3.UP if size.y >= size.z else Vector3.BACK


static func _local_visual_aabb(node: Node3D) -> AABB:
	if node is MeshInstance3D:
		var mesh := (node as MeshInstance3D).mesh
		if mesh:
			return mesh.get_aabb()
	return AABB()
