class_name TFGoalBase
extends EntityBase
# Shared TFC goal logic for item_tfgoal, i_t_g, and info_tfgoal.
# Ported from TFComponent.cpp (checkActivation, processGoals, processEffects).

enum GoalState { INACTIVE, ACTIVE, REMOVED }

const GOALSTATE_INACTIVE := GoalState.INACTIVE
const GOALSTATE_ACTIVE := GoalState.ACTIVE
const GOALSTATE_REMOVED := GoalState.REMOVED

# Activation flags (goal_activation / g_a)
const GA_PLAYER_TOUCH := 1              # TFGA_TOUCH — activated by a player touch
const GA_DETPACK_EXPLOSION := 2         # TFGA_EXPLOSION — activated by a detpack/fissure blast in range
const GA_DROP_ON_DEATH := 4
const GA_RETURN_ON_DEATH_DROP := 8
const GA_RETURN_IF_REMOVE_BY_GOAL := 16
const GA_RETURN_AFTER_PAUSE_REMOVE := 32
const GA_IF_AP_FAILS_CRITERIA := 64
const GA_REMOVE_AFTER_PAUSE := 128
const GA_KEEP_ITEM_WHEN_PLAYER_DIES := 256
const GA_GLOWS_WHEN_NOT_CARRIED := 512
const GA_PLAYER_KEEPS_EFFECTS := 1024
const GA_DROP_MODEL_ON_SPAWN := 2048
const GA_IS_DROPPABLE := 4096
const GA_IS_SOLID := 8192

# Effect flags (goal_effects / g_e)
const GE_AP := 1                       # affect activating player
const GE_AP_TEAM := 2                  # affect AP's teammates
const GE_AP_NONTEAM := 4              # affect AP's opposing team
const GE_NONAP := 8                   # affect everyone except AP
const GE_EVERYONE := 16               # affect all players
const GE_SAME_ENVIRONMENT := 32       # affect all in the goal's environment (water vs air)
const GE_CHECK_APA_INDIVIDUALLY := 64

# Result flags (goal_result / g_r), from TFCGOAL_RESULT_* in tfcentities.h. Only these
# six exist; other bits appear on shipped maps but are undefined/inert in the original too.
const GR_REMOVE_IMMEDIATELY := 1   # TFCGOAL_RESULT_SINGLE — RemoveGoal() after firing
const GR_ENDGAME := 4              # ends the match (see below — no match-end path yet)
const GR_RESET_SPY := 16           # clears an Ice wizard's disguise (no disguise system yet)
const GR_FORCE_RESPAWN_NO_DIE := 32
const GR_DESTROY_PLANTS := 64      # kills every thornbush/beanstalk in the world
const GR_ITEM_GLOWS := 512         # defined in the original but never read there either

# --- Parsed properties ---
var goal_no: int = 0
var group_no: int = 0
var goal_state: int = GoalState.INACTIVE
var owned_by: int = 0           # owned_by
var req_team: int = 0        # team_no (required team)
var goal_activation: int = 0 # g_a
var goal_effects: int = 0    # g_e
var goal_results: int = 0    # g_r
var target_key: String = ""

# Timing
var delay_time: float = 0.0
var stay_active: float = 0.0   # wait
var pause_time: float = 0.0
var active_time: float = 0.0   # cooldown between activations

# Cascading goal operations
var goal_to_activate: int = 0
var goal_to_inactivate: int = 0
var goal_to_remove: int = 0
var goal_to_restore: int = 0
var group_to_activate: int = 0
var group_to_inactivate: int = 0
var group_to_remove: int = 0
var group_to_restore: int = 0

# Item operations
var item_to_give: int = 0
var item_to_remove: int = 0
var item_to_return: int = 0
var item_group_to_remove: int = 0

# Spawn operations
var spawn_to_remove: int = 0
var spawn_to_restore: int = 0
var spawn_group_to_remove: int = 0
var spawn_group_to_restore: int = 0

# Criteria
var item_is_needed: int = 0       # items_allowed
var item_from_group: int = 0      # h_i_g
var item_from_not_group: int = 0  # n_i_g
var item_has_moved: int = 0
var item_not_has_moved: int = 0
var goal_is_active: int = 0
var goal_is_inactive: int = 0
var goal_is_removed: int = 0
var group_is_active: int = 0
var group_is_inactive: int = 0
var group_is_removed: int = 0
var else_goal: int = 0

# Conditional triggers
var all_active: int = 0         # if all in group N active
var all_active_goal: int = 0    # then activate goal N (last_impulse)
var all_carried: int = 0        # distance
var all_carried_goal: int = 0   # pain_finished
var goal_on_return: int = 0     # impulse

