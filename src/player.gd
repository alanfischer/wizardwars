## Base class for both the local player (local_player.gd) and remote players (remote_player.gd).
## Handles shared state (health, mana, team, element) and common logic
## (healing, dragon mounting). The satchel pack, plants and weapon charge are
## composed in from src/behaviors/.
class_name Player
extends CharacterBody3D

const Movement = preload("res://addons/pmove/movement.gd")
const SnapshotInterp = preload("res://src/systems/snapshot_interp.gd")
const RESPAWN_DELAY := 5.0
const DEATH_HOP_BELOW := 10.0 * GameConsts.SCALE_FACTOR
const DEATH_HOP_MAX := 300.0 * GameConsts.SCALE_FACTOR
## How far under the waterline a swimmer's feet sit at the top of its rise. The swim override only
## holds while the WaterDetector sphere still overlaps liquid, and its offset is derived from this,
## so this is the highest the swim can lift a body — everything above it is ballistic.
## WaypointBaker.WATER_EXIT_RISE is the climb-out reach that follows from it, and
## PM_CheckWaterJump's own window (LadderWater.water_jump) is the same number from the other side.
const SWIM_FEET_DEPTH := 0.8

## The glow shell the original put on a wizard carrying a combo spell. White, the colour it used,
## kept short of 1.0 so a wizard's own skin still reads through the shell. Lives here because both
## views wear it: the wizard and staff everyone else sees (RemotePlayer._update_combo_glow) and the
## carrier's own hands (LocalPlayer._update_combo_glow), which have to agree on the look.
const COMBO_GLOW_COLOR := Color(1.0, 1.0, 1.0)
const COMBO_GLOW_STRENGTH := 0.55

# --- Shared State ---
var peer_id: int = 0
var team: int = GameConsts.Team.NONE
var element: int = GameConsts.Element.FIRE
var health := 100.0
var max_health := 100.0
var mana := 100.0
var max_mana := 100.0
## Server-authoritative: this player is sustaining a mana-draining beam (rays,
## levitate). Ticked from RemotePlayer._physics_process like the satchel fuse.
var mana_drain_active := false
var _mana_drain_sync_timer := 0.0
## Server-side cooldown gate for call_for_help (Time.get_ticks_msec()/1000.0).
var _next_help_call := 0.0
## Server-authoritative combat bookkeeping, set by the fire/attack path.
var last_fired_weapon_idx := -1  # slot of the last fire; -1 = none yet (falls back to current)
var lag_comp_shot_time_ms := 0   # shooter's render time (server clock) for hitscan lag-comp rewind; 0 = no rewind
var shot_seq := 0  # the command firing right now, pairing its projectile with a stand-in; 0 = none
var is_dead := false
var is_respawning := false
## The killing blow's shove (Combat.damage_force), held from the blow to the body it leaves.
var _death_push := Vector3.ZERO
## TFC invulnerability powerup (goal invincible_finished) — server-side timestamp
## (Time.get_ticks_msec()/1000.0) until which all damage is ignored.
var invincible_until := 0.0
var is_invisible := false
var _invis_alpha := 1.0

## True for every player puppet running server-authoritative physics on this machine —
## all puppets on the listen-server host, none on a pure client. NOT "this machine's own
## player": every connected client's puppet on the host has this true too.
var is_host_puppet := false
## Listen-server host: our view is a prediction of the body puppet, not a body. The
## puppet is the damageable entity — the view must stay out of the "damageable" group
## or effect/AoE/bot-targeting walks hit it too, with none of the puppet's state.
var has_body_puppet := false
var speed_multiplier := 1.0
var weapon: Weapon
var weapons: Array[Weapon] = []
var current_weapon_idx: int = 0
## Weapons granted mid-life (item_weapon pickups, /give), as SpawnRegistry names. Kept as names
## so every peer rebuilds an identical weapon at the same index: sync_attack replays a shot by
## index, so an observer whose replica lacks it would draw nothing. Cleared on respawn.
var granted_weapons: Array[String] = []
## Staff clashes landed on an ally this life, toward a combo spell (Staff._combo_swing).
## -1 once a spell has been earned: one per life, and the pair has to find fresh partners.
## Host-side bookkeeping only, so it isn't synced. Cleared on respawn.
var combo_hits: int = 0
@warning_ignore("unused_private_class_variable")
var _last_weapon_idx: int = 0
@warning_ignore("unused_private_class_variable")
var _base_fov := 0.0
var carried_items: Array = []

