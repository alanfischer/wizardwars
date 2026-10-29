extends RefCounted

## Server-side rules for the gameplay requests clients send. NetworkManager owns the wire — the
## @rpc stubs and the send_request_* wrappers — and this owns what the server DOES when one
## arrives: team/class validation, chat routing, and the rules a shot has to pass (mana, can_fire).
##
## Every entry point runs on the authority only, with the sender already resolved to a peer id, so
## nothing here reads multiplayer.get_remote_sender_id() — the listen host reaches the same rules
## for its own input by calling these directly, which is why the gate and the rule can't stay fused.
## Stateless by design, hence static: the authority's state lives on the players and on
## NetworkManager's roster, never here.

# --- +use ---

static func use(sender_id: int, target_path: NodePath) -> void:
	var target := NetworkManager.get_node_or_null(target_path)
	# has_method("trigger") isn't the real gate: GoldSrcEntity.is_player_usable checks FCAP_IMPULSE_USE.
	if target and target.has_method("trigger") and GoldSrcEntity.is_player_usable(target):
		var activator := NetworkManager.get_player(sender_id)
		if not activator:
			return
		target.trigger(activator, TriggerSystem.Type.TOGGLE)


# --- Attack ---
# Not requests: the server's FireControl calls these as it plays the player's input commands, so the
# trigger's timing is the commands' own (see RemotePlayer.fire_frame).

## shot_time_ms is the shooter's render time in the server clock domain; LagCompensation clamps it
## and rewinds targets to it. Returns a FireControl.Shot.
static func attack(remote: RemotePlayer, aim_from: Vector3, aim_dir: Vector3, charge_percent: float,
		secondary: bool, shot_time_ms: int) -> int:
	var weapon: Weapon = remote.weapon_at(remote.current_weapon_idx)
	if remote.is_dead or weapon == null:
		return FireControl.Shot.REFUSED
	var already_draining := remote.mana_drain_active  # sustained weapons already draining skip the initial cost
	var fire_aim_dir := aim_dir.normalized() if aim_dir.length_squared() > 0.001 else Vector3.ZERO
	if weapon.mana_cost > 0.0 and not (weapon.mana_drain > 0.0 and already_draining) \
			and remote.mana < weapon.min_mana_to_fire(remote, fire_aim_dir):
		return FireControl.Shot.DENIED
	if not weapon.can_fire(remote, fire_aim_dir):
		NetworkManager.send_to_owner(remote.peer_id, &"sync_fire_warning")
		return FireControl.Shot.WARNED
	# Tag the remote player with the shot timestamp so hitscan can rewind targets.
	remote.lag_comp_shot_time_ms = shot_time_ms
	var did_fire := weapon.fire(remote, aim_from, fire_aim_dir, charge_percent, secondary)
	remote.lag_comp_shot_time_ms = 0
	if not did_fire:
		return FireControl.Shot.REFUSED
	var weapon_idx: int = remote.current_weapon_idx
	remote.last_fired_weapon_idx = weapon_idx
	# Sustained weapons ride PLAYER_FLAG_FIRING in the snapshot so observers self-heal a dropped
	# start/stop. Only primary fire holds a beam; secondary stays a discrete sync_attack event.
	if weapon.sustained and not secondary:
		remote.sync_firing = true
	NetworkManager.broadcast_attack(remote.peer_id, weapon_idx, fire_aim_dir, secondary)
	if weapon.mana_cost > 0.0 and not (weapon.mana_drain > 0.0 and already_draining):
		remote.mana = maxf(remote.mana - weapon.actual_mana_cost(remote), 0.0)
		NetworkManager.sync_mana_to_owner(remote)
	if weapon.mana_drain > 0.0:
		remote.mana_drain_active = true
	return FireControl.Shot.FIRED


static func stop_attack(remote: RemotePlayer) -> void:
	if remote.mana_drain_active:
		remote.mana_drain_active = false
		NetworkManager.sync_mana_to_owner(remote)
	var stopped := remote.last_fired_weapon()
	remote.end_sustained_fire(stopped)
	NetworkManager.broadcast_stop_attack(remote.peer_id, stopped)