# Scoring
var team_score: int = 0         # count (APA team)
var team_scores: Array[int] = [0, 0, 0, 0, 0]  # increase_team, increase_team1..4

# Shared activation state (used by info_tfgoal and item_tfgoal)
var _last_activate_time: float = 0.0
var _activate_pending_time: float = 0.0
var _activator: Node = null

# Messages (just stored, printed on activation for now)
var msg_broadcast: String = ""
var msg_ap: String = ""
var msg_team: String = ""
var msg_nonteam: String = ""
var msg_owner: String = ""
# TFC noise3/noise4: shown on auto-return to spawn (noise3 = flag's own team, noise4 =
# others). Presence marks a returnable flag vs. an incidental goalitem that returns silently.
var msg_return_team: String = ""    # noise3
var msg_return_nonteam: String = ""  # noise4

# Player effects
var heal_amount: int = 0       # health to give activating player (from health / ammo_medikit)
var mana_amount: int = 0       # mana to give activating player (from any TFC ammo type)
var satchel_amount: int = 0    # satchels to give activating player (from no_grenades_1/2)
var invincible_time: float = 0.0  # invincible_finished — seconds of invulnerability
var frags_amount: int = 0      # frags — personal score for each affected player
var noise: String = ""         # sound to play on activation

# Spoken sentences (TFC "speak" keys — word streams or "!NAME" sentences),
# tiered like the msg_* broadcasts: AP > team/owner > non-team > everyone.
var spk_ap: String = ""        # AP_speak
var spk_team: String = ""      # team_speak
var spk_nonteam: String = ""   # non_team_speak
var spk_owner: String = ""     # owners_team_speak
var spk_all: String = ""       # speak


func _exit_tree() -> void:
	pass  # items get reparented — cleanup is in NOTIFICATION_PREDELETE


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		GoalSystem.unregister(self)
		var targetname: String = ent.get("targetname", "")
		if not targetname.is_empty():
			TriggerSystem.unregister(targetname, self)


static func _get_team(node: Node) -> int:
	return node.team if node and "team" in node else 0