## Server-authoritative sustained-fire state (beam/ray held on). Rides the per-tick
## snapshot as PLAYER_FLAG_FIRING via get_broadcast_flags. Written by server code
## through NetworkManager.get_player(), so it must live on the base class.
var sync_firing := false

## Pending role queued by die_for_class_change; consumed by the respawn path.
## -1 = no change pending.
var class_change_pending_team: int = -1
var class_change_pending_element: int = -1

var _move_ctx: PlayerMovementContext
var satchel_pack := SatchelBehavior.new()
var plants := PlantBehavior.new()
var charge := ChargeBehavior.new()
## The trigger, stepped per input command: by the server for every player, and by the view to
## predict its own shots.
var fire := FireControl.new()
var _mounted_dragon: Node = null
var _dragon_entity_id: int = -1

var is_dragon_mounted: bool:
	get: return _dragon_entity_id != -1 or is_instance_valid(_mounted_dragon)

const _INVIS_FADE_RATE := 2.5
const _INVIS_MAX_VISIBLE_ALPHA := 0.5
const _INVIS_SPEED_REF := 8.0

@onready var ladder_detector: Area3D = get_node_or_null("LadderDetector")
@onready var water_detector: Area3D = get_node_or_null("WaterDetector")

var is_bear := false
var _bear_mana_drain_timer := 0.0
const BEAR_DRAIN_INTERVAL := 2.5
const BEAR_DRAIN_AMOUNT := 5.0
# Set by trigger_push each frame; consumed by get_movement_modifiers to suppress ground friction.
@warning_ignore("unused_private_class_variable")
var _push_base_vel: Vector3 = Vector3.ZERO

var is_alive: bool:
	get: return not is_dead and not is_respawning

var gravity_scale: float:
	set(v): _move_ctx.gravity_scale = v
	get: return _move_ctx.gravity_scale if _move_ctx else 1.0


## Waist-deep or deeper (GoldSrc waterlevel 2), as of the last simulated tick. LocalPlayer
## overrides this with its own per-frame check; on a puppet it is the sim's own answer.
func is_in_water() -> bool:
	return _move_ctx.in_water if _move_ctx else false


## Hull penetration into `mover` from netmove's own probe, -1.0 if unmeasured. A brush mover
## asks before calling itself Blocked (see FuncDoorBase._physics_process).
func mover_obstruction(mover: Object) -> float:
	return _move_ctx.mover_obstruction(mover) if _move_ctx else -1.0


func _init() -> void:
	add_to_group("damageable")
	for behavior in [satchel_pack, plants, charge]:
		behavior.initialize(self)


func _ready() -> void:
	# Ladder and water detectors should be in the scene (player.tscn)
	# but we can fallback to creating them if needed.
	if not ladder_detector:
		_create_detectors()
	_move_ctx = PlayerMovementContext.new(self, ladder_detector, water_detector)
	_post_ready()


## Virtual method for subclass-specific ready logic.
func _post_ready() -> void:
	pass


func _active_camera() -> Camera3D:
	return null


## Bounds-checked weapon lookup — null when idx is out of range. Callers that index
## weapons[] off a network-supplied or cached index should go through this.
func weapon_at(idx: int) -> Weapon:
	return weapons[idx] if idx >= 0 and idx < weapons.size() else null


## The weapon this player most recently fired, for sustained-fire stop/drain
## bookkeeping. Falls back to the current weapon before the first shot.
func last_fired_weapon() -> Weapon:
	return weapon_at(last_fired_weapon_idx if last_fired_weapon_idx >= 0 else current_weapon_idx)


## Append the runtime grants to a freshly built wizard loadout. Every site that rebuilds
## weapons[] from a Wizard goes through this, or a bear revert / dismount would silently
## drop what the player picked up.
func with_granted(base: Array[Weapon]) -> Array[Weapon]:
	if granted_weapons.is_empty():
		return base
	var out: Array[Weapon] = base.duplicate()
	for key in granted_weapons:
		var w := SpawnRegistry.build_weapon(key, element)
		if w:
			out.append(w)
	return out


