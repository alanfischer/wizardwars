extends Node
## Everything the server tells a client to show, in one place.
##
## These are the handlers NetworkManager._dispatch_to_scene reaches by name: a sync event arrives,
## and this turns it into something visible — a hit on the local player, an effect on someone
## else's puppet, a sprite over a head. Almost none of it is a decision; the server already made
## those. The one rule they all share is that the local player is NOT in the puppet table (the
## client's own body is LocalPlayer, a predicted view), so a handler that could be about either has
## to answer for both.
##
## Parented to main.gd as "ClientSync" — the name the dispatcher looks for. The predicted local
## view comes from Game.local_player; the puppets come from NetworkManager's player registry.

## Sprites hung over a player's head — the status icons and the call-for-help arrow — sit where
## GoldSrc's TE_PLAYERATTACHMENT put them: 60 units above a player origin, just clear of the head.
## The help call also lives the three seconds that message's lifetime field gave it.
const FLOATING_SPRITE_HEIGHT := 2.4
const HELP_CALL_DURATION := 3.0
## Roughly mouth height on a standing player, so the shout comes from the caller and not their feet.
const HELP_CALL_VOICE_HEIGHT := 1.5
## A shout has to carry past the room it was made in — the default one-shot radius is ~320 units,
## this is GoldSrc's ATTN_NORM, roughly the 1000 units the original call reached.
const HELP_CALL_RANGE := 25.0

## main.gd, only as the parent to hang gib effects under. Puppets come from NetworkManager, and
## the local player is NOT in that registry — it is Game.local_player, a predicted view.
var _main: Node3D


func bind(main: Node3D) -> void:
	_main = main


func _on_sync_vr_hand_states(peer_ids: PackedInt32Array, right_positions: PackedVector3Array, left_positions: PackedVector3Array, hand_flags: PackedByteArray) -> void:
	var own_id := multiplayer.get_unique_id()
	var have_local_view: bool = Game.local_player != null
	# player_table() rather than get_player(): the fields below are RemotePlayer's, not the Player
	# base class every get_player() caller is held to. By reference, so a session with one VR player
	# doesn't copy the whole roster every half-tick — hence the validity check below.
	var puppets := NetworkManager.player_table()
	for i in peer_ids.size():
		var pid := peer_ids[i]
		if have_local_view and pid == own_id:
			continue
		var remote = puppets.get(pid)
		if remote and is_instance_valid(remote):
			remote.sync_right_hand_world = right_positions[i]
			remote.sync_left_hand_world = left_positions[i]
			remote.sync_left_handed = bool(hand_flags[i] & 1)


func _on_sync_attack(peer_id: int, weapon_idx: int = 0, aim_dir: Vector3 = Vector3.ZERO, secondary: bool = false) -> void:
	# Skip effects for our own attacks — already created locally when we fired
	if Game.local_player and peer_id == multiplayer.get_unique_id():
		return
	var remote = NetworkManager.get_player(peer_id)
	if not remote or remote.is_dead:
		return
	# Update remote's active weapon so play_attack() picks the right animation
	if weapon_idx >= 0 and weapon_idx < remote.weapons.size():
		remote.current_weapon_idx = weapon_idx
	# Held beams (players AND bots) are driven by the snapshot's PLAYER_FLAG_FIRING — self-healing
	# on/off in remote_player._reconcile_firing — so ignore the unreliable start event for them,
	# or the event and the snapshot would both start the beam. Secondary shots are always
	# discrete, so they still play through this event path.
	if not secondary:
		var w: Weapon = remote.weapon_at(weapon_idx)
		if w and w.sustained:
			return
	if remote.has_method("play_attack"):
		remote.play_attack()
	if weapon_idx >= 0 and weapon_idx < remote.weapons.size():
		var weapon: Weapon = remote.weapons[weapon_idx]
		weapon.fire(remote, Vector3.INF, aim_dir, 0.0, secondary)
		remote.last_fired_weapon_idx = weapon_idx  # so stop_attack stops the right one