func _parse_tf_properties(p_ent: Dictionary) -> void:
	ent = p_ent
	goal_no = parse_int(ent, "goal_no", 0)
	group_no = parse_int(ent, "group_no", 0)
	owned_by = parse_int(ent, "owned_by", 0)
	req_team = parse_int(ent, "team_no", 0)
	goal_activation = parse_int(ent, "goal_activation", 0)
	if goal_activation == 0:
		goal_activation = parse_int(ent, "g_a", 0)
	goal_effects = parse_int(ent, "goal_effects", 0)
	if goal_effects == 0:
		goal_effects = parse_int(ent, "g_e", 0)
	goal_results = parse_int(ent, "goal_result", 0)
	if goal_results == 0:
		goal_results = parse_int(ent, "g_r", 0)
	target_key = ent.get("target", "")

	# Initial state: 1=active, 2=inactive, 3=removed (default=inactive)
	var gs := parse_int(ent, "goal_state", 2)
	match gs:
		1: goal_state = GoalState.ACTIVE
		3: goal_state = GoalState.REMOVED
		_: goal_state = GoalState.INACTIVE

	# Timing
	delay_time = parse_float(ent, "delay_time", 0.0)
	stay_active = parse_float(ent, "wait", 0.0)
	pause_time = parse_float(ent, "pausetime", 0.0)
	active_time = parse_float(ent, "active_time", 0.0)

	# Cascading goals
	goal_to_activate = parse_int(ent, "activate_goal_no", 0)
	goal_to_inactivate = parse_int(ent, "inactivate_goal_no", 0)
	goal_to_remove = _parse_int_multi(ent, ["remove_goal_no", "rv_g"])
	goal_to_restore = _parse_int_multi(ent, ["restore_goal_no", "rs_g"])
	group_to_activate = parse_int(ent, "activate_group_no", 0)
	group_to_inactivate = parse_int(ent, "inactivate_group_no", 0)
	group_to_remove = _parse_int_multi(ent, ["remove_group_no", "rv_gr"])
	group_to_restore = _parse_int_multi(ent, ["restore_group_no", "rs_gr"])

	# Item operations
	item_to_give = parse_int(ent, "items", 0)
	item_to_remove = parse_int(ent, "axhitme", 0)
	item_to_return = parse_int(ent, "return_item_no", 0)
	item_group_to_remove = _parse_int_multi(ent, ["remove_item_group", "r_i_g"])

	# Spawn operations
	spawn_to_remove = _parse_int_multi(ent, ["remove_spawnpoint", "rv_s"])
	spawn_to_restore = _parse_int_multi(ent, ["restore_spawnpoint", "rs_s"])
	spawn_group_to_remove = _parse_int_multi(ent, ["remove_spawngroup", "rv_s_h"])
	spawn_group_to_restore = _parse_int_multi(ent, ["restore_spawngroup", "rs_s_h"])

	# Criteria
	item_is_needed = parse_int(ent, "items_allowed", 0)
	item_from_group = _parse_int_multi(ent, ["has_item_from_group", "h_i_g"])
	item_from_not_group = _parse_int_multi(ent, ["hasnt_item_from_group", "n_i_g"])
	item_has_moved = parse_int(ent, "if_item_has_moved", 0)
	item_not_has_moved = parse_int(ent, "if_item_hasnt_moved", 0)
	goal_is_active = parse_int(ent, "if_goal_is_active", 0)
	goal_is_inactive = parse_int(ent, "if_goal_is_inactive", 0)
	goal_is_removed = parse_int(ent, "if_goal_is_removed", 0)
	group_is_active = parse_int(ent, "if_group_is_active", 0)
	group_is_inactive = parse_int(ent, "if_group_is_inactive", 0)
	group_is_removed = parse_int(ent, "if_group_is_removed", 0)
	else_goal = parse_int(ent, "else_goal", 0)

	# Conditional triggers
	all_active = parse_int(ent, "all_active", 0)
	all_active_goal = parse_int(ent, "last_impulse", 0)
	all_carried = parse_int(ent, "distance", 0)
	all_carried_goal = parse_int(ent, "pain_finished", 0)
	goal_on_return = parse_int(ent, "impulse", 0)

	# Scoring
	team_score = parse_int(ent, "count", 0)
	team_scores[0] = parse_int(ent, "increase_team", 0)
	team_scores[1] = parse_int(ent, "increase_team1", 0)
	team_scores[2] = parse_int(ent, "increase_team2", 0)
	team_scores[3] = parse_int(ent, "increase_team3", 0)
	team_scores[4] = parse_int(ent, "increase_team4", 0)

	# Player effects — both "health" and "ammo_medikit" heal the activating player
	var _ent_health := parse_int(ent, "health", 0)
	var _ent_medikit := parse_int(ent, "ammo_medikit", 0)
	heal_amount = _ent_health + _ent_medikit
	# TFC ammo types (shells/nails/cells/rockets) map to mana; hand grenades
	# (no_grenades_1/2) map to satchels.
	var _shells := parse_int(ent, "ammo_shells", 0)
	var _nails := parse_int(ent, "ammo_nails", 0)
	var _cells := parse_int(ent, "ammo_cells", 0)
	var _rockets := _parse_int_multi(ent, ["ammo_rockets", "a_r"])
	mana_amount = _shells + _nails + _cells + _rockets
	satchel_amount = parse_int(ent, "no_grenades_1", 0) + parse_int(ent, "no_grenades_2", 0)
	# Load-bearing on ww_roc2: the 11s grant here outlasts the 10s-delayed death
	# cloud so the capturer survives it.
	invincible_time = parse_float(ent, "invincible_finished", 0.0)
	frags_amount = parse_int(ent, "frags", 0)
	noise = ent.get("noise", "")
	spk_ap = ent.get("AP_speak", "")
	spk_team = ent.get("team_speak", "")
	spk_nonteam = ent.get("non_team_speak", "")
	spk_owner = ent.get("owners_team_speak", "")
	spk_all = ent.get("speak", "")

	# TFC backpack default: pickups with no explicit activation/effect flags are
	# implicitly touch-activated and affect the activating player.
	var has_pickup_effects := heal_amount != 0 or mana_amount != 0 or satchel_amount != 0
	if has_pickup_effects and goal_activation == 0:
		goal_activation = GA_PLAYER_TOUCH
	if has_pickup_effects and goal_effects == 0:
		goal_effects = GE_AP

	# Messages
	msg_broadcast = _get_msg(ent, ["broadcast", "b_b", "netname_broadcast", "n_b"])
	msg_ap = ent.get("message", "")
	msg_team = _get_msg(ent, ["team_broadcast", "b_t", "netname_team_broadcast", "n_t"])
	msg_nonteam = _get_msg(ent, ["non_team_broadcast", "b_n", "netname_non_team_broadcast", "n_n"])
	msg_owner = _get_msg(ent, ["owners_team_broadcast", "b_o", "netname_owners_team_broadcast", "n_o"])
	msg_return_team = ent.get("noise3", "")
	msg_return_nonteam = ent.get("noise4", "")

	GoalSystem.register(self, goal_no, group_no)

	var targetname: String = ent.get("targetname", "")
	if targetname.is_empty() and goal_no != 0:
		targetname = "_goal_%d" % goal_no  # auto-generate for goals with no targetname
		ent["targetname"] = targetname
	if not targetname.is_empty():
		TriggerSystem.register(targetname, self)