## Apply one grant on this peer. Runs on the host puppet, on every observer's replica, and on
## the owner's LocalPlayer, all from the same sync event, so the indices agree.
##
## One combo spell at a time: a second book displaces the first. Done here rather than server-side
## so every peer performs the same swap off the same event — a revoke broadcast of its own could
## interleave with the grant and leave the replicas holding different slots.
func add_granted_weapon(key: String) -> bool:
	if key in granted_weapons:
		return false
	var w := SpawnRegistry.build_weapon(key, element)
	if w == null:
		return false
	if SpawnRegistry.is_combo_weapon(key):
		for held in combo_weapons_held():
			remove_granted_weapon(held)
	granted_weapons.append(key)
	weapons.append(w)
	return true


## True while this player is carrying a combo spell — what the glow shell reads every frame,
## so it answers without building a list in the usual (empty) case.
func has_combo_weapon() -> bool:
	for key in granted_weapons:
		if SpawnRegistry.is_combo_weapon(key):
			return true
	return false


## The combo spells this player is carrying. At most one once add_granted_weapon has had its say,
## but returned as a list so a loadout that arrived some other way still ends up with one book
## rather than jamming on the first.
func combo_weapons_held() -> Array[String]:
	var out: Array[String] = []
	for key in granted_weapons:
		if SpawnRegistry.is_combo_weapon(key):
			out.append(key)
	return out


## Apply one revocation on this peer — the mirror of add_granted_weapon, run from the same sync
## event on every peer so the indices stay in step. Grants are appended, so dropping one shifts
## every slot after it: the three stored indices move with it, and a player standing on the slot
## that just vanished falls back to the one before it (GoldSrc's GetNextBestWeapon).
func remove_granted_weapon(key: String) -> bool:
	var idx := granted_weapons.find(key)
	if idx < 0:
		return false
	var slot := weapons.size() - granted_weapons.size() + idx  # grants sit after the base loadout
	granted_weapons.remove_at(idx)
	if slot < 0 or slot >= weapons.size():
		return false
	weapons.remove_at(slot)
	current_weapon_idx = _slot_after_removal(current_weapon_idx, slot, true)
	last_fired_weapon_idx = _slot_after_removal(last_fired_weapon_idx, slot, false)
	charge.weapon_idx = _slot_after_removal(charge.weapon_idx, slot, false)
	return true


func _slot_after_removal(idx: int, removed: int, keep_valid: bool) -> int:
	if idx > removed:
		return idx - 1
	if idx == removed:
		return maxi(0, mini(removed, weapons.size() - 1)) if keep_valid else -1
	return idx


## Server: take a granted weapon back from this player and tell every peer. False if they
## weren't carrying it. A one-shot spell spends itself this way.
func revoke_weapon(key: String) -> bool:
	if not NetworkManager.is_authority():
		return false
	key = key.to_lower()
	if key not in granted_weapons:
		return false
	NetworkManager.broadcast_revoke_weapon(peer_id, key)
	return true


## Server: hand this player a weapon and tell every peer. False if it was already carried or
## the key is unknown.
func grant_weapon(key: String) -> bool:
	if not NetworkManager.is_authority():
		return false
	key = key.to_lower()
	if key in granted_weapons or not SpawnRegistry.has_weapon(key):
		return false
	NetworkManager.broadcast_grant_weapon(peer_id, key)
	return true


# --- Server-facing player contract ---
# Every method server code reaches through NetworkManager.get_player() MUST be declared
# here, so a call only one subclass implements is a parse-time error, not a runtime crash.

## True when this player runs a server-authoritative input queue on this machine
## (client/bot puppets on the host). The host's own player and pure-client
## puppets return false.
func has_server_movement() -> bool:
	return false


func get_server_movement() -> ServerMovement:
	return null


## True when this object is the authoritative server-side player for its peer id —
## the one that may run authority branches (broadcasts, authoritative kills).
## Offline that's the LocalPlayer; online it's the registered body puppet on the
## host. The is_host() clause is load-bearing: clients cache puppet replicas too,
## so a get_player() hit alone does not imply authority.
func _is_server_player() -> bool:
	return not NetworkManager.is_online() or \
			(NetworkManager.is_host() and NetworkManager.get_player(peer_id) == self)


## The netmove body wrapper driven by ServerMovement. Null when this player has
## no server-side simulation on this machine.
func get_godot_body() -> GodotBody:
	return null


