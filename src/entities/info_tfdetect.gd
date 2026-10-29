class_name InfoTFDetect
extends EntityBase
# info_tfdetect — TFC map configuration entity.
# Stores team names, player limits, class restrictions, and broadcast message.
# Required once per TFC map; parsed by GoalSystem for team configuration.

var number_of_teams: int = 2
var team_names: Array[String] = ["Blue", "Red", "", ""]
var team_lives: Array[int] = [-1, -1, -1, -1]
var team_max_players: Array[int] = [0, 0, 0, 0]
var class_restrictions: Array[int] = [0, 0, 0, 0]  # per-team class restriction bitmask
var broadcast_msg: String = ""


func _ready() -> void:
	super()

	# C++ behavior: multiple info_tfdetect/info_wwdetect entities accumulate into
	# a single TFGlobalInfo. Only set fields that are actually present in this entity.

	if ent.has("number_of_teams"):
		number_of_teams = parse_int(ent, "number_of_teams", 2)
		GoalSystem.team_count = number_of_teams

	# Only a team NAME declares a team. The per-team settings below do not: Worldcraft
	# writes every FGD key out at its 0 default, so "present" says nothing, and mappers
	# fill slots for teams that don't exist anyway (ww_chasm and ww_feudal set
	# team3_max/team4_max on 2-team maps; ww_countryside and ww_matrox restrict classes
	# on all four). Which teams are actually playable comes from the spawn points —
	# see GoalSystem.get_team_count.
	var name_keys := ["team1_name", "team2_name", "team3_name", "team4_name"]
	for i in range(4):
		if not ent.get(name_keys[i], "").is_empty():
			GoalSystem.team_names[i] = ent.get(name_keys[i])
			_declare_team(i)

	# Lives per round: ammo_shells=team1, ammo_nails=team2, etc.
	var life_keys := ["ammo_shells", "ammo_nails", "ammo_rockets", "ammo_cells"]
	for i in range(4):
		if ent.has(life_keys[i]):
			team_lives[i] = parse_int(ent, life_keys[i], -1)

	# Max players per team
	var maxp_keys := ["ammo_medikit", "ammo_detpack", "maxammo_medikit", "maxammo_detpack"]
	for i in range(4):
		if ent.has(maxp_keys[i]):
			GoalSystem.team_max_players[i] = parse_int(ent, maxp_keys[i], 0)

	# Class restrictions: TFC-standard keys
	var restrict_keys := ["maxammo_shells", "maxammo_nails", "maxammo_rockets", "maxammo_cells"]
	for i in range(4):
		if ent.has(restrict_keys[i]):
			GoalSystem.class_restrictions[i] = parse_int(ent, restrict_keys[i], 0)

	# WW-specific keys override TFC keys if present (info_wwdetect)
	for i in range(4):
		var key := "class_team%d" % (i + 1)
		if ent.has(key):
			GoalSystem.class_restrictions[i] = parse_int(ent, key, 0)

	# Team alliances (e.g. team1_allies = "2" means team 1 is allied with team 2)
	var ally_keys := ["team1_allies", "team2_allies", "team3_allies", "team4_allies"]
	for i in range(4):
		if ent.has(ally_keys[i]):
			var ally_team := parse_int(ent, ally_keys[i], 0)
			if ally_team >= 1 and ally_team <= 4:
				GoalSystem.team_allies[i] |= (1 << (ally_team - 1))

	# display_item_status* declares flag HUD status → this is a CTF/flag map, so the
	# generic "flag captured" score VOX is appropriate (see GoalSystem.announce_score).
	for k in ent.keys():
		if str(k).begins_with("display_item_status"):
			GoalSystem.display_item_status = true
			break

	# WW-specific: the map asking for combo chaos, which repurposes its GoldSrc weapon and
	# ammo pickups as random combo spellbooks. The server can still force it either way.
	if ent.has("combo_chaos"):
		GoalSystem.map_combo_chaos = parse_int(ent, "combo_chaos", 0) != 0

	broadcast_msg = ent.get("broadcast", "")

	Log.debug("info_tfdetect: teams=%d [%s] class_restrict=%s allies=%s broadcast='%s'" % [
		GoalSystem.get_team_count(),
		", ".join(GoalSystem.team_names.slice(0, GoalSystem.get_team_count())),
		GoalSystem.class_restrictions, GoalSystem.team_allies, broadcast_msg])


func _declare_team(idx: int) -> void:
	GoalSystem._declared_teams |= (1 << idx)