# --- Activation criteria check (TFComponent::checkActivation) ---

func check_activation(player: Node) -> bool:
	var passed := _check_criteria(player)
	if goal_activation & GA_IF_AP_FAILS_CRITERIA:
		# GA_IF_AP_FAILS_CRITERIA: invert the overall result (HL behavior)
		if passed:
			Log.debug("%d: criteria passed but reversed (GA_IF_AP_FAILS_CRITERIA)" % goal_no, "tfgoal")
		return not passed
	return passed


func _check_criteria(player: Node) -> bool:
	# Team check
	if player and req_team != 0:
		var player_team: int = _get_team(player)
		if player_team != req_team:
			Log.info("%d: criteria failed: team %d != required %d" % [goal_no, player_team, req_team], "tfgoal")
			return false

	# Goal state criteria
	if goal_is_active != 0:
		var g := GoalSystem.get_goal(goal_is_active)
		if not g or g.goal_state != GoalState.ACTIVE:
			Log.info("%d: criteria failed: if_goal_is_active=%d (goal %s, state=%d, need ACTIVE=1)" % [
				goal_no, goal_is_active, "exists" if g else "NULL", g.goal_state if g else -1], "tfgoal")
			return false

	if goal_is_inactive != 0:
		var g := GoalSystem.get_goal(goal_is_inactive)
		if not g or g.goal_state != GoalState.INACTIVE:
			Log.info("%d: criteria failed: if_goal_is_inactive=%d (goal %s, state=%d, need INACTIVE=0)" % [
				goal_no, goal_is_inactive, "exists" if g else "NULL", g.goal_state if g else -1], "tfgoal")
			return false

	if goal_is_removed != 0:
		var g := GoalSystem.get_goal(goal_is_removed)
		if not g or g.goal_state != GoalState.REMOVED:
			Log.info("%d: criteria failed: if_goal_is_removed=%d (goal %s, state=%d, need REMOVED=2)" % [
				goal_no, goal_is_removed, "exists" if g else "NULL", g.goal_state if g else -1], "tfgoal")
			return false

	# Group state criteria (ALL in group must match)
	if group_is_active != 0:
		for g in GoalSystem.get_group(group_is_active):
			if g.goal_state != GoalState.ACTIVE:
				return false

	if group_is_inactive != 0:
		for g in GoalSystem.get_group(group_is_inactive):
			if g.goal_state != GoalState.INACTIVE:
				return false

	if group_is_removed != 0:
		for g in GoalSystem.get_group(group_is_removed):
			if g.goal_state != GoalState.REMOVED:
				return false

	# Item checks (player must be carrying specific item)
	if item_is_needed != 0:
		var item := GoalSystem.get_goal(item_is_needed)
		if not item or not item.has_method("get_carrier") or item.get_carrier() != player:
			Log.info("%d: criteria failed: need item %d (found=%s, carrier=%s, player=%s)" % [
				goal_no, item_is_needed,
				str(item.name) if item else "null",
				item.get_carrier().name if item and item.has_method("get_carrier") and item.get_carrier() else "null",
				str(player.name) if player else "null"], "tfgoal")
			return false

	# Item from group check
	if item_from_group != 0:
		var found := false
		for g in GoalSystem.get_group(item_from_group):
			if g.has_method("get_carrier") and g.get_carrier() == player:
				found = true
				break
		if not found:
			# cz2: also pass if item_to_give is itself in the required group
			if item_to_give != 0:
				var give_item := GoalSystem.get_goal(item_to_give)
				if give_item and give_item.group_no == item_from_group:
					found = true
			if not found:
				Log.info("%d: criteria failed: h_i_g=%d (player not carrying item from group)" % [goal_no, item_from_group], "tfgoal")
				return false

	# Item NOT from group check
	if item_from_not_group != 0:
		for g in GoalSystem.get_group(item_from_not_group):
			if g.has_method("get_carrier") and g.get_carrier() == player:
				return false

	# Item moved checks
	if item_has_moved != 0:
		var item := GoalSystem.get_goal(item_has_moved)
		if not item or not item.has_method("is_moved") or not item.is_moved():
			return false

	if item_not_has_moved != 0:
		var item := GoalSystem.get_goal(item_not_has_moved)
		if not item or not item.has_method("is_moved") or item.is_moved():
			return false

	return true