## Movement modifiers for one tick (speed/gravity/friction from weapons + status).
## Both the predicted view and the server body override with their live sources.
func get_movement_modifiers(_cmd) -> Movement.MovementModifiers:
	return Movement.MovementModifiers.new()


## End a sustained fire: stop the weapon AND clear the authoritative snapshot
## firing bit as one operation, so no stop path can clear one without the other
## (a stranded beam, or a stuck PLAYER_FLAG_FIRING that makes observers re-heal
## a dead beam). Subclasses extend to clear their own firing state.
func end_sustained_fire(w: Weapon) -> void:
	sync_firing = false
	fire.auto_firing = false
	if w:
		w.stop_firing(self)


## Teleport to a position and yaw. Zeroes velocity. Subclasses extend to clear
## motion state that must not survive a teleport (prediction buffer, lag-comp
## position history).
func teleport_to(pos: Vector3, yaw: float) -> void:
	velocity = Vector3.ZERO
	global_position = pos
	rotation.y = yaw


## Change element. RemotePlayer extends this to reload the 3P model and loadout.
func set_element(new_element: int) -> void:
	element = new_element


## Flags byte for the per-tick player-state snapshot (NetworkManager.PLAYER_FLAG_*).
func get_broadcast_flags() -> int:
	return 0


## Queue a team/class change: record the pending role, then die so the normal
## respawn path applies it when the timer fires. Safe to call repeatedly while
## counting down — it only updates the pending values. RemotePlayer overrides
## with the full server flow (no corpse, queue clear, death broadcast).
func die_for_class_change(pending_team: int, pending_element: int) -> void:
	class_change_pending_team = pending_team
	class_change_pending_element = pending_element
	if not is_dead:
		die()


## Give mana (resupply/backpack pickup). Authority-side: syncs the new totals to
## the owner — for the host body / offline this dispatches _on_sync_mana locally.
func add_mana(amount: float) -> void:
	mana = minf(mana + amount, max_mana)
	if NetworkManager.is_authority():
		NetworkManager.sync_mana_to_owner(self)


func add_satchels(amount: int) -> void:
	satchel_pack.add(amount)
	if NetworkManager.is_authority():
		NetworkManager.sync_mana_to_owner(self)


func _create_detectors() -> void:
	# Fallback for scenes that haven't been updated to inherit player.tscn yet
	if not ladder_detector:
		ladder_detector = Area3D.new()
		ladder_detector.name = "LadderDetector"
		ladder_detector.collision_layer = 0
		ladder_detector.collision_mask = GameConsts.MASK_LADDER
		ladder_detector.monitorable = false
		var ladder_shape := CylinderShape3D.new()
		ladder_shape.height = 1.8
		ladder_shape.radius = 0.4
		var ladder_col := CollisionShape3D.new()
		ladder_col.shape = ladder_shape
		ladder_col.position.y = 0.9
		ladder_detector.add_child(ladder_col)
		add_child(ladder_detector)
	
	if not water_detector:
		water_detector = Area3D.new()
		water_detector.name = "WaterDetector"
		water_detector.collision_layer = 0
		water_detector.collision_mask = GameConsts.MASK_WATER
		water_detector.monitorable = false
		# Waist sphere: the threshold for SWIMMING (GoldSrc waterlevel 2). Its underside is what
		# decides how high a swimmer can rise, so that is the named constant and the offset follows
		# from it — see SWIM_FEET_DEPTH.
		var water_shape := SphereShape3D.new()
		water_shape.radius = 0.1
		var water_col := CollisionShape3D.new()
		water_col.shape = water_shape
		water_col.position.y = SWIM_FEET_DEPTH + water_shape.radius
		water_detector.add_child(water_col)
		add_child(water_detector)


# --- Common Logic ---

func heal(amount: float, _healer: Node3D = null, allow_overheal := false) -> void:
	if is_dead:
		return
	var cap := max_health * GameConsts.OVERHEAL_FACTOR if allow_overheal else max_health
	health = minf(health + amount, maxf(cap, health))
	# Healing clears all status effects
	if NetworkManager.is_authority():
		StatusSystem.clear_all(self)
	_on_healed(amount, allow_overheal)


## Virtual method for side effects when healed (HUD, RPCs).
func _on_healed(_amount: float, _allow_overheal: bool) -> void:
	pass


