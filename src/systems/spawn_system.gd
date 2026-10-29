extends Node
# Manages player spawn points with team filtering and dynamic activation/deactivation
# for control point maps: goals can remove/restore individual spawns (by goal_no) or
# groups (by group_no) to progressively move spawn locations as points are captured.
# Spawn nodes must have team_no, goal_no, group_no properties and get_spawn_position().

# All registered spawn points
var _spawns: Array[Node3D] = []

# Teams that have at least one spawn point (bitmask, like C++ m_iGlobalTeams)
var global_teams: int = 0

# goal_no -> Node3D (for individual spawn remove/restore)
var _by_goal: Dictionary = {}

# group_no -> Array[Node3D]
var _by_group: Dictionary = {}

# Disabled spawn point set (goal_no -> true)
var _disabled_goals: Dictionary = {}

# Last spawn picked per team (team_no -> Node3D) to avoid back-to-back repeats
var _last_spawn: Dictionary = {}


func register(spawn: Node3D, goal_no: int, group_no: int) -> void:
	_spawns.append(spawn)
	var team_no: int = spawn.team_no
	if team_no >= 1 and team_no <= 4:
		global_teams |= (1 << (team_no - 1))
	if goal_no != 0:
		if _by_goal.has(goal_no):
			push_warning("SpawnSystem: duplicate spawn goal_no %d" % goal_no)
		_by_goal[goal_no] = spawn
	if group_no != 0:
		if not _by_group.has(group_no):
			_by_group[group_no] = []
		_by_group[group_no].append(spawn)


func unregister(spawn: Node3D) -> void:
	_spawns.erase(spawn)
	for key in _by_goal.keys():
		if _by_goal[key] == spawn:
			_by_goal.erase(key)
			_disabled_goals.erase(key)
	for key in _by_group.keys():
		var arr: Array = _by_group[key]
		arr.erase(spawn)
		if arr.is_empty():
			_by_group.erase(key)


func remove_spawn(goal_no: int) -> void:
	if goal_no == 0:
		return
	if _by_goal.has(goal_no):
		_disabled_goals[goal_no] = true
		Log.debug("SpawnSystem: removed spawn %d" % goal_no)


func restore_spawn(goal_no: int) -> void:
	if goal_no == 0:
		return
	_disabled_goals.erase(goal_no)
	Log.debug("SpawnSystem: restored spawn %d" % goal_no)


func is_spawn_disabled(goal_no: int) -> bool:
	return _disabled_goals.has(goal_no)


func remove_group(group_no: int) -> void:
	if group_no == 0:
		return
	if not _by_group.has(group_no):
		return
	for spawn in _by_group[group_no]:
		if spawn.goal_no != 0:
			_disabled_goals[spawn.goal_no] = true
		else:
			spawn.set_meta("disabled", true)
	Log.debug("SpawnSystem: removed group %d (%d spawns)" % [
		group_no, _by_group[group_no].size()])


func restore_group(group_no: int) -> void:
	if group_no == 0:
		return
	if not _by_group.has(group_no):
		return
	for spawn in _by_group[group_no]:
		if spawn.goal_no != 0:
			_disabled_goals.erase(spawn.goal_no)
		else:
			spawn.set_meta("disabled", false)
	Log.debug("SpawnSystem: restored group %d (%d spawns)" % [
		group_no, _by_group[group_no].size()])


func is_active(spawn: Node3D) -> bool:
	if spawn.goal_no != 0 and _disabled_goals.has(spawn.goal_no):
		return false
	return not spawn.get_meta("disabled", false)


## Returns a random active spawn point for the given team, or null.
## Falls back to team_no=0 (deathmatch/generic) spawns if no team-specific ones exist.
func get_spawn_for_team(team: int) -> Node3D:
	var candidates: Array[Node3D] = []
	for spawn in _spawns:
		if spawn.team_no == team and is_active(spawn):
			candidates.append(spawn)
	# Deathmatch fallback: use generic (team_no=0) spawns
	if candidates.is_empty():
		for spawn in _spawns:
			if spawn.team_no == 0 and is_active(spawn):
				candidates.append(spawn)
	if candidates.is_empty():
		Log.info("SpawnSystem: no active spawns for team %d (total %d)" % [team, _spawns.size()])
		return null
	# Avoid repeating the last spawn picked for this team
	var pick: Node3D
	if candidates.size() > 1 and _last_spawn.has(team):
		var filtered := candidates.filter(func(s): return s != _last_spawn[team])
		if not filtered.is_empty():
			candidates = filtered
	pick = candidates[randi() % candidates.size()]
	_last_spawn[team] = pick
	Log.info("SpawnSystem: team %d picked group %d (%d candidates)" % [
		team, pick.group_no, candidates.size()])
	return pick


## True if the team has spawns and every one is a dragonrider start
## (info_dragonrider_spawn). Such teams (ww_chasm's teams 3/4) are mount-a-dragon
## slots allied to a foot team, not foot teams themselves — bots can't play them,
## so auto-balance must skip them.
func team_is_dragonrider_only(team: int) -> bool:
	var saw_spawn := false
	for spawn in _spawns:
		if spawn.team_no != team:
			continue
		saw_spawn = true
		if not (spawn is InfoDragonriderSpawn):
			return false
	return saw_spawn


func get_all_spawns() -> Array[Node3D]:
	return _spawns


func reset() -> void:
	_spawns.clear()
	_by_goal.clear()
	_by_group.clear()
	_disabled_goals.clear()
	_last_spawn.clear()
	global_teams = 0