# --- Process cascading goals (TFComponent::processGoals) ---

func process_goals(player: Node) -> void:
	# The activating player rides into every cascaded op, matching the original's
	# DoGoalWork/DoGroupWork(pActivator); no result bit strips it.
	var mod: Node = player

	_apply_goal_op(goal_to_activate, mod, "activate")
	_apply_goal_op(goal_to_inactivate, mod, "inactivate")
	_apply_goal_op(goal_to_remove, mod, "remove")
	_apply_goal_op(goal_to_restore, mod, "restore")

	# Group operations
	_apply_group_op(group_to_activate, mod, "activate")
	_apply_group_op(group_to_inactivate, mod, "inactivate")
	_apply_group_op(group_to_remove, mod, "remove")
	_apply_group_op(group_to_restore, mod, "restore")

	# Item operations
	_apply_item_op(item_to_give, mod, "activate")
	_apply_item_op(item_to_remove, mod, "remove")
	if item_to_return != 0:
		var g := GoalSystem.get_goal(item_to_return)
		if g:
			g.goal_return(mod)
	if item_group_to_remove != 0:
		for g in GoalSystem.get_group(item_group_to_remove):
			if g.has_method("get_carrier"):
				g.goal_remove(mod)

	# Spawn operations
	if spawn_to_remove != 0:
		SpawnSystem.remove_spawn(spawn_to_remove)
	if spawn_to_restore != 0:
		SpawnSystem.restore_spawn(spawn_to_restore)
	if spawn_group_to_remove != 0:
		SpawnSystem.remove_group(spawn_group_to_remove)
	if spawn_group_to_restore != 0:
		SpawnSystem.restore_group(spawn_group_to_restore)

	process_effects(player)

	if not target_key.is_empty():
		TriggerSystem.fire(target_key, player, TriggerSystem.Type.TOGGLE)

	_check_all_conditions(player)

	if goal_results & GR_REMOVE_IMMEDIATELY:
		goal_remove(null)


# --- Process effects (TFComponent::processEffects) ---

func process_effects(player: Node) -> void:
	# Team scoring
	var spoken := speak_coverage()
	for t in range(1, 5):
		if team_scores[t] != 0:
			GoalSystem.add_score(t, team_scores[t], spoken)
	if team_scores[0] != 0 and player:
		# increase_team goes to APA's team (overloaded)
		var pt: int = _get_team(player)
		if pt > 0:
			GoalSystem.add_score(pt, team_scores[0], spoken)
	if team_score != 0 and player:
		var pt: int = _get_team(player)
		if pt > 0:
			GoalSystem.add_score(pt, team_score, spoken)

	_apply_player_effects(player)

	if goal_results & GR_FORCE_RESPAWN_NO_DIE:
		_apply_force_respawn(player)

	# World-level result: fires once regardless of who activated (outside AffectPlayer in the original).
	if goal_results & GR_DESTROY_PLANTS:
		# Plants are owned per-player here, so clearing each player's pair covers the
		# original's "every thornbush/beanstalk edict" sweep.
		PlantBehavior.remove_all_everywhere()

	if not noise.is_empty() and player is Node3D:
		SoundSystem.play_3d(noise, player.global_position)

	_show_goal_messages(player)


func _apply_player_effects(ap: Node) -> void:
	if heal_amount == 0 and mana_amount == 0 and satchel_amount == 0 \
			and invincible_time <= 0.0 and frags_amount == 0:
		return
	var ap_team: int = _get_team(ap)

	# GE_AP: activating player only
	if goal_effects & GE_AP and ap:
		_apply_effects_to(ap)
		_apply_mana_and_satchels(ap)

	# Flags that target multiple players
	var multi_flags := GE_AP_TEAM | GE_AP_NONTEAM | GE_NONAP | GE_EVERYONE | GE_SAME_ENVIRONMENT
	if not (goal_effects & multi_flags):
		return

	# The goal's own environment never changes across the loop — query it once.
	var goal_in_water := _is_point_in_water(global_position) if goal_effects & GE_SAME_ENVIRONMENT else false

	for p in get_tree().get_nodes_in_group("damageable"):
		if not (p.has_method("heal") or p.has_method("take_damage")):
			continue
		var pt: int = p.team if "team" in p else 0
		var is_ap := (p == ap)
		if goal_effects & GE_SAME_ENVIRONMENT:
			# Matches original IsAffectedBy's pointcontents check — e.g. diving
			# underwater shields a player from the in-air roc2 death cloud.
			if (req_team == 0 or pt == req_team) and _in_same_environment(p, goal_in_water):
				_apply_effects_to(p)
		elif goal_effects & GE_EVERYONE:
			_apply_effects_to(p)
		elif goal_effects & GE_AP_TEAM and pt == ap_team and not is_ap:
			_apply_effects_to(p)
		elif goal_effects & GE_AP_NONTEAM and pt != ap_team and pt > 0:
			_apply_effects_to(p)
		elif goal_effects & GE_NONAP and not is_ap:
			_apply_effects_to(p)