## Apply pre-calculated damage directly (no frost reduction, no friendly fire check).
## Used by network sync to avoid double-applying frost reduction.
func apply_damage_raw(amount: float, attacker: Node3D = null,
		type: int = GameConsts.DamageType.PHYSICAL) -> void:
	if is_dead:
		return
	health = maxf(health - amount, 0.0)
	_on_damage_applied(amount)
	if health <= 0.0:
		die(attacker, type, amount)


## Virtual method for side effects when damage is applied (HUD).
func _on_damage_applied(_amount: float) -> void:
	pass


func take_damage(amount: float, type: int = GameConsts.DamageType.PHYSICAL, attacker: Node3D = null) -> void:
	if is_dead:
		return
	if not is_in_group("damageable"):
		# Not a live body: a puppet whose peer is still loading the map (main._on_peer_connected),
		# a spectator, or the host's own view. Group membership is what every AoE/homing scan
		# reads, so a direct hit has to agree with it. NOT a team check — deathmatch players
		# have no team and are ordinary targets.
		return
	if attacker and Teams.nodes_friendly(attacker, self):
		return
	if MatchSystem.is_intermission():
		return  # match over: the scoreboard is up and nobody can be shot off it

	if NetworkManager.is_authority():
		# Authority path (host or offline)
		if Time.get_ticks_msec() / 1000.0 < invincible_until:
			return
		StatusSystem.on_damage_dealt(self, type, attacker)
		_on_damage_taken_authority(amount, type, attacker)
		if amount >= health:
			_death_push = Combat.damage_force(self, amount, attacker)
		apply_damage_raw(amount, attacker, type)
	else:
		# Remote client path: damage is applied via RPC (apply_damage_raw)
		pass


## Virtual method for authority-side damage effects (syncing to owner).
func _on_damage_taken_authority(_amount: float, _type: int, _attacker: Node3D) -> void:
	pass


## `type` is what landed the killing blow and `damage` is how big it was — the death handlers
## read both to decide what the body leaves behind (GameConsts.damage_gibs). A death that isn't an
## injury (a force-kill, a class change) passes no damage and leaves an ordinary corpse.
func die(attacker: Node3D = null, type: int = GameConsts.DamageType.PHYSICAL,
		damage: float = 0.0) -> void:
	if is_dead:
		return
	is_dead = true
	# Marks the spawn-damage grace active for a normal death too (not just
	# die_for_class_change) — otherwise a body reviving in the lava it died in gets
	# re-hit on the first frame. Cleared by _schedule_respawn_clear at spawn.
	is_respawning = true
	health = 0.0

	# Explicit clear so status visuals don't stay stuck above the puppet through
	# respawn — StatusLogic.tick silently purges dead targets without emitting one.
	if NetworkManager.is_authority():
		StatusSystem.clear_all(self)

	_cleanup_on_death()
	_on_died(attacker, type, damage)
	_death_push = Vector3.ZERO


func _cleanup_on_death() -> void:
	if is_bear:
		_revert_bear_form()

	if is_dragon_mounted:
		dismount_dragon()

	_stop_all_attacks()
	fire.clear()
	_drop_all_items()

	# A primed-but-unthrown satchel drops at the body and keeps ticking (server
	# spawns the entity; clients receive it via the replication spawner).
	if NetworkManager.is_authority():
		satchel_pack.drop_on_death()

	# Beanstalks and thornplants intentionally survive player death.
	# They are only destroyed on class change (cleanup_for_class_change).


## Virtual method for subclass-specific death logic.
func _on_died(_attacker: Node3D, _type: int = GameConsts.DamageType.PHYSICAL,
		_damage: float = 0.0) -> void:
	pass


## What the body leaves moving at: the wizard's own velocity plus the killing blow's shove, and
## then CBasePlayer::Killed's hop — anything not already rising is tossed up 0-300 u/s.
func corpse_velocity(body_velocity: Vector3) -> Vector3:
	var v := body_velocity + _death_push
	if v.y < DEATH_HOP_BELOW:
		v.y += randf_range(0.0, DEATH_HOP_MAX)
	return v


## The other half of what a death leaves is GameConsts.damage_gibs, which is not a player's
## question: a gibbed wizard leaves no corpse at all, so Grimfeast and Raise Dead have nothing
## to take.
static func death_type_leaves_corpse(type: int) -> bool:
	return type != GameConsts.DamageType.RAISING


