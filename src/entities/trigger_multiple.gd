class_name TriggerMultiple
extends EntityBase
# trigger_multiple / trigger_once — brush volume that fires its target while a player
# stands in it. Converts StaticBody3D collision to Area3D for player detection.

## CTriggerMultiple::Spawn rewrites an absent or zero wait to 0.2s.
const DEFAULT_WAIT := 0.2

var _area: Area3D = null
var _target_key: String
var _wait_time: float
var _req_team: int
var _owned_by: int       # team that receives netname_owners_team_broadcast messages
var _broadcast_msg: String  # sent to _owned_by team on activation (TFC hunted-area notification)
var _is_once: bool = false
var _last_trigger_time: float = -999.0
var _fired: bool = false
## Does this trigger fire a door? -1 until asked, because the registry fills in BSP lump order
## and a trigger can be ready before the door it names (see map entity _ready order).
var _fires_door: int = -1


func _ready() -> void:
	super()
	_target_key = ent.get("target", "")
	_wait_time = parse_float(ent, "wait", 0.0)
	if _wait_time <= 0.0:
		_wait_time = DEFAULT_WAIT
	_req_team = parse_int(ent, "team_no", 0)
	_owned_by = parse_int(ent, "owned_by", 0)
	_broadcast_msg = ent.get("netname_owners_team_broadcast", "").strip_edges()
	_is_once = ent.get("classname", "") == "trigger_once"

	_area = GoldSrcEntity.use_volume_as_trigger(self, GameConsts.MASK_DOOR_TOUCH)
	_area.body_entered.connect(_on_body_entered)
	Log.debug("[trigger_multiple] ready: target=%s team=%d owned_by=%d pos=%s" % [_target_key, _req_team, _owned_by, str(global_position)])


## CBaseTrigger::MultiTouch runs every frame a player is inside, not once on the way in.
## Standing still has to keep firing, because what the trigger fires can refuse the visit:
## ww_chasm's cap points run a PotatoC script that ignores the touch while the point is
## disarmed (5s after every capture) or while the previous point is still enemy-held. On
## body_entered alone, entering the volume spends the player's one and only touch.
func _physics_process(_delta: float) -> void:
	if _is_network_client() or _area == null or (_is_once and _fired):
		return
	if Time.get_ticks_msec() / 1000.0 < _last_trigger_time + _wait_time:
		return
	if not _area.has_overlapping_bodies():
		return
	for body in _area.get_overlapping_bodies():
		_touch(body)


func _on_body_entered(body: Node3D) -> void:
	_touch(body)


func _touch(body: Node3D) -> void:
	if not body is CharacterBody3D:
		return
	# Client: host is authoritative for entity interactions
	if _is_network_client():
		return
	# Monsters stand in these volumes now, because on half the maps the thing that opens a base
	# door is a team trigger rather than the door's own touch area (2fort's resupplies,
	# ww_wolteg's spawn doors), and a door with a targetname builds no touch area at all.
	# Opening a door is the whole of what a monster may do with a trigger: firing the rest —
	# capture goals, monstermakers, the multi_managers that run a map's round — would hand the
	# map's script to something that was never written into it. `is_alive` is a player property,
	# so each kind is asked after its own liveness.
	if GoldSrcEntity.is_player_body(body):
		if not body.is_alive:
			return
	elif bool(body.get("is_dead")) or not _fires_a_door():
		return
	# Deferred: _fire can mutate the scene/physics (targets, doors, kills); doing so inside a
	# body_entered callback re-enters the physics server mid-step and corrupts it (Linux
	# segfault under load).
	call_deferred("_fire", body)


func trigger(activator: Node, _type: TriggerSystem.Type) -> void:
	_fire(activator)


func _fire(activator: Node) -> void:
	if _fired and _is_once:
		return

	# team_no is the goal criterion from ActivateMultiTrigger's UTIL_IsMasterTriggered, which runs
	# before the broadcast below and before the wait is stamped: a wrong-team touch costs nothing.
	if not Teams.may_pass_team_gate(activator, _req_team):
		return

	# Re-fire cooldown (ActivateMultiTrigger's nextthink gate — per trigger, not per player)
	var now := Time.get_ticks_msec() / 1000.0
	if now < _last_trigger_time + _wait_time:
		return
	_last_trigger_time = now
	if not _target_key.is_empty():
		TriggerSystem.fire(_target_key, activator, TriggerSystem.Type.TOGGLE)
	if not _broadcast_msg.is_empty() and _owned_by > 0:
		_broadcast_to_team(_broadcast_msg, _owned_by)

	if _is_once:
		_fired = true
		for child in get_children():
			if child is Area3D:
				child.set_deferred("monitoring", false)


## True when something this trigger names is a door. Resolved once, on the first non-player
## touch, and cached — the answer cannot change for the life of the map.
func _fires_a_door() -> bool:
	if _fires_door < 0:
		_fires_door = 0
		if not _target_key.is_empty():
			for n in TriggerSystem.get_nodes(_target_key):
				if n is FuncDoorBase:
					_fires_door = 1
					break
	return _fires_door == 1


func _broadcast_to_team(msg: String, team: int) -> void:
	var text := GoalMessages.translate(msg)
	var main_scene = get_tree().current_scene
	if not main_scene:
		return
	var local_player = Game.local_player
	if local_player and local_player.team == team:
		if Game.hud:
			Game.hud.show_center_message(text, Color.WHITE, 3.0, true)
	for puppet in get_tree().get_nodes_in_group("damageable"):
		var pid = puppet.get("peer_id")
		# pid > 0 = clients only (bots have no screen). Skip the host's own body too —
		# the local branch above already showed it, and sync_hud_text is call_local, so
		# rpc_id-to-self would display the message a second time.
		if pid and pid > 0 and pid != multiplayer.get_unique_id() \
				and puppet.get("team") == team:
			NetworkManager.sync_hud_text.rpc_id(pid, text, NetworkManager.HUD_CENTER,
				1.0, 1.0, 1.0, 3.0, true)
