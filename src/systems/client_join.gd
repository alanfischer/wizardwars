extends Node
## Picking a team and a class, and making sure the pick actually took.
##
## One screen's worth of UI drives a sequence that spans the network: the menu's selection becomes
## a request_join_team, the server answers with assign_spawn or reject_team_join, and nothing on
## screen says which until it arrives. Three things have to hold through that gap — a live player
## can't dodge death by switching class, a re-pick of the same role is a no-op, and a request that
## never lands has to re-ask rather than leave a spectator staring at an empty map. Those are the
## three mechanisms in this file: the respawn-timer handoff, the is_actual_change gate, and the
## watchdog.
##
## Offline is the same sequence with the round-trip removed: no server to ask, so the death,
## cleanup and respawn all apply locally.
##
## Parented to main.gd as "ClientJoin". The RPC answers still arrive on main (_dispatch_to_scene
## reaches the scene by name) and come back here through clear_watchdog() and abandon().

## Outstanding request_join_team, so a lost one doesn't strand us (see _join_watchdog).
const JOIN_WATCHDOG_DELAY := 4.0
const JOIN_MAX_RETRIES := 3

var _local_class_change_pending_team := -1
var _local_class_change_pending_element := -1
var _local_class_change_waiting := false
var _pending_join_seq := 0
var _pending_join_tries := 0

## The class menu, rebuilt by main on every map load — hence the reconnect here and the
## is_instance_valid() guard: a refused join has to put back a menu that may already be freed.
var _team_select_ui: CanvasLayer


func bind_menu(ui: CanvasLayer) -> void:
	_team_select_ui = ui
	ui.selection_made.connect(select_team_class)


func select_team_class(team: int, element: int) -> void:
	var lp := Game.local_player
	if not lp:
		return
	var is_actual_change : bool = lp.team != team or lp.element != element
	# Re-confirming the same class is a no-op (matches TFC): otherwise an alive player would
	# die()+instantly respawn (free heal + teleport to base) and a dead one would skip the respawn
	# delay. Spectators and first-join always differ (team NONE), so this only short-circuits a
	# true reselect.
	if not is_actual_change and not lp.spectating:
		return
	if NetworkManager.is_online():
		# Don't optimistically die()/cleanup here — the server drives the whole sequence. An
		# optimistic local death would strand us in the spectator cam if the server REJECTS the
		# join (team full / invalid class), since no assign_spawn arrives to un-spectate.
		NetworkManager.send_request_join_team(team, element)
		# The menu is already hidden by the time we get here, so a request that never lands
		# leaves a spectator with nothing on screen and nothing to re-drive the join. Only the
		# never-spawned case: once dead, the server answers through the respawn timer (a
		# same-role re-pick deliberately answers nothing at all), and _respawn_watchdog owns it.
		if lp.spectating and not lp.is_dead:
			clear_watchdog()  # a fresh pick starts its retry budget over
			_arm_join_watchdog(team, element)
		return
	# Offline: no server round-trip, so apply death/cleanup and respawn locally. Re-confirming the
	# same role keeps owned plants, matching TFC class-menu behavior.
	if is_actual_change:
		lp.cleanup_for_class_change()
	var was_alive : bool = not lp.is_dead and not lp.spectating
	if was_alive:
		lp.die()
	# Redirect the respawn timer to apply the class change after the delay, so a live player can't
	# dodge death by switching class mid-combat.
	if lp._respawn_timer and lp._respawn_timer.time_left > 0:
		# A re-confirm with nothing already queued rides the timer out as it is.
		if _local_class_change_waiting or is_actual_change:
			_queue_local_class_change(lp, team, element)
		return
	_finish_class_change(lp, team, element)


func _queue_local_class_change(lp: LocalPlayer, team: int, element: int) -> void:
	_local_class_change_pending_team = team
	_local_class_change_pending_element = element
	var timer = lp._respawn_timer
	if not timer or timer.time_left <= 0.0:
		_on_local_class_change_timeout()
		return
	var default_respawn := Callable(lp, "_respawn")
	if timer.timeout.is_connected(default_respawn):
		timer.timeout.disconnect(default_respawn)
	var class_change_timeout := Callable(self, "_on_local_class_change_timeout")
	if not _local_class_change_waiting and not timer.timeout.is_connected(class_change_timeout):
		_local_class_change_waiting = true
		timer.timeout.connect(class_change_timeout)