## A command's weaponselect.
static func switch_weapon(remote: RemotePlayer, idx: int) -> void:
	if idx < 0 or idx >= remote.weapons.size():
		return
	var old_weapon: Weapon = remote.weapon_at(remote.current_weapon_idx)
	if old_weapon:
		remote.end_sustained_fire(old_weapon)
		# A beam's observers clear via the firing bit and don't need this; a discrete holder like
		# levitate does.
		NetworkManager.broadcast_stop_attack(remote.peer_id, old_weapon)
	remote.current_weapon_idx = idx
	remote.fire.reset()


# --- Satchels ---

static func prime_satchel(sender_id: int) -> void:
	var remote := NetworkManager.get_player(sender_id)
	if remote and remote.satchel_pack.prime():
		NetworkManager.sync_mana_to_owner(remote)


static func throw_satchel(sender_id: int, aim_dir: Vector3) -> void:
	var remote := NetworkManager.get_player(sender_id)
	if remote:
		remote.satchel_pack.throw(aim_dir)


# --- Help call ---

## The server owns the cooldown and picks the voice line, so every peer draws the same sprite and
## hears the same shout. Sent to the caller's PVS, as the original's TE_PLAYERATTACHMENT was.
static func help_call(sender_id: int) -> void:
	var remote := NetworkManager.get_player(sender_id)
	if not remote:
		return
	var call_fx := remote.call_for_help()
	if call_fx.is_empty():
		return
	NetworkManager.send_to_pvs_and_dispatch(AABB(remote.global_position + GameConsts.PLAYER_CENTER, Vector3.ZERO),
		&"sync_player_help_call", [sender_id, call_fx[0], call_fx[1]])


# --- Team / class ---

static func join_team(peer_id: int, team: int, element: int) -> void:
	Log.info("[Join] request from peer %d: team=%d element=%d" % [peer_id, team, element])
	if not GoalSystem.is_valid_class(team, element):
		# Refuse out loud. A bare return left the asker a spectator with the class menu already
		# dismissed and no message, because every other refusal below answers and this one didn't.
		Log.info("Peer %d rejected from team %d (class %d not allowed)" % [peer_id, team, element])
		NetworkManager.send_join_rejected_to(peer_id, team, "doesn't allow that class")
		return
	var remote := NetworkManager.get_player(peer_id)
	if remote == null:
		# No puppet for this peer (it connected while the map was swapping and _spawn_missed_players
		# never caught it). Every send below goes through `remote`, so committing the team here
		# recorded and broadcast a join whose assign_spawn never went out — a permanent spectator
		# the log called "Assigned". Refuse instead, so the retry can find the puppet.
		Log.warn("Peer %d has no puppet — refusing team %d so the join can be retried" % [peer_id, team])
		NetworkManager.send_join_rejected_to(peer_id, team, "isn't ready for you yet")
		return
	if remote.team != team and GoalSystem.is_team_full(team):
		Log.info("Peer %d rejected from team %d (full)" % [peer_id, team])
		NetworkManager.send_join_rejected_to(peer_id, team, "is full")
		return
	# Only tear down owned entities on an actual class/team change — re-confirming the same role
	# keeps the sentry/plant, matching TFC class-menu behavior.
	if remote.team != team or remote.element != element:
		remote.cleanup_for_class_change()
		# Serves the respawn delay before the change takes effect (die_for_class_change), so
		# players can't dodge it by opening the class menu while combat-dead. team 0 spawns immediately.
		if remote.team != 0:
			remote.die_for_class_change(team, element)
			return
	elif remote.is_dead:
		return  # same-role request while dead: the existing respawn timer owns the countdown
	# Resolve the spawn BEFORE committing the team. Spawns toggle off on control maps, and
	# recording a team we then fail to spawn strands the client: no assign_spawn arrives, so the
	# view sits in the spectator cam with nothing to re-drive the join, while the host starts
	# streaming and rendering their never-spawned placeholder body as a statue at its parked
	# position. Refuse instead — the player keeps the class menu and can retry.
	# The class-change path above has already returned; _host_respawn owns its spawn (and retries).
	var sp := SpawnSystem.get_spawn_for_team(team)
	if sp == null:
		Log.info("Peer %d rejected from team %d (no active spawn)" % [peer_id, team])
		NetworkManager.send_join_rejected_to(peer_id, team, "has no spawn point")
		return
	remote.team = team
	var pos : Vector3 = sp.get_spawn_position()
	var yaw := sp.rotation.y
	# apply_effects=false: defers _apply_spawn_point_effects (dragon mount) until after
	# assign_spawn is sent, or sync_dragon_mount arrives first and gets wiped by spawn_at_transform.
	remote.spawn_at(sp, element, true, false)
	NetworkManager.set_player_team(peer_id, team)  # host copy of the PVS-independent roster
	NetworkManager.sync_team_for_peer.rpc(peer_id, team, element, pos, yaw)
	remote.sync_spawn_to_network(sp, true, true, false)
	remote._apply_spawn_point_effects(sp)
	Log.info("Assigned peer %d to team %d (element=%d) spawn at %s" % [peer_id, team, element, pos])