## TFC TFGE_SAME_ENVIRONMENT: goal and player must both be in water or both
## out of it (reference IsAffectedBy compares pointcontents of the origins).
## `goal_in_water` is the goal's own status, precomputed once by the caller.
func _in_same_environment(p: Node, goal_in_water: bool) -> bool:
	var p3d := p as Node3D
	if not p3d:
		return true
	# +0.9 matches the player water detector's center (waist height on a
	# feet-origin CharacterBody3D); the goal origin is used as-is.
	return goal_in_water == _is_point_in_water(p3d.global_position + Vector3.UP * 0.9)


# Overridable seam (a test stub swaps this for a deterministic check).
func _is_point_in_water(pos: Vector3) -> bool:
	return SpatialQuery.is_point_in_water(self, pos)


## Heal/damage, timed invulnerability, and personal score for one affected player.
func _apply_effects_to(target: Node) -> void:
	if heal_amount != 0:
		_apply_heal_or_damage(target, heal_amount)
	if invincible_time > 0.0 and "invincible_until" in target:
		target.invincible_until = Time.get_ticks_msec() / 1000.0 + invincible_time
	if frags_amount != 0 and "peer_id" in target:
		# Folds into the frag count and (on the host) broadcasts to clients.
		GoalSystem.add_player_points(int(target.peer_id), frags_amount)


func _apply_mana_and_satchels(target: Node) -> void:
	if mana_amount <= 0 and satchel_amount <= 0:
		return
	# Player.add_mana/add_satchels clamp and sync the new totals to the owner
	# (locally dispatched for the host body / offline).
	if not target.has_method("add_mana"):
		return
	if mana_amount > 0:
		target.add_mana(float(mana_amount))
	if satchel_amount > 0:
		if not _give_combo_spell(target):
			target.add_satchels(satchel_amount)


## Combo chaos turns a TFC resupply backpack's grenades into a combo spell, the same trade
## item_dm_pickup makes for a map's leftover guns. Unlike a spellbook on the ground this can't be
## left for someone else, so the roll skips what the toucher already carries rather than coming
## up empty. False when chaos is off or there is nothing left to hand over, and the caller falls
## back to satchels.
func _give_combo_spell(target: Node) -> bool:
	if not GoalSystem.is_combo_chaos() or not target.has_method("grant_weapon"):
		return false
	var held: Array = target.get("granted_weapons") if "granted_weapons" in target else []
	var key: String = SpawnRegistry.random_combo_weapon(held)
	return not key.is_empty() and target.grant_weapon(key)


func _apply_force_respawn(ap: Node) -> void:
	var ap_team: int = _get_team(ap)
	for p in get_tree().get_nodes_in_group("damageable"):
		var pt: int = p.team if "team" in p else 0
		var is_ap := (p == ap)
		var affected := false
		if goal_effects & GE_AP and is_ap:
			affected = true
		if goal_effects & GE_AP_TEAM and pt == ap_team and not is_ap:
			affected = true
		if goal_effects & GE_AP_NONTEAM and pt != ap_team and pt > 0:
			affected = true
		if goal_effects & GE_NONAP and not is_ap:
			affected = true
		if not affected:
			continue
		if p.has_method("_host_respawn"):
			p._host_respawn(true)
		# Goal-driven respawns (ww_monoliths) skip PotatoC's world clear, so a
		# live satchel needs removing explicitly.
		var pack := SatchelBehavior.of(p)
		if pack:
			pack.remove_live()


static func _apply_heal_or_damage(target: Node, amount: int) -> void:
	if amount < 0 and target.has_method("take_damage"):
		target.take_damage(float(-amount))
	elif amount > 0 and target.has_method("heal"):
		target.heal(float(amount))


# --- Goal messages → HUD center text ---