func _on_local_class_change_timeout() -> void:
	_local_class_change_waiting = false
	var lp := Game.local_player
	if lp:
		lp._respawn_timer = null
	var team := _local_class_change_pending_team
	var element := _local_class_change_pending_element
	_local_class_change_pending_team = -1
	_local_class_change_pending_element = -1
	if not lp or team < 0 or element < 0:
		return
	if not lp.is_dead and not lp.spectating:
		return
	_finish_class_change(lp, team, element)


func _finish_class_change(lp: LocalPlayer, team: int, element: int) -> void:
	_local_class_change_pending_team = -1
	_local_class_change_pending_element = -1
	_local_class_change_waiting = false
	lp.is_dead = false
	lp._stop_all_attacks()
	lp.apply_local_spawn_state(element, true, true)
	Log.info("[team_class_selected] element=%d wizard_speed=%.3f" % [element, lp.speed_multiplier])
	_join_team(lp, team)


func _join_team(lp: LocalPlayer, team: int) -> void:
	lp.team = team
	if NetworkManager.is_online() and not NetworkManager.is_host():
		# Client: ask host to pick a spawn and send us coordinates
		NetworkManager.send_request_join_team(team, lp.element)
		return
	# Host or offline: pick spawn locally
	var sp := SpawnSystem.get_spawn_for_team(team)
	if sp:
		lp.spawn_at(sp, lp.element, true)
		if NetworkManager.is_online():
			NetworkManager.set_player_team(multiplayer.get_unique_id(), team)  # host copy of the PVS-independent roster
			NetworkManager.sync_team_for_peer.rpc(multiplayer.get_unique_id(), team, lp.element, lp.position, lp.rotation.y)
		Log.info("Joined team %d (element=%d), spawned at %s, yaw=%.1f°" % [
			team, lp.element, sp.position, rad_to_deg(sp.rotation.y)])
	else:
		push_warning("No active spawn point found for team %d" % team)


## The join didn't take — the server refused it, or never answered (_join_watchdog). Either way
## whoever asked is a spectator with the menu already dismissed and nothing on screen, so say why
## and put the menu back up behind the message.
func abandon(message: String) -> void:
	clear_watchdog()  # answered, or given up on; resending would only repeat it
	if Game.hud:
		Game.hud.show_center_message(message, Color(1.0, 0.3, 0.3), 3.0)
	var lp := Game.local_player
	if is_instance_valid(_team_select_ui) and not _team_select_ui.visible and lp and lp.spectating:
		_team_select_ui.show_ui()


## Track an outstanding join so a dropped request_join_team can't strand us as a spectator with
## the class menu already dismissed. The server answers every join — assign_spawn on success,
## reject_team_join on refusal — so silence past the deadline means the request or its answer was
## lost, and the only recovery is to ask again. The pick itself rides on the timer's own callable,
## so `seq` is the only thing a resolved or superseded join has to invalidate.
func _arm_join_watchdog(team: int, element: int) -> void:
	_pending_join_seq += 1
	get_tree().create_timer(JOIN_WATCHDOG_DELAY).timeout.connect(
			_join_watchdog.bind(_pending_join_seq, team, element))


func clear_watchdog() -> void:
	_pending_join_tries = 0
	_pending_join_seq += 1  # invalidates any timer still in flight


func _join_watchdog(seq: int, team: int, element: int) -> void:
	if seq != _pending_join_seq:
		return  # answered, superseded, or cleared by a map change
	var lp := Game.local_player
	if not lp or not lp.spectating or not NetworkManager.is_online():
		clear_watchdog()
		return
	if _pending_join_tries >= JOIN_MAX_RETRIES:
		Log.warn("[Join] no answer for team %d (element=%d) after %d tries — reopening the menu (%s)"
			% [team, element, _pending_join_tries, _link_report()])
		abandon("Join failed — pick again")
		return
	_pending_join_tries += 1
	Log.warn("[Join] no answer for team %d (element=%d) after %.0fs — resending (try %d/%d) (%s)"
		% [team, element, JOIN_WATCHDOG_DELAY, _pending_join_tries, JOIN_MAX_RETRIES, _link_report()])
	NetworkManager.send_request_join_team(team, element)
	_arm_join_watchdog(team, element)


## The uplink's reliable channel as goldnet sees it: queued but never delivered means our requests
## are stuck behind something, rather than lost with the answer.
func _link_report() -> String:
	var s := NetworkManager.transport.link_stats()
	if s.is_empty():
		return "no link stats"
	return "reliable queued=%d delivered=%d, silent %dms, commands pending=%d dropped=%d, uplink %d pps" % [
		s.get("messages_queued", 0), s.get("messages_delivered", 0), s.get("silent_ms", 0),
		s.get("commands_pending", 0), s.get("commands_dropped", 0), s.get("uplink_pps", 0)]