func _revert_bear_form() -> void:
	is_bear = false
	_bear_mana_drain_timer = 0.0


func _tick_bear_mana_drain(delta: float) -> void:
	if not is_bear or not NetworkManager.is_authority() or is_dead:
		return
	_bear_mana_drain_timer += delta
	if _bear_mana_drain_timer < BEAR_DRAIN_INTERVAL:
		return
	_bear_mana_drain_timer -= BEAR_DRAIN_INTERVAL
	mana = maxf(mana - BEAR_DRAIN_AMOUNT, 0.0)
	if mana <= 0.0:
		_on_bear_mana_empty()
		return
	_on_bear_drain_tick()


func _on_bear_drain_tick() -> void:
	pass


func _on_bear_mana_empty() -> void:
	pass

func _stop_all_attacks() -> void:
	for w in weapons:
		w.stop_firing(self)
	mana_drain_active = false
	fire.reset()

func _drop_all_items() -> void:
	if NetworkManager.is_authority():
		for item in carried_items.duplicate():
			if is_instance_valid(item) and item.has_method("goal_drop"):
				item.goal_drop(self)
	carried_items.clear()


func reset_for_spawn(new_element: int = -1, reload_loadout: bool = true, dismount: bool = true) -> void:
	## Reset class/resource state common to normal respawn, forced respawn, and
	## class changes. Spawn placement and collision timing stay with callers.
	if dismount:
		dismount_dragon()
	else:
		_mounted_dragon = null
		_dragon_entity_id = -1
	is_bear = false
	_bear_mana_drain_timer = 0.0
	is_invisible = false
	_invis_alpha = 1.0
	if new_element >= 0:
		element = new_element
	var wizard := Wizard.create(element)
	max_health = wizard.max_health
	health = max_health
	mana = max_mana
	satchel_pack.refill()
	speed_multiplier = wizard.speed_multiplier
	current_weapon_idx = 0
	granted_weapons.clear()
	combo_hits = 0
	if reload_loadout:
		_apply_spawn_loadout(wizard)


## Virtual method for subclass-specific model/weapon refresh at spawn time.
func _apply_spawn_loadout(wizard: Wizard) -> void:
	weapons = with_granted(wizard.weapons)


func spawn_at(sp: Node, new_element: int = -1, dismount: bool = true, apply_effects: bool = true) -> void:
	## Execute the common spawn transaction. Callers still choose which spawn
	## point to use.
	if NetworkManager.is_authority():
		StatusSystem.clear_all(self)
	reset_for_spawn(new_element, true, dismount)
	_on_spawn_state_reset()
	_move_to_spawn_point(sp)
	_on_spawn_transform_applied()
	is_dead = false
	_enable_after_spawn()
	if NetworkManager.is_authority():
		_activate_spawn_items(sp)
		if apply_effects:
			_apply_spawn_point_effects(sp)
	_schedule_respawn_clear()


func spawn_at_transform(pos: Vector3, yaw: float, new_element: int = -1, dismount: bool = true) -> void:
	## Client-side spawn confirmation path when only a networked transform is
	## available, not the source spawn entity.
	reset_for_spawn(new_element, true, dismount)
	_on_spawn_state_reset()
	velocity = Vector3.ZERO
	global_position = pos
	rotation.y = yaw
	gravity_scale = 1.0
	_on_spawn_transform_applied()
	is_dead = false
	_enable_after_spawn()
	_schedule_respawn_clear()


func sync_spawn_to_network(sp: Node, send_owner_spawn: bool = true, send_mana: bool = true, broadcast_respawn: bool = true) -> void:
	if not NetworkManager.is_authority():
		return
	if NetworkManager.is_peer_connected(peer_id):
		# Owner-directed messages — bots (negative ids, never "connected") have no owner.
		if send_owner_spawn and is_instance_valid(sp):
			NetworkManager.send_to_owner(peer_id, &"assign_spawn",
				[sp.get_spawn_position(), sp.rotation.y, team, element])
		if send_mana:
			NetworkManager.sync_mana_to_owner(self)
	if broadcast_respawn:
		# ALL players including bots: clients reset the puppet on this (re-enable its
		# collision shape, clear death leftovers). Gating it on is_peer_connected left
		# client-side bot puppets collision-disabled after their first death.
		NetworkManager.sync_player_respawn.rpc(peer_id)