func _show_goal_messages(player: Node) -> void:
	var ap_team: int = _get_team(player)
	for r in _collect_message_recipients():
		var node: Node = r[0]
		var r_team: int = r[1]
		var pid: int = r[2]

		var is_ap := (node == player)
		var mt := _select_tier([msg_ap, msg_team, msg_owner, msg_nonteam, msg_broadcast], is_ap, r_team, ap_team)
		var text := ""
		var color := Color.WHITE
		var sound := true
		match mt:
			0:
				text = GoalMessages.translate(msg_ap)
				sound = false  # personal messages (backpack pickup, etc.) are silent
			1: text = GoalMessages.translate(msg_team)
			2: text = GoalMessages.translate(msg_owner)
			3: text = GoalMessages.translate(msg_nonteam)
			4: text = GoalMessages.translate(msg_broadcast)

		# TFC netname_* messages embed the activator's name ("%s escaped home!")
		if text.contains("%s"):
			text = text.replace("%s", _player_display_name(player))

		var st := _select_tier([spk_ap, spk_team, spk_owner, spk_nonteam, spk_all], is_ap, r_team, ap_team)
		var spk: String = [spk_ap, spk_team, spk_owner, spk_nonteam, spk_all][st] if st >= 0 else ""

		if text.is_empty() and spk.is_empty():
			continue

		if pid == 0:
			if not text.is_empty() and Game.hud:
				Game.hud.show_center_message(text, color, 3.0, sound)
			if not spk.is_empty():
				SentenceSystem.play_speak_global(spk)
		elif not _is_network_client():
			if not text.is_empty():
				NetworkManager.sync_hud_text.rpc_id(pid, text, NetworkManager.HUD_CENTER, color.r, color.g, color.b, 3.0, sound)
			if not spk.is_empty():
				SentenceSystem.play_speak_global.rpc_id(pid, spk)


## Gates the "flag returned" announcer so incidental goalitems (no noise3/4, e.g.
## the ww_hunt notepad) return silently, matching TFC.
func has_return_message() -> bool:
	return not msg_return_team.is_empty() or not msg_return_nonteam.is_empty()


## pid 0 means "deliver on this machine's own HUD" — the host's own server body
## (kept as the identity node so `node == player` still matches msg_ap), or the
## offline/pure-client LocalPlayer when no server body carries our id.
func _collect_message_recipients() -> Array:
	var recipients: Array = []
	var local_player = Game.local_player
	var own_id: int = multiplayer.get_unique_id()
	var have_own_body := false
	for puppet in get_tree().get_nodes_in_group("damageable"):
		if puppet == local_player:
			continue
		var pid = puppet.get("peer_id")
		if pid and pid > 0:
			recipients.append([puppet, puppet.get("team"), 0 if pid == own_id else pid])
			if pid == own_id:
				have_own_body = true
	if local_player and not have_own_body:
		recipients.append([local_player, local_player.team, 0])
	return recipients


## The flag's own team sees noise3, everyone else noise4. Guarded by
## has_return_message() at the call site.
func show_return_messages() -> void:
	var team_text := GoalMessages.translate(msg_return_team)
	var nonteam_text := GoalMessages.translate(msg_return_nonteam)
	# owned_by is the flag's own team; falling back to req_team (who may grab it,
	# often the enemy) keeps "your"/"enemy" wording sane when owned_by is unset.
	var flag_team := owned_by if owned_by > 0 else req_team
	for r in _collect_message_recipients():
		var r_team: int = r[1]
		var pid: int = r[2]
		var is_owner := r_team == flag_team
		var text: String = team_text if is_owner else nonteam_text
		if text.is_empty():
			continue
		if pid == 0:
			if Game.hud:
				Game.hud.show_center_message(text, Color.WHITE, 3.0, false)
		elif not _is_network_client():
			NetworkManager.sync_hud_text.rpc_id(pid, text, NetworkManager.HUD_CENTER, 1.0, 1.0, 1.0, 3.0, false)


## Most specific non-empty tier for a recipient, or -1. Tiers: 0=AP, 1=team,
## 2=owner, 3=non-team, 4=broadcast.
func _select_tier(tiers: Array, is_ap: bool, r_team: int, ap_team: int) -> int:
	if is_ap and not tiers[0].is_empty():
		return 0
	elif r_team == ap_team and not tiers[1].is_empty():
		return 1
	elif r_team == owned_by and owned_by > 0 and not tiers[2].is_empty():
		return 2
	elif r_team != ap_team and not tiers[3].is_empty():
		return 3
	elif not tiers[4].is_empty():
		return 4
	return -1


## Listener groups this goal already speaks to (GoalSystem.SPOKEN_* bits), so a score
## event can drop its generic stinger for anyone already hearing the map's own line.
## A group only counts covered if EVERY listener in it is covered.
func speak_coverage() -> int:
	var covered := 0
	if not spk_team.is_empty() or not spk_all.is_empty():
		covered |= GoalSystem.SPOKEN_FRIENDLY
	if not spk_nonteam.is_empty() or not spk_all.is_empty():
		covered |= GoalSystem.SPOKEN_ENEMY
	return covered