func _on_sync_stop_attack(peer_id: int) -> void:
	if Game.local_player and peer_id == multiplayer.get_unique_id():
		return
	var remote = NetworkManager.get_player(peer_id)
	if not remote:
		return
	var weapon: Weapon = remote.last_fired_weapon()
	if weapon:
		# Sustained beams are snapshot-driven — stopping here would desync _sustained_shown, so let
		# PLAYER_FLAG_FIRING clear them instead.
		if weapon.sustained:
			return
		weapon.stop_firing(remote)
	if remote._attack_player:
		remote._attack_player.stop()


func _on_sync_player_heal(amount: float, allow_overheal := false) -> void:
	if Game.local_player:
		Game.local_player.heal(amount, null, allow_overheal)


func _on_owner_state(seq: int, pos: Vector3, vel: Vector3,
		crouched: bool, on_floor: bool, jumping: bool, jump_held: bool) -> void:
	if Game.local_player:
		Game.local_player._on_server_state(seq, pos, vel, crouched, on_floor, jumping, jump_held)


func _on_sync_mana(new_mana: float, new_satchels: int) -> void:
	if Game.local_player:
		Game.local_player._on_sync_mana(new_mana, new_satchels)


## sync_mana and sync_mana_drain are the same event on two channels (reliable, and unreliable for a
## sustained drain where newer values supersede). They get one handler each so the "_on_" + rpc name
## rule holds without exception; this is the single place that says they mean the same thing.
func _on_sync_mana_drain(new_mana: float, new_satchels: int) -> void:
	_on_sync_mana(new_mana, new_satchels)


func _on_sync_dragon_flame_drain(flame: int) -> void:
	_on_sync_dragon_flame(flame)


func _on_sync_dragon_flame(flame: int) -> void:
	if Game.local_player:
		Game.local_player._on_sync_dragon_flame(flame)


func _on_sync_fire_warning() -> void:
	if Game.local_player:
		Game.local_player.on_fire_warning()


func _on_sync_player_damage(amount: float, _type: int = 0) -> void:
	if Game.local_player and not Game.local_player.is_dead:
		Game.local_player.apply_damage_raw(amount)


func _on_sync_player_frost(duration: float) -> void:
	if Game.local_player:
		StatusSystem.apply_frost_local(Game.local_player, duration)


func _on_sync_screen_fade(color: Color, duration: float, holdtime: float, reverse: bool) -> void:
	if Game.local_player and Game.local_player._hud:
		Game.local_player._hud.show_fade(color, duration, holdtime, reverse)


func _on_sync_screen_shake(amplitude: float, duration: float, frequency: float) -> void:
	if Game.local_player:
		Game.local_player.shake_view(amplitude, duration, frequency)


func _on_sync_view_punch(roll_degrees: float) -> void:
	if Game.local_player:
		Game.local_player.punch_view(roll_degrees)


func _on_sync_player_status(status_type: int) -> void:
	if Game.local_player:
		Game.local_player.show_status(status_type)


func _on_sync_player_clear_status(status_type: int) -> void:
	if Game.local_player:
		Game.local_player.hide_status(status_type)


func _on_sync_plant_indicator(kind: String, active: bool, hp: float, max_hp: float) -> void:
	if Game.local_player:
		Game.local_player.set_plant_indicator(kind, active, hp, max_hp)


func _on_sync_target_id(label: String, relation: int, health_pct: int) -> void:
	if Game.local_player and Game.local_player._hud:
		Game.local_player._hud.set_target_id(label, relation, health_pct)


func _on_status_visual(peer_id: int, status_type: int, active: bool) -> void:
	var remote = NetworkManager.get_player(peer_id)
	if not remote:
		return
	if active:
		_add_floating_status(remote, status_type)
	else:
		_remove_floating_status(remote, status_type)


