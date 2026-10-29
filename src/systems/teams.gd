extends Node
## Who is on whose side, and what a viewer is told about them. One file because every question
## of friend or foe resolves through teams_friendly: a summon's target list, friendly fire, voice
## chat and the crosshair ID line all have to answer the same way about the same pair. A team
## key on a map entity is NOT one of those questions — see may_pass_team_gate. Split out of
## entity_util.gd.


## Returns true if two team numbers are the same team or allied.
## Teamless (0) is never friendly with anything.
## Use this instead of nodes_friendly() when you have raw team ints — e.g. projectiles
## that store a team value at spawn and may outlive their owner_node.
func teams_friendly(a_team: int, t_team: int) -> bool:
	if a_team == 0 or t_team == 0:
		return false
	if a_team == t_team:
		return true
	return GoalSystem.team_allies[a_team - 1] & (1 << (t_team - 1)) != 0


## May `activator` work an entity keyed to `req_team`? One rule, asked by the door itself, by the
## triggers that fire doors and by the triggers that are goals in their own right — because the
## original asks one rule too. CBaseToggle::UTIL_IsMasterTriggered is the whole criteria check
## for a trigger, a door and a button alike, and its team line is the bare
## `pev->team != pActivator->pev->team`. So this is that `==`, and an alliance is not a key:
## the original reads g_iTeamAllies in PlayerRelationship, for friendly fire and the ID line,
## and in no gate anywhere. ww_hunt allies the Hunted with his bodyguards and still keys its
## doors against them.
##
## The one body that gets past it is ours, because the siege is: a monster, marked with
## META_IGNORES_TEAM_DOORS. It is on MONSTER_TEAM, which no map keys a door to, so every base
## door is a wall to a wave and one would stop in the corridor outside. The mark is the bypass,
## not a team and not an alliance: a player's own summon carries its owner's team and obeys the
## map's keys like the owner does, and the siege's own alliance between the defending wizards
## opens nothing — it is there to stop them killing each other.
func may_pass_team_gate(activator: Node, req_team: int) -> bool:
	if req_team == 0:
		return true
	if activator == null:
		return true  # a trigger chain with no activator behind it
	if activator.has_meta(GameConsts.META_IGNORES_TEAM_DOORS):
		return true
	var team = activator.get("team")
	if team == null:
		return true  # not something that has a side; nothing to check it against
	return int(team) == req_team


## True when a summon on `team`, called up by `owner_node`, should leave `node` alone.
##
## Teams answer it whenever there are teams, and they are the whole answer — a wizard who
## changes sides becomes a target like anyone else. With no teams at all (deathmatch, or a
## /spawn with no side) the only thing a summon has to reason from is who called it up, so it
## spares its summoner and anything else that summoner called up.
##
## That second half is what the original reached for and never got working: CGiantPlant asked
## after `monster_thornbush` and `monster_spiritwizard` by classname, assigned over its own
## argument doing it, and misspelled one of the two. Owner is a property every summon already
## carries, so this needs no list of what to be friendly with and covers the next summon the
## day it is written.
func summon_spares(team: int, owner_node: Node, node: Node) -> bool:
	if teams_friendly(team, _team_of(node)):
		return true
	if team != GameConsts.Team.NONE or owner_node == null or not is_instance_valid(owner_node):
		return false
	return node == owner_node or node.get("owner_node") == owner_node


## Returns true if attacker and target are on the same team or allied (friendly fire).
## Self-damage is NOT friendly fire. Teamless (NONE/0) entities have no allies.
## Works for projectiles too — they carry a team int directly.
func nodes_friendly(attacker: Node, target: Node) -> bool:
	if attacker == target or not attacker or not target:
		return false
	return teams_friendly(_team_of(attacker), _team_of(target))


## True if both nodes are the same player: the same node, or the two bodies one player owns
## (LocalPlayer + its server puppet HostBody, sharing a peer_id). nodes_friendly() reports
## self as NOT friendly, so self-exclusion needs this separate check. peer_id 0 never matches.
func is_same_player(a: Node, b: Node) -> bool:
	if not a or not b:
		return false
	if a == b:
		return true
	if not (a is Player and b is Player):
		return false
	var pid: int = (a as Player).peer_id
	return pid > 0 and pid == (b as Player).peer_id


## Names for the summons worth calling out under a crosshair, keyed by script basename. Anything
## absent stays unnamed rather than having its script read out loud ("Func Breakable" over a
## crate) — the original only ever identified players and thornplants.
const TARGET_ID_TYPES := {
	"thornplant": "Thornplant",
	"beanstalk": "Beanstalk",
	"giant_plant": "Giant Plant",
	"skeleton": "Skeleton",
	"spirit_wiz": "Spirit Wizard",
	"wombat": "Wombat",
	"dragon": "Dragon",
}

## The crosshair ID line for `target` as `viewer` sees it: [label, relation, health_pct].
##
## relation is 1 for an ally, -1 for an enemy, and 0 when neither word means anything — a
## deathmatch where everyone is a foe, or something with no side at all. health_pct is -1 when
## the viewer may not read it: the original showed health for allies, and gave the life wizard
## a status bar that read it off everything. Over 100 is an overheal and stays as it reads.
##
## An empty label means "say nothing": world geometry, a map prop, an invisible wizard.
func target_id_line(viewer: Node, target: Node) -> Array:
	if viewer == null or target == null or not is_instance_valid(target):
		return ["", 0, -1]
	if is_same_player(viewer, target):
		return ["", 0, -1]
	var label := ""
	if target is Player:
		var player := target as Player
		# An invisible wizard is exactly the thing this line would give away.
		if not player.is_alive or player.is_invisible:
			return ["", 0, -1]
		label = NetworkManager.display_name(player.peer_id)
	else:
		label = TARGET_ID_TYPES.get(_script_basename(target), "")
		if label.is_empty():
			return ["", 0, -1]
		var caster = target.get("owner_node")
		if caster is Player and (caster as Player).peer_id != 0:
			label = "%s's %s" % [NetworkManager.display_name((caster as Player).peer_id), label]
	var relation := 0
	if nodes_friendly(viewer, target):
		relation = 1
	elif _has_side(viewer) and _has_side(target):
		relation = -1
	var health_pct := -1
	var elem: Variant = viewer.get("element")
	var reads_health: bool = relation == 1 or elem == GameConsts.Element.LIFE
	if reads_health:
		var hp: Variant = target.get("health")
		var max_hp: Variant = target.get("max_health")
		if hp != null and max_hp != null and float(max_hp) > 0.0:
			health_pct = maxi(0, int(round(float(hp) / float(max_hp) * 100.0)))
	return [label, relation, health_pct]


## "Foe" only means something when both sides exist. In deathmatch every player would wear it,
## which is noise, so a teamless pair reads as neither.
func _has_side(node: Node) -> bool:
	return _team_of(node) != GameConsts.Team.NONE


## The side `node` is on, or Team.NONE for anything that does not carry one. may_pass_team_gate
## reads the property itself instead: it has to tell "no team at all" from Team.NONE.
func _team_of(node: Node) -> int:
	var t: Variant = node.get("team")
	return int(t) if t != null else GameConsts.Team.NONE


func _script_basename(node: Node) -> String:
	var script: Script = node.get_script()
	if script == null or script.resource_path.is_empty():
		return ""
	return script.resource_path.get_file().get_basename()
