extends "res://src/tests/test_base.gd"
## Entity PVS-AABB tracking (VisibilitySystem). Many entities register for PVS during _ready
## BEFORE their visual child is added, so the AABB computed at register time was empty and got
## cached permanently — an empty AABB culls by a single origin point, which can land in a solid/
## occluded leaf and make an in-view entity vanish. Fix: don't cache an empty AABB, and pad any
## still-empty AABB into a small box.
##
## References VisibilitySystem (autoload) → run via the scene runner, not `-s`.

func test_world_aabb_pads_degenerate() -> void:
	# A visual-less entity (empty local AABB) must get a box footprint around its origin, not a point.
	var n := Node3D.new()
	_root().add_child(n)
	n.global_position = Vector3(10, 5, -3)
	var world := VisibilitySystem._world_aabb(n, AABB())
	assert_ne(world.size, Vector3.ZERO, "degenerate AABB is padded to a box, not a zero point")
	assert_true(world.has_point(n.global_position), "padded box contains the entity origin")
	# Box is centred on the origin with the configured half-extent.
	assert_vec3_almost_eq(world.get_center(), n.global_position, 0.001, "padded box centred on origin")
	n.queue_free()


func test_world_aabb_uses_real_bounds_when_present() -> void:
	# A non-empty local AABB is transformed by the node's world transform (unchanged behaviour).
	var n := Node3D.new()
	_root().add_child(n)
	n.global_position = Vector3(4, 0, 0)
	var local := AABB(Vector3(-1, -1, -1), Vector3(2, 2, 2))
	var world := VisibilitySystem._world_aabb(n, local)
	assert_vec3_almost_eq(world.get_center(), Vector3(4, 0, 0), 0.001, "real bounds follow the node")
	assert_vec3_almost_eq(world.size, Vector3(2, 2, 2), 0.001, "real bounds preserved")
	n.queue_free()


func test_compute_aabb_empty_without_visual() -> void:
	var n := Node3D.new()
	_root().add_child(n)
	var aabb := VisibilitySystem._compute_local_aabb(n)
	assert_eq(aabb.size, Vector3.ZERO, "no VisualInstance3D in subtree → empty AABB")
	n.queue_free()


func test_compute_aabb_picks_up_late_visual() -> void:
	# The core of the fix: a visual added AFTER tracking is still discovered on recompute.
	var n := Node3D.new()
	_root().add_child(n)
	assert_eq(VisibilitySystem._compute_local_aabb(n).size, Vector3.ZERO, "empty before visual")
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(2, 3, 4)
	mi.mesh = box
	n.add_child(mi)
	var aabb := VisibilitySystem._compute_local_aabb(n)
	assert_ne(aabb.size, Vector3.ZERO, "visual added after tracking is discovered on recompute")
	assert_vec3_almost_eq(aabb.size, Vector3(2, 3, 4), 0.01, "recomputed bounds match the mesh")
	n.queue_free()


func test_track_defers_lock_until_visual_exists() -> void:
	# Tracking before the visual exists must NOT permanently cache the empty AABB.
	var n := Node3D.new()
	_root().add_child(n)
	var id := 999001
	VisibilitySystem.track_node(id, n)
	var entry = VisibilitySystem._entities.get(id)
	assert_true(entry != null, "entity tracked")
	assert_false(entry.local_aabb_computed, "empty AABB is NOT locked in — will keep retrying")
	VisibilitySystem.untrack_node(id)
	n.queue_free()


func test_track_captures_real_bounds() -> void:
	# Tracking an entity that already has a visual captures its REAL bounds (the sprite/mesh size),
	# not a padded guess. Locking is deferred to the settle pass (so post-_ready size tweaks land).
	var n := Node3D.new()
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(3, 5, 7)
	mi.mesh = box
	n.add_child(mi)
	_root().add_child(n)
	var id := 999002
	VisibilitySystem.track_node(id, n)
	var entry = VisibilitySystem._entities.get(id)
	assert_true(entry != null, "entity tracked")
	assert_vec3_almost_eq(entry.local_aabb.size, Vector3(3, 5, 7), 0.01, "tracked with the real visual bounds, not a pad")
	assert_false(entry.local_aabb_computed, "lock is deferred to the settle pass, not grabbed at track time")
	VisibilitySystem.untrack_node(id)
	n.queue_free()


func test_beam_footprint_spans_its_endpoints() -> void:
	# env_beam draws in a top_level holder at the world origin, and a dedicated server never builds
	# the strip, so the visual subtree put every ww_monoliths cap beam at (0,0,0). It links its
	# start-end box instead, as GoldSrc's CBeam::RelinkBeam does.
	var s := Node3D.new()
	var e := Node3D.new()
	_root().add_child(s)
	_root().add_child(e)
	_spawned.append(s)
	_spawned.append(e)
	s.global_position = Vector3(30, 20, 45)
	e.global_position = Vector3(30, 7, 45)
	TriggerSystem.register("pvs_beam_s", s)
	TriggerSystem.register("pvs_beam_e", e)
	var b: EnvBeam = load("res://src/entities/env_beam.gd").new()
	b.set_meta("entity", {
		"classname": "env_beam", "LightningStart": "pvs_beam_s", "LightningEnd": "pvs_beam_e",
		"origin": "0 0 0",
	})
	_root().add_child(b)
	_spawned.append(b)
	b.global_position = Vector3(30, 11, 45)
	b._process(0.0)
	var entry = VisibilitySystem._entities.get(b._entity.entity_id)
	assert_true(entry != null, "beam tracked")
	assert_true(entry.local_aabb_computed, "footprint is pinned, not left to the visual subtree")
	var world := VisibilitySystem._world_aabb(b, entry.local_aabb)
	assert_true(world.grow(0.001).has_point(s.global_position), "footprint reaches the start")
	assert_true(world.grow(0.001).has_point(e.global_position), "footprint reaches the end")
	assert_false(world.grow(0.001).has_point(Vector3.ZERO), "and is nowhere near the world origin")
	TriggerSystem.unregister("pvs_beam_s", s)
	TriggerSystem.unregister("pvs_beam_e", e)