func _add_floating_status(puppet: Node3D, status_type: int) -> void:
	var key := "status_%d" % status_type
	if puppet.get_node_or_null(key):
		return  # already showing
	var sprite_path: String = StatusSystem.STATUS_SPRITES.get(status_type, "")
	if sprite_path.is_empty():
		return
	# Tint frost sprite blue
	var tint := Color(0.3, 0.6, 1.0) if status_type == GameConsts.StatusType.FROSTED else Color.WHITE
	var sprite := _make_floating_sprite(sprite_path,
		FLOATING_SPRITE_HEIGHT + status_type * 0.4, tint)  # stack vertically
	if sprite:
		sprite.name = key
		puppet.add_child(sprite)


## A billboard hanging over a player's head, in the size and pose GoldSrc's TE_PLAYERATTACHMENT
## drew them. Null when the sprite can't be loaded.
func _make_floating_sprite(sprite_path: String, height: float, tint := Color.WHITE) -> Sprite3D:
	var sprite := AssetLoader.load_sprite_node(sprite_path)
	if not sprite:
		return null
	sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	sprite.pixel_size = GameConsts.SCALE_FACTOR
	sprite.transparent = true
	sprite.position = Vector3(0, height, 0)
	var mat := AssetLoader.get_sprite_material_template().duplicate()
	if sprite.texture:
		mat.albedo_texture = sprite.texture
	mat.albedo_color = tint
	sprite.material_override = mat
	return sprite


func _remove_floating_status(puppet: Node3D, status_type: int) -> void:
	var key := "status_%d" % status_type
	var node := puppet.get_node_or_null(key)
	if node:
		node.queue_free()


## A teammate is asking for a heal: a sprite rides over their head for a few seconds, and they
## shout from where they stood when they asked.
func _on_sync_player_help_call(peer_id: int, sprite_path: String, sound_path: String) -> void:
	# A client has no puppet for its own body (LocalPlayer is the view), so a caller falls back
	# to their own view for the position to shout from and the sprite to carry.
	var caller: Node3D = NetworkManager.get_player(peer_id)
	if caller == null and Game.local_player and Game.local_player.peer_id == peer_id:
		caller = Game.local_player
	if caller == null:
		return
	# Placed in the world, not parented to the caller: a hidden node silences an
	# AudioStreamPlayer3D under it, and the listen host's own body puppet is always hidden — so
	# attaching the shout to the caller meant the host never heard themselves call.
	SoundSystem.play_3d_local(sound_path,
		caller.global_position + Vector3.UP * HELP_CALL_VOICE_HEIGHT, 1.0, 0.0, HELP_CALL_RANGE)
	var existing := caller.get_node_or_null("HelpCall")
	if existing:
		existing.name = &"HelpCallGone"  # queue_free is deferred; free the name now, not next frame
		existing.queue_free()
	var sprite := _make_floating_sprite(sprite_path, FLOATING_SPRITE_HEIGHT)
	if sprite == null:
		return
	sprite.name = "HelpCall"
	caller.add_child(sprite)
	# The caller can't see the sprite over their own head, so mirror it into their status strip.
	if Game.local_player and Game.local_player.peer_id == peer_id:
		Game.local_player.show_help_call(sprite_path, HELP_CALL_DURATION)
	get_tree().create_timer(HELP_CALL_DURATION).timeout.connect(
		func() -> void:
			if is_instance_valid(sprite):
				sprite.queue_free())


func _on_sync_hit_confirmed(lethal := false) -> void:
	if Game.local_player and Game.local_player.has_method("on_hit_confirmed"):
		Game.local_player.on_hit_confirmed(lethal)



func _on_sync_grant_weapon(peer_id: int, key: String) -> void:
	var remote = NetworkManager.get_player(peer_id)
	if remote:
		remote.add_granted_weapon(key)
	if Game.local_player and peer_id == multiplayer.get_unique_id():
		Game.local_player.add_granted_weapon(key)


