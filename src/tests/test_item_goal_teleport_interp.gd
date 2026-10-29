extends "res://src/tests/test_base.gd"
## A goalitem's reliable GRAB/DROP/RETURN teleport has to beat the interp stream on the client:
## interp_entities stamps the buffered carried-position back over the teleport every frame, and
## once home the flag leaves the capturer's PVS so no fresh sample ever corrects it. Clearing
## the interp history on teleport is what makes it stick (ww_december: flag stuck on the altar).


func _spawn_item_as_client() -> ItemTFGoal:
	NetworkManager.test_authority = NetworkManager.TestAuthority.CLIENT
	NetworkManager.transport.relevance_events = true
	var item := ItemTFGoal.new()
	item.set_meta("entity", {"classname": "item_tfgoal", "goal_no": "1"})
	_root().add_child(item)
	await (Engine.get_main_loop() as SceneTree).process_frame
	return item


## Fill the buffer the way a carried flag does: samples at the capture spot, far from home.
func _seed_carried_samples(id: int) -> void:
	NetworkManager.push_mover_snapshot(id, 1000, Vector3(40, 0, 40), Vector3.ZERO, Vector3.ZERO)
	NetworkManager.push_mover_snapshot(id, 1033, Vector3(40, 0, 40), Vector3.ZERO, Vector3.ZERO)


func _buffer_has_data(id: int) -> bool:
	var buf: InterpolationBuffer = NetworkManager._entity_buffers.get(id)
	return buf != null and buf.has_data()


func _cleanup(item: Node) -> void:
	NetworkManager.test_authority = NetworkManager.TestAuthority.REAL
	NetworkManager.transport.relevance_events = false
	NetworkManager.reset_entities()
	item.queue_free()


func test_return_drops_stale_interp_history() -> void:
	var item: ItemTFGoal = await _spawn_item_as_client()
	var id: int = item._entity.entity_id
	_seed_carried_samples(id)
	assert_true(_buffer_has_data(id), "the carried flag has interp history to clobber with")
	item._local_sync(item._ACTION_RETURN, 0, Vector3.ZERO)
	assert_false(_buffer_has_data(id),
		"a capture return drops the history, so interp can't drag the flag back to the altar")
	_cleanup(item)


func test_drop_drops_stale_interp_history() -> void:
	# Same contract for the death-drop teleport, which lands the flag somewhere the stream
	# hasn't described either.
	var item: ItemTFGoal = await _spawn_item_as_client()
	var id: int = item._entity.entity_id
	_seed_carried_samples(id)
	item._local_sync(item._ACTION_DROP, 0, Vector3(5, 0, 5))
	assert_false(_buffer_has_data(id), "a drop teleport drops the history too")
	_cleanup(item)