func _on_spawn_state_reset() -> void:
	pass


func _move_to_spawn_point(sp: Node) -> void:
	if not is_instance_valid(sp):
		return
	velocity = Vector3.ZERO
	global_position = sp.get_spawn_position()
	rotation.y = sp.rotation.y
	gravity_scale = 1.0


## Single gate on "damageable" membership: a host view (has_body_puppet) never
## joins, however many times spawn/spectate toggles ask.
func set_damageable(enabled: bool) -> void:
	if enabled and not has_body_puppet:
		if not is_in_group("damageable"):
			add_to_group("damageable")
	elif is_in_group("damageable"):
		remove_from_group("damageable")


func _enable_after_spawn() -> void:
	var shape := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if shape:
		shape.disabled = false
	set_damageable(true)
	visible = true


func _on_spawn_transform_applied() -> void:
	pass


func _activate_spawn_items(sp: Node) -> void:
	if not is_instance_valid(sp):
		return
	var item_id: int = int(sp.get("items"))
	if item_id == 0:
		return
	var item := GoalSystem.get_goal(item_id)
	if item and item.has_method("goal_activate"):
		item.goal_activate(self)


func _schedule_respawn_clear() -> void:
	get_tree().create_timer(0.1).timeout.connect(func(): is_respawning = false)


# --- Dragon Mounting ---

func mount_dragon(dragon: Node) -> void:
	if _mounted_dragon == dragon or not is_instance_valid(dragon):
		return
	
	if is_dragon_mounted:
		dismount_dragon()
	
	_mounted_dragon = dragon
	_dragon_entity_id = dragon.entity_id

	# Only the server-side player object, not plain is_authority() — the host's
	# LocalPlayer view also passes that and would re-broadcast a mount already confirmed.
	if _is_server_player():
		_on_dragon_mount_authority(dragon)
		# Offline there's nobody to broadcast to, and call_local would re-run
		# on_dragon_mount_confirmed — the local setup above already did it.
		if NetworkManager.is_online():
			NetworkManager.sync_dragon_mount.rpc(peer_id, dragon.entity_id, true)


func dismount_dragon() -> void:
	if not is_dragon_mounted:
		return
	
	var dragon = _mounted_dragon
	if not is_instance_valid(dragon) and _dragon_entity_id != -1:
		dragon = NetworkManager.get_synced_entity(_dragon_entity_id)
	
	_mounted_dragon = null
	_dragon_entity_id = -1

	# Same guard as mount_dragon: the host's view clearing its mount state must not
	# re-broadcast or kill the dragon — its body puppet already ran this branch.
	if _is_server_player():
		_on_dragon_dismount_authority(dragon)
		if NetworkManager.is_online():
			NetworkManager.sync_dragon_mount.rpc(peer_id, -1, false)
		# Dragons always die when dismounted (authority only)
		if is_instance_valid(dragon):
			dragon.take_damage(Dragon.MAX_HEALTH * 2)


## Virtual method for authority-side mount effects.
func _on_dragon_mount_authority(_dragon: Node) -> void:
	pass

## Virtual method for authority-side dismount effects.
func _on_dragon_dismount_authority(_dragon: Node) -> void:
	pass


func _apply_spawn_point_effects(sp: Node) -> void:
	_try_mount_spawn_dragon(sp)


func _try_mount_spawn_dragon(sp: Node) -> void:
	if not is_instance_valid(sp) or not sp.has_method("spawn_dragon_for_rider"):
		return
	var dragon = sp.spawn_dragon_for_rider()
	if is_instance_valid(dragon):
		dragon.trigger(self)


func cleanup_for_class_change() -> void:
	_drop_all_items()
	_stop_all_attacks()
	if NetworkManager.is_authority():
		StatusSystem.clear_all(self)
	
	if is_bear:
		_revert_bear_form()

	if is_dragon_mounted:
		dismount_dragon()

	plants.remove_all()