func _on_sync_revoke_weapon(peer_id: int, key: String) -> void:
	var remote = NetworkManager.get_player(peer_id)
	if remote:
		remote.remove_granted_weapon(key)
	if Game.local_player and peer_id == multiplayer.get_unique_id():
		Game.local_player.remove_granted_weapon(key)


func _on_sync_bear_morph(peer_id: int, is_bear: bool, new_health: float, new_max_health: float) -> void:
	# Server-authoritative puppets already swapped their model in become_bear/_wizard; only
	# client-side replicas need the visual re-applied.
	var remote = NetworkManager.get_player(peer_id)
	if remote and remote.has_method("apply_bear_morph_visual") and not remote.has_server_movement():
		remote.apply_bear_morph_visual(is_bear)
	if Game.local_player and peer_id == multiplayer.get_unique_id():
		Game.local_player.on_bear_morph_confirmed(is_bear, new_health, new_max_health)


func _on_sync_dragon_mount(peer_id: int, entity_id: int, mounted: bool) -> void:
	var remote = NetworkManager.get_player(peer_id)
	if remote and remote.has_method("apply_dragon_mount_visual"):
		remote.apply_dragon_mount_visual(entity_id, mounted)
	if Game.local_player and peer_id == multiplayer.get_unique_id():
		Game.local_player.on_dragon_mount_confirmed(entity_id, mounted)


func _on_sync_player_invis(peer_id: int, active: bool) -> void:
	var remote = NetworkManager.get_player(peer_id)
	if remote and remote.has_method("apply_invis_visual"):
		remote.apply_invis_visual(active)
	# Host's own invisibility: mirror onto the first-person view (hand-model fade).
	if Game.local_player and peer_id == multiplayer.get_unique_id():
		Game.local_player.is_invisible = active


func _on_sync_player_death(peer_id: int) -> void:
	if Game.local_player and peer_id == multiplayer.get_unique_id():
		if not Game.local_player.is_dead:  # server says we're dead — force-kill if client hasn't realized yet
			Game.local_player.die()
		return
	var remote = NetworkManager.get_player(peer_id)
	if remote:
		for w in remote.weapons:
			w.stop_firing(remote)
		# Latch dead FIRST: on goldnet there's no presence-timeout fallback, so a late in-flight
		# bundle would otherwise re-show the body via _on_net_synchronized.
		remote.is_dead = true
		# Clear PVS presence so the presence-driven _process doesn't re-show the body before the
		# stream stops (the host omits dead players next tick).
		remote.mark_pvs_absent()
		# Disable the collider deferred, but re-derive it from is_dead at flush time so a same-frame
		# revive (ww_hunt target-killed -> notepad return -> GR_FORCE_RESPAWN) isn't clobbered.
		remote.call_deferred(&"sync_collider_to_liveness")


## Every replicated burst lands here, whatever fired it — the host through
## broadcast_and_dispatch, a client off the RPC. The caller owns the burst's shape; this only
## plays it.
func _on_sync_gib_burst(pos: Vector3, material: int, extent: Vector3, count: int,
		sound: String, gibmodel: String) -> void:
	GibEffect.play_burst(pos, material, extent, count, sound, _main, gibmodel)


func _on_sync_player_respawn(peer_id: int) -> void:
	var remote = NetworkManager.get_player(peer_id)
	if remote:
		remote.is_dead = false  # clears the death latch set in _on_sync_player_death
		if remote.has_method("apply_remote_spawn_state"):
			remote.apply_remote_spawn_state(remote.element, true, false)
		else:
			remote.reset_for_spawn(remote.element, true, false)
		# On goldnet collision is presence-gated, so the stream re-enables it on PVS re-entry;
		# force-enabling here would strand an out-of-view respawn as invisible-but-colliding.
		if not NetworkManager.transport.relevance_events:
			var shape = remote.get_node_or_null("CollisionShape3D")
			if shape:
				shape.set_deferred("disabled", false)
		for st in [GameConsts.StatusType.POISON, GameConsts.StatusType.BURNING, GameConsts.StatusType.FROSTED]:
			_remove_floating_status(remote, st)