static func _player_display_name(p: Node) -> String:
	if p and "peer_id" in p and NetworkManager.has_player_name(p.peer_id):
		return NetworkManager.display_name(p.peer_id)
	return str(p.name) if p else "Someone"


# --- State transition virtuals (overridden by subclasses) ---

func goal_activate(_player: Node) -> void:
	goal_state = GoalState.ACTIVE

func goal_inactivate(_player: Node) -> void:
	goal_state = GoalState.INACTIVE

func goal_remove(_player: Node) -> void:
	goal_state = GoalState.REMOVED

func goal_restore(_player: Node) -> void:
	goal_state = GoalState.INACTIVE

func goal_return(_player: Node) -> void:
	pass


## Shared by info_tfgoal and item_tfgoal. False if blocked by state/cooldown/criteria.
func _try_activate(player: Node) -> bool:
	var time := Time.get_ticks_msec() / 1000.0

	if goal_state == GoalState.ACTIVE:
		Log.info("%d: blocked (already ACTIVE)" % goal_no, "tfgoal")
		return false
	if time < _last_activate_time + active_time and _last_activate_time > 0.0:
		Log.info("%d: blocked (cooldown)" % goal_no, "tfgoal")
		return false
	if _activate_pending_time != 0.0:
		Log.info("%d: blocked (pending)" % goal_no, "tfgoal")
		return false

	if not check_activation(player):
		if else_goal != 0:
			var eg := GoalSystem.get_goal(else_goal)
			if eg:
				eg.goal_activate(player)
		Log.info("%d: blocked (criteria failed)" % goal_no, "tfgoal")
		return false

	goal_state = GoalState.ACTIVE
	_activator = player
	_last_activate_time = time
	Log.info("%d: activate SUCCESS (player=%s)" % [goal_no, str(player.name) if player else "null"], "tfgoal")
	return true


# --- Goal operation helpers ---

func _apply_goal_op(id: int, mod: Node, op: String) -> void:
	if id == 0:
		return
	var g := GoalSystem.get_goal(id)
	if not g:
		Log.info("%d: goal_op: goal %d not found!" % [goal_no, id], "tfgoal")
		return
	Log.info("%d: goal_op: %s goal %d" % [goal_no, op, id], "tfgoal")
	match op:
		"activate": g.goal_activate(mod)
		"inactivate": g.goal_inactivate(mod)
		"remove": g.goal_remove(mod)
		"restore": g.goal_restore(mod)


func _apply_group_op(group_id: int, mod: Node, op: String) -> void:
	if group_id == 0:
		return
	for g in GoalSystem.get_group(group_id):
		match op:
			"activate": g.goal_activate(mod)
			"inactivate": g.goal_inactivate(mod)
			"remove": g.goal_remove(mod)
			"restore": g.goal_restore(mod)


func _apply_item_op(id: int, mod: Node, op: String) -> void:
	if id == 0:
		return
	var g := GoalSystem.get_goal(id)
	if not g or not g.has_method("get_carrier"):
		Log.info("%d: item_op: item %d not found or not carriable (found=%s)" % [goal_no, id, str(g != null)], "tfgoal")
		return
	Log.info("%d: item_op: %s item %d" % [goal_no, op, id], "tfgoal")
	match op:
		"activate": g.goal_activate(mod)
		"remove": g.goal_remove(mod)


# --- Helpers ---


func _check_all_conditions(player: Node) -> void:
	# all_active: if all goals in group N are active, activate goal M
	if all_active != 0 and all_active_goal != 0:
		var all_act := true
		for g in GoalSystem.get_group(all_active):
			if g.goal_state != GoalState.ACTIVE:
				all_act = false
				break
		if all_act:
			var target := GoalSystem.get_goal(all_active_goal)
			if target:
				target.goal_activate(player)

	# all_carried: if all items in group N are carried, activate goal M
	if all_carried != 0 and all_carried_goal != 0:
		var all_car := true
		for g in GoalSystem.get_group(all_carried):
			if not g.has_method("get_carrier") or g.get_carrier() == null:
				all_car = false
				break
		if all_car:
			var target := GoalSystem.get_goal(all_carried_goal)
			if target:
				target.goal_activate(player)


func _parse_int_multi(data: Dictionary, keys: Array) -> int:
	for key in keys:
		if data.has(key):
			return int(data[key])
	return 0


func _get_msg(data: Dictionary, keys: Array) -> String:
	for key in keys:
		if data.has(key):
			return str(data[key])
	return ""