# --- Identity ---

## The 24-char clamp is the rule; the peer record and the broadcast are NetworkManager's.
static func set_player_name(sender_id: int, player_name: String) -> void:
	var clamped := player_name.substr(0, 24)
	NetworkManager.set_player_name(sender_id, clamped)
	NetworkManager.sync_player_name.rpc(sender_id, clamped)
	Log.info("Player name for peer %d: %s" % [sender_id, clamped])


# --- Chat ---

static func chat(sender_id: int, message: String, team_only: bool) -> void:
	message = message.strip_edges().left(128)
	if message.is_empty():
		return
	if team_only:
		var sender_player := NetworkManager.get_player(sender_id)
		var sender_team: int = sender_player.team if sender_player else GameConsts.Team.NONE
		if sender_team == GameConsts.Team.NONE:
			return
		if sender_player.get_tree().has_group(InfoAreaMarker.GROUP):
			var area := InfoAreaMarker.nearest_name(sender_player.get_tree(),
				sender_player.global_position + GameConsts.PLAYER_CENTER)
			message = "(%s): %s" % [area, message]
		var roster := NetworkManager.player_roster()
		for pid in roster:
			var p: Player = roster[pid]
			if Teams.teams_friendly(sender_team, p.team):
				NetworkManager.sync_chat.rpc_id(pid, sender_id, message, true)
	else:
		NetworkManager.sync_chat.rpc(sender_id, message, false)


# --- Voice ---

## One voice packet goes to one channel's listeners. The server never decodes voice — it decides
## who hears it, on the same team test chat uses, and relays the bytes untouched.
##
## Both channels walk the roster rather than broadcasting, because every recipient needs
## filtering: the sender must not hear themselves, and bots have no ears. A listen host is a
## listener like any other and takes its copy as a direct call, which keeps the fan-out clear of
## what an rpc_id to your own peer does or does not do (test_chat_echo.gd is where chat had to
## answer that). The roster is also what keeps a dedicated server out of its own fan-out — peer 1
## there never registers a player.
const VOICE_MAX_PACKET := 1024

static func voice(sender_id: int, kind: int, packet: PackedByteArray, team_only: bool) -> void:
	# A voice frame at the configured bitrate is tens of bytes and a stream marker is a short
	# JSON line, so anything near the cap is already not voice.
	if packet.is_empty() or packet.size() > VOICE_MAX_PACKET:
		return
	if not VoiceChat.budget_allows(sender_id, packet.size()):
		return
	var host_id := NetworkManager.multiplayer.get_unique_id()
	for pid in voice_listeners(sender_id, team_only):
		if pid == host_id:
			VoiceChat.receive(sender_id, kind, packet)
		else:
			NetworkManager.sync_voice.rpc_id(pid, sender_id, kind, packet)


## Who hears `sender_id` on this channel. Split out from voice() so the routing can be read back
## in a test without a microphone, a second peer or an rpc to send: the fan-out above is then
## only delivery.
static func voice_listeners(sender_id: int, team_only: bool) -> PackedInt32Array:
	var listeners := PackedInt32Array()
	var sender_player := NetworkManager.get_player(sender_id)
	if sender_player == null:
		return listeners
	var sender_team: int = sender_player.team
	if team_only and sender_team == GameConsts.Team.NONE:
		return listeners
	var roster := NetworkManager.player_roster()
	for pid in roster:
		if pid == sender_id or pid < 0:
			continue
		if team_only and not Teams.teams_friendly(sender_team, roster[pid].team):
			continue
		listeners.append(pid)
	return listeners
