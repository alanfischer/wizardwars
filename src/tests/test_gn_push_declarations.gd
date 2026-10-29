extends "res://src/tests/test_base.gd"
## goldnet reads a slot every tick UNLESS the sync declared push for it, which is the game
## promising to call NetworkManager.mark_entity_dirty on every write to it. Declaring a slot
## nothing marks is the one way to bring back silent staleness, so these pin each declaration to
## the publish funnel that backs it. The rest is what a SyncSpec table can still get wrong on its
## own, plus the player puppet's drift from the config baked into remote_player.tscn.

const MoverNetScript = preload("res://src/behaviors/mover_net_publisher.gd")
const MainScript = preload("res://src/main.gd")
const RemotePlayerScript = preload("res://src/remote_player.gd")
const DragonScript = preload("res://src/monsters/dragon.gd")
const SyncSpecScript = preload("res://addons/goldnet/sync_spec.gd")


func _pushed(spec: Dictionary) -> Array:
	return SyncSpecScript.pushed(spec)


func test_mover_push_matches_publish_funnel() -> void:
	# MoverNetPublisher.publish() writes exactly these five and marks on the way out, so all five are
	# declared. A sixth slot added to the table later must NOT declare push without a mark.
	var declared := ["mover_net_pos", "mover_net_rot", "mover_net_vel", "mover_net_angvel",
			"mover_net_stamp"]
	var spec: Dictionary = MoverNetScript.MOVER_SPEC
	var push := _pushed(spec)
	assert_eq(push.size(), declared.size(), "every mover slot is push-declared")
	for name in declared:
		assert_true(name in push, "%s is declared push (publish funnel marks it)" % name)
	assert_eq(spec.size(), declared.size(), "and the table replicates nothing else")
	# The paths are written against the publisher's node name by hand (a const can't interpolate
	# it). A rename that misses them replicates nothing and says nothing.
	for key in spec:
		var path := NodePath(key)
		assert_eq(String(path.get_name(0)), MoverNetScript.NODE_NAME,
				"%s is rooted at the publisher's node name" % key)


func test_player_push_matches_set_net_state() -> void:
	# set_net_state is the one writer that marks the puppet dirty; the spawn props it doesn't
	# write (peer_id/element/team) must stay polled.
	var push := _pushed(RemotePlayerScript.PLAYER_SPEC)
	for name in ["net_seq", "net_pos", "net_yaw", "net_pitch", "net_vel", "net_flags",
			"net_weapon_idx", "net_stamp_ms"]:
		assert_true(name in push, "%s is declared push (set_net_state marks it)" % name)
	for name in ["peer_id", "element", "team"]:
		assert_false(name in push, "%s is a spawn prop, polled — nothing marks it" % name)


func test_player_spec_matches_the_baked_config() -> void:
	# The one place left where the config and the hints are two objects. Read off the PackedScene
	# (no instantiation, so this needs no player rig) and compare.
	var cfg := _baked_net_config()
	assert_true(cfg != null, "remote_player.tscn's NetSync has a replication config")
	if cfg == null:
		return
	var problems: PackedStringArray = SyncSpecScript.validate(RemotePlayerScript.PLAYER_SPEC, cfg)
	assert_eq(problems.size(), 0, "PLAYER_SPEC agrees with the baked config: %s" % problems)


func test_hand_added_entity_props_are_not_push_declared() -> void:
	# net_sync_properties() bolts a property onto the shared dyn-entity sync with no publish funnel
	# behind it — the dragon's :is_ridden is a plain setter that never marks. Fine because
	# _spawn_dyn_entity adds it as {} and leaves it polled; declaring push without a mark is the bug.
	var bridge_push := _pushed(MainScript.DYN_ENTITY_SPEC)
	var d: Dragon = DragonScript.new()
	for p in d.net_sync_properties():
		var path := NodePath(p)
		var leaf := String(path.get_subname(path.get_subname_count() - 1))
		assert_false(leaf in bridge_push,
				"%s is polled, not push-declared (nothing marks it)" % leaf)
	d.free()


func test_every_spec_is_sound() -> void:
	# An unrecognised quant hint (goldnet falls back to full precision and says nothing), a
	# malformed path, or two slots sharing a leaf name so one hint silently covers both.
	for named in [["MOVER_SPEC", MoverNetScript.MOVER_SPEC],
			["DYN_ENTITY_SPEC", MainScript.DYN_ENTITY_SPEC],
			["PLAYER_SPEC", RemotePlayerScript.PLAYER_SPEC]]:
		var problems: PackedStringArray = SyncSpecScript.validate(named[1])
		assert_eq(problems.size(), 0, "%s is sound: %s" % [named[0], problems])


## remote_player.tscn's NetSync config, straight off the PackedScene.
func _baked_net_config() -> SceneReplicationConfig:
	var ps: PackedScene = load("res://src/remote_player.tscn")
	var st := ps.get_state()
	for i in st.get_node_count():
		if st.get_node_name(i) != "NetSync":
			continue
		for j in st.get_node_property_count(i):
			if String(st.get_node_property_name(i, j)) == "replication_config":
				return st.get_node_property_value(i, j) as SceneReplicationConfig
	return null
