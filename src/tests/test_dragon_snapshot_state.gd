extends "res://src/tests/test_base.gd"
## The dragon's ridden state rides goldnet's snapshot as synchronizer properties, not
## a sync_entity_state RPC — so it can't arrive before the dragon it describes. The
## setters are the single apply point on both peers.

const DragonScript = preload("res://src/monsters/dragon.gd")


func test_declared_properties_resolve() -> void:
	var d: Dragon = DragonScript.new()
	var props := d.net_sync_properties()
	for p in props:
		var path := NodePath(p)
		if path.get_name_count() == 0:
			# ":name" — a property on the entity itself.
			assert_true(path.get_subname(0) in d, "declared property %s exists" % p)
		else:
			# "Node:name" — a shared carrier's slot, resolved against a child at runtime.
			assert_eq(path.get_name(0), "NetInterp", "shared slots live on the NetInterp bridge")
	assert_true(":is_ridden" in props, "ridden state is declared")
	assert_true("NetInterp:net_anim" in props, "animation rides the shared bridge slot")
	d.free()


func test_ridden_clears_collision_layer() -> void:
	var d: Dragon = DragonScript.new()
	d.collision_layer = GameConsts.MASK_ENTITY
	# What a client does on receiving the property: a ridden dragon must not be solid,
	# or the rider collides with their own mount.
	d.is_ridden = true
	assert_eq(d.collision_layer, 0, "ridden dragon is not solid")
	d.is_ridden = false
	assert_eq(d.collision_layer, GameConsts.MASK_ENTITY, "dismounted dragon is solid again")
	d.free()


func test_setters_ignore_unchanged_writes() -> void:
	# _physics_process writes is_ridden every tick as a catch-all, so re-writing the
	# same value must not re-apply (and must leave the delta with nothing to send).
	var d: Dragon = DragonScript.new()
	d.is_ridden = true
	d.collision_layer = 123  # pretend something else owns it
	d.is_ridden = true
	assert_eq(d.collision_layer, 123, "unchanged write is a no-op")
	d.free()


## Spy: GibEffect.spawn and the corpse spawner are both headless-guarded, so record the
## routing instead.
class SpyDragon:
	extends DragonScript
	var effects: Array[Vector3] = []
	var gibbed: Array[bool] = []
	var corpses: Array[Vector3] = []
	func _death_effect(pos: Vector3, was_gibbed: bool) -> void:
		effects.append(pos)
		gibbed.append(was_gibbed)
	func _spawn_corpse(origin: Vector3) -> bool:
		corpses.append(origin)
		return true


func test_death_reaches_a_client_replica() -> void:
	# The regression: the host's death visual is local, so a client that is never told only
	# sees the despawn — the dragon popped out instead of coming apart. death_pos is the telling.
	var d := SpyDragon.new()
	d.setup({"team_no": 0}, false)
	_keep(d)
	d._apply_sync_state({"death_pos": Vector3(1.0, 2.0, 3.0), "gibbed": true})
	assert_eq(d.effects.size(), 1, "client bursts where the host saw it die")
	assert_eq(d.effects[0], Vector3(1.0, 2.0, 3.0), "at the host's position, not the replica's")
	assert_true(d.gibbed[0], "...and it was told which of the two deaths it was")


func test_host_death_publishes_then_frees() -> void:
	var d := _dying_dragon(GameConsts.GIB_DAMAGE * 2.0)
	assert_eq(d.effects.size(), 1, "host bursts too")
	assert_eq(d.effects[0], Vector3(5.0, Dragon.GIB_CENTER_Y, 5.0), "burst is mid-body")
	assert_true(d.gibbed[0], "a blow that size takes it apart")
	assert_true(d.corpses.is_empty(), "nothing is left to leave a body")
	assert_true(d.is_queued_for_deletion(), "nothing survives the death frame")


## The new half: whittled down rather than blown apart, a dragon leaves its body behind.
func test_a_small_last_blow_leaves_a_body() -> void:
	var d := _dying_dragon(GameConsts.GIB_DAMAGE)
	assert_eq(d.corpses.size(), 1, "it falls where it died")
	# Not the mid-body point the burst uses: a corpse draws its model from the origin it is
	# handed, so anything but the dragon's own would move the body in the frame it dies.
	assert_eq(d.corpses[0], Vector3(5.0, 0.0, 5.0), "the corpse is left where the model was drawn")
	assert_false(d.gibbed[0], "and it is not torn apart")
	assert_true(d.is_queued_for_deletion(), "the dragon itself is still gone")


## A dragon killed at (5, 0, 5) by a single blow of `last_blow`. Two hits, because the first
## has to leave it alive for the second to be the one that counts.
func _dying_dragon(last_blow: float) -> SpyDragon:
	var d := SpyDragon.new()
	d.setup({"team_no": 0}, true)
	_root().add_child(d)  # global_position is inert outside the tree
	_keep(d)
	d.global_position = Vector3(5.0, 0.0, 5.0)
	d.take_damage(Dragon.MAX_HEALTH - last_blow)
	d.take_damage(last_blow)
	return d


func test_death_is_a_one_shot_not_converging_state() -> void:
	# Why the dragon doesn't carry a dying flag on the snapshot: the gibs are their own scene
	# nodes, so no state has to persist on the entity past the frame it died in.
	var d: Dragon = DragonScript.new()
	assert_false("is_dying" in d, "no dying state to replicate")
	for p in d.net_sync_properties():
		assert_false("dying" in p, "death isn't snapshot state: %s" % p)
	d.free()
