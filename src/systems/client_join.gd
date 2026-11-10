extends Node
## Picking a team and a class, and making sure the pick actually took.
##
## One screen's worth of UI drives a sequence that spans the network: the menu's selection becomes
## a request_join_team, the server answers with assign_spawn or reject_team_join, and nothing on
## screen says which until it arrives. Three things have to hold through that gap — a live player
## can't dodge death by switching class, a re-pick of the same role is a no-op, and a request that
## never lands has to re-ask rather than leave a spectator staring at an empty map. Those are the
## three mechanisms in this file: the role queued for the respawn (die_for_class_change), the
## is_actual_change gate, and the watchdog.
##
## Offline is the same sequence with the round-trip removed: no server to ask, so the death,
## cleanup and respawn all apply locally.
##
## Parented to main.gd as "ClientJoin" and registered as a sync handler, so reject_team_join lands
## here. assign_spawn still arrives on main, which owns the spawn, and comes back through
## clear_watchdog().

## Outstanding request_join_team, so a lost one doesn't strand us (see _join_watchdog).
const JOIN_WATCHDOG_DELAY := 4.0
const JOIN_MAX_RETRIES := 3

var _pending_join_seq := 0
var _pending_join_tries := 0

## The role a scripted launch (--team/--class) comes back on every map, menu skipped. 0 = none.
var _auto_team := 0
var _auto_class := 0

## The class menu, built on every map load and freed on unload.
var _menu: TeamSelectUI


func set_auto_team(team: int) -> void:
	_auto_team = team


func set_auto_class(element: int) -> void:
	_auto_class = element


## A new map's class menu, for the caller to parent (main, or the VR lobby panel).
func build_menu() -> TeamSelectUI:
	teardown_menu()
	_menu = TeamSelectUI.new()
	_menu.name = "TeamSelectUI"
	_menu.selection_made.connect(select_team_class)
	return _menu


func teardown_menu() -> void:
	if _menu:
		_menu.queue_free()
		_menu = null


## The game went live: come back on the scripted role, else put the menu up for a spectator.
## Deferred — on a listen host the map change registers the host puppet after this call, and the
## join request needs that puppet. True when the menu went up.
func start_game() -> bool:
	var lp := Game.local_player
	if _auto_team > 0 and lp and lp.spectating:
		select_team_class.call_deferred(_auto_team,
				_auto_class if _auto_class > 0 else GameConsts.Element.FIRE)
		return false
	if _menu and lp and lp.spectating:
		_menu.show_ui()
		return true
	return false


func open_team_menu() -> bool:
	if not _menu:
		return false
	_menu.show_ui()
	return true


## Only once there is a team to pick a class on.
func open_class_menu() -> bool:
	var lp := Game.local_player
	if not _menu or not lp or lp.team == GameConsts.Team.NONE:
		return false
	_menu.show_class_only(lp.team)
	return true


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
	if lp.spectating and not lp.is_dead:
		_spawn_offline(lp, team, element)
		return
	# The respawn timer applies the pick, so a live player can't dodge death by switching class
	# mid-combat. A same-role pick while dead re-queues the current role over any earlier pick.
	lp.die_for_class_change(team, element)


## A never-spawned spectator has no death to serve.
func _spawn_offline(lp: LocalPlayer, team: int, element: int) -> void:
	var sp := SpawnSystem.get_spawn_for_team(team)
	if sp == null:
		_abandon("%s has no spawn point" % GoalSystem.get_team_name(team))
		return
	lp.team = team
	lp.spawn_at(sp, element, true)
	Log.info("Joined team %d (element=%d), spawned at %s, yaw=%.1f°" % [
		team, element, sp.position, rad_to_deg(sp.rotation.y)])


## The server refused a team (full, no active spawn, class restricted).
func _on_reject_team_join(team: int, reason: String) -> void:
	_abandon("%s %s" % [GoalSystem.get_team_name(team), reason])


## The join didn't take — the server refused it, or never answered (_join_watchdog). Either way
## whoever asked is a spectator with the menu already dismissed and nothing on screen, so say why
## and put the menu back up behind the message.
func _abandon(message: String) -> void:
	clear_watchdog()  # answered, or given up on; resending would only repeat it
	if Game.hud:
		Game.hud.show_center_message(message, Color(1.0, 0.3, 0.3), 3.0)
	var lp := Game.local_player
	if _menu and not _menu.visible and lp and lp.spectating:
		_menu.show_ui()


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
		_abandon("Join failed — pick again")
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