## Send full player state to a specific peer (late-join sync).
## Called by NetworkManager.request_player_states() — add any new per-player
## state here rather than teaching network_manager about it.
func sync_state_to_peer(target_peer_id: int) -> void:
	if is_bear:
		NetworkManager.sync_bear_morph.rpc_id(target_peer_id, peer_id, true, health, max_health)
	if is_instance_valid(_mounted_dragon):
		NetworkManager.sync_dragon_mount.rpc_id(target_peer_id, peer_id, _mounted_dragon.entity_id, true)
	elif _dragon_entity_id != -1:
		NetworkManager.sync_dragon_mount.rpc_id(target_peer_id, peer_id, _dragon_entity_id, true)
	for key in granted_weapons:
		NetworkManager.sync_grant_weapon.rpc_id(target_peer_id, peer_id, key)

func _add_carried_item(item: Node) -> void:
	if item not in carried_items:
		carried_items.append(item)

func _remove_carried_item(item: Node) -> void:
	carried_items.erase(item)


# "Call for help" — WW's version of TFC's medic call. The arrow pops over the caller's head and
# they shout for a heal; a poisoned caller retches instead, which tells a teammate to bring a cure
# rather than a life ray.
#
# The original swapped the arrow for the yuck sprite when poisoned, because GoldSrc WW drew no
# other icon: the sprite was the only way to see the poison. Here poison already shows its own
# icon, over the head and in the caller's status strip, so swapping would just draw it twice and
# lose the "I am calling" half of the message. The voice line carries the distinction instead.
const HELP_CALL_COOLDOWN := 6.0
const HELP_SPRITE := "sprites/icons/arrow.spr"
const HELP_SOUNDS: Array[String] = ["player/health1.wav", "player/health2.wav", "player/health3.wav"]
const HELP_POISON_SOUNDS: Array[String] = ["player/poison1.wav", "player/poison2.wav"]


## Server: call for help. Returns [sprite_path, sound_path] for the caller's peers to play,
## or an empty array when the call is refused (dead, a bear, or still on cooldown).
func call_for_help() -> Array:
	if is_dead or is_bear:
		return []
	var now := Time.get_ticks_msec() / 1000.0
	if now < _next_help_call:
		return []
	_next_help_call = now + HELP_CALL_COOLDOWN
	var poisoned := StatusSystem.has_status(self, GameConsts.StatusType.POISON)
	return [HELP_SPRITE, (HELP_POISON_SOUNDS if poisoned else HELP_SOUNDS).pick_random()]


## Server: drain mana while this player sustains a beam weapon. When mana runs
## out, force-stop the beam and reliably sync the empty state; otherwise sync the
## draining value on the throttled unreliable channel (newer values supersede, so
## a dropped update self-heals). Called each physics tick from the puppet.
func tick_mana_drain(delta: float) -> void:
	if not mana_drain_active:
		return
	if is_dead:
		mana_drain_active = false
		return
	var fired_weapon := last_fired_weapon()
	if fired_weapon == null or fired_weapon.mana_drain <= 0.0:
		mana_drain_active = false
		return
	mana = maxf(mana - fired_weapon.mana_drain * delta, 0.0)
	if mana <= 0.0:
		# Out of mana — force-stop. Reliable sync_mana so the "stop" is guaranteed.
		mana_drain_active = false
		end_sustained_fire(fired_weapon)
		NetworkManager.sync_mana_to_owner(self)
		# No-op today (end_sustained_fire already cleared PLAYER_FLAG_FIRING) but keeps
		# the stop path correct if a future discrete drain weapon needs it.
		NetworkManager.broadcast_stop_attack(peer_id, fired_weapon)
		return
	_mana_drain_sync_timer += delta
	if _mana_drain_sync_timer >= NetworkManager.NET_TICK_INTERVAL:
		_mana_drain_sync_timer -= NetworkManager.NET_TICK_INTERVAL
		NetworkManager.sync_mana_to_owner(self, false)


func _update_invis_alpha_common(delta: float, current_speed: float, models: Array[Node3D]) -> void:
	var target: float
	if is_invisible:
		var speed_ratio := clampf(current_speed / _INVIS_SPEED_REF, 0.0, 1.0)
		target = speed_ratio * _INVIS_MAX_VISIBLE_ALPHA
	else:
		target = 1.0
	
	var new_alpha := move_toward(_invis_alpha, target, _INVIS_FADE_RATE * delta)
	if new_alpha == _invis_alpha:
		return
	
	_invis_alpha = new_alpha
	for model in models:
		if is_instance_valid(model):
			AssetLoader.set_model_alpha(model, _invis_alpha)
